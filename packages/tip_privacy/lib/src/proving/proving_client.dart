/// Client for the STRK20 proving service.
///
/// Shielded transactions carry a zk-STARK proof, and generating one is well
/// beyond what a phone should attempt: the reference deployment budgets roughly
/// half a minute on server-class hardware. The protocol is designed around that,
/// so proving is a remote call rather than local work. This client makes it.
///
/// The transport matters here as much as it does for discovery. The request
/// carries the transaction being proved, so a plain transport reveals to
/// whoever terminates TLS exactly what is about to be submitted, and when.
library;

import 'dart:async';
import 'dart:convert';

import '../errors.dart';
import '../discovery/transport.dart';

/// A proof and the facts a verifier needs alongside it.
class ProofResult {
  const ProofResult({
    required this.proof,
    required this.proofFacts,
    this.messages = const [],
    this.screeningSignature,
  });

  factory ProofResult.fromJson(Map<String, dynamic> json) {
    final additional = json['additional_data'] as Map<String, dynamic>?;
    final signature = additional?['signature'] as Map<String, dynamic>?;
    return ProofResult(
      proof: json['proof'] as String? ?? '',
      proofFacts: (json['proof_facts'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      messages: (json['l2_to_l1_messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ProvedMessage.fromJson)
          .toList(),
      screeningSignature:
          signature == null ? null : ScreeningSignature.fromJson(signature),
    );
  }

  /// Base64-encoded proof bytes.
  final String proof;

  /// Facts the on-chain verifier checks the proof against.
  final List<String> proofFacts;

  /// Messages the proved execution emitted towards L1.
  ///
  /// Not incidental. The pool compiles the client's actions into server actions
  /// and emits them as an L2 to L1 message, so this is where the calldata for
  /// `apply_actions` comes from. Calling `compile_actions` separately would ask
  /// the chain to do the same work twice and risk the two disagreeing.
  final List<ProvedMessage> messages;

  /// Present only for transactions the compliance layer had to attest.
  final ScreeningSignature? screeningSignature;

  /// The server actions the pool compiled, as raw felts.
  ///
  /// [poolAddress] identifies which message to read: the proved transaction is
  /// sent by the pool, so the message from that address is the one carrying its
  /// output.
  List<String> serverActionsFor(String poolAddress) {
    final wanted = _normaliseHex(poolAddress);
    for (final message in messages) {
      if (_normaliseHex(message.fromAddress) == wanted) return message.payload;
    }
    throw ProtocolException(
      'The proof carried no message from the pool at $poolAddress, so there '
      'are no server actions to apply',
    );
  }
}

/// One L2 to L1 message emitted by a proved execution.
class ProvedMessage {
  const ProvedMessage({
    required this.fromAddress,
    required this.toAddress,
    required this.payload,
  });

  factory ProvedMessage.fromJson(Map<String, dynamic> json) => ProvedMessage(
        fromAddress: json['from_address'] as String? ?? '0x0',
        toAddress: json['to_address'] as String? ?? '0x0',
        payload: (json['payload'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  final String fromAddress;
  final String toAddress;
  final List<String> payload;
}

/// Compares addresses by value, since the same one is written with and without
/// leading zeros depending on who wrote it.
String _normaliseHex(String value) {
  final digits = value.toLowerCase().replaceFirst('0x', '').replaceFirst(
        RegExp('^0+'),
        '',
      );
  return digits.isEmpty ? '0' : digits;
}

/// A screening attestation the prover attaches to deposits that need one.
class ScreeningSignature {
  const ScreeningSignature({
    required this.issuedAt,
    required this.r,
    required this.s,
  });

  factory ScreeningSignature.fromJson(Map<String, dynamic> json) =>
      ScreeningSignature(
        issuedAt: (json['issued_at'] as num?)?.toInt() ?? 0,
        r: json['sig_r'] as String? ?? '0x0',
        s: json['sig_s'] as String? ?? '0x0',
      );

  final int issuedAt;
  final String r;
  final String s;
}

/// How hard to retry a prover that says it is busy.
class ProvingRetryPolicy {
  const ProvingRetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
  });

  /// No retries at all.
  static const none = ProvingRetryPolicy(maxRetries: 0);

  final int maxRetries;
  final Duration baseDelay;

  /// Ceiling on a single backoff, so a large [maxRetries] cannot schedule an
  /// absurdly long sleep.
  final Duration maxDelay;

  /// Backoff before retry [attempt], zero-indexed: 1s, 2s, 4s by default.
  Duration delayFor(int attempt) {
    final scaled = baseDelay * (1 << attempt);
    return scaled > maxDelay ? maxDelay : scaled;
  }
}

/// Calls the proving service over JSON-RPC.
class ProvingClient {
  ProvingClient({
    required this.transport,
    this.retryPolicy = const ProvingRetryPolicy(),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final DiscoveryTransport transport;
  final ProvingRetryPolicy retryPolicy;
  final Future<void> Function(Duration) _sleep;

  var _nextId = 1;

  /// Proves a transaction against [blockId].
  ///
  /// Retries only when the prover reports itself busy. Every other failure is a
  /// real one and surfaces immediately, because retrying an invalid transaction
  /// or a screening rejection just wastes the user's time.
  Future<ProofResult> proveTransaction({
    required Object blockId,
    required Map<String, dynamic> transaction,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        final result = await _call('starknet_proveTransaction', {
          'block_id': blockId,
          'transaction': transaction,
        });
        return ProofResult.fromJson(result);
      } on ProvingException catch (e) {
        if (!e.isTransient || attempt >= retryPolicy.maxRetries) rethrow;
        await _sleep(retryPolicy.delayFor(attempt));
      }
    }
  }

  /// The Starknet RPC spec version the prover implements.
  Future<String> specVersion() async {
    final result = await _call('starknet_specVersion', null);
    final version = result['result'];
    if (version is String) return version;
    throw const ProtocolException(
      'starknet_specVersion did not return a version string',
    );
  }

  /// Whether the prover is reachable and answering.
  Future<bool> isHealthy() async {
    try {
      await specVersion();
      return true;
    } on PrivacyException {
      return false;
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic>? params,
  ) async {
    final response = await transport.post('/', {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      if (params != null) 'params': params,
    });

    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw ProvingException(
        (error['code'] as num?)?.toInt() ?? -32603,
        error['message'] as String? ?? 'Unknown proving service error',
        data: switch (error['data']) {
          final String s => s,
          null => null,
          final other => jsonEncode(other),
        },
      );
    }

    final result = response['result'];
    if (result is Map<String, dynamic>) return result;

    // specVersion returns a bare string rather than an object; wrap it so the
    // single call path can stay uniform.
    if (result != null) return {'result': result};

    throw const ProtocolException(
      'Proving service response contained neither result nor error',
    );
  }

  void close() => transport.close();
}
