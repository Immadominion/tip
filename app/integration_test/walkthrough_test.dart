/// Walks the app on a real device, pausing on each screen.
///
/// Not an assertion suite. This exists so the interface can be looked at on
/// actual hardware, at actual sizes, with actual fonts, which is the only way
/// to catch a layout that only breaks on a phone. Run it and screenshot from
/// outside:
///
///   `flutter test integration_test/walkthrough_test.dart -d DEVICE`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/screens/boot_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_store.dart';

/// Long enough to screenshot from outside without racing the test.
const _hold = Duration(seconds: 4);

class _MemoryWalletStore extends WalletStore {
  _MemoryWalletStore({this.stored});

  String? stored;

  @override
  Future<String?> readSeedPhrase() async => stored;

  @override
  Future<void> writeSeedPhrase(String mnemonic) async => stored = mnemonic;

  @override
  Future<void> deleteSeedPhrase() async => stored = null;
}

class _MemoryActivityStore extends ActivityStore {
  List<ActivityEntry> entries = const [];

  @override
  Future<List<ActivityEntry>> read() async => entries;

  @override
  Future<void> write(List<ActivityEntry> next) async => entries = next;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('walk every screen', (tester) async {
    final store = _MemoryWalletStore(stored: WalletFactory.generateMnemonic());

    await tester.pumpWidget(
      MaterialApp(
        title: 'tip',
        debugShowCheckedModeBanner: false,
        theme: TipTheme.light,
        darkTheme: TipTheme.dark,
        home: BootScreen(
          store: store,
          activityStore: _MemoryActivityStore(),
        ),
      ),
    );

    Future<void> hold(String what) async {
      debugPrint('SCREEN: $what');
      await tester.pumpAndSettle();
      await tester.pump(_hold);
      await Future<void>.delayed(_hold);
    }

    await hold('home');

    await tester.tap(find.text('Send'));
    await hold('send');
    await tester.tap(find.byTooltip('Back').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Receive'));
    await hold('receive');
    await tester.tap(find.byTooltip('Back').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tip'));
    await hold('tip');
    await tester.tap(find.byTooltip('Back').first);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('tip link'));
    await hold('claim');
    await tester.tap(find.byTooltip('Back').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await hold('settings');
  });
}
