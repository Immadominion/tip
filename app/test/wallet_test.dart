/// Key derivation from a seed phrase.
///
/// These assertions are the difference between a wallet a user can recover and
/// one that quietly derives a different, empty account after a reinstall.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart';

/// OpenZeppelin account class hash, as a stand-in for whichever account
/// contract ships.
final _classHash = Felt.fromHexString(
  '0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f',
);

const _phrase =
    'legal winner thank year wave sausage worth useful legal winner thank '
    'year wave sausage worth useful legal will';

void main() {
  final factory = WalletFactory(accountClassHash: _classHash);

  group('mnemonic generation', () {
    test('produces a 24 word phrase', () {
      expect(WalletFactory.generateMnemonic().split(' '), hasLength(24));
    });

    test('produces a different phrase every time', () {
      final phrases = List.generate(5, (_) => WalletFactory.generateMnemonic());
      expect(phrases.toSet(), hasLength(5));
    });

    test('generates phrases that validate', () {
      expect(
        WalletFactory.isValidMnemonic(WalletFactory.generateMnemonic()),
        isTrue,
      );
    });
  });

  group('mnemonic validation', () {
    test('accepts a known good phrase', () {
      expect(WalletFactory.isValidMnemonic(_phrase), isTrue);
    });

    test('rejects a phrase with a bad checksum', () {
      // Swapping the final word breaks the checksum. Catching this at import
      // is what stops a typo from silently opening an empty wallet.
      const broken =
          'legal winner thank year wave sausage worth useful legal winner '
          'thank year wave sausage worth useful legal winner';
      expect(WalletFactory.isValidMnemonic(broken), isFalse);
    });

    test('rejects a word that is not in the wordlist', () {
      expect(
        WalletFactory.isValidMnemonic('$_phrase notaword'),
        isFalse,
      );
    });

    test('rejects empty input', () {
      expect(WalletFactory.isValidMnemonic(''), isFalse);
    });
  });

  group('derivation', () {
    test('is deterministic across calls', () {
      final a = factory.deriveFrom(_phrase);
      final b = factory.deriveFrom(_phrase);

      expect(a.accountPrivateKey, equals(b.accountPrivateKey));
      expect(a.accountAddress, equals(b.accountAddress));
      expect(a.viewingKey, equals(b.viewingKey));
    });

    test('tolerates surrounding whitespace', () {
      expect(
        factory.deriveFrom('  $_phrase  ').accountAddress,
        equals(factory.deriveFrom(_phrase).accountAddress),
      );
    });

    test('a different phrase gives a different account', () {
      final other = factory.deriveFrom(WalletFactory.generateMnemonic());
      final base = factory.deriveFrom(_phrase);
      expect(other.accountAddress, isNot(equals(base.accountAddress)));
      expect(other.viewingKey, isNot(equals(base.viewingKey)));
    });

    test('rejects an invalid phrase rather than deriving nonsense', () {
      expect(
        () => factory.deriveFrom('not a real seed phrase at all'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('produces a viewing key the pool will accept', () {
      // A non-canonical key is rejected on chain, so this has to hold for every
      // wallet, not just most of them.
      for (var i = 0; i < 20; i++) {
        final keys = factory.deriveFrom(WalletFactory.generateMnemonic());
        expect(
          isCanonicalViewingKey(keys.viewingKey),
          isTrue,
          reason: 'derived a non-canonical viewing key',
        );
      }
    });

    test('the viewing key is not the account key', () {
      // They share a seed but must be independent: leaking the ability to read
      // history must not hand over the ability to spend.
      final keys = factory.deriveFrom(_phrase);
      expect(keys.viewingKey, isNot(equals(keys.accountPrivateKey.toBigInt())));
      expect(keys.viewingKey, isNot(equals(keys.accountPublicKey.toBigInt())));
    });

    test('derives a non-zero account address', () {
      expect(factory.deriveFrom(_phrase).accountAddress.toBigInt(),
          greaterThan(BigInt.zero));
    });

    test('shortens the address for display without losing the ends', () {
      final keys = factory.deriveFrom(_phrase);
      final full = keys.accountAddress.toHexString();
      final short = keys.shortAddress;

      expect(short, contains('...'));
      expect(full, startsWith(short.split('...').first));
      expect(full, endsWith(short.split('...').last));
    });
  });
}
