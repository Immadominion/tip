/// The encrypted backup.
///
/// This is the most dangerous file in the app after the keystore. A mistake
/// here either strands somebody's wallet or hands it to whoever holds the
/// blob, so the tests below care about round trips, about refusing the wrong
/// password, and about never producing the same ciphertext twice.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/backup/seed_vault.dart';
import 'package:tip/src/wallet/wallet.dart';

const _vault = SeedVault();
const _password = 'correct horse battery staple';

final _phrase = WalletFactory.generateMnemonic();

void main() {
  group('round trip', () {
    test('a sealed phrase comes back exactly', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      expect(
        await _vault.open(sealed: sealed, password: _password),
        equals(_phrase),
      );
    });

    test('it survives the trip through JSON', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      final reopened = SealedSeed.decode(sealed.encode());
      expect(
        await _vault.open(sealed: reopened, password: _password),
        equals(_phrase),
      );
    });

    test('the phrase is trimmed, not mangled', () async {
      final sealed = await _vault.seal(
        mnemonic: '  $_phrase  ',
        password: _password,
      );
      expect(
        await _vault.open(sealed: sealed, password: _password),
        equals(_phrase),
      );
    });
  });

  group('what the blob gives away', () {
    test('the phrase is nowhere in it', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      final blob = sealed.encode();
      for (final word in _phrase.split(' ')) {
        expect(blob, isNot(contains(word)), reason: word);
      }
      expect(blob, isNot(contains(_password)));
    });

    test('it carries nothing that identifies the wallet', () async {
      // No address, no public key, no chain. The row is already keyed to an
      // account, and adding the address would hand the server the link between
      // a person and their on-chain history.
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      final json = jsonDecode(sealed.encode()) as Map<String, Object?>;
      expect(
        json.keys.toSet(),
        equals({'v', 'kdf', 'm', 't', 'p', 'salt', 'nonce', 'ct', 'mac'}),
      );
    });

    test('sealing twice never produces the same ciphertext', () async {
      // A repeated nonce under the same key leaks the plaintext outright.
      final first = await _vault.seal(mnemonic: _phrase, password: _password);
      final second = await _vault.seal(mnemonic: _phrase, password: _password);

      expect(first.nonce, isNot(equals(second.nonce)));
      expect(first.salt, isNot(equals(second.salt)));
      expect(first.ciphertext, isNot(equals(second.ciphertext)));
    });

    test('it carries the cost it was made with, so costs can be raised later',
        () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      expect(sealed.memoryKib, equals(argonMemoryKib));
      expect(sealed.iterations, equals(argonIterations));
      expect(sealed.parallelism, equals(argonParallelism));
    });
  });

  group('refusing to open', () {
    test('a wrong password is refused, not silently mis-decrypted', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      expect(
        () => _vault.open(sealed: sealed, password: 'a different password'),
        throwsA(isA<SeedVaultException>()),
      );
    });

    test('a password that differs by one character is refused', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      expect(
        () => _vault.open(sealed: sealed, password: '${_password}x'),
        throwsA(isA<SeedVaultException>()),
      );
    });

    test('a tampered ciphertext is caught by the tag', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      sealed.ciphertext[0] ^= 0xff;
      expect(
        () => _vault.open(sealed: sealed, password: _password),
        throwsA(isA<SeedVaultException>()),
      );
    });

    test('a tampered salt is caught too', () async {
      final sealed = await _vault.seal(
        mnemonic: _phrase,
        password: _password,
      );
      sealed.salt[0] ^= 0xff;
      expect(
        () => _vault.open(sealed: sealed, password: _password),
        throwsA(isA<SeedVaultException>()),
      );
    });
  });

  group('the password rule', () {
    test('a short password is refused before anything is sealed', () async {
      expect(SeedVault.passwordProblem('short'), isNotNull);
      expect(
        () => _vault.seal(mnemonic: _phrase, password: 'short'),
        throwsA(isA<SeedVaultException>()),
      );
    });

    test('the minimum is exactly the advertised length', () {
      expect(SeedVault.passwordProblem('a' * minimumPasswordLength), isNull);
      expect(
        SeedVault.passwordProblem('a' * (minimumPasswordLength - 1)),
        isNotNull,
      );
    });

    test('the reason says nobody can reset it', () {
      expect(SeedVault.passwordProblem('x'), contains('nobody can reset'));
    });

    test('an empty phrase is refused', () {
      expect(
        () => _vault.seal(mnemonic: '   ', password: _password),
        throwsA(isA<SeedVaultException>()),
      );
    });
  });

  group('reading a damaged envelope', () {
    Future<String> sealedJson() async =>
        (await _vault.seal(mnemonic: _phrase, password: _password)).encode();

    test('rubbish is refused', () {
      for (final raw in ['', 'not json', '[]', '{}', '{"v":"one"}']) {
        expect(
          () => SealedSeed.decode(raw),
          throwsA(isA<SeedVaultException>()),
          reason: raw,
        );
      }
    });

    test('a missing field is refused rather than defaulted', () async {
      final json = jsonDecode(await sealedJson()) as Map<String, Object?>;
      for (final key in ['salt', 'nonce', 'ct', 'mac', 'm', 't', 'p']) {
        final broken = Map<String, Object?>.from(json)..remove(key);
        expect(
          () => SealedSeed.fromJson(broken),
          throwsA(isA<SeedVaultException>()),
          reason: 'missing $key',
        );
      }
    });

    test('a future version says to update rather than failing oddly', () async {
      final json = jsonDecode(await sealedJson()) as Map<String, Object?>;
      final future = Map<String, Object?>.from(json)
        ..['v'] = sealedSeedVersion + 1;
      expect(
        () => SealedSeed.fromJson(future),
        throwsA(
          predicate(
            (e) => e is SeedVaultException && e.message.contains('Update'),
          ),
        ),
      );
    });

    test('another KDF is refused', () async {
      final json = jsonDecode(await sealedJson()) as Map<String, Object?>;
      final other = Map<String, Object?>.from(json)..['kdf'] = 'scrypt';
      expect(
        () => SealedSeed.fromJson(other),
        throwsA(isA<SeedVaultException>()),
      );
    });
  });

  group('determinism where it is wanted', () {
    test('a pinned salt and nonce give a reproducible blob', () async {
      // Not a property of production, which uses Random.secure. This pins the
      // format so an accidental change to it shows up here rather than as
      // backups that stop opening.
      final vault = const SeedVault();
      final a = await vault.seal(
        mnemonic: 'abandon abandon abandon',
        password: _password,
        random: Random(7),
      );
      final b = await vault.seal(
        mnemonic: 'abandon abandon abandon',
        password: _password,
        random: Random(7),
      );
      expect(a.encode(), equals(b.encode()));
      expect(
        await vault.open(sealed: a, password: _password),
        equals('abandon abandon abandon'),
      );
    });
  });
}
