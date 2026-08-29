/// One wallet's connection to the STRK20 pool.
///
/// Every private operation follows the same four steps: read what the pool
/// already holds, build the actions, prove them, and submit the compiled
/// result. This is that sequence, with the parts that are easy to get wrong
/// written down once rather than at each call site.
///
/// The awkward details it hides:
///
/// A proof must be based on a block behind the head, because the node refuses
/// one that is too recent and blocks keep arriving while the proof is built.
///
/// The signature covers the proof facts. A transaction signed without them is
/// signed over a different message, and the account rejects it saying only
/// "invalid signature".
///
/// The pool takes both a deposit and its fee with `transfer_from`, so anything
/// that moves value in has to approve first, in the same multicall.
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

import '../wallet/wallet.dart';
import 'pool_config.dart';

/// Something the pool or one of its services refused.
class PoolException implements Exception {
  const PoolException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message: $detail';
}

/// What a completed private operation produced.
class PoolSubmission {
  const PoolSubmission({required this.transactionHash, required this.proof});

  final Felt transactionHash;
  final tp.ProofResult proof;
}


/// How a submitted transaction ended.
///
/// This used to be the raw execution-status string, with `'PENDING'` invented
/// for a timeout. Every result screen then compared against `'SUCCEEDED'` and
/// rendered anything else as "the transaction reverted and the fee was still
/// charged" — which for a timeout is simply false. The transaction was accepted
/// and is very likely to land; what ran out was our patience, not the
/// transaction. A type makes the third case impossible to forget.
enum Settlement {
  succeeded,
  reverted,

  /// Not an outcome: we stopped waiting. Says nothing about whether it lands.
  pending;

  factory Settlement.fromExecutionStatus(String status) => switch (status) {
        'SUCCEEDED' => Settlement.succeeded,
        'REVERTED' => Settlement.reverted,
        // An unrecognised status is not a revert. Starknet has added execution
        // statuses before and treating a new one as failure would tell the user
        // their money is gone when it is not.
        _ => Settlement.pending,
      };

  bool get isSuccess => this == Settlement.succeeded;
  bool get isReverted => this == Settlement.reverted;
  bool get isPending => this == Settlement.pending;
}

class PoolSession {
  PoolSession({
    required this.config,
    required this.keys,
    required this.chainId,
    required this.feeToken,
  });

  final PoolConfig config;
  final WalletKeys keys;
  final Felt chainId;

  /// The token the pool's own fee is denominated in.
  final BigInt feeToken;

  BigInt get _self => keys.accountAddress.toBigInt();
  BigInt get _viewingKey => keys.viewingKey;

  // ---- reading ---------------------------------------------------------

  /// The public key the pool holds for [address], or zero when unregistered.
  Future<BigInt> registeredPublicKey(BigInt address) async =>
      _felt((await call('get_public_key', [_hex(address)])).first);

  Future<bool> isRegistered(BigInt address) async =>
      (await registeredPublicKey(address)) != BigInt.zero;

  Future<BigInt> feeAmount() async =>
      _felt((await call('get_fee_amount', const [])).first);

  Future<bool> channelExists(BigInt marker) async =>
      _felt((await call('channel_exists', [_hex(marker)])).first) !=
      BigInt.zero;

  Future<bool> subchannelExists(BigInt marker) async =>
      _felt((await call('subchannel_exists', [_hex(marker)])).first) !=
      BigInt.zero;

  Future<bool> nullifierExists(BigInt nullifier) async =>
      _felt((await call('nullifier_exists', [_hex(nullifier)])).first) !=
      BigInt.zero;

  /// How many notes a channel already holds for a token.
  Future<int> noteCount({
    required BigInt channelKey,
    required BigInt token,
  }) =>
      tp.countOccupiedSlots(
        exists: (id) async =>
            _felt((await call('get_note', [_hex(id)])).first) != BigInt.zero,
        idFor: (index) => tp.computeNoteId(
          channelKey: channelKey,
          token: token,
          index: index,
        ),
      );

  Future<int> subchannelCount(BigInt channelKey) => tp.countOccupiedSlots(
        exists: (id) async =>
            _felt((await call('get_subchannel_info', [_hex(id)])).first) !=
            BigInt.zero,
        idFor: (index) =>
            tp.computeSubchannelId(channelKey: channelKey, index: index),
      );

