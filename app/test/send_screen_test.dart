/// The send screen's compose stage.
///
/// Everything here is about refusing to proceed. The interesting behaviour of
/// a send screen is not the happy path, it is which mistakes it catches before
/// a signature exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/screens/send_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_controller.dart';

final _network = TipNetwork.sepolia;
final _strk = _network.feeToken;

class _StubChain extends ChainClient {
  _StubChain() : super(network: _network);

  @override
  Future<BalanceSnapshot> balances(Felt address) async => BalanceSnapshot(
        amounts: [
          TokenAmount.parse('42.5', _strk),
          TokenAmount.zero(_network.tokens[1]),
        ],
        failures: const {},
      );

  @override
  Future<bool> isDeployed(Felt address) async => true;
}

Future<WalletController> _wallet() async {
  final controller = WalletController(
    keys: WalletFactory(accountClassHash: _network.accountClassHash)
        .deriveFrom(WalletFactory.generateMnemonic()),
    client: _StubChain(),
  );
  await controller.refresh();
  return controller;
}

Future<void> _pump(WidgetTester tester, WalletController wallet) =>
    tester.pumpWidget(
      MaterialApp(theme: TipTheme.light, home: SendScreen(wallet: wallet)),
    );

Finder get _reviewButton => find.widgetWithText(FilledButton, 'Review');

bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_reviewButton).onPressed != null;

void main() {
  testWidgets('review is unavailable until both fields are filled',
      (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    expect(_enabled(tester), isFalse);

    await tester.enterText(find.byType(TextField).first, '0x1234abcd');
    await tester.pump();
    expect(_enabled(tester), isFalse, reason: 'amount is still empty');

    await tester.enterText(find.byType(TextField).last, '1.5');
    await tester.pump();
    expect(_enabled(tester), isTrue);

    wallet.dispose();
  });

  testWidgets('an Ethereum address is refused by name', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    await tester.enterText(
      find.byType(TextField).first,
      '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
    );
    await tester.enterText(find.byType(TextField).last, '1');
    await tester.pump();

    expect(find.textContaining('Ethereum'), findsOneWidget);
    expect(_enabled(tester), isFalse);

    wallet.dispose();
  });

  testWidgets('an address that is not hex is refused', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    await tester.enterText(find.byType(TextField).first, '0xzzzz');
    await tester.pump();

    expect(find.textContaining('not hex'), findsOneWidget);
    wallet.dispose();
  });

  testWidgets('an amount with more precision than STRK has is refused',
      (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    await tester.enterText(find.byType(TextField).first, '0x1234abcd');
    await tester.enterText(
      find.byType(TextField).last,
      '0.0000000000000000001',
    );
    await tester.pump();

    expect(find.textContaining('decimal places'), findsOneWidget);
    expect(_enabled(tester), isFalse);

    wallet.dispose();
  });

  testWidgets('the balance is shown next to the amount', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    expect(find.text('Balance 42.5 STRK'), findsOneWidget);
    wallet.dispose();
  });

  testWidgets('it says plainly that the transfer is public', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    expect(find.textContaining('public transfer'), findsOneWidget);
    wallet.dispose();
  });

  testWidgets('every token on the network can be chosen', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    for (final token in _network.tokens) {
      expect(
        find.widgetWithText(ChoiceChip, token.symbol),
        findsOneWidget,
        reason: token.symbol,
      );
    }
    wallet.dispose();
  });
}
