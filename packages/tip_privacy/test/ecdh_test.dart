/// Verifies STARK-curve key derivation and ECDH against reference values
/// generated from the Cairo implementation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/cairo-reference-data.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  final inputs = fixture['inputs'] as Map<String, dynamic>;
  final outputs = fixture['outputs'] as Map<String, dynamic>;

  final recipientPrivateKey = _felt(inputs['recipientPrivateKey'] as String);
  final auditorPrivateKey = _felt(inputs['auditorPrivateKey'] as String);
  final ephemeralSecret = _felt(inputs['ephemeralSecret'] as String);

  group('derivePublicKey', () {
    test('matches the Cairo reference for the recipient key', () {
      expect(
        derivePublicKey(recipientPrivateKey),
        equals(_felt(inputs['recipientPublicKeyDerived'] as String)),
      );
    });

    test('matches the Cairo reference for the auditor key', () {
      expect(
        derivePublicKey(auditorPrivateKey),
        equals(_felt(inputs['auditorPublicKey'] as String)),
      );
    });

    test('matches the Cairo reference for the ephemeral key', () {
      expect(
        derivePublicKey(ephemeralSecret),
        equals(_felt(outputs['encChannelEphemeralPubkey'] as String)),
      );
    });

    test('rejects a non-positive private key', () {
      expect(() => derivePublicKey(BigInt.zero), throwsA(isA<ArgumentError>()));
      expect(
        () => derivePublicKey(BigInt.from(-1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('recoverPointFromX', () {
    test('recovers a point that is actually on the curve', () {
      final x = derivePublicKey(recipientPrivateKey);
      final point = recoverPointFromX(x);
      expect(point.x!.toBigInteger(), equals(x));

      // y^2 == x^3 + ax + b must hold for the recovered point.
      final y = point.y!.toBigInteger()!;
      final a = point.curve.a!.toBigInteger()!;
      final b = point.curve.b!.toBigInteger()!;
      expect(
        (y * y) % fieldPrime,
        equals((x.modPow(BigInt.from(3), fieldPrime) + a * x + b) % fieldPrime),
      );
    });

    test('rejects an x-coordinate that is not on the curve', () {
      // Search for a value with no square root rather than assuming one, since
      // roughly half of all field elements are non-residues.
      BigInt? offCurve;
      for (var candidate = BigInt.two;
          candidate < BigInt.from(200);
          candidate += BigInt.one) {
        final a = starknetCurveA;
        final b = starknetCurveB;
        final ySquared =
            (candidate.modPow(BigInt.from(3), fieldPrime) + a * candidate + b) %
                fieldPrime;
        if (modSqrt(ySquared, fieldPrime) == null) {
          offCurve = candidate;
          break;
        }
      }
      expect(offCurve, isNotNull,
          reason: 'expected to find an off-curve x-coordinate to test with');
      expect(
        () => recoverPointFromX(offCurve!),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ECDH', () {
    test('both parties derive the same shared secret', () {
      final recipientPublicKey = derivePublicKey(recipientPrivateKey);
      final ephemeralPublicKey = derivePublicKey(ephemeralSecret);

      final fromSender = sharedSecretX(ephemeralSecret, recipientPublicKey);
      final fromRecipient =
          sharedSecretX(recipientPrivateKey, ephemeralPublicKey);

      expect(fromSender, equals(fromRecipient));
    });

    test('a different key produces a different shared secret', () {
      final recipientPublicKey = derivePublicKey(recipientPrivateKey);
      final auditorPublicKey = derivePublicKey(auditorPrivateKey);

      expect(
        sharedSecretX(ephemeralSecret, recipientPublicKey),
        isNot(equals(sharedSecretX(ephemeralSecret, auditorPublicKey))),
      );
    });
  });

  group('modSqrt', () {
    test('returns a genuine square root', () {
      final n = BigInt.from(4);
      final root = modSqrt(n, fieldPrime);
      expect(root, isNotNull);
      expect((root! * root) % fieldPrime, equals(n));
    });

    test('is deterministic across calls', () {
      final n = BigInt.from(9);
      expect(modSqrt(n, fieldPrime), equals(modSqrt(n, fieldPrime)));
    });

    test('handles zero', () {
      expect(modSqrt(BigInt.zero, fieldPrime), equals(BigInt.zero));
    });
  });
}
