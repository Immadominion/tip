/// The tip and claim screens.
///
/// Both are checked for the same thing: refusing to act on a link they cannot
/// vouch for, and telling the user what a tip actually costs before they pay
/// for it.
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
import 'package:tip/src/screens/claim_screen.dart';
import 'package:tip/src/screens/tip_screen.dart';
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
          TokenAmount.parse('10', _strk),
          TokenAmount.zero(_network.tokens[1]),
        ],
        failures: const {},
      );

  @override
  Future<bool> isDeployed(Felt address) async => true;
}

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

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: TipTheme.light, home: child));
  await tester.pump();
}

void main() {
  group('tip screen', () {
    testWidgets('it explains that the recipient needs no wallet',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));

      expect(find.textContaining('no wallet yet'), findsOneWidget);
      wallet.dispose();
    });

    testWidgets('it shows the fee line before anything is paid',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));

      expect(find.text('Fees to create and claim'), findsOneWidget);
      expect(find.text('Total you pay'), findsOneWidget);
      wallet.dispose();
    });

    testWidgets('it says the unused fee goes to the recipient, not back',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));

      expect(
        find.textContaining('goes to the person claiming it, not'),
        findsOneWidget,
      );
      wallet.dispose();
    });

    testWidgets('the button is dead until an amount is entered',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      wallet.dispose();
    });

    testWidgets('a failed price offers a retry rather than dying quietly',
        (tester) async {
      // The stub chain cannot estimate, which is exactly the state a flaky
      // public endpoint produces.
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));
      await tester.pumpAndSettle();

      expect(find.text('Try again'), findsOneWidget);
      wallet.dispose();
    });

    testWidgets('the error is one sentence, not an error inside an error',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, TipScreen(wallet: wallet));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not price a tip:'), findsNothing);
      wallet.dispose();
    });
  });

  group('claim screen', () {
    testWidgets('lookup is unavailable until a link is pasted',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, ClaimScreen(wallet: wallet));

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      wallet.dispose();
    });

    testWidgets('a mangled link is refused before any lookup', (tester) async {
      final wallet = await _wallet();
      await _pump(tester, ClaimScreen(wallet: wallet));

      await tester.enterText(find.byType(TextField), 'https://usetip.xyz/claim');
      await tester.pump();

      expect(find.textContaining('no claim code'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      wallet.dispose();
    });

    testWidgets('a truncated code is refused rather than looked up',
        (tester) async {
      final wallet = await _wallet();
      await _pump(tester, ClaimScreen(wallet: wallet));

      await tester.enterText(find.byType(TextField), 'https://usetip.xyz/claim#abcd');
      await tester.pump();

      expect(find.textContaining('wrong length'), findsOneWidget);
      wallet.dispose();
    });

    testWidgets('a tip can be scanned instead of pasted', (tester) async {
      final wallet = await _wallet();
      await _pump(tester, ClaimScreen(wallet: wallet));

      expect(find.byTooltip('Scan'), findsOneWidget);
      wallet.dispose();
    });

    testWidgets('a well-formed link enables the lookup', (tester) async {
      final wallet = await _wallet();
      await _pump(tester, ClaimScreen(wallet: wallet));

      final key = ClaimLinks.create(
        accountClassHash: _network.accountClassHash,
      );
      await tester.enterText(find.byType(TextField), key.link().toString());
      await tester.pump();

      expect(find.textContaining('wrong length'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      wallet.dispose();
    });
  });
}
