/// Proving client behaviour: JSON-RPC shape, error mapping, and the retry
/// policy, all driven by a scripted transport so no prover is needed.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

class _ScriptedTransport implements DiscoveryTransport {
  _ScriptedTransport(this.responses);

  final List<Map<String, dynamic>> responses;
  final List<Map<String, dynamic>> requests = [];
  int _index = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    requests.add(body);
    if (_index >= responses.length) {
      throw StateError('No scripted response for request ${_index + 1}');
    }
    return responses[_index++];
  }

  @override
  Future<Map<String, dynamic>> get(String path) async => responses[_index++];

  @override
  void close() {}
}

Map<String, dynamic> _busy() => {
      'jsonrpc': '2.0',
      'id': 1,
      'error': {'code': -32005, 'message': 'Service busy'},
    };

Map<String, dynamic> _proof() => {
      'jsonrpc': '2.0',
      'id': 1,
      'result': {
        'proof': 'YmFzZTY0cHJvb2Y=',
        'proof_facts': ['0x1', '0x2'],
        'l2_to_l1_messages': <dynamic>[],
      },
    };

void main() {
  group('proveTransaction', () {
    test('returns the proof and its facts', () async {
      final transport = _ScriptedTransport([_proof()]);
      final client = ProvingClient(transport: transport);

      final result = await client.proveTransaction(
        blockId: 'latest',
        transaction: const {'type': 'INVOKE'},
      );

      expect(result.proof, equals('YmFzZTY0cHJvb2Y='));
      expect(result.proofFacts, equals(['0x1', '0x2']));
      expect(result.screeningSignature, isNull);
    });

    test('sends a well-formed JSON-RPC envelope', () async {
      final transport = _ScriptedTransport([_proof()]);
      await ProvingClient(transport: transport).proveTransaction(
        blockId: 'latest',
        transaction: const {'type': 'INVOKE'},
      );

      final request = transport.requests.single;
      expect(request['jsonrpc'], equals('2.0'));
      expect(request['method'], equals('starknet_proveTransaction'));
      expect(request['id'], isA<int>());
      final params = request['params'] as Map<String, dynamic>;
      expect(params['block_id'], equals('latest'));
      expect(params['transaction'], equals({'type': 'INVOKE'}));
    });

    test('parses a screening attestation when the prover attaches one',
        () async {
      final transport = _ScriptedTransport([
        {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'proof': 'cHJvb2Y=',
            'proof_facts': <dynamic>[],
            'l2_to_l1_messages': <dynamic>[],
            'additional_data': {
              'signature': {
                'issued_at': 1750000000,
                'sig_r': '0xaa',
                'sig_s': '0xbb',
              },
            },
          },
        },
      ]);

      final result = await ProvingClient(transport: transport)
          .proveTransaction(blockId: 'latest', transaction: const {});

      expect(result.screeningSignature, isNotNull);
      expect(result.screeningSignature!.issuedAt, equals(1750000000));
      expect(result.screeningSignature!.r, equals('0xaa'));
    });
  });

  group('retry policy', () {
    test('retries a busy prover and then succeeds', () async {
      final transport = _ScriptedTransport([_busy(), _busy(), _proof()]);
      final delays = <Duration>[];

      final client = ProvingClient(
        transport: transport,
        sleep: (d) async => delays.add(d),
      );

      final result = await client.proveTransaction(
        blockId: 'latest',
        transaction: const {},
      );

      expect(result.proof, isNotEmpty);
      expect(transport.requests, hasLength(3));
      // Exponential: 1s then 2s.
      expect(
          delays, equals(const [Duration(seconds: 1), Duration(seconds: 2)]));
    });

    test('gives up after maxRetries and surfaces the error', () async {
      final transport = _ScriptedTransport([_busy(), _busy()]);
      final client = ProvingClient(
        transport: transport,
        retryPolicy: const ProvingRetryPolicy(maxRetries: 1),
        sleep: (_) async {},
      );

      await expectLater(
        client.proveTransaction(blockId: 'latest', transaction: const {}),
        throwsA(
          isA<ProvingException>().having((e) => e.code, 'code', -32005),
        ),
      );
      expect(transport.requests, hasLength(2));
    });

    test('does not retry a non-transient error', () async {
      final transport = _ScriptedTransport([
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': 1000, 'message': 'Invalid transaction input'},
        },
        _proof(),
      ]);

      final client = ProvingClient(
        transport: transport,
        sleep: (_) async {},
      );

      await expectLater(
        client.proveTransaction(blockId: 'latest', transaction: const {}),
        throwsA(isA<ProvingException>().having((e) => e.code, 'code', 1000)),
      );
      // One attempt only. Retrying an invalid transaction is pointless.
      expect(transport.requests, hasLength(1));
    });

    test('does not retry a screening rejection', () async {
      final transport = _ScriptedTransport([
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': 10000, 'message': 'Transaction rejected'},
        },
      ]);

      await expectLater(
        ProvingClient(transport: transport, sleep: (_) async {})
            .proveTransaction(blockId: 'latest', transaction: const {}),
        throwsA(
          isA<ProvingException>()
              .having((e) => e.isTransient, 'isTransient', isFalse),
        ),
      );
    });

    test('caps the backoff delay', () {
      const policy = ProvingRetryPolicy(
        baseDelay: Duration(seconds: 10),
        maxDelay: Duration(seconds: 30),
      );
      expect(policy.delayFor(0), equals(const Duration(seconds: 10)));
      expect(policy.delayFor(1), equals(const Duration(seconds: 20)));
      // 40s would exceed the cap.
      expect(policy.delayFor(2), equals(const Duration(seconds: 30)));
      expect(policy.delayFor(20), equals(const Duration(seconds: 30)));
    });

    test('maxRetries of zero disables retrying', () async {
      final transport = _ScriptedTransport([_busy(), _proof()]);

      await expectLater(
        ProvingClient(
          transport: transport,
          retryPolicy: ProvingRetryPolicy.none,
          sleep: (_) async {},
        ).proveTransaction(blockId: 'latest', transaction: const {}),
        throwsA(isA<ProvingException>()),
      );
      expect(transport.requests, hasLength(1));
    });
  });

  group('health', () {
    test('reports healthy when the prover answers', () async {
      final transport = _ScriptedTransport([
        {'jsonrpc': '2.0', 'id': 1, 'result': '0.10.0'},
      ]);
      expect(await ProvingClient(transport: transport).isHealthy(), isTrue);
    });

    test('reports unhealthy when the prover errors', () async {
      final transport = _ScriptedTransport([
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32603, 'message': 'Internal error'},
        },
      ]);
      expect(await ProvingClient(transport: transport).isHealthy(), isFalse);
    });
  });
}
