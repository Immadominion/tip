/// Pricing a public transfer.
///
/// `transfer_service.dart` is the only file in the app that signs an ordinary
/// transfer, and it had no tests at all. Everything it decides is a decision
/// about somebody's money: whether they can afford the thing they asked for,
/// what to tell them when they cannot, and how much of a balance is actually
/// sendable once the fee is kept back.
///
/// The subtlety worth guarding is that when the token being sent *is* the fee
/// token, the amount and the fee come out of the same pot. Checking them
/// separately is how a wallet lets someone send their entire balance and then
/// fail to pay for the transaction that sends it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/fee_bounds.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/chain/signing_account.dart';
import 'package:tip/src/chain/token.dart';
import 'package:tip/src/chain/transfer_service.dart';

final _network = TipNetwork.sepolia;
final _strk = _network.feeToken;

/// A second token, so the "different pot" branch can be exercised.
final _other = TipToken(
  address: Felt.fromHexString('0xdeadbeef'),
  symbol: 'TEST',
  name: 'Test token',
  decimals: 18,
);

final _from = SigningAccount(
  address: Felt.fromHexString('0xa11ce'),
  privateKey: Felt.fromHexString('0x1'),
  publicKey: Felt.fromHexString('0x2'),
);
final _to = Felt.fromHexString('0xb0b');

class _StubChain extends ChainClient {
  _StubChain({
    required this.held,
    this.deployed = true,
  }) : super(network: _network);

  /// Symbol to balance, as a decimal string.
  final Map<String, String> held;
  final bool deployed;

  @override
  Future<bool> isDeployed(Felt address) async => deployed;

  @override
  Future<TokenAmount> balanceOf({
    required TipToken token,
    required Felt address,
  }) async =>
      TokenAmount.parse(held[token.symbol] ?? '0', token);
}

/// Replaces the one line that has to reach a node.
class _StubTransfers extends TransferService {
  _StubTransfers({
    required super.client,
    required this.maxFee,
    this.estimateThrows = false,
  });

  /// The ceiling the node would quote, in whole STRK.
  final String maxFee;
  final bool estimateThrows;

  int estimates = 0;

  @override
  Future<FeeBounds> estimateTransfer({
    required SigningAccount from,
    required TipToken token,
    required Felt recipient,
    required TokenAmount amount,
  }) async {
    estimates++;
    if (estimateThrows) throw Exception('node said no');
    // maxFee is computed from the consumed-times-price terms, so the whole
    // ceiling goes on l2 at a price of one.
    final ceiling = TokenAmount.parse(maxFee, _strk).raw;
    return FeeBounds(
      l1GasConsumed: Felt.fromInt(0),
      l1GasPrice: Felt.fromInt(0),
      l1DataGasConsumed: Felt.fromInt(0),
      l1DataGasPrice: Felt.fromInt(0),
      l2GasConsumed: Felt(ceiling),
      l2GasPrice: Felt.fromInt(1),
      estimatedFee: ceiling * BigInt.two ~/ BigInt.from(3),
    );
  }
}

void main() {
  group('what is refused before anything is priced', () {
    test('an amount of zero is refused, and costs no estimate', () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.zero(_strk),
      );
      expect(quote.blockers, isNotEmpty);
      expect(quote.canSend, isFalse);
      expect(service.estimates, 0);
    });

    test('more than the balance is refused without an estimate', () async {
      // Estimating a transfer the account cannot afford reverts inside the
      // estimate, so there is nothing useful to price until the amount fits.
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '1'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('5', _strk),
      );
      expect(quote.blockers.first, contains('less than that'));
      expect(service.estimates, 0);
    });

    test('an undeployed account says so, rather than quoting a fee', () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}, deployed: false),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('1', _strk),
      );
      expect(quote.needsDeployment, isTrue);
      expect(quote.fee, isNull);
      expect(quote.maxFee, isNull);
      expect(service.estimates, 0);
    });
  });

  group('the amount and the fee come out of the same pot', () {
    test('sending the whole balance of the fee token is refused', () async {
      // The failure this exists for: checking the amount against the balance
      // and the fee against the balance separately lets both pass, and then the
      // transaction cannot pay for itself.
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('10', _strk),
      );
      expect(quote.canSend, isFalse);
      expect(quote.blockers.join(), contains('nothing for the fee'));
    });

    test('and it suggests an amount that would actually work', () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('10', _strk),
      );
      // Balance minus the ceiling, not minus the estimate.
      expect(quote.blockers.join(), contains('9'));
    });

    test('an amount that leaves room for the fee is allowed', () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('8', _strk),
      );
      expect(quote.blockers, isEmpty);
      expect(quote.canSend, isTrue);
    });

    test('exactly balance-minus-ceiling is allowed, not off by one', () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'STRK': '10'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _strk,
        recipient: _to,
        amount: TokenAmount.parse('9', _strk),
      );
      expect(quote.canSend, isTrue, reason: 'the boundary must be sendable');
    });
  });

  group('a different token is a different pot', () {
    test('the fee is checked against STRK, not against the token sent',
        () async {
      // Sending the whole balance of another token is fine, as long as there is
      // STRK to pay with.
      final service = _StubTransfers(
        client: _StubChain(held: {'TEST': '5', 'STRK': '2'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _other,
        recipient: _to,
        amount: TokenAmount.parse('5', _other),
      );
      expect(quote.canSend, isTrue);
    });

    test('no STRK to pay with is refused, however much of the token there is',
        () async {
      final service = _StubTransfers(
        client: _StubChain(held: {'TEST': '5', 'STRK': '0'}),
        maxFee: '1',
      );
      final quote = await service.quote(
        from: _from,
        token: _other,
        recipient: _to,
        amount: TokenAmount.parse('1', _other),
      );
      expect(quote.canSend, isFalse);
      expect(quote.blockers.join(), contains('cover the fee'));
    });
  });

  test('a refused estimate is a blocker, not a crash', () async {
    final service = _StubTransfers(
      client: _StubChain(held: {'STRK': '10'}),
      maxFee: '1',
      estimateThrows: true,
    );
    final quote = await service.quote(
      from: _from,
      token: _strk,
      recipient: _to,
      amount: TokenAmount.parse('1', _strk),
    );
    expect(quote.canSend, isFalse);
    expect(quote.blockers.join(), contains('Could not work out the fee'));
    expect(quote.maxFee, isNull);
  });

  test('the quote reports the ceiling, not the estimate, as maxFee', () async {
    // The ceiling is what the account has to hold. Reporting the estimate here
    // is how a wallet lets someone approve a transaction they cannot submit.
    final service = _StubTransfers(
      client: _StubChain(held: {'STRK': '10'}),
      maxFee: '3',
    );
    final quote = await service.quote(
      from: _from,
      token: _strk,
      recipient: _to,
      amount: TokenAmount.parse('1', _strk),
    );
    expect(quote.maxFee!.raw, TokenAmount.parse('3', _strk).raw);
    expect(quote.fee!.raw, lessThan(quote.maxFee!.raw));
  });
}
