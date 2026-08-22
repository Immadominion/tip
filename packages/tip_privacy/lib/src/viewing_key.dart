/// Viewing key derivation.
///
/// The viewing key is the second secret in this protocol. The account key
/// authorises spending; the viewing key decrypts the notes addressed to you.
/// Losing it means losing sight of your own balance, and leaking it means
/// someone can read your entire history, retroactively and permanently.
///
/// StarkWare's reference client derives it from a separate user-remembered
/// passphrase. This package defaults to deriving it from the same seed as the
/// account key instead, so a wallet has one secret to protect and back up
/// rather than two. The protocol permits this: it only requires that the
/// registered key be a canonical scalar, and says nothing about where that
/// scalar came from.
///
/// The passphrase form is also provided, matching the reference algorithm, so a
/// key created by another client can still be imported.
library;

import 'dart:convert';

import 'errors.dart';
import 'hashes.dart';

/// Order of the STARK curve.
final BigInt curveOrder = BigInt.parse(
  '3618502788666131213697322783095070105526743751716087489154079457884512865583',
);

/// Half the curve order. The pool's `is_canonical_key` accepts a key strictly
/// below this and rejects everything else.
final BigInt halfCurveOrder = curveOrder ~/ BigInt.two;

/// Domain tag separating our seed-derived viewing key from every other hash in
/// the protocol.
///
/// Without this, a viewing key derived from the same seed could collide with
/// some other derivation that happens to hash the same inputs.
const String viewingKeyDomainTag = 'TIP_VIEWING_KEY:V1';

/// Poseidon rounds used by the passphrase derivation.
///
/// Matches the reference client. The rounds exist to put a brute-force cost in
/// front of a low-entropy human passphrase; they do nothing meaningful for a
/// high-entropy seed, which is why the seed path below does not iterate.
const int passphraseKdfRounds = 1000;

/// Bytes packed into one felt. A felt holds 251 bits, so 31 bytes always fit.
const int _bytesPerFelt = 31;

/// Folds an arbitrary scalar into a canonical viewing key.
///
/// The pool requires `key < ORDER / 2`, so this reduces into the scalar field
/// and mirrors the upper half down. Zero and the vanishingly rare fixed points
/// fall back to 1 so that every input yields a usable, non-zero key.
BigInt canonicalViewingKey(BigInt key) {
  var scalar = key % curveOrder;
  if (scalar >= halfCurveOrder) {
    scalar = curveOrder - scalar;
  }
  if (scalar == BigInt.zero || scalar >= halfCurveOrder) {
    return BigInt.one;
  }
  return scalar;
}

/// Whether [key] is in the form the pool will accept.
bool isCanonicalViewingKey(BigInt key) =>
    key > BigInt.zero && key < halfCurveOrder;

/// Derives a viewing key from the wallet's seed.
///
/// This is the default path. [seed] is the same high-entropy secret the account
/// key comes from; the domain tag keeps the two derivations apart, and
/// [accountAddress] salts the result so the same seed used for two accounts
/// produces two unrelated viewing keys.
///
/// No iteration: the input already carries full entropy, so stretching it would
/// cost startup time and buy nothing.
BigInt deriveViewingKeyFromSeed({
  required List<int> seed,
  required BigInt accountAddress,
}) {
  if (seed.isEmpty) {
    throw const ProtocolException('Seed must not be empty');
  }
  return canonicalViewingKey(
    poseidonHash([
      viewingKeyDomainTag,
      ..._packBytes(seed),
      accountAddress,
    ]),
  );
}

/// Derives a viewing key from a user passphrase, matching the reference client.
///
/// Provided for importing a key created elsewhere. Prefer
/// [deriveViewingKeyFromSeed] for new wallets: a passphrase is a second secret
/// the user has to remember, and forgetting it costs them visibility of their
/// own money.
BigInt deriveViewingKeyFromPassphrase({
  required String passphrase,
  required BigInt accountAddress,
}) {
  var key = poseidonHash([
    ..._packUtf8WithLength(passphrase),
    accountAddress,
  ]);
  for (var round = 1; round < passphraseKdfRounds; round++) {
    key = poseidonHash([key, accountAddress]);
  }
  return canonicalViewingKey(key);
}

/// Packs bytes into big-endian felt limbs, prefixed by the byte length.
///
/// The length prefix is what makes the encoding injective. Big-endian packing
/// drops leading zero bytes inside a limb, so without it `[0, 97]` and `[97]`
/// would pack identically and derive the same key.
List<BigInt> _packBytes(List<int> bytes) {
  final felts = <BigInt>[BigInt.from(bytes.length)];
  for (var offset = 0; offset < bytes.length; offset += _bytesPerFelt) {
    var limb = BigInt.zero;
    final end = (offset + _bytesPerFelt).clamp(0, bytes.length);
    for (var i = offset; i < end; i++) {
      limb = (limb << 8) | BigInt.from(bytes[i]);
    }
    felts.add(limb);
  }
  return felts;
}

List<BigInt> _packUtf8WithLength(String value) =>
    _packBytes(utf8.encode(value));
