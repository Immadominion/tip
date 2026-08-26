/// The invocation handed to the proving service.
library;

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

BigInt _b(int v) => BigInt.from(v);

final _pool =
    BigInt.parse('254a6b2997ef52e9f830ce1f543f6b29768295e8d17e', radix: 16);
final _user =
    BigInt.parse('30a7cef4289ca32268279642bfb19fcf924a8b34', radix: 16);
final _viewingKey = BigInt.parse('2d64bcce836df7a8077cccb5cbcf7c41', radix: 16);
// selector('compile_actions'), passed in rather than computed here.
final _selector = BigInt.parse('1234abcd', radix: 16);

List<ClientAction> _actions() => [SetViewingKey(random: _b(0xabc123))];

ProofInvocation _build({List<ClientAction>? actions}) => buildProofInvocation(
      poolAddress: _pool,
      userAddress: _user,
      viewingKey: _viewingKey,
      actions: actions ?? _actions(),
      compileActionsSelector: _selector,
      signature: [_b(0xaa), _b(0xbb)],
    );

void main() {
  group('compileActionsCalldata', () {
    test('is user, viewing key, then the encoded actions', () {
      final calldata = compileActionsCalldata(
        userAddress: _user,
        viewingKey: _viewingKey,
        actions: _actions(),
      );
      // Matches the calldata the live pool accepted: 0x1 0x0 0xabc123.
      expect(calldata[0], equals(_user));
      expect(calldata[1], equals(_viewingKey));
      expect(calldata.sublist(2), equals([_b(1), _b(0), _b(0xabc123)]));
    });
  });

  group('wrapAsExecuteCalldata', () {
    test('uses the account multicall layout', () {
      expect(
        wrapAsExecuteCalldata(
          to: _b(0x111),
          selector: _b(0x222),
          calldata: [_b(7), _b(8)],
        ),
        // one call, target, selector, length, payload
        equals([_b(1), _b(0x111), _b(0x222), _b(2), _b(7), _b(8)]),
      );
    });

    test('an empty payload still carries its zero length', () {
      expect(
        wrapAsExecuteCalldata(to: _b(1), selector: _b(2), calldata: const []),
        equals([_b(1), _b(1), _b(2), _b(0)]),
      );
    });
  });

  group('buildProofInvocation', () {
    test('sends from the pool, not the user', () {
      // The counterintuitive part of the protocol, and the easiest thing to
      // get backwards.
      final invocation = _build();
      expect(invocation.senderAddress, equals('0x${_pool.toRadixString(16)}'));
      expect(
        invocation.senderAddress,
        isNot(equals('0x${_user.toRadixString(16)}')),
      );
    });

    test('the user address travels inside the calldata instead', () {
      final invocation = _build();
      expect(invocation.calldata, contains('0x${_user.toRadixString(16)}'));
    });

    test('wraps compile_actions as a single call', () {
      final calldata = _build().calldata;
      expect(calldata[0], equals('0x1')); // one call
      expect(calldata[1], equals('0x${_pool.toRadixString(16)}'));
      expect(calldata[2], equals('0x${_selector.toRadixString(16)}'));
      // Then the inner length, then user, viewing key, and the action span.
      expect(calldata[3], equals('0x5'));
      expect(calldata.length, equals(4 + 5));
    });

    test('serialises as a v3 INVOKE', () {
      final json = _build().toJson();
      expect(json['type'], equals('INVOKE'));
      expect(json['version'], equals('0x3'));
      expect(json['nonce'], equals('0x0'));
      expect(json['resource_bounds'], isA<Map<String, dynamic>>());
      expect(json['paymaster_data'], isEmpty);
    });

    test('carries the signature it was given', () {
      expect(_build().signature, equals(['0xaa', '0xbb']));
    });

    test('refuses an empty action list', () {
      expect(
        () => _build(actions: const []),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('L2 gas defaults to a limit the prover will accept', () {
      // The live prover rejects a zero L2 limit outright: it is the ceiling
      // the OS enforces on the execution, not a fee the user pays. This
      // invocation is never broadcast, so the safe upper bound is the right
      // default and asking for an estimate first would be a round trip spent
      // on nothing.
      final bounds =
          _build().toJson()['resource_bounds'] as Map<String, dynamic>;
      expect(bounds.keys, containsAll(['l1_gas', 'l1_data_gas', 'l2_gas']));
      expect(
        (bounds['l2_gas'] as Map)['max_amount'],
        equals(provingL2GasLimit),
      );
      expect((bounds['l2_gas'] as Map)['max_amount'], isNot(equals('0x0')));
    });

    test('the fee bounds stay at zero, since nothing is being paid for', () {
      final bounds =
          _build().toJson()['resource_bounds'] as Map<String, dynamic>;
      expect((bounds['l1_gas'] as Map)['max_amount'], equals('0x0'));
      expect((bounds['l1_data_gas'] as Map)['max_amount'], equals('0x0'));
      expect((bounds['l2_gas'] as Map)['max_price_per_unit'], equals('0x0'));
    });

    test('a multi-action batch lengthens the inner calldata', () {
      final invocation = _build(actions: [
        SetViewingKey(random: _b(0xabc)),
        Deposit(token: _b(0x1234), amount: _b(1000)),
      ]);
      // user(1) + viewing key(1) + count(1) + SetViewingKey(2) + Deposit(3)
      expect(invocation.calldata[3], equals('0x8'));
    });
  });

  _applyActionsTests();
}

void _applyActionsTests() {
  group('applyActionsCalldata', () {
    // The shape of a real proof message, from the live Sepolia prover: the
    // pool's class hash, then a length-prefixed Span<ServerAction>.
    const payload = [
      '0x56ab118a8a6e38efc93ad758cefe909fee421fa931ce3cf72df624d345623b2',
      '0x3',
      '0x0',
      '0xaaa',
      '0x1',
    ];

    test('drops the class hash and keeps the span intact', () {
      final calldata = applyActionsCalldata(messagePayload: payload);
      expect(calldata.first, equals('0x3'), reason: 'the span length leads');
      expect(calldata.sublist(0, 4), equals(payload.sublist(1)));
    });

    test('an absent attestation is Option::None, which is variant one', () {
      // The pool's ABI lists Some before None. Getting this backwards reads as
      // a malformed attestation rather than an absent one.
      expect(applyActionsCalldata(messagePayload: payload).last, equals('0x1'));
    });

    test('an attestation appends Some and its three fields', () {
      final calldata = applyActionsCalldata(
        messagePayload: payload,
        screening: const ScreeningAttestationFelts(
          issuedAt: '0x64',
          r: '0xa1',
          s: '0xb2',
        ),
      );
      expect(
        calldata.sublist(calldata.length - 4),
        equals(['0x0', '0x64', '0xa1', '0xb2']),
      );
    });

    test('the signature tuple carries no length prefix of its own', () {
      final calldata = applyActionsCalldata(
        messagePayload: payload,
        screening: const ScreeningAttestationFelts(
          issuedAt: '0x1',
          r: '0x2',
          s: '0x3',
        ),
      );
      // Some, issued_at, r, s. A tuple serialises as its members in order.
      expect(calldata.length, equals(payload.length - 1 + 4));
    });

    test('a payload too short to hold actions is refused', () {
      for (final short in [<String>[], ['0xc']]) {
        expect(
          () => applyActionsCalldata(messagePayload: short),
          throwsA(isA<ProtocolException>()),
          reason: '$short',
        );
      }
    });
  });
}
