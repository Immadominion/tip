/// The local mirror of the pool's index bookkeeping.
///
/// Every rule checked here is one the contract enforces after a proof has been
/// generated, which takes the better part of a minute. Getting them right
/// locally is the difference between a wallet that feels instant and one that
/// makes you wait to be told no.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

final _token = BigInt.from(0xaaaa);
final _otherToken = BigInt.from(0xbbbb);
final _channel = BigInt.from(0x1111);
final _otherChannel = BigInt.from(0x2222);
final _recipient = BigInt.from(0xdead);
final _recipientKey = BigInt.from(0xbeef);

BigInt _resolver(BigInt addr, BigInt key) => _channel;

void main() {
  group('allocating', () {
    test('the first index in every sequence is zero', () {
      final pool = PoolSimulator();
      final batch = pool.beginBatch();

      expect(batch.takeOutgoingChannelIndex(), equals(0));
      expect(batch.takeSubchannelIndex(_channel), equals(0));
      expect(
        batch.takeNoteIndex(channelKey: _channel, token: _token),
        equals(0),
      );
    });

    test('indices in one batch run consecutively', () {
      // Two notes in one transfer, the recipient's and the change, must not
      // collide. Slots are write-once, so a repeat is rejected outright.
      final pool = PoolSimulator();
      final batch = pool.beginBatch();

      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 0);
      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 1);
      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 2);
    });

    test('each channel and token counts separately', () {
      // The contract mixes both into compute_note_id, so they are different
      // sequences and both start at zero.
      final pool = PoolSimulator();
      final batch = pool.beginBatch();

      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 0);
      expect(batch.takeNoteIndex(channelKey: _channel, token: _otherToken), 0);
      expect(batch.takeNoteIndex(channelKey: _otherChannel, token: _token), 0);
      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 1);
    });

    test('a committed batch moves the counters on', () {
      final pool = PoolSimulator();
      final first = pool.beginBatch();
      first.takeNoteIndex(channelKey: _channel, token: _token);
      first.commit();

      final second = pool.beginBatch();
      expect(second.takeNoteIndex(channelKey: _channel, token: _token), 1);
    });

    test('an abandoned batch gives its indices back', () {
      // A reverted transaction rolls the whole batch back on chain, so the
      // slots are free again and the next attempt starts where it did.
      final pool = PoolSimulator();
      final first = pool.beginBatch();
      first.takeNoteIndex(channelKey: _channel, token: _token);
      first.takeNoteIndex(channelKey: _channel, token: _token);
      first.takeSubchannelIndex(_channel);
      first.takeOutgoingChannelIndex();
      first.abandon();

      final second = pool.beginBatch();
      expect(second.takeNoteIndex(channelKey: _channel, token: _token), 0);
      expect(second.takeSubchannelIndex(_channel), 0);
      expect(second.takeOutgoingChannelIndex(), 0);
    });

    test('abandoning does not undo what was committed before it', () {
      final pool = PoolSimulator();
      final first = pool.beginBatch();
      first.takeNoteIndex(channelKey: _channel, token: _token);
      first.commit();

      final second = pool.beginBatch();
      second.takeNoteIndex(channelKey: _channel, token: _token);
      second.abandon();

      expect(pool.peekNoteIndex(channelKey: _channel, token: _token), 1);
    });
  });

  group('one batch at a time', () {
    test('opening a second batch is refused', () {
      // Two open batches allocate from the same counters and hand out the same
      // index twice. The second transaction to land is then a write to an
      // occupied slot.
      final pool = PoolSimulator();
      pool.beginBatch();
      expect(() => pool.beginBatch(), throwsA(isA<ProtocolException>()));
    });

    test('a settled batch releases the lock', () {
      final pool = PoolSimulator();
      pool.beginBatch().commit();
      expect(() => pool.beginBatch(), returnsNormally);
      expect(pool.hasOpenBatch, isTrue);
    });

    test('a settled batch cannot be used again', () {
      final pool = PoolSimulator();
      final batch = pool.beginBatch();
      batch.commit();

      expect(
        () => batch.takeNoteIndex(channelKey: _channel, token: _token),
        throwsA(isA<ProtocolException>()),
      );
      expect(() => batch.commit(), throwsA(isA<ProtocolException>()));
      expect(() => batch.abandon(), throwsA(isA<ProtocolException>()));
    });
  });

  group('what the chain says wins', () {
    test('an observed count replaces the local one', () {
      final pool = PoolSimulator();
      pool.observeNoteCount(channelKey: _channel, token: _token, count: 7);
      expect(pool.peekNoteIndex(channelKey: _channel, token: _token), 7);

      final batch = pool.beginBatch();
      expect(batch.takeNoteIndex(channelKey: _channel, token: _token), 7);
    });

    test('an observed count can correct the local one downward', () {
      // Which is what a reorg looks like from here.
      final pool = PoolSimulator();
      pool.observeNoteCount(channelKey: _channel, token: _token, count: 9);
      pool.observeNoteCount(channelKey: _channel, token: _token, count: 4);
      expect(pool.peekNoteIndex(channelKey: _channel, token: _token), 4);
    });

    test('a negative count is refused rather than stored', () {
      final pool = PoolSimulator();
      expect(
        () => pool.observeNoteCount(
          channelKey: _channel,
          token: _token,
          count: -1,
        ),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => pool.observeSubchannelCount(channelKey: _channel, count: -1),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => pool.observeOutgoingChannelCount(-1),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('nullifiers mark a note spent', () {
      final pool = PoolSimulator();
      final nullifier = BigInt.from(0xf00d);
      expect(pool.isSpent(nullifier), isFalse);
      pool.observeNullifier(nullifier);
      expect(pool.isSpent(nullifier), isTrue);
    });
  });

  group('checking a batch before it is proved', () {
    CreateEncNote note(int index) => CreateEncNote(
          recipientAddr: _recipient,
          recipientPublicKey: _recipientKey,
          token: _token,
          amount: BigInt.from(10),
          index: index,
          salt: BigInt.from(5),
        );

    test('a well formed batch has no problems', () {
      final pool = PoolSimulator();
      expect(
        pool.checkSequential([note(0), note(1)], channelKeyFor: _resolver),
        isEmpty,
      );
    });

    test('a gap is caught', () {
      final pool = PoolSimulator();
      final problems =
          pool.checkSequential([note(0), note(2)], channelKeyFor: _resolver);
      expect(problems, hasLength(1));
      expect(problems.single, contains('index 2'));
      expect(problems.single, contains('next free index is 1'));
    });

    test('starting above zero on an empty sequence is caught', () {
      final pool = PoolSimulator();
      expect(
        pool.checkSequential([note(3)], channelKeyFor: _resolver),
        hasLength(1),
      );
    });

    test('it counts on from what the chain already has', () {
      final pool = PoolSimulator()
        ..observeNoteCount(channelKey: _channel, token: _token, count: 4);

      expect(
        pool.checkSequential([note(4), note(5)], channelKeyFor: _resolver),
        isEmpty,
      );
      expect(
        pool.checkSequential([note(0)], channelKeyFor: _resolver),
        hasLength(1),
      );
    });

    test('a repeated index is caught, since slots are write once', () {
      final pool = PoolSimulator();
      expect(
        pool.checkSequential([note(0), note(0)], channelKeyFor: _resolver),
        hasLength(1),
      );
    });

    test('channels and subchannels are checked too', () {
      final pool = PoolSimulator();

      expect(
        pool.checkSequential(
          [
            OpenChannel(
              recipientAddr: _recipient,
              index: 1,
              random: BigInt.one,
              salt: BigInt.one,
            ),
          ],
          channelKeyFor: _resolver,
        ),
        hasLength(1),
      );

      expect(
        pool.checkSequential(
          [
            OpenSubchannel(
              recipientAddr: _recipient,
              recipientPublicKey: _recipientKey,
              channelKey: _channel,
              index: 0,
              token: _token,
              salt: BigInt.one,
            ),
          ],
          channelKeyFor: _resolver,
        ),
        isEmpty,
      );
    });

    test('actions with no index are ignored rather than tripping the check',
        () {
      final pool = PoolSimulator();
      expect(
        pool.checkSequential(
          [
            Deposit(token: _token, amount: BigInt.from(5)),
            UseNote(channelKey: _channel, token: _token, index: 3),
            note(0),
          ],
          channelKeyFor: _resolver,
        ),
        isEmpty,
        reason: 'UseNote reads an existing note, it does not allocate one',
      );
    });
  });
}
