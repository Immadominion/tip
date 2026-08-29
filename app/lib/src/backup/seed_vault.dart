/// Encrypting a recovery phrase so it can be stored somewhere we do not trust.
///
/// The point of a backup is that signing in on a new phone brings your wallet
/// with you. The problem is that anything a server can hand you, a server can
/// also use, so a backup the server can read is custody wearing a disguise.
///
/// So the phrase is sealed on the device with a key derived from a password
/// only the user knows, and what goes to the server is a blob it cannot open.
/// Losing the password means losing the backup. That is not a flaw to be
/// engineered around; it is the property that makes this self-custody, and the
/// UI has to say so plainly rather than implying a reset exists.
///
/// Two deliberate choices worth defending:
///
/// The KDF parameters travel inside the envelope rather than being compiled in.
/// Argon2 costs that look adequate now will look thin in three years, and a
/// blob that carries its own parameters can be re-sealed harder later without
/// stranding every backup made before the change.
///
/// Nothing identifying goes in. No address, no public key, no chain, no
/// nickname. The row is already keyed to an account, and adding the wallet
/// address beside it would hand the server the exact link between a person and
/// their on-chain history that the rest of this project exists to avoid.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Envelope format. Bump when the shape changes, never reuse.
const sealedSeedVersion = 1;

/// Argon2id cost, as of 2026.
///
/// 64 MiB, three passes, no parallelism — OWASP's second listed configuration
/// rather than its 19 MiB floor.
///
/// The floor is sized for a password guarded by a login endpoint that can rate
/// limit and lock out. This one is not: the sealed blob is held on a server, so
/// a breach of that table hands an attacker every envelope and unlimited
/// offline attempts against them. The only thing standing between a guess and a
/// recovery phrase is how long each guess takes, which makes the cost the whole
/// defence rather than one layer of several.
///
/// About a second on a mid-range phone, against well under one before. That is
/// a real cost to a backup nobody waits for, and it buys roughly a threefold
/// increase in memory and a fifty percent increase in passes against someone
/// running the same computation a million times.
///
/// Raising these again later stays safe: every blob carries the numbers it was
/// made with, so old backups keep opening at the cost they were sealed at.
const argonMemoryKib = 65536;
const argonIterations = 3;
const argonParallelism = 1;

/// Bytes of salt and nonce. Sixteen and twelve, which is what the primitives
/// want and what everyone else uses.
const saltBytes = 16;
const nonceBytes = 12;

/// The shortest password this will seal with.
///
/// Twelve. This one number is the entire strength of the backup: whoever holds
/// the blob can guess at it offline for as long as they like, and no server
/// rate limit stands in the way. A four digit PIN would be opened in seconds,
/// so the app does not offer one.
const minimumPasswordLength = 12;

class SeedVaultException implements Exception {
  const SeedVaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A recovery phrase that has been sealed, and everything needed to open it
/// again except the password.
class SealedSeed {
  const SealedSeed({
    required this.version,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  final int version;
  final int memoryKib;
  final int iterations;
  final int parallelism;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  Map<String, Object?> toJson() => {
        'v': version,
        'kdf': 'argon2id',
        'm': memoryKib,
        't': iterations,
        'p': parallelism,
        'salt': base64.encode(salt),
        'nonce': base64.encode(nonce),
        'ct': base64.encode(ciphertext),
        'mac': base64.encode(mac),
      };

  String encode() => jsonEncode(toJson());

  static SealedSeed decode(String raw) {
    late final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not an object');
      json = Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const SeedVaultException('That backup is not readable');
    }
    return fromJson(json);
  }

  static SealedSeed fromJson(Map<String, Object?> json) {
    final version = json['v'];
    if (version is! int) {
      throw const SeedVaultException('That backup is not readable');
    }
    if (version > sealedSeedVersion) {
      // Newer than this build understands. Guessing at it would either fail
      // confusingly or, worse, appear to work.
      throw const SeedVaultException(
        'This backup was made by a newer version of tip. Update the app and '
        'try again.',
      );
    }
    if (json['kdf'] != 'argon2id') {
      throw const SeedVaultException('That backup uses a method tip cannot read');
    }

    Uint8List field(String key) {
      final value = json[key];
      if (value is! String) {
        throw const SeedVaultException('That backup is incomplete');
      }
      try {
        return Uint8List.fromList(base64.decode(value));
      } on FormatException {
        throw const SeedVaultException('That backup is damaged');
      }
    }

    int number(String key) {
      final value = json[key];
      if (value is! int || value <= 0) {
        throw const SeedVaultException('That backup is incomplete');
      }
      return value;
    }

    return SealedSeed(
      version: version,
      memoryKib: number('m'),
      iterations: number('t'),
      parallelism: number('p'),
      salt: field('salt'),
      nonce: field('nonce'),
      ciphertext: field('ct'),
      mac: field('mac'),
    );
  }
}

/// How hard the password is to turn into a key.
///
/// Separated out so tests can run at a cost that finishes, since the real
/// numbers take the better part of a second by design and a suite that seals a
/// dozen times would take a minute of it. Production never passes this: the
/// default is the real cost, and a blob records the numbers it was made with,
/// so a cheap one made in a test cannot be mistaken for a real one later.
class Argon2Cost {
  const Argon2Cost({
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
  });

