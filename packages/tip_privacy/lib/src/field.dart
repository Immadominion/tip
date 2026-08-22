/// STARK field arithmetic.
///
/// The STRK20 pool masks values by adding a Poseidon hash to the plaintext
/// modulo the STARK curve's base field prime, so field arithmetic and a
/// modular square root are foundational to the whole client.
library;

/// STARK curve base field prime: 2^251 + 17 * 2^192 + 1.
///
/// Matches `starkCurve.CURVE.Fp.ORDER` in the reference SDK.
final BigInt fieldPrime = BigInt.parse(
  '3618502788666131213697322783095070105623107215331596699973092056135872020481',
);

/// `(a + b) mod p`, always non-negative.
BigInt addMod(BigInt a, BigInt b) => (a + b) % fieldPrime;

/// `(a - b) mod p`, always non-negative.
///
/// Dart's `%` already returns a non-negative result for a positive modulus, but
/// the extra normalisation is kept explicit because this is the decrypt path and
/// a negative intermediate here would silently corrupt a note.
BigInt subMod(BigInt a, BigInt b) {
  final r = (a - b) % fieldPrime;
  return r.isNegative ? r + fieldPrime : r;
}

/// Deterministic modular square root via Tonelli-Shanks.
///
/// Returns null when [n] is not a quadratic residue mod [p].
///
/// Why this exists rather than using pointycastle's `ECFieldElement.sqrt()`:
/// that implementation is randomised (it requires a registered `SecureRandom`
/// and throws `RegistryFactoryException` without one). A non-deterministic
/// square root is the wrong primitive for wallet code, so this is implemented
/// directly.
///
/// The cheap `(p+1)/4` shortcut does not apply to the STARK prime: here
/// `p - 1 = 2^192 * (2^59 + 17)`, so the 2-adic valuation is 192 and the general
/// algorithm is required.
BigInt? modSqrt(BigInt n, BigInt p) {
  final one = BigInt.one;
  final two = BigInt.two;

  n = n % p;
  if (n == BigInt.zero) return BigInt.zero;

  // Euler's criterion.
  if (n.modPow((p - one) ~/ two, p) != one) return null;

  // Factor p - 1 = q * 2^s with q odd.
  var q = p - one;
  var s = 0;
  while (q.isEven) {
    q = q ~/ two;
    s++;
  }

  // Smallest quadratic non-residue, found deterministically.
  var z = two;
  while (z.modPow((p - one) ~/ two, p) != p - one) {
    z += one;
  }

  var m = s;
  var c = z.modPow(q, p);
  var t = n.modPow(q, p);
  var r = n.modPow((q + one) ~/ two, p);

  while (t != one) {
    var i = 0;
    var temp = t;
    while (temp != one) {
      temp = (temp * temp) % p;
      i++;
    }
    final b = c.modPow(two.pow(m - i - 1), p);
    m = i;
    c = (b * b) % p;
    t = (t * c) % p;
    r = (r * b) % p;
  }
  return r;
}
