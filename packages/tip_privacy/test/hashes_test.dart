/// Verifies the hash suite against reference values generated from the Cairo
/// implementation.
///
/// Fixture is `sdk/tests/fixtures/cairo-reference-data.json` from
/// starkware-libs/starknet-privacy (Apache-2.0), vendored unchanged so these
/// tests run without a network or a Cairo toolchain.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _felt(String hex) =>
    BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/cairo-reference-data.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  final inputs = fixture['inputs'] as Map<String, dynamic>;
  final outputs = fixture['outputs'] as Map<String, dynamic>;

  final sender = _felt(inputs['sender'] as String);
  final recipient = _felt(inputs['recipient'] as String);
  final senderPrivateKey = _felt(inputs['senderPrivateKey'] as String);
  final recipientPublicKey = _felt(inputs['recipientPublicKey'] as String);
  final channelKey = _felt(inputs['channelKey'] as String);
  final token = _felt(inputs['token'] as String);
  final index = inputs['index'] as int;
  final salt = _felt(inputs['salt'] as String);
  final sharedX = _felt(inputs['sharedX'] as String);

  void expectFelt(BigInt actual, String outputKey) {
    expect(actual, equals(_felt(outputs[outputKey] as String)));
  }

  group('short string encoding', () {
    test('encodes a domain tag as big-endian ASCII', () {
      expect(
        shortStringToFelt('CHANNEL_KEY_TAG:V1'),
        equals(_felt('0x4348414e4e454c5f4b45595f5441473a5631')),
      );
    });

    test('rejects strings longer than 31 characters', () {
      expect(
        () => shortStringToFelt('x' * 32),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-ASCII input', () {
      expect(() => shortStringToFelt('privé'), throwsA(isA<ArgumentError>()));
    });
  });

  group('hashes match the Cairo reference', () {
    test('computeChannelKey', () {
      expectFelt(
        computeChannelKey(
          senderAddr: sender,
          senderPrivateKey: senderPrivateKey,
          recipientAddr: recipient,
          recipientPublicKey: recipientPublicKey,
        ),
        'channelKey',
      );
    });

    test('computeChannelMarker', () {
      expectFelt(
        computeChannelMarker(
          channelKey: channelKey,
          senderAddr: sender,
          recipientAddr: recipient,
          recipientPublicKey: recipientPublicKey,
        ),
        'channelMarker',
      );
    });

    test('computeSubchannelId', () {
      expectFelt(
        computeSubchannelId(channelKey: channelKey, index: index),
        'subchannelId',
      );
    });

    test('computeSubchannelMarker', () {
      expectFelt(
        computeSubchannelMarker(
          channelKey: channelKey,
          recipientAddr: recipient,
          recipientPublicKey: recipientPublicKey,
          token: token,
        ),
        'subchannelMarker',
      );
    });

    test('computeNoteId', () {
      expectFelt(
        computeNoteId(channelKey: channelKey, token: token, index: index),
        'noteId',
      );
    });

    test('computeNullifier', () {
      expectFelt(
        computeNullifier(
          channelKey: channelKey,
          token: token,
          index: index,
          ownerPrivateKey: senderPrivateKey,
        ),
        'nullifier',
      );
    });

    test('computeEncAmountHash', () {
      expectFelt(
        computeEncAmountHash(
          channelKey: channelKey,
          token: token,
          index: index,
          salt: salt,
        ),
        'encAmountHash',
      );
    });

    test('computeEncTokenHash', () {
      expectFelt(
        computeEncTokenHash(
          channelKey: channelKey,
          index: index,
          salt: salt,
        ),
        'encTokenHash',
      );
    });

    test('computeEncPrivateKeyHash', () {
      expectFelt(computeEncPrivateKeyHash(sharedX), 'encPrivateKeyHash');
    });

    test('computeEncChannelKeyHash', () {
      expectFelt(computeEncChannelKeyHash(sharedX), 'encChannelKeyHash');
    });

    test('computeEncSenderAddrHash', () {
      expectFelt(computeEncSenderAddrHash(sharedX), 'encSenderAddrHash');
    });

    test('computeEncRecipientAddrHash', () {
      expectFelt(
        computeEncRecipientAddrHash(
          senderAddr: sender,
          senderPrivateKey: senderPrivateKey,
          index: index,
          salt: salt,
        ),
        'encRecipientAddrHash',
      );
    });

    test('computeOutgoingChannelId', () {
      expectFelt(
        computeOutgoingChannelId(
          senderAddr: sender,
          senderPrivateKey: senderPrivateKey,
          index: index,
        ),
        'outgoingChannelId',
      );
    });
  });

  group('domain separation', () {
    test('every tag produces a distinct hash for identical input', () {
      final tags = <String>[
        HashTags.channelKey,
        HashTags.channelMarker,
        HashTags.noteId,
        HashTags.nullifier,
        HashTags.encAmount,
        HashTags.encToken,
        HashTags.encPrivateKey,
        HashTags.encUserAddr,
        HashTags.encChannelKey,
        HashTags.encSenderAddr,
        HashTags.encRecipientAddr,
        HashTags.subchannelId,
        HashTags.subchannelMarker,
        HashTags.outgoingChannelId,
        HashTags.identityKey,
      ];
      final hashes =
          tags.map((tag) => poseidonHash([tag, BigInt.one])).toSet();
      expect(hashes, hasLength(tags.length));
    });

    test('the index padding zero is not incidental', () {
      // Dropping the trailing 0 after `index` must change the hash. If this
      // ever passes, the padding convention has been lost somewhere.
      final withPadding =
          computeNoteId(channelKey: channelKey, token: token, index: index);
      final withoutPadding =
          poseidonHash([HashTags.noteId, channelKey, token, index]);
      expect(withPadding, isNot(equals(withoutPadding)));
    });
  });
}
