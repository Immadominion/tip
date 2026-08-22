/// Discovery client behaviour, driven by a scripted transport so the tests
/// cover pagination, reorg handling, and error mapping without a network.
library;

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
}
