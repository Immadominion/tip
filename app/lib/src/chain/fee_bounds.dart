/// Turning a fee estimate into the bounds a transaction is signed with.
///
/// An estimate is what the transaction would cost if it ran right now against
/// the state the node used. By the time it executes, gas prices have moved and
/// validation has run for real, and it costs more. Signing for exactly the
/// estimate produces a transaction that reverts and still charges the fee.
///
/// There is a second reason this file exists. `starknet.dart` accepts a
/// `feeMultiplier` and applies it as `Felt.fromDouble(1.2)`, which is
/// `BigInt.from(1.2)`, which is 1. Every multiplier below two is silently
/// discarded, so the safety margin the SDK appears to add is not there. A
/// 0.1 STRK transfer on Sepolia reverted on exactly this: estimated 1,649,040
/// L2 gas, used 1,729,040.
library;

import 'package:starknet/starknet.dart';

/// Headroom over the estimate, as a fraction.
///
/// Fifty percent on both the amounts and the prices, matching what starknet.js
/// settled on for v3 transactions. It is a ceiling, not a charge: the account
/// pays what execution actually uses, and the only cost of a generous ceiling
/// is that the balance has to cover it.
const feeMarginNumerator = 3;
const feeMarginDenominator = 2;

class FeeBounds {
  const FeeBounds({
    required this.l1GasConsumed,
    required this.l1GasPrice,
    required this.l1DataGasConsumed,
    required this.l1DataGasPrice,
    required this.l2GasConsumed,
    required this.l2GasPrice,
    required this.estimatedFee,
  });

  /// Applies the margin to [estimate].
  factory FeeBounds.from(
    FeeEstimations estimate, {
    int numerator = feeMarginNumerator,
    int denominator = feeMarginDenominator,
  }) {
    Felt scale(Felt value) => Felt(
          value.toBigInt() * BigInt.from(numerator) ~/ BigInt.from(denominator),
        );

    return FeeBounds(
      l1GasConsumed: scale(estimate.l1GasConsumed),
      l1GasPrice: scale(estimate.l1GasPrice),
      l1DataGasConsumed: scale(estimate.l1DataGasConsumed),
      l1DataGasPrice: scale(estimate.l1DataGasPrice),
      l2GasConsumed: scale(estimate.l2GasConsumed),
      l2GasPrice: scale(estimate.l2GasPrice),
      estimatedFee: estimate.overallFee.toBigInt(),
    );
  }

  final Felt l1GasConsumed;
  final Felt l1GasPrice;
  final Felt l1DataGasConsumed;
  final Felt l1DataGasPrice;
  final Felt l2GasConsumed;
  final Felt l2GasPrice;

  /// What the transaction is expected to cost, unmargined. This is the number
  /// worth showing a user, because it is close to what they will be charged.
  final BigInt estimatedFee;

  /// The most this transaction can cost. The account must hold at least this
  /// much or validation rejects it, so this is the number the balance check
  /// has to use even though the user will not pay it.
  BigInt get maxFee =>
      l1GasConsumed.toBigInt() * l1GasPrice.toBigInt() +
      l1DataGasConsumed.toBigInt() * l1DataGasPrice.toBigInt() +
      l2GasConsumed.toBigInt() * l2GasPrice.toBigInt();
}