  Future<int> outgoingChannelCount() => tp.countOccupiedSlots(
        exists: (id) async =>
            _felt(
              (await call('get_outgoing_channel_info', [_hex(id)])).first,
            ) !=
            BigInt.zero,
        idFor: (index) => tp.computeOutgoingChannelId(
          senderAddr: _self,
          senderPrivateKey: _viewingKey,
          index: index,
        ),
      );

  /// The channel this wallet pays [recipient] through, and its markers.
  ///
  /// Derived, not looked up. A channel key is a hash of both parties, so the
  /// sender can compute it before the channel exists, which is what makes
  /// opening it in the same batch as the first note possible.
  ChannelRef channelTo({
    required BigInt recipient,
    required BigInt recipientPublicKey,
    required BigInt token,
  }) {
    final key = tp.computeChannelKey(
      senderAddr: _self,
      senderPrivateKey: _viewingKey,
      recipientAddr: recipient,
      recipientPublicKey: recipientPublicKey,
    );
    return ChannelRef(
      key: key,
      recipient: recipient,
      recipientPublicKey: recipientPublicKey,
      token: token,
      channelMarker: tp.computeChannelMarker(
        channelKey: key,
        senderAddr: _self,
        recipientAddr: recipient,
        recipientPublicKey: recipientPublicKey,
      ),
      subchannelMarker: tp.computeSubchannelMarker(
        channelKey: key,
        recipientAddr: recipient,
        recipientPublicKey: recipientPublicKey,
        token: token,
      ),
    );
  }

  // ---- proving ---------------------------------------------------------

  /// Proves [actions], based on a block far enough behind the head.
  Future<tp.ProofResult> prove(List<tp.ClientAction> actions) async {
    if (actions.isEmpty) {
      throw const PoolException('There is nothing to prove');
    }

    final inner = tp.compileActionsCalldata(
      userAddress: _self,
      viewingKey: _viewingKey,
      actions: actions,
    );

    const bounds = tp.ResourceBounds(
      l2Gas: tp.ResourceBound(
        maxAmount: tp.provingL2GasLimit,
        maxPricePerUnit: '0x0',
      ),
    );

    final hash = tp.provedInvokeTransactionHash(
      senderAddress: config.poolAddress,
      calldata: tp.wrapAsExecuteCalldata(
        to: config.poolAddress,
        selector: getSelectorByName('compile_actions').toBigInt(),
        calldata: inner,
      ),
      chainId: chainId.toBigInt(),
      nonce: tp.proofInvocationNonce,
      resourceBounds: bounds,
      proofFacts: const [],
    );

    final signature =
        await StarkSigner(privateKey: keys.accountPrivateKey)
            .sign(hash, BigInt.from(32));

    final invocation = tp.buildProofInvocation(
      poolAddress: config.poolAddress,
      userAddress: _self,
      viewingKey: _viewingKey,
      actions: actions,
      compileActionsSelector:
          getSelectorByName('compile_actions').toBigInt(),
      signature: signature.map((f) => f.toBigInt()).toList(),
      resourceBounds: bounds,
    );

    final head = await blockNumber();
    // Over OHTTP: a proving request carries the whole transaction about to be
    // submitted, so a plain transport tells whoever terminates TLS exactly
    // what is coming and when.
    final client = tp.ProvingClient(transport: _proverTransport());
    try {
      return await client.proveTransaction(
        blockId: {'block_number': tp.provingBlockFor(head)},
        transaction: invocation.toJson(),
      );
    } finally {
      client.close();
    }
  }

  /// Whether the proving service is answering.
  ///
  /// Worth asking before a user composes a transfer rather than after. Proving
  /// is the slowest step and the one most likely to be down, since it is the
  /// piece a wallet cannot host, and finding out at the end costs a minute of
  /// somebody's attention to arrive at the same answer this gets in a second.
  ///
  /// Never throws. An unreachable prover is the thing being reported, not a
  /// failure of the reporting.
  Future<bool> proverReachable() async {
    final client = tp.ProvingClient(
      transport: _proverTransport(timeout: const Duration(seconds: 10)),
      retryPolicy: tp.ProvingRetryPolicy.none,
    );
    try {
      return await client.isHealthy();
    } on Object {
      return false;
    } finally {
      client.close();
    }
  }

  // ---- submitting ------------------------------------------------------

