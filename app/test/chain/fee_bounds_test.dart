/// Fee bounds.
///
/// The case that matters is the one that already happened on Sepolia: bounds
/// equal to the estimate, and a transaction that reverts for being eighty
/// thousand gas short while still charging the fee.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/fee_bounds.dart';

FeeEstimations _estimate({
  int l1Amount = 100,
  int l1Price = 10,
  int l1DataAmount = 50,
  int l1DataPrice = 4,
  int l2Amount = 1649040,
  int l2Price = 2,
  int overall = 4000000,
}) =>
    FeeEstimations(
      l1GasConsumed: Felt.fromInt(l1Amount),
      l1GasPrice: Felt.fromInt(l1Price),
      l1DataGasConsumed: Felt.fromInt(l1DataAmount),
      l1DataGasPrice: Felt.fromInt(l1DataPrice),
      l2GasConsumed: Felt.fromInt(l2Amount),
      l2GasPrice: Felt.fromInt(l2Price),
      overallFee: Felt.fromInt(overall),
      unit: 'FRI',
    );

void main() {
  test('raises every bound by half', () {
    final bounds = FeeBounds.from(_estimate());
    expect(bounds.l1GasConsumed.toBigInt(), equals(BigInt.from(150)));
    expect(bounds.l1GasPrice.toBigInt(), equals(BigInt.from(15)));
    expect(bounds.l1DataGasConsumed.toBigInt(), equals(BigInt.from(75)));
    expect(bounds.l1DataGasPrice.toBigInt(), equals(BigInt.from(6)));
    expect(bounds.l2GasPrice.toBigInt(), equals(BigInt.from(3)));
  });

  test('covers the overrun that reverted the first live transfer', () {
    // Estimated 1,649,040 L2 gas, execution used 1,729,040.
    final bounds = FeeBounds.from(_estimate(l2Amount: 1649040));
    expect(
      bounds.l2GasConsumed.toBigInt(),
      greaterThan(BigInt.from(1729040)),
    );
  });

  test('keeps the estimate separate from the ceiling', () {
    // The user is shown the estimate, because that is roughly what they pay.
    // The balance check uses the ceiling, because validation requires it.
    final bounds = FeeBounds.from(_estimate(overall: 4000000));
    expect(bounds.estimatedFee, equals(BigInt.from(4000000)));
    expect(bounds.maxFee, greaterThan(bounds.estimatedFee));
  });

  test('the ceiling is the sum of each resource at its bound', () {
    final bounds = FeeBounds.from(
      _estimate(
        l1Amount: 100,
        l1Price: 10,
        l1DataAmount: 50,
        l1DataPrice: 4,
        l2Amount: 1000,
        l2Price: 2,
      ),
    );
    // 150*15 + 75*6 + 1500*3
    expect(bounds.maxFee, equals(BigInt.from(150 * 15 + 75 * 6 + 1500 * 3)));
  });

  test('a zero estimate stays zero rather than becoming a floor', () {
    final bounds = FeeBounds.from(
      _estimate(
        l1Amount: 0,
        l1Price: 0,
        l1DataAmount: 0,
        l1DataPrice: 0,
        l2Amount: 0,
        l2Price: 0,
        overall: 0,
      ),
    );
    expect(bounds.maxFee, equals(BigInt.zero));
  });

  test('scales without overflowing at values a felt can hold', () {
    final big = BigInt.two.pow(120);
    final bounds = FeeBounds.from(
      FeeEstimations(
        l1GasConsumed: Felt(big),
        l1GasPrice: Felt.fromInt(1),
        l1DataGasConsumed: Felt.zero,
        l1DataGasPrice: Felt.zero,
        l2GasConsumed: Felt.zero,
        l2GasPrice: Felt.zero,
        overallFee: Felt(big),
        unit: 'FRI',
      ),
    );
    expect(bounds.l1GasConsumed.toBigInt(), equals(big * BigInt.from(3) ~/ BigInt.two));
  });

  test('the margin is configurable, and one-to-one leaves the estimate alone', () {
    final bounds = FeeBounds.from(_estimate(), numerator: 1, denominator: 1);
    expect(bounds.l2GasConsumed.toBigInt(), equals(BigInt.from(1649040)));
  });
}
