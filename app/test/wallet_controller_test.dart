/// The controller's own logic, with the chain replaced by a stub.
///
/// What is worth testing here is what the screen shows when the chain is slow,
/// partly broken, or reports a balance of nothing. Those are the states a user
/// hits and the ones a happy-path demo never reaches.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_controller.dart';

final _network = TipNetwork.sepolia;
final _strk = _network.tokens[0];
final _eth = _network.tokens[1];

class _StubChain extends ChainClient {
  _StubChain({
    required this.snapshot,
    this.deployed = true,
    this.failure,
  }) : super(network: _network);

  BalanceSnapshot snapshot;
  bool deployed;
  Object? failure;

  @override
  Future<BalanceSnapshot> balances(Felt address) async {
    if (failure != null) throw failure!;
    return snapshot;
  }

  @override
  Future<bool> isDeployed(Felt address) async {
    if (failure != null) throw failure!;
    return deployed;
  }
}

WalletController _controller(ChainClient client) => WalletController(
      keys: WalletFactory(accountClassHash: _network.accountClassHash)
          .deriveFrom(WalletFactory.generateMnemonic()),
      client: client,
    );

BalanceSnapshot _snapshot({
  String strk = '0',
  String eth = '0',
  Map<Object, Object> failures = const {},
}) =>
    BalanceSnapshot(
      amounts: [
        TokenAmount.parse(strk, _strk),
        TokenAmount.parse(eth, _eth),
      ],
      failures: failures.cast(),
    );

void main() {
  test('before the first read it reports that it has not loaded', () {
    final controller = _controller(_StubChain(snapshot: _snapshot()));
    expect(controller.hasLoaded, isFalse);
    expect(controller.feeBalance.isZero, isTrue);
    controller.dispose();
  });

  test('a refresh fills in balances and deployment', () async {
    final controller = _controller(
      _StubChain(snapshot: _snapshot(strk: '12.5', eth: '0.25')),
    );
    await controller.refresh();

    expect(controller.hasLoaded, isTrue);
    expect(controller.feeBalance.format(), equals('12.5'));
    expect(controller.balanceOf(_eth).format(), equals('0.25'));
    expect(controller.isDeployed, isTrue);
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('a failed refresh records the error and stays unloaded', () async {
    final controller = _controller(
      _StubChain(snapshot: _snapshot(), failure: const ChainException('down')),
    );
    await controller.refresh();

    expect(controller.error, isA<ChainException>());
    expect(controller.hasLoaded, isFalse);
    expect(controller.isRefreshing, isFalse);
    controller.dispose();
  });

  test('a later failure does not erase the balances already shown', () async {
    // Showing the last known balance beats blanking the screen every time a
    // free endpoint hiccups, as long as the error is surfaced alongside it.
    final chain = _StubChain(snapshot: _snapshot(strk: '5'));
    final controller = _controller(chain);
    await controller.refresh();
    expect(controller.feeBalance.format(), equals('5'));

    chain.failure = const ChainException('down');
    await controller.refresh();

    expect(controller.error, isA<ChainException>());
    expect(controller.feeBalance.format(), equals('5'));
    expect(controller.hasLoaded, isTrue);
    controller.dispose();
  });

  test('the fee token stays listed at zero, since its absence blocks sending',
      () async {
    final controller = _controller(_StubChain(snapshot: _snapshot()));
    await controller.refresh();

    final symbols = controller.visibleBalances.map((a) => a.token.symbol);
    expect(symbols, contains('STRK'));
    expect(symbols, isNot(contains('ETH')));
    controller.dispose();
  });

  test('the fee token leads the list, then the largest balances', () async {
    final controller = _controller(
      _StubChain(snapshot: _snapshot(strk: '1', eth: '900')),
    );
    await controller.refresh();

    expect(
      controller.visibleBalances.map((a) => a.token.symbol).toList(),
      equals(['STRK', 'ETH']),
    );
    controller.dispose();
  });

  test('an unreadable token is reported rather than shown as zero', () async {
    final controller = _controller(
      _StubChain(snapshot: _snapshot(failures: {_eth: 'node down'})),
    );
    await controller.refresh();

    expect(controller.balances!.isComplete, isFalse);
    expect(controller.balances!.failures.keys, contains(_eth));
    controller.dispose();
  });

  test('an undeployed account is reported as such, not as an error', () async {
    final controller = _controller(
      _StubChain(snapshot: _snapshot(), deployed: false),
    );
    await controller.refresh();

    expect(controller.isDeployed, isFalse);
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('notifies listeners around a refresh', () async {
    final controller = _controller(_StubChain(snapshot: _snapshot(strk: '1')));
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.refresh();

    // One when the refresh starts, one when it finishes, so a spinner can
    // appear and disappear.
    expect(notifications, equals(2));
    controller.dispose();
  });
}
