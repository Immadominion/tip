/// The send screen's compose stage.
///
/// Everything here is about refusing to proceed. The interesting behaviour of
/// a send screen is not the happy path, it is which mistakes it catches before
/// a signature exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_link.dart';
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

/// The real one reaches for the platform keystore, which never answers in a
/// widget test.
class _MemoryActivityStore extends ActivityStore {
  List<ActivityEntry> entries = const [];

  @override
  Future<List<ActivityEntry>> read() async => entries;

  @override
  Future<void> write(List<ActivityEntry> next) async => entries = next;
}

Future<WalletController> _wallet() async {
  final controller = WalletController(
    keys: WalletFactory(accountClassHash: _network.accountClassHash)
        .deriveFrom(WalletFactory.generateMnemonic()),
    client: _StubChain(),
    activityStore: _MemoryActivityStore(),
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

  testWidgets('an address can be scanned as well as typed', (tester) async {
    final wallet = await _wallet();
    await _pump(tester, wallet);

    expect(find.byTooltip('Scan'), findsOneWidget);
    expect(find.byTooltip('Paste'), findsOneWidget);
    wallet.dispose();
  });

  group('scanning the wrong code', () {
    final classHash = _network.accountClassHash;

    test('a tip link is named as such, not called an invalid address', () {
      final key = ClaimLinks.create(accountClassHash: classHash);
      final problem = scannedTipLinkProblem(
        key.link().toString(),
        accountClassHash: classHash,
      );
      expect(problem, isNotNull);
      expect(problem, contains('tip link'));
    });

    test('the tip scheme is caught too', () {
      final key = ClaimLinks.create(accountClassHash: classHash);
      expect(
        scannedTipLinkProblem(
          'tip://claim#${key.token}',
          accountClassHash: classHash,
        ),
        isNotNull,
      );
    });

    test('a real address is not flagged', () {
      expect(
        scannedTipLinkProblem(
          '0x30a7cef4289ca32268279642bfb19fcf924a8b34a919210f79920b366e1d0cc',
          accountClassHash: classHash,
        ),
        isNull,
      );
    });

    test('nonsense is left to the address validator to explain', () {
      expect(
        scannedTipLinkProblem('hello', accountClassHash: classHash),
        isNull,
      );
    });
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
