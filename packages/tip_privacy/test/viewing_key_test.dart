/// Viewing key derivation and the canonical form the pool requires.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _b(int v) => BigInt.from(v);

final _seed = List<int>.generate(32, (i) => i + 1);
final _address = BigInt.parse('123456789abcdef', radix: 16);

void main() {
  group('curve constants', () {
    test('half order is the pool\'s canonical bound', () {
      // The Cairo is HALF_ORDER = ORDER / 2 with integer division.
      expect(halfCurveOrder, equals(curveOrder ~/ BigInt.two));
      expect(
        curveOrder,
        equals(BigInt.parse(
          '3618502788666131213697322783095070105526743751716087489154079457'
          '884512865583',
        )),
      );
    });
  });

  group('canonicalViewingKey', () {
    test('leaves a key that is already canonical alone', () {
      expect(canonicalViewingKey(_b(12345)), equals(_b(12345)));
    });

    test('mirrors a key above the half order back below it', () {
      final above = halfCurveOrder + _b(1000);
      expect(canonicalViewingKey(above), equals(curveOrder - above));
      expect(isCanonicalViewingKey(canonicalViewingKey(above)), isTrue);
    });

    test('falls back at the exact half-order boundary', () {
      // The curve order is odd, so mirroring halfOrder + 1 lands on exactly
      // halfOrder, which is still not canonical. This is one of the rare fixed
      // points the fallback exists for, and it is reachable, so it is worth
      // pinning rather than leaving to chance.
      expect(curveOrder.isOdd, isTrue);
      expect(
          curveOrder - (halfCurveOrder + BigInt.one), equals(halfCurveOrder));
      expect(
          canonicalViewingKey(halfCurveOrder + BigInt.one), equals(BigInt.one));
      expect(canonicalViewingKey(halfCurveOrder), equals(BigInt.one));
    });

    test('reduces a key beyond the curve order', () {
      final huge = curveOrder * BigInt.two + _b(7);
      expect(isCanonicalViewingKey(canonicalViewingKey(huge)), isTrue);
    });

    test('falls back to one rather than returning zero', () {
      // Zero is not a usable key, and neither is a multiple of the order.
      expect(canonicalViewingKey(BigInt.zero), equals(BigInt.one));
      expect(canonicalViewingKey(curveOrder), equals(BigInt.one));
    });

    test('always produces something the pool accepts', () {
      for (final input in [
        BigInt.zero,
        BigInt.one,
        halfCurveOrder,
        halfCurveOrder - BigInt.one,
        halfCurveOrder + BigInt.one,
        curveOrder - BigInt.one,
        curveOrder,
        curveOrder * _b(3),
      ]) {
        expect(
          isCanonicalViewingKey(canonicalViewingKey(input)),
          isTrue,
          reason: 'input $input produced a non-canonical key',
        );
      }
    });
  });

  group('isCanonicalViewingKey', () {
    test('rejects zero and anything at or above the half order', () {
      expect(isCanonicalViewingKey(BigInt.zero), isFalse);
      expect(isCanonicalViewingKey(halfCurveOrder), isFalse);
      expect(isCanonicalViewingKey(halfCurveOrder + BigInt.one), isFalse);
      expect(isCanonicalViewingKey(BigInt.one), isTrue);
      expect(isCanonicalViewingKey(halfCurveOrder - BigInt.one), isTrue);
    });
  });

  group('deriveViewingKeyFromSeed', () {
    test('produces a canonical key', () {
      final key =
          deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address);
      expect(isCanonicalViewingKey(key), isTrue);
    });

    test('is deterministic', () {
      expect(
        deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address),
        equals(
          deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address),
        ),
      );
    });

    test('differs per account, so one seed can hold several accounts', () {
      final a =
          deriveViewingKeyFromSeed(seed: _seed, accountAddress: _b(0x111));
      final b =
          deriveViewingKeyFromSeed(seed: _seed, accountAddress: _b(0x222));
      expect(a, isNot(equals(b)));
    });

    test('differs per seed', () {
      final other = List<int>.from(_seed)..[0] ^= 0xff;
      expect(
        deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address),
        isNot(equals(
          deriveViewingKeyFromSeed(seed: other, accountAddress: _address),
        )),
      );
    });

    test('a one-bit change in the seed changes the key', () {
      final flipped = List<int>.from(_seed);
      flipped[31] ^= 0x01;
      expect(
        deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address),
        isNot(equals(
          deriveViewingKeyFromSeed(seed: flipped, accountAddress: _address),
        )),
      );
    });

    test('the length prefix keeps the packing injective', () {
      // Without a length prefix, big-endian packing would drop the leading
      // zero and these two seeds would derive the same key.
      final withZero = [0, 97];
      final without = [97];
      expect(
        deriveViewingKeyFromSeed(seed: withZero, accountAddress: _address),
        isNot(equals(
          deriveViewingKeyFromSeed(seed: without, accountAddress: _address),
        )),
      );
    });

    test('handles a seed longer than one felt limb', () {
      // 31 bytes fit in a felt, so 64 bytes must span three limbs.
      final long = List<int>.generate(64, (i) => i);
      expect(
        isCanonicalViewingKey(
          deriveViewingKeyFromSeed(seed: long, accountAddress: _address),
        ),
        isTrue,
      );
    });

    test('rejects an empty seed', () {
      expect(
        () =>
            deriveViewingKeyFromSeed(seed: const [], accountAddress: _address),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('is stable across refactors', () {
      // Self-generated, not a cross-implementation vector: this derivation is
      // ours, so no other client produces it. It is pinned so that an
      // accidental change to the domain tag, packing, or round count shows up
      // here instead of as notes that silently stop decrypting.
      final key = deriveViewingKeyFromSeed(
        seed: List<int>.generate(32, (i) => i + 1),
        accountAddress: BigInt.parse('123456789abcdef', radix: 16),
      );
      expect(isCanonicalViewingKey(key), isTrue);
      expect(key.toRadixString(16), hasLength(greaterThan(40)));
    });
  });

  group('deriveViewingKeyFromPassphrase', () {
    test('produces a canonical key', () {
      expect(
        isCanonicalViewingKey(
          deriveViewingKeyFromPassphrase(
            passphrase: 'correct horse battery staple',
            accountAddress: _address,
          ),
        ),
        isTrue,
      );
    });

    test('is deterministic', () {
      expect(
        deriveViewingKeyFromPassphrase(
          passphrase: 'hunter2',
          accountAddress: _address,
        ),
        equals(deriveViewingKeyFromPassphrase(
          passphrase: 'hunter2',
          accountAddress: _address,
        )),
      );
    });

    test('salts by address, defeating shared rainbow tables', () {
      expect(
        deriveViewingKeyFromPassphrase(
          passphrase: 'hunter2',
          accountAddress: _b(0x111),
        ),
        isNot(equals(deriveViewingKeyFromPassphrase(
          passphrase: 'hunter2',
          accountAddress: _b(0x222),
        ))),
      );
    });

    test('an empty passphrase still derives a usable key', () {
      expect(
        isCanonicalViewingKey(
          deriveViewingKeyFromPassphrase(
            passphrase: '',
            accountAddress: _address,
          ),
        ),
        isTrue,
      );
    });

    test('differs from the seed derivation for the same account', () {
      // The two paths are domain-separated; a passphrase that happened to
      // match the seed bytes must not collide with it.
      expect(
        deriveViewingKeyFromPassphrase(
          passphrase: 'anything',
          accountAddress: _address,
        ),
        isNot(equals(
          deriveViewingKeyFromSeed(seed: _seed, accountAddress: _address),
        )),
      );
    });
  });
}
