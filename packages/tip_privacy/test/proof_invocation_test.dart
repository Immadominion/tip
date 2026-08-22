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

    test('resource bounds default to zero and serialise in full', () {
      final bounds =
          _build().toJson()['resource_bounds'] as Map<String, dynamic>;
      expect(bounds.keys, containsAll(['l1_gas', 'l1_data_gas', 'l2_gas']));
      expect((bounds['l2_gas'] as Map)['max_amount'], equals('0x0'));
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
}