  final int memoryKib;
  final int iterations;
  final int parallelism;

  static const production = Argon2Cost(
    memoryKib: argonMemoryKib,
    iterations: argonIterations,
    parallelism: argonParallelism,
  );
}

class SeedVault {
  const SeedVault({this.cost = Argon2Cost.production});

  final Argon2Cost cost;

  /// Why [password] is not usable, or null if it is.
  static String? passwordProblem(String password) {
    if (password.length < minimumPasswordLength) {
      return 'Use at least $minimumPasswordLength characters. This password is '
          'the only thing protecting your backup, and nobody can reset it.';
    }

    // Length alone let `aaaaaaaaaaaa` through, which is twelve characters and
    // one guess. These reject the shapes that are long and still trivial,
    // without demanding a symbol and a capital — that rule reliably produces
    // `P@ssw0rd1`, which is worse than the passphrase it discourages.
    final distinct = password.split('').toSet().length;
    if (distinct < 5) {
      return 'Too few different characters. A few unrelated words are easier '
          'to remember and far harder to guess.';
    }

    if (_isSequential(password)) {
      return 'That is a keyboard or alphabet run, which is one of the first '
          'things a guessing program tries.';
    }

    final lower = password.toLowerCase();
    if (_commonPasswords.any((common) => lower == common)) {
      return 'That password appears on every list of common passwords.';
    }

    return null;
  }

  /// Whether the whole string steps by a constant amount, in either direction.
  ///
  /// Catches `123456789012` and `abcdefghijkl`, and their reverses, which pass
  /// both a length check and a distinct-character check while being about as
  /// guessable as a password gets.
  static bool _isSequential(String password) {
    if (password.length < 4) return false;
    final step = password.codeUnitAt(1) - password.codeUnitAt(0);
    if (step != 1 && step != -1) return false;
    for (var i = 2; i < password.length; i++) {
      if (password.codeUnitAt(i) - password.codeUnitAt(i - 1) != step) {
        return false;
      }
    }
    return true;
  }

  /// Not a wordlist, and not pretending to be one. Just the handful long enough
  /// to clear the length check, so that the most obvious answers do not.
  static const _commonPasswords = {
    'password1234',
    'passwordpassword',
    'qwertyuiop12',
    'qwertyuiopasdfgh',
    'letmeinletmein',
    'iloveyouiloveyou',
    'administrator',
    'welcome123456',
    '123456789012',
    'aaaaaaaaaaaa',
  };

  /// Seals [mnemonic] under [password].
  ///
  /// [random] exists so tests can pin a salt and a nonce. Production uses a
  /// cryptographic source, and reusing a nonce with the same key would leak
  /// the plaintext outright.
  Future<SealedSeed> seal({
    required String mnemonic,
    required String password,
    Random? random,
  }) async {
    final problem = passwordProblem(password);
    if (problem != null) throw SeedVaultException(problem);
    if (mnemonic.trim().isEmpty) {
      throw const SeedVaultException('There is nothing to back up');
    }

    final source = random ?? Random.secure();
    final salt = _bytes(saltBytes, source);
    final nonce = _bytes(nonceBytes, source);

    final key = await _deriveKey(
      password: password,
      salt: salt,
      memoryKib: cost.memoryKib,
      iterations: cost.iterations,
      parallelism: cost.parallelism,
    );

    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(mnemonic.trim()),
      secretKey: key,
      nonce: nonce,
    );

    return SealedSeed(
      version: sealedSeedVersion,
      memoryKib: cost.memoryKib,
      iterations: cost.iterations,
      parallelism: cost.parallelism,
      salt: salt,
      nonce: nonce,
      ciphertext: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Opens [sealed] with [password], or says the password is wrong.
  ///
  /// A wrong password and a tampered blob are indistinguishable here, because
  /// AES-GCM authenticates before it decrypts and both fail the same check.
  /// The message favours the far likelier of the two.
  Future<String> open({
    required SealedSeed sealed,
    required String password,
  }) async {
    final key = await _deriveKey(
      password: password,
      salt: sealed.salt,
      memoryKib: sealed.memoryKib,
      iterations: sealed.iterations,
      parallelism: sealed.parallelism,
    );

    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          sealed.ciphertext,
          nonce: sealed.nonce,
          mac: Mac(sealed.mac),
        ),
        secretKey: key,
      );
      return utf8.decode(plain);
    } on SecretBoxAuthenticationError {
      throw const SeedVaultException(
        'That password does not open this backup.',
      );
    } on FormatException {
      throw const SeedVaultException('That backup is damaged');
    }
  }

  Future<SecretKey> _deriveKey({
    required String password,
    required Uint8List salt,
    required int memoryKib,
    required int iterations,
    required int parallelism,
  }) async {
    final argon = Argon2id(
      memory: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: 32,
    );
    return argon.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }
}

Uint8List _bytes(int count, Random source) =>
    Uint8List.fromList(List<int>.generate(count, (_) => source.nextInt(256)));
