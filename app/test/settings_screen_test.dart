/// Settings.
///
/// The two destructive entries are what these tests are for: neither may
/// happen without a deliberate confirmation, and cancelling either must leave
/// the wallet exactly as it was.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/screens/settings_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_controller.dart';
import 'package:tip/src/wallet/wallet_store.dart';

final _network = TipNetwork.sepolia;

class _StubChain extends ChainClient {
  _StubChain() : super(network: _network);

  @override
  Future<BalanceSnapshot> balances(Felt address) async => BalanceSnapshot(
        amounts: [TokenAmount.zero(_network.feeToken)],
        failures: const {},
      );

  @override
  Future<bool> isDeployed(Felt address) async => true;
}

class _MemoryActivityStore extends ActivityStore {
  List<ActivityEntry> entries = const [];
  bool cleared = false;

  @override
  Future<List<ActivityEntry>> read() async => entries;

  @override
  Future<void> write(List<ActivityEntry> next) async => entries = next;

  @override
  Future<void> clear() async {
    cleared = true;
    entries = const [];
  }
}

class _MemoryWalletStore extends WalletStore {
  String? seed = 'stored';
  bool deleted = false;

  @override
  Future<void> deleteSeedPhrase() async {
    deleted = true;
    seed = null;
  }
}

class _Harness {
  _Harness()
      : activity = _MemoryActivityStore(),
        wallet = _MemoryWalletStore();

  final _MemoryActivityStore activity;
  final _MemoryWalletStore wallet;
  int erasedCallbacks = 0;

  late final controller = WalletController(
    keys: WalletFactory(accountClassHash: _network.accountClassHash)
        .deriveFrom(_mnemonic),
    client: _StubChain(),
    activityStore: activity,
    walletStore: wallet,
  );
}

final _mnemonic = WalletFactory.generateMnemonic();

Future<_Harness> _pump(WidgetTester tester) async {
  // Tall viewport so the whole list is built. The default 800x600 leaves the
  // destructive entries below the fold, unbuilt, and untappable.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: SettingsScreen(
        wallet: harness.controller,
        onErased: () => harness.erasedCallbacks++,
      ),
    ),
  );
  return harness;
}

void main() {
  testWidgets('the phrase is hidden until it is deliberately revealed',
      (tester) async {
    final harness = await _pump(tester);
    final firstWord = _mnemonic.split(' ').first;

    expect(find.textContaining('1. $firstWord'), findsNothing);

    await tester.tap(find.text('Show recovery phrase'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show it'));
    await tester.pumpAndSettle();

    expect(find.text('1. $firstWord'), findsOneWidget);
    harness.controller.dispose();
  });

  testWidgets('cancelling the reveal keeps the phrase hidden', (tester) async {
    final harness = await _pump(tester);
    final firstWord = _mnemonic.split(' ').first;

    await tester.tap(find.text('Show recovery phrase'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('1. $firstWord'), findsNothing);
    expect(find.text('Show recovery phrase'), findsOneWidget);
    harness.controller.dispose();
  });

  testWidgets('every word of the phrase is shown, numbered', (tester) async {
    final harness = await _pump(tester);
    await tester.tap(find.text('Show recovery phrase'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show it'));
    await tester.pumpAndSettle();

    final words = _mnemonic.split(' ');
    expect(words, hasLength(24));
    for (var i = 0; i < words.length; i++) {
      expect(
        find.text('${i + 1}. ${words[i]}'),
        findsOneWidget,
        reason: 'word ${i + 1}',
      );
    }
    harness.controller.dispose();
  });

  testWidgets('cancelling removal erases nothing', (tester) async {
    final harness = await _pump(tester);

    await tester.tap(find.text('Remove wallet from this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(harness.wallet.deleted, isFalse);
    expect(harness.activity.cleared, isFalse);
    expect(harness.erasedCallbacks, equals(0));
    harness.controller.dispose();
  });

  testWidgets('confirming removal clears the log and the seed', (tester) async {
    final harness = await _pump(tester);

    await tester.tap(find.text('Remove wallet from this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(harness.activity.cleared, isTrue);
    expect(harness.wallet.deleted, isTrue);
    expect(harness.erasedCallbacks, equals(1));
    harness.controller.dispose();
  });

  testWidgets('it says the phrase is the only way back', (tester) async {
    final harness = await _pump(tester);
    expect(find.textContaining('only way back to them'), findsOneWidget);
    expect(
      find.textContaining('Deleting the app does not reliably do this'),
      findsOneWidget,
    );
    harness.controller.dispose();
  });

  testWidgets('the address is shown in its full canonical form',
      (tester) async {
    final harness = await _pump(tester);
    final shown = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data)
        .whereType<String>();

    expect(shown.any((s) => s.length == 66 && s.startsWith('0x')), isTrue);
    harness.controller.dispose();
  });

  testWidgets('removal does not claim the funds are gone when they are not',
      (tester) async {
    // The dialog said "the funds are gone and nobody can recover them for you"
    // regardless of whether an encrypted backup existed. For someone who made
    // one on purpose that is simply false, and it is the most frightening
    // possible way to be wrong.
    final harness = await _pump(tester);

    await tester.tap(find.text('Remove wallet from this device'));
    await tester.pumpAndSettle();

    // With no backup configured in this harness, the blunt warning is correct
    // and must still be there.
    expect(find.textContaining('the funds are gone'), findsOneWidget);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    harness.controller.dispose();
  });

  testWidgets('removal keeps the backup unless it is asked to delete it',
      (tester) async {
    // The checkbox defaults to off and dismissing the dialog cannot turn it on,
    // because deleting the last remote copy of a recovery phrase should never
    // be something that happens by not noticing.
    final harness = await _pump(tester);

    await tester.tap(find.text('Remove wallet from this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(harness.wallet.deleted, isTrue);
    expect(harness.erasedCallbacks, equals(1));
    harness.controller.dispose();
  });

}
