/// Note selection and the shield, unshield, and private transfer flows.
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _b(int v) => BigInt.from(v);

final _token = _b(0x1234);
final _otherToken = _b(0x9999);

SpendableNote _note(int amount, {int index = 0, BigInt? token}) =>
    SpendableNote(
      channelKey: _b(0xdef),
      token: token ?? _token,
      index: index,
      amount: _b(amount),
    );

/// Predictable randomness so a flow's output can be asserted exactly.
class _FixedRandom implements RandomSource {
  int _felt = 0;
  int _salt = 0;

  @override
  BigInt nextFelt() => _b(0xf00 + _felt++);

  @override
  BigInt nextNoteSalt() => _b(0x500 + _salt++);
}

void main() {
  group('selectNotes', () {
    test('picks a single note that covers the amount', () {
      final selection = selectNotes(
        available: [_note(100, index: 0), _note(50, index: 1)],
        token: _token,
        amount: _b(80),
      );
      expect(selection.notes, hasLength(1));
      expect(selection.notes.single.amount, equals(_b(100)));
      expect(selection.change, equals(_b(20)));
    });

    test('combines notes when no single one is enough', () {
      final selection = selectNotes(
        available: [_note(30, index: 0), _note(40, index: 1)],
        token: _token,
        amount: _b(60),
      );
      expect(selection.notes, hasLength(2));
      expect(selection.total, equals(_b(70)));
      expect(selection.change, equals(_b(10)));
    });

    test('prefers larger notes to keep the spend count down', () {
      // Every spent note publishes a nullifier, so fewer is quieter on chain.
      final selection = selectNotes(
        available: [
          _note(10, index: 0),
          _note(90, index: 1),
          _note(10, index: 2),
        ],
        token: _token,
        amount: _b(85),
      );
      expect(selection.notes, hasLength(1));
      expect(selection.notes.single.index, equals(1));
    });

    test('leaves no change on an exact match', () {
      final selection = selectNotes(
        available: [_note(100)],
        token: _token,
        amount: _b(100),
      );
      expect(selection.change, equals(BigInt.zero));
    });

    test('ignores notes in other tokens', () {
      expect(
        () => selectNotes(
          available: [_note(1000, token: _otherToken)],
          token: _token,
          amount: _b(1),
        ),
        throwsA(isA<InsufficientNotesException>()),
      );
    });

    test('reports how much was actually available when short', () {
      try {
        selectNotes(
          available: [_note(30), _note(20, index: 1)],
          token: _token,
          amount: _b(100),
        );
        fail('expected InsufficientNotesException');
      } on InsufficientNotesException catch (e) {
        expect(e.requested, equals(_b(100)));
        expect(e.available, equals(_b(50)));
      }
    });

    test('rejects a non-positive amount', () {
      expect(
        () => selectNotes(
          available: [_note(100)],
          token: _token,
          amount: BigInt.zero,
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('buildShield', () {
    test('deposits then creates the matching note', () {
      final actions = buildShield(
        token: _token,
        amount: _b(1000),
        recipientAddr: _b(0x123),
        recipientPublicKey: _b(0xabc),
        noteIndex: 0,
        random: _FixedRandom(),
      );

      expect(actions, hasLength(2));
      expect(actions[0], isA<Deposit>());
      expect(actions[1], isA<CreateEncNote>());
      expect((actions[0] as Deposit).amount, equals(_b(1000)));
      // The note records the same value that was deposited.
      expect((actions[1] as CreateEncNote).amount, equals(_b(1000)));
    });
  });

  group('buildUnshield', () {
    test('spends notes, withdraws, and returns change', () {
      final actions = buildUnshield(
        available: [_note(100)],
        token: _token,
        amount: _b(60),
        toAddr: _b(0xaaa),
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 7,
        random: _FixedRandom(),
      );

      // Change before the withdrawal. The pool applies actions in phase order
      // and creating a note is an earlier phase than withdrawing, so the other
      // way round reverts with ACTIONS_OUT_OF_ORDER. This test asserted the
      // wrong order until a real unshield proved it on chain.
      expect(actions, hasLength(3));
      expect(actions[0], isA<UseNote>());
      expect(actions[1], isA<CreateEncNote>());
      expect(actions[2], isA<Withdraw>());
      expect(() => assertPhaseOrder(actions), returnsNormally);

      expect((actions[2] as Withdraw).amount, equals(_b(60)));
      final change = actions[1] as CreateEncNote;
      expect(change.amount, equals(_b(40)));
      expect(change.recipientAddr, equals(_b(0x123)));
      expect(change.index, equals(7));
    });

    test('every flow it builds is in an order the pool accepts', () {
      // The check the library now exposes, applied to the library's own output.
      final unshield = buildUnshield(
        available: [_note(100)],
        token: _token,
        amount: _b(60),
        toAddr: _b(0xaaa),
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 7,
        random: _FixedRandom(),
      );
      final transfer = buildPrivateTransfer(
        available: [_note(100)],
        token: _token,
        amount: _b(60),
        recipientAddr: _b(0xaaa),
        recipientPublicKey: _b(0xbbb),
        recipientNoteIndex: 0,
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 7,
        random: _FixedRandom(),
      );
      final shield = buildShield(
        token: _token,
        amount: _b(10),
        recipientAddr: _b(0x123),
        recipientPublicKey: _b(0xabc),
        noteIndex: 0,
        random: _FixedRandom(),
      );

      for (final batch in [unshield, transfer, shield]) {
        expect(() => assertPhaseOrder(batch), returnsNormally);
      }
    });

    test('omits the change note on an exact spend', () {
      final actions = buildUnshield(
        available: [_note(100)],
        token: _token,
        amount: _b(100),
        toAddr: _b(0xaaa),
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 7,
        random: _FixedRandom(),
      );

      expect(actions, hasLength(2));
      expect(actions.whereType<CreateEncNote>(), isEmpty);
    });

    test('spends one note per input', () {
      final actions = buildUnshield(
        available: [_note(30, index: 0), _note(40, index: 1)],
        token: _token,
        amount: _b(65),
        toAddr: _b(0xaaa),
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 7,
        random: _FixedRandom(),
      );

      expect(actions.whereType<UseNote>(), hasLength(2));
      expect(
        (actions.whereType<CreateEncNote>().single).amount,
        equals(_b(5)),
      );
    });

    test('refuses to build when the balance is short', () {
      expect(
        () => buildUnshield(
          available: [_note(10)],
          token: _token,
          amount: _b(100),
          toAddr: _b(0xaaa),
          selfAddr: _b(0x123),
          selfPublicKey: _b(0xabc),
          changeNoteIndex: 7,
          random: _FixedRandom(),
        ),
        throwsA(isA<InsufficientNotesException>()),
      );
    });
  });

  group('buildPrivateTransfer', () {
    test('pays the recipient and keeps the change', () {
      final actions = buildPrivateTransfer(
        available: [_note(100)],
        token: _token,
        amount: _b(70),
        recipientAddr: _b(0x456),
        recipientPublicKey: _b(0xbcd),
        recipientNoteIndex: 0,
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 3,
        random: _FixedRandom(),
      );

      expect(actions, hasLength(3));
      final notes = actions.whereType<CreateEncNote>().toList();
      expect(notes, hasLength(2));

      expect(notes[0].recipientAddr, equals(_b(0x456)));
      expect(notes[0].amount, equals(_b(70)));
      expect(notes[1].recipientAddr, equals(_b(0x123)));
      expect(notes[1].amount, equals(_b(30)));
    });

    test('never emits a Withdraw, so nothing becomes public', () {
      final actions = buildPrivateTransfer(
        available: [_note(100)],
        token: _token,
        amount: _b(70),
        recipientAddr: _b(0x456),
        recipientPublicKey: _b(0xbcd),
        recipientNoteIndex: 0,
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 3,
        random: _FixedRandom(),
      );

      expect(actions.whereType<Withdraw>(), isEmpty);
      expect(actions.whereType<Deposit>(), isEmpty);
    });

    test('gives each note a distinct salt', () {
      final actions = buildPrivateTransfer(
        available: [_note(100)],
        token: _token,
        amount: _b(70),
        recipientAddr: _b(0x456),
        recipientPublicKey: _b(0xbcd),
        recipientNoteIndex: 0,
        selfAddr: _b(0x123),
        selfPublicKey: _b(0xabc),
        changeNoteIndex: 3,
        random: _FixedRandom(),
      );

      // A reused salt would link the recipient's note to the change note and
      // undo the privacy of the transfer.
      final salts =
          actions.whereType<CreateEncNote>().map((n) => n.salt).toSet();
      expect(salts, hasLength(2));
    });

    test('encodes to valid calldata end to end', () {
      final encoded = encodeActions(
        buildPrivateTransfer(
          available: [_note(100)],
          token: _token,
          amount: _b(70),
          recipientAddr: _b(0x456),
          recipientPublicKey: _b(0xbcd),
          recipientNoteIndex: 0,
          selfAddr: _b(0x123),
          selfPublicKey: _b(0xabc),
          changeNoteIndex: 3,
          random: _FixedRandom(),
        ),
      );

      expect(encoded.first, equals(_b(3)));
      expect(encoded[1], equals(_b(6))); // UseNote
    });
  });

  _channelSetupTests();
}

void _channelSetupTests() {
  final recipient = BigInt.from(0xabc);
  final recipientKey = BigInt.from(0xdef);
  final channelKey = BigInt.from(0x111);
  final token = BigInt.from(0x222);

  List<ClientAction> setup({
    bool channelExists = false,
    bool subchannelExists = false,
  }) =>
      buildChannelSetup(
        recipientAddr: recipient,
        recipientPublicKey: recipientKey,
        channelKey: channelKey,
        token: token,
        channelIndex: 0,
        subchannelIndex: 0,
        random: _FixedRandom(),
        channelExists: channelExists,
        subchannelExists: subchannelExists,
      );

  group('buildChannelSetup', () {
    test('opens both when neither exists', () {
      final actions = setup();
      expect(
        actions.map((a) => a.kind),
        equals([ClientActionKind.openChannel, ClientActionKind.openSubchannel]),
      );
    });

    test('opens only the subchannel when the channel is already there', () {
      // Opening a channel that exists reverts the whole transaction, taking
      // the deposit with it.
      final actions = setup(channelExists: true);
      expect(actions.single.kind, equals(ClientActionKind.openSubchannel));
    });

    test('opens nothing once both exist', () {
      expect(setup(channelExists: true, subchannelExists: true), isEmpty);
    });

    test('the subchannel carries the channel key and the token', () {
      final subchannel = setup(channelExists: true).single as OpenSubchannel;
      expect(subchannel.channelKey, equals(channelKey));
      expect(subchannel.token, equals(token));
      expect(subchannel.recipientPublicKey, equals(recipientKey));
    });
  });

  _secureRandomTests();
}

void _secureRandomTests() {
  group('SecureRandomSource', () {
    test('a note salt is inside the bounds the contract accepts', () {
      // Zero means absent, one is reserved for open notes, and the salt is
      // 120 bits. All three are asserted by the contract.
      final source = SecureRandomSource();
      for (var i = 0; i < 200; i++) {
        final salt = source.nextNoteSalt();
        expect(salt, greaterThan(BigInt.one));
        expect(salt, lessThan(twoPow120));
      }
    });

    test('a felt is never zero', () {
      final source = SecureRandomSource();
      for (var i = 0; i < 200; i++) {
        expect(source.nextFelt(), isNot(equals(BigInt.zero)));
      }
    });

    test('it does not repeat itself', () {
      // A reused salt links two transactions that should look unrelated.
      final source = SecureRandomSource();
      final seen = {for (var i = 0; i < 200; i++) source.nextNoteSalt()};
      expect(seen, hasLength(200));
    });

    test('a zero draw becomes a usable value rather than a rejected one', () {
      final source = SecureRandomSource(_AlwaysZero());
      expect(source.nextFelt(), equals(BigInt.one));
      expect(source.nextNoteSalt(), equals(BigInt.two));
    });
  });
}

/// Forces the branch that a real generator reaches once in 2^248 draws.
class _AlwaysZero implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
