/// Discovery client behaviour, driven by a scripted transport so the tests
/// cover pagination, reorg handling, and error mapping without a network.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

/// A transport that replays a scripted list of responses and records requests.
class _ScriptedTransport implements DiscoveryTransport {
  _ScriptedTransport(this.responses);

  final List<Object> responses;
  final List<({String path, Map<String, dynamic> body})> requests = [];
  int _index = 0;
  bool closed = false;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    requests.add((path: path, body: body));
    if (_index >= responses.length) {
      throw StateError('No scripted response for request ${_index + 1}');
    }
    final next = responses[_index++];
    if (next is Exception) throw next;
    return next as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> get(String path) async {
    requests.add((path: path, body: const {}));
    final next = responses[_index++];
    if (next is Exception) throw next;
    return next as Map<String, dynamic>;
  }

  @override
  void close() => closed = true;
}

Map<String, dynamic> _completeCursor({List<String> channels = const []}) => {
      'channel_discovery_complete': true,
      'channels': {
        for (final c in channels)
          c: {
            'subchannel_discovery_complete': true,
            'subchannels': {
              '0x1': {'note_discovery_complete': true},
            },
          },
      },
    };

void main() {
  final pool = BigInt.parse('40337b1af3c663e86e333bab5a4b28da8d4652a15a69bee',
      radix: 16);
  final viewingKey = BigInt.from(0xbeef);
  final address = BigInt.from(0x123);

  group('cursor completion', () {
    test('an empty cursor is not complete', () {
      expect(DiscoveryCursor.initial().isComplete, isFalse);
    });

    test('top-level completion alone is not enough', () {
      // A channel whose subchannels are still being walked means the sync has
      // more notes to fetch, even though channel discovery finished.
      final cursor = DiscoveryCursor.fromJson({
        'channel_discovery_complete': true,
        'channels': {
          '0xa': {'subchannel_discovery_complete': false},
        },
      });
      expect(cursor.isComplete, isFalse);
    });

    test('an incomplete note walk keeps the cursor incomplete', () {
      final cursor = DiscoveryCursor.fromJson({
        'channel_discovery_complete': true,
        'channels': {
          '0xa': {
            'subchannel_discovery_complete': true,
            'subchannels': {
              '0x1': {'note_discovery_complete': false},
            },
          },
        },
      });
      expect(cursor.isComplete, isFalse);
    });

    test('fully walked state is complete', () {
      expect(
        DiscoveryCursor.fromJson(_completeCursor(channels: ['0xa'])).isComplete,
        isTrue,
      );
    });
  });

  group('syncIncoming', () {
    test('accumulates notes across pages and pins the block ref', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': 5000,
          'channels': [
            {'channel_key': '0xaa', 'sender_addr': '0x111'},
          ],
          'subchannels': <dynamic>[],
          'notes': [
            {
              'sender_addr': '0x111',
              'token': '0x1',
              'index': 0,
              'note_id': '0xd1',
              'amount': '0x64',
              'salt': '0x5',
              'block_number': 4999,
            },
          ],
          'cursor': {'channel_discovery_complete': false},
        },
        {
          'block_ref': 5000,
          'channels': <dynamic>[],
          'subchannels': <dynamic>[],
          'notes': [
            {
              'sender_addr': '0x111',
              'token': '0x1',
              'index': 1,
              'note_id': '0xd2',
              'amount': '0x36',
              'salt': '0x6',
              'block_number': 5000,
            },
          ],
          'cursor': _completeCursor(),
        },
      ]);

      final client =
          DiscoveryClient(transport: transport, poolContractAddress: pool);
      final result = await client.syncIncoming(
        address: address,
        viewingKey: viewingKey,
      );

      expect(result.notes, hasLength(2));
      expect(result.channels, hasLength(1));
      expect(transport.requests, hasLength(2));

      // The second request must pin the block ref returned by the first, or the
      // two pages could be read at different chain states.
      expect(transport.requests[0].body.containsKey('block_ref'), isFalse);
      expect(transport.requests[1].body['block_ref'], equals(5000));
    });

    test('sums balances per token', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': 1,
          'channels': <dynamic>[],
          'subchannels': <dynamic>[],
          'notes': [
            {
              'sender_addr': '0x1',
              'token': '0xaaa',
              'index': 0,
              'note_id': '0x1',
              'amount': '0x64',
              'salt': '0x1',
              'block_number': 1,
            },
            {
              'sender_addr': '0x2',
              'token': '0xaaa',
              'index': 1,
              'note_id': '0x2',
              'amount': '0x1',
              'salt': '0x2',
              'block_number': 1,
            },
            {
              'sender_addr': '0x3',
              'token': '0xbbb',
              'index': 0,
              'note_id': '0x3',
              'amount': '0x9',
              'salt': '0x3',
              'block_number': 1,
            },
          ],
          'cursor': _completeCursor(),
        },
      ]);

      final client =
          DiscoveryClient(transport: transport, poolContractAddress: pool);
      final balances = (await client.syncIncoming(
        address: address,
        viewingKey: viewingKey,
      ))
          .balanceByToken();

      expect(
          balances[BigInt.parse('aaa', radix: 16)], equals(BigInt.from(101)));
      expect(balances[BigInt.parse('bbb', radix: 16)], equals(BigInt.from(9)));
    });

    test('sends the pool address, recipient, and viewing key', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': 1,
          'channels': <dynamic>[],
          'subchannels': <dynamic>[],
          'notes': <dynamic>[],
          'cursor': _completeCursor(),
        },
      ]);

      await DiscoveryClient(transport: transport, poolContractAddress: pool)
          .syncIncoming(address: address, viewingKey: viewingKey);

      final body = transport.requests.single.body;
      expect(transport.requests.single.path, '/v1/sync/incoming_state');
      expect(body['contract_address'], equals(feltToHex(pool)));
      expect(body['recipient_address'], equals('0x123'));
      expect(body['viewing_key'], equals('0xbeef'));
    });

    test('propagates a reorg instead of returning partial results', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': 1,
          'channels': <dynamic>[],
          'subchannels': <dynamic>[],
          'notes': <dynamic>[],
          'cursor': {'channel_discovery_complete': false},
        },
        const ReorgException('Block reorged'),
      ]);

      final client =
          DiscoveryClient(transport: transport, poolContractAddress: pool);

      expect(
        () => client.syncIncoming(address: address, viewingKey: viewingKey),
        throwsA(isA<ReorgException>()),
      );
    });

    test('refuses to loop forever on a cursor that never completes', () async {
      final neverDone = {
        'block_ref': 1,
        'channels': <dynamic>[],
        'subchannels': <dynamic>[],
        'notes': <dynamic>[],
        'cursor': {'channel_discovery_complete': false},
      };
      final transport = _ScriptedTransport(List<Object>.filled(10, neverDone));

      final client = DiscoveryClient(
        transport: transport,
        poolContractAddress: pool,
        maxPages: 3,
      );

      expect(
        () => client.syncIncoming(address: address, viewingKey: viewingKey),
        throwsA(isA<DiscoveryException>()),
      );
    });
  });

  group('preflight', () {
    test('reports readiness when nothing needs setting up', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': '0x1',
          'sender_registered': true,
          'channel_exists': true,
          'subchannel_exists': true,
        },
      ]);

      final requirement =
          await DiscoveryClient(transport: transport, poolContractAddress: pool)
              .preflight(
        address: address,
        viewingKey: viewingKey,
        recipient: BigInt.from(0x456),
        token: BigInt.from(0x1),
      );

      expect(requirement.isReady, isTrue);
    });

    test('is not ready when the channel is missing', () async {
      final transport = _ScriptedTransport([
        {
          'block_ref': '0x1',
          'sender_registered': true,
          'channel_exists': false,
          'subchannel_exists': false,
        },
      ]);

      final requirement =
          await DiscoveryClient(transport: transport, poolContractAddress: pool)
              .preflight(
        address: address,
        viewingKey: viewingKey,
        recipient: BigInt.from(0x456),
        token: BigInt.from(0x1),
      );

      expect(requirement.isReady, isFalse);
      expect(requirement.senderRegistered, isTrue);
      expect(requirement.channelExists, isFalse);
    });
  });

  group('response decoding', () {
    test('maps HTTP 409 to a reorg', () {
      expect(
        () => decodeDiscoveryResponse('/v1/sync/incoming_state', 409, 'reorg'),
        throwsA(isA<ReorgException>()),
      );
    });

    test('surfaces the service error code', () {
      try {
        decodeDiscoveryResponse(
          '/v1/sync/incoming_state',
          400,
          '{"error_code":"DECRYPTION_FAILED"}',
        );
        fail('expected a DiscoveryException');
      } on DiscoveryException catch (e) {
        expect(e.errorCode, equals('DECRYPTION_FAILED'));
        expect(e.statusCode, equals(400));
      }
    });

    test('rejects a non-JSON body', () {
      expect(
        () => decodeDiscoveryResponse('/health', 200, 'not json'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a malformed felt', () {
      expect(
        () => IncomingChannel.fromJson(
          {'channel_key': 'nonsense', 'sender_addr': '0x1'},
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a missing required field', () {
      expect(
        () => IncomingChannel.fromJson({'channel_key': '0x1'}),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  _feltBaseTests();
}

void _feltBaseTests() {
  group('parseServiceFelt', () {
    test('reads a hex-prefixed identifier as hex', () {
      expect(parseServiceFelt('0x10'), equals(BigInt.from(16)));
      expect(parseServiceFelt('0X10'), equals(BigInt.from(16)));
    });

    test('reads an unprefixed number as decimal', () {
      // The bug this exists for: amounts and salts arrive as plain decimal.
      // Read as hex they do not fail, they come back wrong.
      expect(
        parseServiceFelt('1000000000000000000'),
        equals(BigInt.parse('1000000000000000000')),
      );
    });

    test('one STRK stays one STRK', () {
      // A real note from a real shield. Parsed as hex this reads as
      // 4722.366483 STRK, which is what the wallet showed before the fix.
      final oneStrk = BigInt.from(10).pow(18);
      expect(parseServiceFelt('1000000000000000000'), equals(oneStrk));
      expect(
        parseServiceFelt('0x1000000000000000000'),
        isNot(equals(oneStrk)),
        reason: 'the same digits in hex are a different number',
      );
    });

    test('a decimal salt survives', () {
      expect(
        parseServiceFelt('847352467113937274664853351989015054'),
        equals(BigInt.parse('847352467113937274664853351989015054')),
      );
    });

    test('surrounding whitespace is tolerated', () {
      expect(parseServiceFelt('  0xff '), equals(BigInt.from(255)));
      expect(parseServiceFelt(' 255 '), equals(BigInt.from(255)));
    });

    test('nonsense is refused in either base', () {
      for (final bad in ['', '0x', '0xzz', 'hello', '12ab']) {
        expect(
          () => parseServiceFelt(bad),
          throwsA(isA<ProtocolException>()),
          reason: '"$bad"',
        );
      }
    });

    test('the error says which base it expected', () {
      expect(
        () => parseServiceFelt('0xzz'),
        throwsA(predicate((e) => '$e'.contains('hex'))),
      );
      expect(
        () => parseServiceFelt('nope'),
        throwsA(predicate((e) => '$e'.contains('decimal'))),
      );
    });
  });

  _retryTests();
}

void _retryTests() {
  group('riding out a service that is briefly down', () {
    /// Answers with [statuses] in order, then 200 forever.
    http.Client flaky(List<int> statuses, {List<String>? seen}) {
      var call = 0;
      return MockClient((request) async {
        seen?.add(request.url.path);
        final status = call < statuses.length ? statuses[call] : 200;
        call++;
        return http.Response(status == 200 ? '{"status":"OK"}' : 'nope', status);
      });
    }

    Future<void> noSleep(Duration _) async {}

    test('a 502 is retried rather than surfaced', () async {
      // The live service returns 502 with "try again in 30 seconds" while it
      // restarts. A balance that vanishes because a server was deploying is a
      // balance the user stops trusting.
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: flaky([502, 502]),
        sleep: noSleep,
      );
      expect(await transport.get('/health'), equals({'status': 'OK'}));
    });

    test('every transient status is retried', () async {
      for (final status in transientStatusCodes) {
        final transport = PlainJsonTransport(
          baseUrl: Uri.parse('https://example.test'),
          client: flaky([status]),
          sleep: noSleep,
        );
        expect(
          await transport.get('/health'),
          equals({'status': 'OK'}),
          reason: 'status $status',
        );
      }
    });

    test('it gives up rather than retrying forever', () async {
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: flaky([502, 502, 502, 502, 502, 502, 502, 502]),
        sleep: noSleep,
      );
      expect(
        () => transport.get('/health'),
        throwsA(isA<DiscoveryException>()),
      );
    });

    test('a reorg is not retried, it is an answer', () async {
      // Repeating it arrives at the same place having wasted the wait.
      final seen = <String>[];
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: flaky([reorgStatusCode], seen: seen),
        sleep: noSleep,
      );
      expect(
        () => transport.get('/health'),
        throwsA(isA<ReorgException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
    });

    test('a bad request is not retried either', () async {
      final seen = <String>[];
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: flaky([422], seen: seen),
        sleep: noSleep,
      );
      expect(
        () => transport.get('/health'),
        throwsA(isA<DiscoveryException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
    });

    test('retries can be turned off entirely', () async {
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: flaky([502]),
        retryPolicy: DiscoveryRetryPolicy.none,
        sleep: noSleep,
      );
      expect(
        () => transport.get('/health'),
        throwsA(isA<DiscoveryException>()),
      );
    });

    test('a connection that never lands is retried, then named', () async {
      // What a wallet sees when the service is down rather than merely busy.
      // It used to escape as a raw http.ClientException, which reached the
      // screen as a stack-trace-shaped string.
      var calls = 0;
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('Connection refused');
        }),
        sleep: noSleep,
      );

      await expectLater(
        transport.get('/health'),
        throwsA(
          isA<TransportException>()
              .having((e) => e.host, 'host', 'example.test')
              .having((e) => e.timedOut, 'timedOut', isFalse),
        ),
      );
      expect(calls, 4, reason: 'the initial attempt plus three retries');
    });

    test('a connection that recovers is not surfaced at all', () async {
      var calls = 0;
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: MockClient((_) async {
          if (calls++ == 0) throw http.ClientException('Connection reset');
          return http.Response('{"status":"OK"}', 200);
        }),
        sleep: noSleep,
      );
      expect(await transport.get('/health'), equals({'status': 'OK'}));
    });

    test('a request that hangs is abandoned and says so', () async {
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: MockClient((_) => Completer<http.Response>().future),
        retryPolicy: DiscoveryRetryPolicy.none,
        timeout: const Duration(milliseconds: 20),
        sleep: noSleep,
      );
      await expectLater(
        transport.get('/health'),
        throwsA(
          isA<TransportException>()
              .having((e) => e.timedOut, 'timedOut', isTrue),
        ),
      );
    });

    test('a malformed body is still a protocol error, not a network one', () {
      // The classifier has to leave real answers alone. Reporting a service
      // that replied with nonsense as unreachable would send the user to check
      // their signal for a bug on the server.
      final transport = PlainJsonTransport(
        baseUrl: Uri.parse('https://example.test'),
        client: MockClient((_) async => http.Response('not json', 200)),
        sleep: noSleep,
      );
      expect(
        () => transport.get('/health'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('the backoff grows and then stops growing', () {
      const policy = DiscoveryRetryPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 4),
      );
      expect(policy.delayFor(0), equals(const Duration(seconds: 1)));
      expect(policy.delayFor(1), equals(const Duration(seconds: 2)));
      expect(policy.delayFor(9), equals(const Duration(seconds: 4)));
    });
  });
}
