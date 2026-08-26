/// The transaction hash for a submission that carries a proof.
///
/// A private transaction is submitted as an ordinary v3 INVOKE with two extra
/// top-level fields, `proof` and `proof_facts`, that standard Starknet RPC does
/// not define. The important part is not that they ride along: it is that the
/// facts are *inside the transaction hash*, so a signature computed by a normal
/// v3 signer is a signature over a different message and the account rejects it
/// with nothing more helpful than "invalid signature".
///
/// The construction is the standard v3 hash with one element appended:
/// `poseidon(proof_facts)`, and only when the facts are non-empty. Empty facts
/// leave the hash exactly as a normal transaction's, which is what lets the
/// same code path serve both.
library;

import '../errors.dart';
import '../hashes.dart';
import '../short_string.dart';
import 'proof_invocation.dart';

/// Cairo short string `L1_GAS`, `L2_GAS`, `L1_DATA`, as the fee field expects.
const _l1Gas = 'L1_GAS';
const _l2Gas = 'L2_GAS';
const _l1DataGas = 'L1_DATA';

/// `TransactionHashPrefix::Invoke`, the short string `invoke`.
const _invokePrefix = 'invoke';

BigInt _parseFelt(String hex) {
  final digits = hex.toLowerCase().replaceFirst('0x', '');
  if (digits.isEmpty) return BigInt.zero;
  final value = BigInt.tryParse(digits, radix: 16);
  if (value == null) {
    throw ProtocolException('Not a hex felt: $hex');
  }
  return value;
}

/// One resource's contribution to the fee field: the tag, then the amount and
/// the price packed into the low bits.
BigInt _packBound(String tag, ResourceBound bound) =>
    (shortStringToFelt(tag) << (128 + 64)) +
    (_parseFelt(bound.maxAmount) << 128) +
    _parseFelt(bound.maxPricePerUnit);

/// `hash(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds)`.
///
/// The order is fixed by the protocol and is not the order the bounds are
/// written in JSON: L1, then L2, then L1 data.
BigInt hashFeeFields({
  required BigInt tip,
  required ResourceBounds bounds,
}) =>
    poseidonHash([
      tip,
      _packBound(_l1Gas, bounds.l1Gas),
      _packBound(_l2Gas, bounds.l2Gas),
      _packBound(_l1DataGas, bounds.l1DataGas),
    ]);

/// The two data availability modes packed into one felt.
BigInt packDataAvailabilityModes({
  bool nonceOnL1 = true,
  bool feeOnL1 = true,
}) =>
    (BigInt.from(nonceOnL1 ? 0 : 1) << 32) + BigInt.from(feeOnL1 ? 0 : 1);

/// The hash a proved submission must be signed over.
///
/// [proofFacts] appends one element when non-empty and nothing at all when
/// empty, which matches how the facts themselves are omitted from the
/// transaction rather than sent as an empty array.
BigInt provedInvokeTransactionHash({
  required BigInt senderAddress,
  required List<BigInt> calldata,
  required BigInt chainId,
  required BigInt nonce,
  required ResourceBounds resourceBounds,
  required List<BigInt> proofFacts,
  List<BigInt> accountDeploymentData = const [],
  List<BigInt> paymasterData = const [],
  BigInt? tip,
  bool nonceDataOnL1 = true,
  bool feeDataOnL1 = true,
}) {
  final elements = <BigInt>[
    shortStringToFelt(_invokePrefix),
    BigInt.from(3),
    senderAddress,
    hashFeeFields(tip: tip ?? BigInt.zero, bounds: resourceBounds),
    poseidonHash(paymasterData),
    chainId,
    nonce,
    packDataAvailabilityModes(
      nonceOnL1: nonceDataOnL1,
      feeOnL1: feeDataOnL1,
    ),
    poseidonHash(accountDeploymentData),
    poseidonHash(calldata),
    if (proofFacts.isNotEmpty) poseidonHash(proofFacts),
  ];

  return poseidonHash(elements);
}
