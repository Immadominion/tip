/// STARK-curve key derivation and Diffie-Hellman.
///
/// starknet.dart exposes the STARK curve and its generator point (it needs them
/// for transaction signing) but ships no key-agreement function, so this builds
/// ECDH directly on those primitives.
///
/// Checked against reference values generated from the Cairo implementation in
/// starkware-libs/starknet-privacy.
library;

import 'package:pointycastle/ecc/api.dart';
import 'package:starknet/starknet.dart';

import 'field.dart';

/// STARK curve parameter `a` in `y^2 = x^3 + a*x + b`.
BigInt get starknetCurveA => starknetCurve.a!.toBigInteger()!;

/// STARK curve parameter `b` in `y^2 = x^3 + a*x + b`.
BigInt get starknetCurveB => starknetCurve.b!.toBigInteger()!;

/// Derives the public key for [privateKey] as the x-coordinate of
/// `privateKey * G`.
///
/// The protocol only ever transmits and stores x-coordinates, so that is what
/// this returns.
BigInt derivePublicKey(BigInt privateKey) {
  if (privateKey <= BigInt.zero) {
    throw ArgumentError.value(
      privateKey,
      'privateKey',
      'Private key must be positive',
    );
  }
  final point = generatorPoint * privateKey;
  if (point == null || point.isInfinity) {
    throw ArgumentError.value(
      privateKey,
      'privateKey',
      'Private key produced the point at infinity',
    );
  }
  return point.x!.toBigInteger()!;
}

/// Recovers a curve point from a bare x-coordinate by solving
/// `y^2 = x^3 + a*x + b`.
///
/// Either square root is acceptable here. Scalar multiplication satisfies
/// `k * (x, -y) == -(k * (x, y))`, and negation only flips the y-coordinate, so
/// both roots yield the same shared x-coordinate under ECDH. That property is
/// precisely why the protocol can publish public keys as x-coordinates alone.
///
/// Throws [ArgumentError] if [x] is not on the curve.
ECPoint recoverPointFromX(BigInt x) {
  final ySquared = (x.modPow(BigInt.from(3), fieldPrime) +
          starknetCurveA * x +
          starknetCurveB) %
      fieldPrime;
  final y = modSqrt(ySquared, fieldPrime);
  if (y == null) {
    throw ArgumentError.value(
      x,
      'x',
      'x-coordinate is not on the STARK curve',
    );
  }
  return starknetCurve.createPoint(x, y);
}

/// Computes the ECDH shared secret between [privateKey] and a counterparty's
/// public key given as the x-coordinate [peerPublicKeyX].
///
/// Returns the x-coordinate of the shared point, which is what every
/// encryption in the protocol keys off.
BigInt sharedSecretX(BigInt privateKey, BigInt peerPublicKeyX) {
  final peerPoint = recoverPointFromX(peerPublicKeyX);
  final shared = peerPoint * privateKey;
  if (shared == null || shared.isInfinity) {
    throw ArgumentError(
      'ECDH produced the point at infinity for the given key pair',
    );
  }
  return shared.x!.toBigInteger()!;
}