  /// Applies a proof on chain.
  ///
  /// [approve] is what the pool is allowed to take with `transfer_from`: its
  /// own fee, plus whatever a deposit in the batch moves in. Zero for
  /// operations that only move value around inside the pool.
  Future<PoolSubmission> submit({
    required tp.ProofResult proof,
    required BigInt approve,
  }) async {
    final applyCalldata = tp.applyActionsCalldata(
      messagePayload: proof.serverActionsFor(config.poolHex),
      screening: proof.screeningSignature == null
          ? null
          : tp.ScreeningAttestationFelts(
              issuedAt: _hex(BigInt.from(proof.screeningSignature!.issuedAt)),
              r: proof.screeningSignature!.r,
              s: proof.screeningSignature!.s,
            ),
    );

    final calls = <FunctionCall>[
      if (approve > BigInt.zero)
        FunctionCall(
          contractAddress: Felt(feeToken),
          entryPointSelector: getSelectorByName('approve'),
          calldata: [Felt(config.poolAddress), Felt(approve), Felt.zero],
        ),
      FunctionCall(
        contractAddress: Felt(config.poolAddress),
        entryPointSelector: getSelectorByName('apply_actions'),
        calldata: applyCalldata.map(Felt.fromHexString).toList(),
      ),
    ];

    final nonce = Felt.fromHexString(
      await _rpcResult('starknet_getNonce', [
        'latest',
        keys.accountAddress.toHexString(),
      ]) as String,
    );

    final bounds = await _submissionBounds();
    final calldata =
        functionCallsToCalldata(functionCalls: calls, useLegacyCalldata: false);

    // Over our own hash, because the proof facts belong inside it.
    final hash = tp.provedInvokeTransactionHash(
      senderAddress: _self,
      calldata: calldata.map((f) => f.toBigInt()).toList(),
      chainId: chainId.toBigInt(),
      nonce: nonce.toBigInt(),
      resourceBounds: bounds,
      proofFacts: proof.proofFacts.map(_felt).toList(),
    );
    final signature = await StarkSigner(privateKey: keys.accountPrivateKey)
        .sign(hash, BigInt.from(32));

    final response = await _rpc('starknet_addInvokeTransaction', [
      {
        'type': 'INVOKE',
        'version': '0x3',
        'sender_address': keys.accountAddress.toHexString(),
        'calldata': calldata.map((f) => f.toHexString()).toList(),
        'signature': signature.map((f) => f.toHexString()).toList(),
        'nonce': nonce.toHexString(),
        'resource_bounds': bounds.toJson(),
        'tip': tp.requiredTip,
        'paymaster_data': <String>[],
        'account_deployment_data': <String>[],
        'nonce_data_availability_mode': 'L1',
        'fee_data_availability_mode': 'L1',
        ...tp.proofFields(proofFacts: proof.proofFacts, proof: proof.proof),
      },
    ]);

    if (response['error'] != null) {
      throw PoolException(
        'The node refused the transaction',
        detail: jsonEncode(response['error']),
      );
    }

    return PoolSubmission(
      transactionHash:
          Felt.fromHexString((response['result'] as Map)['transaction_hash'] as String),
      proof: proof,
    );
  }

  /// Waits for a submitted transaction to settle.
  Future<Settlement> awaitSettled(
    Felt hash, {
    Duration timeout = const Duration(minutes: 5),
    Duration interval = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final response =
          await _rpc('starknet_getTransactionStatus', [hash.toHexString()]);
      final result = response['result'];
      if (result is Map) {
        final execution = result['execution_status'] as String?;
        if (execution != null) return Settlement.fromExecutionStatus(execution);
      }
      await Future<void>.delayed(interval);
    }
    return Settlement.pending;
  }

  // ---- plumbing --------------------------------------------------------

  Future<int> blockNumber() async =>
      ((await _rpcResult('starknet_blockNumber', const <Object>[])) as num)
          .toInt();

  /// An encrypted transport to one of the pool's services.
  ///
  /// OHTTP rather than plain JSON. Both requests carry things that must not be
  /// readable by infrastructure in the middle. Discovery carries the viewing
  /// key. So does proving — `compile_actions(user_addr, viewing_key, actions)`
  /// is the prover's own entrypoint — along with the pending transaction, so
  /// the prover sees strictly more, not something different. An earlier version
  /// of this comment said the viewing key went to one and the transaction to
  /// the other, which was wrong and made the self-hosted plain-transport option
  /// look safer than it is.
  /// The transport to the prover.
  ///
  /// Encrypted unless the operator has said they run the prover themselves,
  /// in which case there is no third party to be oblivious to and the bare
  /// service has no gateway to be oblivious through. See
  /// [PoolConfig.selfHostedProver] for why this is declared rather than
  /// detected.
  tp.DiscoveryTransport _proverTransport({Duration? timeout}) =>
      config.selfHostedProver
          ? tp.PlainJsonTransport(
              baseUrl: config.provingUrl,
              timeout: timeout ?? tp.defaultRequestTimeout,
            )
          : transportTo(config.provingUrl, timeout: timeout);

