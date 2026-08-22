/// Cairo Serde encoding of the pool's ClientAction enum, and the input
/// validation the contract asserts.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _b(int v) => BigInt.from(v);

void main() {
  group('enum variant indices', () {
    test('follow the declaration order in actions.cairo', () {
      // These indices are the wire format. If the contract ever reorders its
      // enum, this test is the thing that should fail.
      expect(ClientActionKind.setViewingKey.variantIndex, equals(0));
      expect(ClientActionKind.openChannel.variantIndex, equals(1));
      expect(ClientActionKind.openSubchannel.variantIndex, equals(2));
      expect(ClientActionKind.createEncNote.variantIndex, equals(3));
      expect(ClientActionKind.createOpenNote.variantIndex, equals(4));
      expect(ClientActionKind.deposit.variantIndex, equals(5));
      expect(ClientActionKind.useNote.variantIndex, equals(6));
      expect(ClientActionKind.withdraw.variantIndex, equals(7));
      expect(ClientActionKind.invokeExternal.variantIndex, equals(8));
      expect(ClientActionKind.computeAndInvoke.variantIndex, equals(9));
    });
  });

  group('encoding', () {
    test('SetViewingKey is the variant index then its one field', () {
      expect(
        SetViewingKey(random: _b(0xabc)).encode(),
        equals([_b(0), _b(0xabc)]),
      );
    });

    test('Deposit encodes token then amount', () {
      expect(
        Deposit(token: _b(0x1234), amount: _b(1000)).encode(),
        equals([_b(5), _b(0x1234), _b(1000)]),
      );
    });

    test('u128 amounts occupy one felt, not a u256 pair', () {
      // The Cairo field is u128. Encoding it as a low/high pair would shift
      // every following field and produce calldata the contract misreads.
      final encoded =
          Deposit(token: _b(1), amount: twoPow128Bound - BigInt.one).encode();
      expect(encoded, hasLength(3));
      expect(encoded.last, equals(twoPow128Bound - BigInt.one));
    });

    test('Withdraw encodes its four fields in order', () {
      expect(
        Withdraw(
          toAddr: _b(0xaa),
          token: _b(0xbb),
          amount: _b(500),
          random: _b(0xcc),
        ).encode(),
        equals([_b(7), _b(0xaa), _b(0xbb), _b(500), _b(0xcc)]),
      );
    });

    test('UseNote encodes channel key, token, index', () {
      expect(
        UseNote(channelKey: _b(0xdef), token: _b(0x1234), index: 5).encode(),
        equals([_b(6), _b(0xdef), _b(0x1234), _b(5)]),
      );
    });

    test('CreateEncNote encodes all six fields in order', () {
      expect(
        CreateEncNote(
          recipientAddr: _b(0x456),
          recipientPublicKey: _b(0xabc),
          token: _b(0x1234),
          amount: _b(1000),
          index: 5,
          salt: _b(0x5678),
        ).encode(),
        equals([
          _b(3),
          _b(0x456),
          _b(0xabc),
          _b(0x1234),
          _b(1000),
          _b(5),
          _b(0x5678),
        ]),
      );
    });

    test('OpenSubchannel encodes all six fields in order', () {
      expect(
        OpenSubchannel(
          recipientAddr: _b(0x456),
          recipientPublicKey: _b(0xabc),
          channelKey: _b(0xdef),
          index: 2,
          token: _b(0x1234),
          salt: _b(0x5678),
        ).encode(),
        equals([
          _b(2),
          _b(0x456),
          _b(0xabc),
          _b(0xdef),
          _b(2),
          _b(0x1234),
          _b(0x5678),
        ]),
      );
    });

    test('InvokeExternal length-prefixes its calldata span', () {
      expect(
        InvokeExternal(
          contractAddress: _b(0x99),
          calldata: [_b(1), _b(2), _b(3)],
        ).encode(),
        equals([_b(8), _b(0x99), _b(3), _b(1), _b(2), _b(3)]),
      );
    });

    test('an empty span is a bare zero length', () {
      expect(
        InvokeExternal(contractAddress: _b(0x99), calldata: const []).encode(),
        equals([_b(8), _b(0x99), _b(0)]),
      );
    });

    test('ComputeAndInvoke encodes two spans back to back', () {
      expect(
        ComputeAndInvoke(
          contractAddress: _b(0x99),
          computeAdditionalData: [_b(7)],
          invokeAdditionalData: [_b(8), _b(9)],
        ).encode(),
        equals([_b(9), _b(0x99), _b(1), _b(7), _b(2), _b(8), _b(9)]),
      );
    });
  });

  group('batch encoding', () {
    test('prefixes the batch with its action count', () {
      final encoded = encodeActions([
        Deposit(token: _b(0x1234), amount: _b(1000)),
        UseNote(channelKey: _b(0xdef), token: _b(0x1234), index: 0),
      ]);

      expect(
        encoded,
        equals([
          _b(2), // two actions
          _b(5), _b(0x1234), _b(1000), // Deposit
          _b(6), _b(0xdef), _b(0x1234), _b(0), // UseNote
        ]),
      );
    });

    test('an empty batch is a single zero', () {
      expect(encodeActions(const []), equals([BigInt.zero]));
    });

    test('a shield reads as deposit then note creation', () {
      // The shape of a real shield: move tokens in, then create the note that
      // represents them privately.
      final actions = encodeActions([
        Deposit(token: _b(0x1234), amount: _b(1000)),
        CreateEncNote(
          recipientAddr: _b(0x456),
          recipientPublicKey: _b(0xabc),
          token: _b(0x1234),
          amount: _b(1000),
          index: 0,
          salt: _b(0x5678),
        ),
      ]);
      expect(actions.first, equals(_b(2)));
      expect(actions[1], equals(_b(5))); // Deposit
      expect(actions[4], equals(_b(3))); // CreateEncNote
    });
  });

  group('validation matching the contract asserts', () {
    test('rejects a zero random on SetViewingKey', () {
      expect(
        () => SetViewingKey(random: BigInt.zero),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a zero token on Deposit', () {
      expect(
        () => Deposit(token: BigInt.zero, amount: _b(1)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a zero amount on Deposit', () {
      expect(
        () => Deposit(token: _b(1), amount: BigInt.zero),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects every zero field on Withdraw', () {
      for (final broken in [
        () => Withdraw(
            toAddr: BigInt.zero, token: _b(1), amount: _b(1), random: _b(1)),
        () => Withdraw(
            toAddr: _b(1), token: BigInt.zero, amount: _b(1), random: _b(1)),
        () => Withdraw(
            toAddr: _b(1), token: _b(1), amount: BigInt.zero, random: _b(1)),
        () => Withdraw(
            toAddr: _b(1), token: _b(1), amount: _b(1), random: BigInt.zero),
      ]) {
        expect(broken, throwsA(isA<ProtocolException>()));
      }
    });

    test('allows a zero amount on CreateEncNote', () {
      // Explicitly permitted: it lets a client re-create a note at an index
      // burned by a revert, so index reuse does not leak information.
      expect(
        () => CreateEncNote(
          recipientAddr: _b(1),
          recipientPublicKey: _b(1),
          token: _b(1),
          amount: BigInt.zero,
          index: 0,
          salt: _b(2),
        ),
        returnsNormally,
      );
    });

    test('rejects a note salt of 0 or 1', () {
      // 0 means the note does not exist; 1 is reserved for open notes.
      for (final salt in [BigInt.zero, BigInt.one]) {
        expect(
          () => CreateEncNote(
            recipientAddr: _b(1),
            recipientPublicKey: _b(1),
            token: _b(1),
            amount: _b(1),
            index: 0,
            salt: salt,
          ),
          throwsA(isA<ProtocolException>()),
        );
      }
    });

    test('rejects a note salt of 2^120 or more', () {
      expect(
        () => CreateEncNote(
          recipientAddr: _b(1),
          recipientPublicKey: _b(1),
          token: _b(1),
          amount: _b(1),
          index: 0,
          salt: twoPow120,
        ),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => CreateEncNote(
          recipientAddr: _b(1),
          recipientPublicKey: _b(1),
          token: _b(1),
          amount: _b(1),
          index: 0,
          salt: twoPow120 - BigInt.one,
        ),
        returnsNormally,
      );
    });

    test('allows a zero channel key on UseNote', () {
      // The contract asserts only on the token here.
      expect(
        () => UseNote(channelKey: BigInt.zero, token: _b(1), index: 0),
        returnsNormally,
      );
    });

    test('rejects a zero contract address on the invoke actions', () {
      expect(
        () => InvokeExternal(contractAddress: BigInt.zero, calldata: const []),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => ComputeAndInvoke(
          contractAddress: BigInt.zero,
          computeAdditionalData: const [],
          invokeAdditionalData: const [],
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects an amount that overflows u128', () {
      expect(
        () => Deposit(token: _b(1), amount: twoPow128Bound),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a value that overflows the field', () {
      expect(
        () => SetViewingKey(random: feltPrime),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a negative index', () {
      expect(
        () => UseNote(channelKey: _b(1), token: _b(1), index: -1),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
