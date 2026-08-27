/// The randomness the protocol requires.
///
/// Every salt and blinding factor has to be unpredictable. Reusing one links
/// two transactions that should look unrelated, and a note salt is what stops
/// a reverted-then-retried transaction reusing a one-time encryption key.
///
/// This lives here rather than at each call site because it was written three
/// times in tools before it was written once, and each copy was a chance to
/// reach for the wrong generator.
library;

import 'dart:math';

import 'flows.dart';

class SecureRandomSource implements RandomSource {
  SecureRandomSource([Random? random]) : _random = random ?? Random.secure();

  /// Only pass a generator in tests. `Random()` is seeded and predictable, and
  /// a predictable salt is a linkable transaction.
  final Random _random;

  BigInt _pack(int bytes) {
    var value = BigInt.zero;
    for (var i = 0; i < bytes; i++) {
      value = (value << 8) | BigInt.from(_random.nextInt(256));
    }
    return value;
  }

  /// A full-width felt. Zero is not a usable value anywhere it is asked for,
  /// so the vanishingly rare draw of it becomes one.
  @override
  BigInt nextFelt() {
    final value = _pack(31);
    return value == BigInt.zero ? BigInt.one : value;
  }

  /// A note salt: 120 bits, and above 1.
  ///
  /// Zero means the note does not exist and one is reserved for open notes, so
  /// the contract rejects both.
  @override
  BigInt nextNoteSalt() {
    final value = _pack(15);
    return value <= BigInt.one ? BigInt.two : value;
  }
}