  /// An encrypted transport to [service].
  ///
  /// [timeout] is shorter than the default only for calls that are meant to
  /// answer quickly. A proof is not one of them.
  tp.DiscoveryTransport transportTo(Uri service, {Duration? timeout}) =>
      tp.OhttpTransport(
        gatewayUrl: service,
        pinnedKeyConfig: config.pinnedOhttpKey,
        timeout: timeout ?? tp.defaultRequestTimeout,
      );

  /// A read-only call on the pool.
  Future<List<String>> call(String selector, List<String> calldata) async {
    final result = await _rpcResult('starknet_call', [
      {
        'contract_address': config.poolHex,
        'entry_point_selector': getSelectorByName(selector).toHexString(),
        'calldata': calldata,
      },
      'latest',
    ]);
    return (result as List).cast<String>();
  }

  /// Ceilings for a proved submission.
  ///
  /// Sized from measurement, not from caution. Three real submissions on
  /// Sepolia used l1_gas 0, l2_gas between 80 and 86 million, and l1_data_gas
  /// under 1,500, for an actual fee of about 2.8 STRK each. The bounds below
  /// are roughly twice the dominant term.
  ///
  /// Being generous here is not free, which is the part that is easy to miss.
  /// Validation requires the account to hold the entire ceiling, not the fee
  /// it will actually pay, so an ceiling of a hundred STRK makes the
  /// transaction unsubmittable by anyone holding less than that. The first
  /// version of this asked for 78 STRK and was refused by an account holding
  /// 77, having paid nothing and learnt nothing.
  Future<tp.ResourceBounds> _submissionBounds() async {
    final header =
        await _rpcResult('starknet_getBlockWithTxHashes', ['latest'])
            as Map<String, dynamic>;
    String price(String key) =>
        ((header[key] as Map<String, dynamic>?)?['price_in_fri'] as String?) ??
        '0x1';

    return tp.ResourceBounds(
      // Measured at zero. A small allowance rather than none, since a bound of
      // zero leaves no room for a change in how the pool settles.
      l1Gas: tp.ResourceBound(
        maxAmount: '0x2710',
        maxPricePerUnit: price('l1_gas_price'),
      ),
      // Measured at about 1,500.
      l1DataGas: tp.ResourceBound(
        maxAmount: '0x4e20',
        maxPricePerUnit: price('l1_data_gas_price'),
      ),
      // Measured at 80 to 86 million. Verifying a proof is the whole cost of
      // this transaction, so this is the term that matters.
      l2Gas: tp.ResourceBound(
        maxAmount: '0xbebc200',
        maxPricePerUnit: price('l2_gas_price'),
      ),
    );
  }

  /// The most this submission could cost, at the ceilings above.
  ///
  /// Checked before signing so that a wallet which cannot cover it is told
  /// why, rather than being handed the node's "Resources bounds exceed
  /// balance", which names a number without saying what to do about it.
  BigInt maxFeeFor(tp.ResourceBounds bounds) {
    BigInt product(tp.ResourceBound bound) =>
        BigInt.parse(bound.maxAmount.replaceFirst('0x', ''), radix: 16) *
        BigInt.parse(bound.maxPricePerUnit.replaceFirst('0x', ''), radix: 16);
    return product(bounds.l1Gas) +
        product(bounds.l1DataGas) +
        product(bounds.l2Gas);
  }

  Future<Object?> _rpcResult(String method, Object params) async {
    final response = await _rpc(method, params);
    if (response['error'] != null) {
      throw PoolException(
        'The node refused $method',
        detail: jsonEncode(response['error']),
      );
    }
    return response['result'];
  }

  Future<Map<String, dynamic>> _rpc(String method, Object params) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(config.rpcUrl);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }));
      final response = await request.close();
      return jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }
}

/// A channel, and the markers that say whether it and its subchannel exist.
class ChannelRef {
  const ChannelRef({
    required this.key,
    required this.recipient,
    required this.recipientPublicKey,
    required this.token,
    required this.channelMarker,
    required this.subchannelMarker,
  });

  final BigInt key;
  final BigInt recipient;
  final BigInt recipientPublicKey;
  final BigInt token;
  final BigInt channelMarker;
  final BigInt subchannelMarker;
}

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);
String _hex(BigInt value) => '0x${value.toRadixString(16)}';
