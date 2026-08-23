/// Claim links.
///
/// A claim link is bearer money in a URL, so the two properties that matter
/// are that the same secret always reaches the same address, and that a link
/// which has been mangled in transit is refused rather than silently pointing
/// somewhere else.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/chain/address.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_link.dart';

final _classHash = TipNetwork.sepolia.accountClassHash;

ClaimKey _key([int seed = 1]) => ClaimLinks.create(
      accountClassHash: _classHash,
      random: Random(seed),
    );

void main() {
  group('creation', () {
    test('the secret is the advertised length', () {
      expect(_key().secret, hasLength(claimSecretBytes));
    });

    test('the same secret always reaches the same address', () {
      final first = _key(42);
      final second = ClaimLinks.fromSecret(
        secret: first.secret,
        accountClassHash: _classHash,
      );
      expect(second.address, equals(first.address));
      expect(second.privateKey, equals(first.privateKey));
    });

    test('different secrets reach different addresses', () {
      expect(_key(1).address, isNot(equals(_key(2).address)));
    });

    test('the address is one Starknet will accept', () {
      for (var seed = 0; seed < 20; seed++) {
        final key = _key(seed);
        expect(
          () => StarknetAddress.parse(key.address.toHexString()),
          returnsNormally,
          reason: 'seed $seed',
        );
      }
    });

    test('the key is derived from the secret, not equal to it', () {
      final key = _key();
      final asNumber = BigInt.parse(
        key.secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16,
      );
      expect(key.privateKey.toBigInt(), isNot(equals(asNumber)));
    });

    test('a secret of all zeros still yields a usable key', () {
      final key = ClaimLinks.fromSecret(
        secret: Uint8List(claimSecretBytes),
        accountClassHash: _classHash,
      );
      expect(key.privateKey.toBigInt(), greaterThan(BigInt.zero));
      expect(key.address.toBigInt(), greaterThan(BigInt.zero));
    });

    test('an empty secret is refused', () {
      expect(
        () => ClaimLinks.fromSecret(
          secret: Uint8List(0),
          accountClassHash: _classHash,
        ),
        throwsA(isA<ClaimLinkException>()),
      );
    });
  });

  group('the link', () {
    test('carries the secret in the fragment, not the query', () {
      // A fragment is never sent to the server, so opening the link cannot
      // put the claim code in someone's access log.
      final link = _key().link();
      expect(link.fragment, isNotEmpty);
      expect(link.query, isEmpty);
      expect(link.host, equals(claimLinkHost));
      expect(link.scheme, equals('https'));
    });

    test('the token is URL safe and unpadded', () {
      final token = _key().token;
      expect(token, isNot(contains('=')));
      expect(token, isNot(contains('+')));
      expect(token, isNot(contains('/')));
    });

    test('a link round-trips back to the same address', () {
      final key = _key(7);
      final parsed = ClaimLinks.parse(
        key.link().toString(),
        accountClassHash: _classHash,
      );
      expect(parsed.address, equals(key.address));
    });
  });

  group('parsing', () {
    test('accepts a bare token, because people paste that too', () {
      final key = _key(3);
      expect(
        ClaimLinks.parse(key.token, accountClassHash: _classHash).address,
        equals(key.address),
      );
    });

    test('accepts a token a client has re-padded', () {
      final key = _key(4);
      expect(
        ClaimLinks.parse('${key.token}==', accountClassHash: _classHash)
            .address,
        equals(key.address),
      );
    });

    test('accepts the query form, since some clients rewrite fragments', () {
      final key = _key(5);
      expect(
        ClaimLinks.parse(
          'https://$claimLinkHost$claimLinkPath?c=${key.token}',
          accountClassHash: _classHash,
        ).address,
        equals(key.address),
      );
    });

    test('tolerates whitespace around a pasted link', () {
      final key = _key(6);
      expect(
        ClaimLinks.parse('  ${key.link()}\n', accountClassHash: _classHash)
            .address,
        equals(key.address),
      );
    });

    test('refuses a link with no code in it', () {
      expect(
        () => ClaimLinks.parse(
          'https://$claimLinkHost$claimLinkPath',
          accountClassHash: _classHash,
        ),
        throwsA(isA<ClaimLinkException>()),
      );
    });

    test('refuses a truncated code rather than pointing somewhere else', () {
      // The failure this prevents: a chat client cutting the link short, and
      // the app cheerfully deriving a different, empty address.
      final key = _key(8);
      expect(
        () => ClaimLinks.parse(
          key.token.substring(0, 10),
          accountClassHash: _classHash,
        ),
        throwsA(isA<ClaimLinkException>()),
      );
    });

    test('refuses something that is not base64 at all', () {
      expect(
        () => ClaimLinks.parse('!!!!', accountClassHash: _classHash),
        throwsA(isA<ClaimLinkException>()),
      );
    });

    test('refuses an empty paste', () {
      expect(
        () => ClaimLinks.parse('   ', accountClassHash: _classHash),
        throwsA(isA<ClaimLinkException>()),
      );
    });

    test('tryParse returns null instead of throwing', () {
      expect(ClaimLinks.tryParse('nope', accountClassHash: _classHash), isNull);
      expect(
        ClaimLinks.tryParse(_key().token, accountClassHash: _classHash),
        isNotNull,
      );
    });
  });
}
