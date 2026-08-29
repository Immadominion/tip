/// The screen lock.
///
/// A lock on a wallet has one absolute requirement: it must never be the
/// reason someone cannot reach their money. Everything below is a check on
/// that, not on whether the lock is hard to defeat.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/screens/boot_screen.dart';
import 'package:tip/src/screens/settings_screen.dart';
import 'package:tip/src/security/app_lock.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_controller.dart';
import 'package:tip/src/wallet/wallet_store.dart';

final _network = TipNetwork.sepolia;

class _FakeLock extends AppLock {
  _FakeLock({
    this.available = true,
    this.enabled = false,
    this.willSucceed = true,
    this.readThrows = false,
  });

  bool available;
  bool enabled;
  bool willSucceed;
  bool readThrows;
  int prompts = 0;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> isEnabled() async {
    if (readThrows) return false;
    return enabled;
  }

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<bool> authenticate({String reason = 'Unlock your wallet'}) async {
    prompts++;
    return willSucceed;
  }
}

class _FakeStore extends WalletStore {
  _FakeStore({this.stored});

  String? stored;

  @override
  Future<String?> readSeedPhrase() async => stored;

  @override
  Future<void> writeSeedPhrase(String mnemonic) async => stored = mnemonic;
}

class _MemoryActivityStore extends ActivityStore {
  @override
  Future<List<ActivityEntry>> read() async => const [];

  @override
  Future<void> write(List<ActivityEntry> next) async {}
}

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

