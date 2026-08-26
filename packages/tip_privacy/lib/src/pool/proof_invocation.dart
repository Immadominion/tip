/// Building the transaction a prover is asked to prove.
///
/// The shape here is unusual and worth stating plainly. A private transaction
/// is not sent from the user's account. It is an INVOKE whose *sender is the
/// pool itself*, calling the pool's own `compile_actions`. The prover executes
/// that call and returns a proof that the execution happened as claimed; only
/// then is `apply_actions` submitted with the proof attached.
///
/// So this invocation is never broadcast. It is an argument to the prover.
library;

import '../errors.dart';
import 'actions.dart';

/// Nonce used for a proof invocation.
///
/// The invocation is not a real transaction and is never submitted, so there is
/// no account nonce to track. A fixed value keeps proof requests deterministic.
final BigInt proofInvocationNonce = BigInt.zero;

/// L2 gas limit for a proof invocation.
///
/// The prover refuses a zero limit, and says why in as many words:
///
///     l2_gas.max_amount must be non-zero, it is the gas limit enforced by the
///     OS on the transaction. Set this to the value returned by
///     starknet_estimateFee, or use 100000000 (0x5f5e100) as a safe upper
///     bound (sufficient for ~1 million Cairo steps).
///
/// The upper bound is the right default here rather than an estimate. This
/// invocation is never broadcast and never pays a fee, so the number only has
/// to be large enough for the OS to let the execution finish, and a wallet
/// asking for a fee estimate first would be a round trip spent on nothing.
const provingL2GasLimit = '0x5f5e100';

/// A resource bound pair for one gas kind.
class ResourceBound {
  const ResourceBound({required this.maxAmount, required this.maxPricePerUnit});

  static const zero = ResourceBound(maxAmount: '0x0', maxPricePerUnit: '0x0');

  /// Enough L2 gas for the pool's own execution, with room to spare.
  static const provingDefault = ResourceBound(
    maxAmount: provingL2GasLimit,
    maxPricePerUnit: '0x0',
  );

  final String maxAmount;
  final String maxPricePerUnit;

  Map<String, String> toJson() => {
        'max_amount': maxAmount,
        'max_price_per_unit': maxPricePerUnit,
      };
}

/// The v3 fee bounds carried by the invocation.
class ResourceBounds {
  const ResourceBounds({
    this.l1Gas = ResourceBound.zero,
    this.l1DataGas = ResourceBound.zero,
    this.l2Gas = ResourceBound.provingDefault,
  });

  final ResourceBound l1Gas;
  final ResourceBound l1DataGas;
  final ResourceBound l2Gas;

  Map<String, dynamic> toJson() => {
        'l1_gas': l1Gas.toJson(),
        'l1_data_gas': l1DataGas.toJson(),
        'l2_gas': l2Gas.toJson(),
      };
}

/// An INVOKE_TXN_V3 ready to hand to the proving service.
class ProofInvocation {
  const ProofInvocation({
    required this.senderAddress,
    required this.calldata,
    required this.signature,
    required this.nonce,
    required this.resourceBounds,
  });

  final String senderAddress;
  final List<String> calldata;
  final List<String> signature;
  final String nonce;
  final ResourceBounds resourceBounds;

  Map<String, dynamic> toJson() => {
        'type': 'INVOKE',
        'version': '0x3',
        'sender_address': senderAddress,
        'calldata': calldata,
        'signature': signature,
        'nonce': nonce,
        'resource_bounds': resourceBounds.toJson(),
        'tip': '0x0',
        'paymaster_data': <String>[],
        'account_deployment_data': <String>[],
        'nonce_data_availability_mode': 'L1',
        'fee_data_availability_mode': 'L1',
      };
}

String _hex(BigInt value) => '0x${value.toRadixString(16)}';

/// The inner calldata for `compile_actions(user_addr, viewing_key, actions)`.
List<BigInt> compileActionsCalldata({
  required BigInt userAddress,
  required BigInt viewingKey,
  required List<ClientAction> actions,
}) =>
    [
      userAddress,
      viewingKey,
      ...encodeActions(actions),
    ];

/// Wraps one call in the account multicall layout Starknet expects:
/// `[call_count, to, selector, calldata_len, ...calldata]`.
List<BigInt> wrapAsExecuteCalldata({
  required BigInt to,
  required BigInt selector,
  required List<BigInt> calldata,
}) =>
    [
      BigInt.one,
      to,
      selector,
      BigInt.from(calldata.length),
      ...calldata,
    ];

/// Assembles the invocation the prover is asked to prove.
///
/// [signature] is produced by signing the equivalent transaction with the
/// user's key. It is taken as a parameter rather than computed here so that
/// this stays pure and testable, and so the signer can live wherever the key
/// does.
///
/// [compileActionsSelector] is the entrypoint selector for `compile_actions`.
/// It is passed in because computing a selector needs Starknet's keccak, which
/// this module deliberately does not depend on.
ProofInvocation buildProofInvocation({
  required BigInt poolAddress,
  required BigInt userAddress,
  required BigInt viewingKey,
  required List<ClientAction> actions,
  required BigInt compileActionsSelector,
  required List<BigInt> signature,
  ResourceBounds resourceBounds = const ResourceBounds(),
  BigInt? nonce,
}) {
  if (actions.isEmpty) {
    throw const ProtocolException(
      'A proof invocation needs at least one action',
    );
  }

  final inner = compileActionsCalldata(
    userAddress: userAddress,
    viewingKey: viewingKey,
    actions: actions,
  );

  return ProofInvocation(
    // The pool is the sender. This is the part that looks wrong at a glance
    // and is not: the proof is of the pool executing its own view.
    senderAddress: _hex(poolAddress),
    calldata: wrapAsExecuteCalldata(
      to: poolAddress,
      selector: compileActionsSelector,
      calldata: inner,
    ).map(_hex).toList(),
    signature: signature.map(_hex).toList(),
    nonce: _hex(nonce ?? proofInvocationNonce),
    resourceBounds: resourceBounds,
  );
}
