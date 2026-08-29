/// Matching discovered notes to the channel they were created under.
///
/// The bug this file exists for: every note was stamped with the wallet's own
/// self-channel key, which is only right for notes the wallet shielded itself.
/// A note from someone else was added to the balance and then could not be
/// spent, because the `UseNote` built from it named a note id that does not
/// exist on chain. It went unnoticed because every fixture in the package tests
/// hardcodes a single channel key, and the live Sepolia runs only ever watched
/// the receiving side — they never spent from it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/privacy/privacy_controller.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

final _self = BigInt.parse('a11ce', radix: 16);
final _selfChannelKey = BigInt.parse('5e1f', radix: 16);
final _bob = BigInt.parse('b0b', radix: 16);
final _bobChannelKey = BigInt.parse('b0bce11', radix: 16);
final _token = BigInt.parse('57424b', radix: 16);

/// A note whose id is consistent with the channel it claims to be in, which is
/// what the pool would actually have written.
tp.IncomingNote _note({
  required BigInt sender,
  required BigInt channelKey,
  required int index,
  required int amount,
}) =>
    tp.IncomingNote(
      senderAddr: sender,
      token: _token,
      index: index,
      noteId: tp.computeNoteId(
        channelKey: channelKey,
        token: _token,
        index: index,
      ),
      amount: BigInt.from(amount),
      salt: BigInt.one,
      blockNumber: 100,
    );

KeyedNotes _key(
  List<tp.IncomingNote> notes,
  List<tp.IncomingChannel> channels,
) =>
    keyIncomingNotes(
      notes: notes,
      channels: channels,
      self: _self,
      selfChannelKey: _selfChannelKey,
    );

void main() {
  test('a note we shielded ourselves keeps the self channel key', () {
    final result = _key(
      [_note(sender: _self, channelKey: _selfChannelKey, index: 0, amount: 5)],
      const [],
    );
    expect(result.notes, hasLength(1));
    expect(result.notes.single.channelKey, _selfChannelKey);
    expect(result.unspendable, 0);
  });

  test('a note from someone else gets THEIR channel key, not ours', () {
    // The regression. Before the fix this note came back keyed to
    // _selfChannelKey, which made it unspendable.
    final result = _key(
      [_note(sender: _bob, channelKey: _bobChannelKey, index: 0, amount: 7)],
      [tp.IncomingChannel(channelKey: _bobChannelKey, senderAddr: _bob)],
    );
    expect(result.notes, hasLength(1));
    expect(result.notes.single.channelKey, _bobChannelKey);
    expect(result.notes.single.channelKey, isNot(_selfChannelKey));
    expect(result.unspendable, 0);
  });

  test('the note id is verified, so a wrong channel key is caught', () {
    // The service claims Bob's channel, but the note id was computed under a
    // different key. We must not credit it: the key is what UseNote is built
    // against, and a wrong one names a note that does not exist.
    final wrong = BigInt.parse('dead', radix: 16);
    final result = _key(
      [_note(sender: _bob, channelKey: wrong, index: 0, amount: 7)],
      [tp.IncomingChannel(channelKey: _bobChannelKey, senderAddr: _bob)],
    );
    expect(result.notes, isEmpty);
    expect(result.unspendable, 1);
  });

  test('a note from a channel we do not have is left out, not credited', () {
    final result = _key(
      [_note(sender: _bob, channelKey: _bobChannelKey, index: 0, amount: 7)],
      const [],
    );
    expect(result.notes, isEmpty);
    expect(result.unspendable, 1);
  });

  test('a note repeated across a page boundary is counted once', () {
    final note = _note(
      sender: _bob,
      channelKey: _bobChannelKey,
      index: 3,
      amount: 4,
    );
    final result = _key(
      [note, note],
      [tp.IncomingChannel(channelKey: _bobChannelKey, senderAddr: _bob)],
    );
    expect(result.notes, hasLength(1));
  });

  test('mixed senders each keep their own key and both are spendable', () {
    final result = _key(
      [
        _note(sender: _self, channelKey: _selfChannelKey, index: 0, amount: 5),
        _note(sender: _bob, channelKey: _bobChannelKey, index: 0, amount: 7),
      ],
      [tp.IncomingChannel(channelKey: _bobChannelKey, senderAddr: _bob)],
    );
    expect(result.notes, hasLength(2));
    expect(
      result.notes.map((n) => n.channelKey).toSet(),
      {_selfChannelKey, _bobChannelKey},
    );
    // Both are (token, index 0) but in different channels: distinct notes, and
    // the dedupe must not collapse them.
    expect(result.notes.map((n) => n.index).toList(), [0, 0]);
  });

  test('an unkeyable note does not inflate the balance', () {
    final result = _key(
      [
        _note(sender: _self, channelKey: _selfChannelKey, index: 0, amount: 5),
        _note(sender: _bob, channelKey: _bobChannelKey, index: 0, amount: 999),
      ],
      const [],
    );
    final total = result.notes.fold(BigInt.zero, (s, n) => s + n.amount);
    expect(total, BigInt.from(5));
    expect(result.unspendable, 1);
  });
}
