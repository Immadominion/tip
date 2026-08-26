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

/// Cairo `Option::None`, as the pool's ABI orders the variants.
///
/// The ABI lists `Some` before `None`, so `None` is variant 1. Getting this
/// backwards produces calldata the contract reads as a malformed attestation
/// rather than as an absent one.
const optionNone = '0x1';
const optionSome = '0x0';

/// The calldata for `apply_actions(actions, screening)`.
///
/// [messagePayload] is the L2 to L1 message the proved execution emitted, taken
/// straight from the proof. Its first felt is the pool's own class hash and the
/// rest is already a serialised `Span<ServerAction>`, so the class hash is
/// dropped and the remainder passes through untouched. Recompiling the actions
/// locally instead would be asking two parties to agree about something only
/// one of them proved.
///
/// [screening] is the attestation the prover returns for transactions the
/// compliance layer had to sign. Absent for everything else.
List<String> applyActionsCalldata({
  required List<String> messagePayload,
  ScreeningAttestationFelts? screening,
}) {
  if (messagePayload.length < 2) {
    throw const ProtocolException(
      'The proof message is too short to contain any server actions',
    );
  }
  return [
    ...messagePayload.skip(1),
    ...(screening?.encode() ?? const [optionNone]),
  ];
}

/// A screening attestation, ready to append to `apply_actions` calldata.
///
/// Kept as strings rather than as the proving client's own type so that this
/// module stays free of the service layer. The caller converts.
class ScreeningAttestationFelts {
  const ScreeningAttestationFelts({
    required this.issuedAt,
    required this.r,
    required this.s,
  });

  /// Seconds, as the contract's `u64`.
  final String issuedAt;
  final String r;
  final String s;

  /// `Option::Some(ScreeningAttestation { issued_at, signature: (r, s) })`.
  ///
  /// The signature is a Cairo tuple, which serialises as its two members in
  /// order with no length prefix.
  List<String> encode() => [optionSome, issuedAt, r, s];
}
