/// Cairo Serde encoding, limited to the types the pool's actions use.
///
/// Every value crossing into a Cairo contract is a sequence of felts. The rules
/// that matter here:
///
/// - `felt252`, `ContractAddress`, `usize`, and `u128` are each a single felt.
///   Note that `u128` is *not* a two-felt pair; only `u256` is.
/// - A struct is its fields in declaration order, with no length prefix.
/// - An enum is its zero-based variant index, then the variant's payload.
/// - A `Span<T>` or `Array<T>` is a length felt, then the elements.
library;

import '../errors.dart';

/// The STARK field prime. Every felt must be below this.
final BigInt feltPrime = BigInt.parse(
  '3618502788666131213697322783095070105623107215331596699973092056135872020481',
);

/// `2^128`, the exclusive upper bound of a `u128`.
final BigInt twoPow128Bound = BigInt.one << 128;

/// `2^120`, the exclusive upper bound the pool requires of a note salt.
final BigInt twoPow120 = BigInt.one << 120;

/// `2^32`, the exclusive upper bound of a `usize`.
final BigInt twoPow32 = BigInt.one << 32;

/// Checks that [value] is a valid felt and returns it.
BigInt felt(BigInt value, String field) {
  if (value.isNegative) {
    throw ProtocolException('$field must not be negative');
  }
  if (value >= feltPrime) {
    throw ProtocolException('$field does not fit in a felt252');
  }
  return value;
}

/// Checks that [value] fits in a Cairo `u128`.
BigInt u128(BigInt value, String field) {
  if (value.isNegative) {
    throw ProtocolException('$field must not be negative');
  }
  if (value >= twoPow128Bound) {
    throw ProtocolException('$field does not fit in a u128');
  }
  return value;
}

/// Checks that [value] fits in a Cairo `usize`.
BigInt usize(int value, String field) {
  if (value < 0) {
    throw ProtocolException('$field must not be negative');
  }
  final big = BigInt.from(value);
  if (big >= twoPow32) {
    throw ProtocolException('$field does not fit in a usize');
  }
  return big;
}

/// Encodes a `Span<felt252>`: a length felt followed by the elements.
List<BigInt> spanOfFelts(List<BigInt> values, String field) => [
      BigInt.from(values.length),
      for (var i = 0; i < values.length; i++) felt(values[i], '$field[$i]'),
    ];

/// Rejects a zero where the contract requires a non-zero value.
///
/// The pool asserts these on chain. Checking here too turns a failure that
/// would otherwise surface after proof generation into an immediate, named
/// error.
BigInt nonZero(BigInt value, String field) {
  if (value == BigInt.zero) {
    throw ProtocolException('$field must not be zero');
  }
  return value;
}