Future<void> _boot(
  WidgetTester tester, {
  required WalletStore store,
  required AppLock lock,
  Duration lockAfter = const Duration(seconds: 30),
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: BootScreen(
        store: store,
        activityStore: _MemoryActivityStore(),
        lock: lock,
        lockAfter: lockAfter,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('at launch', () {
    testWidgets('an unlocked wallet opens straight to the home screen',
        (tester) async {
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: _FakeLock(enabled: false),
      );
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Unlock'), findsNothing);
    });

    testWidgets('a locked wallet asks before showing anything', (tester) async {
      final lock = _FakeLock(enabled: true, willSucceed: false);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
      );

      expect(find.text('Account'), findsNothing);
      expect(find.text('Unlock'), findsOneWidget);
      expect(lock.prompts, equals(1), reason: 'should prompt without a tap');
    });

    testWidgets('the lock badge keeps its size instead of stretching',
        (tester) async {
      // A stretching column turned this into a violet band across the screen.
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: _FakeLock(enabled: true, willSucceed: false),
      );

      final badge = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.lock_outline),
          matching: find.byType(Container),
        ).first,
      );
      expect(badge.width, equals(56));
      expect(badge.height, equals(56));
    });

    testWidgets('a refusal leaves a way to try again, not a dead end',
        (tester) async {
      final lock = _FakeLock(enabled: true, willSucceed: false);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
      );
      expect(find.textContaining('Not unlocked'), findsOneWidget);

      lock.willSucceed = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
      expect(lock.prompts, equals(2));
    });

    testWidgets('a keystore that will not answer does not lock anyone out',
        (tester) async {
      // An unreadable setting must read as off. The alternative is a wallet
      // that cannot be opened because a preference could not be loaded.
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: _FakeLock(enabled: true, readThrows: true),
      );
      expect(find.text('Account'), findsOneWidget);
    });

    testWidgets('a wallet created in this session is not then locked',
        (tester) async {
      // Whoever just restored the phrase has already proven who they are.
      final store = _FakeStore();
      final lock = _FakeLock(enabled: true);
      await _boot(tester, store: store, lock: lock);

      await tester.tap(find.text('I already have a phrase'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        WalletFactory.generateMnemonic(),
      );
      await tester.pump();
      await tester.tap(find.text('Restore wallet'));
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
    });
  });

  group('coming back to it', () {
    testWidgets('a long absence locks it again', (tester) async {
      final lock = _FakeLock(enabled: true, willSucceed: true);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
        lockAfter: Duration.zero,
      );
      expect(find.text('Account'), findsOneWidget, reason: 'unlocked at launch');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      lock.willSucceed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Account'), findsNothing);
    });

    testWidgets('a brief absence does not', (tester) async {
      // Authenticating backgrounds the app on some devices, and so does
      // switching away to copy an address. Re-prompting for either is how a
      // lock gets turned off for good.
      final lock = _FakeLock(enabled: true, willSucceed: true);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
        lockAfter: const Duration(minutes: 5),
      );
      expect(find.text('Account'), findsOneWidget, reason: 'unlocked at launch');

      // Anything that comes back would now be refused, so if the screen stays
      // on the wallet it is because no re-lock was attempted.
      lock.willSucceed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
    });

    testWidgets('an unlocked wallet stays open however long it is away',
        (tester) async {
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: _FakeLock(enabled: false),
        lockAfter: Duration.zero,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
    });
  });

  group('the toggle', () {
    Future<_FakeLock> pumpSettings(
      WidgetTester tester, {
      required _FakeLock lock,
    }) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final wallet = WalletController(
        keys: WalletFactory(accountClassHash: _network.accountClassHash)
            .deriveFrom(WalletFactory.generateMnemonic()),
        client: _StubChain(),
        activityStore: _MemoryActivityStore(),
        walletStore: _FakeStore(),
      );
      addTearDown(wallet.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: TipTheme.light,
          home: SettingsScreen(
            wallet: wallet,
            onErased: () {},
            lock: lock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return lock;
    }

    testWidgets('is hidden on a device that cannot authenticate',
        (tester) async {
      await pumpSettings(tester, lock: _FakeLock(available: false));
      expect(find.text('Ask to unlock on open'), findsNothing);
    });

    testWidgets('turning it on asks for the lock first', (tester) async {
      // Otherwise a lock the device cannot satisfy gets enabled, and it is
      // only discovered on the next launch with the wallet behind it.
      final lock = await pumpSettings(tester, lock: _FakeLock());

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(lock.prompts, equals(1));
      expect(lock.enabled, isTrue);
    });

    testWidgets('a refused confirmation changes nothing', (tester) async {
      final lock = await pumpSettings(
        tester,
        lock: _FakeLock(willSucceed: false),
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(lock.enabled, isFalse);
      expect(find.textContaining('nothing changed'), findsOneWidget);
    });

    testWidgets('turning it off also asks, so a bystander cannot', (tester) async {
      final lock = await pumpSettings(
        tester,
        lock: _FakeLock(enabled: true, willSucceed: false),
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(lock.enabled, isTrue, reason: 'still on after a refusal');
    });

    testWidgets('it does not claim to encrypt anything further',
        (tester) async {
      await pumpSettings(tester, lock: _FakeLock());
      expect(
        find.textContaining('does not encrypt anything further'),
        findsOneWidget,
      );
    });
  });

  group('what the lock actually covers', () {
    testWidgets('a pushed screen does not survive the lock', (tester) async {
      // The bug: BootScreen is the app's `home:`, so relocking replaced only
      // the bottom route. Anything pushed on top of it — Send, Settings with
      // the recovery phrase on screen, a private transfer mid-flight — is a
      // route *above* `home:` in the same Navigator and stayed both visible and
      // interactive with the lock sitting underneath it. The lock looked
      // engaged and guarded nothing.
      final lock = _FakeLock(enabled: true);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
        lockAfter: Duration.zero,
      );
      expect(find.text('Account'), findsOneWidget, reason: 'unlocked at launch');

      // Push something the way the app does, with content worth protecting.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Center(child: Text('a pushed screen')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('a pushed screen'), findsOneWidget);

      // Leave and come back past the timeout, and fail the prompt — which is
      // what pressing Cancel on the biometric sheet does.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      lock.willSucceed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Unlock'), findsOneWidget);
      expect(
        find.text('a pushed screen'),
        findsNothing,
        reason: 'the pushed route outlived the lock',
      );
      expect(find.text('Account'), findsNothing);
    });

    testWidgets('unlocking returns to the home screen, not to what was pushed',
        (tester) async {
      final lock = _FakeLock(enabled: true);
      await _boot(
        tester,
        store: _FakeStore(stored: WalletFactory.generateMnemonic()),
        lock: lock,
        lockAfter: Duration.zero,
      );

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Center(child: Text('a pushed screen')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      lock.willSucceed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      lock.willSucceed = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('a pushed screen'), findsNothing);
    });
  });

}
