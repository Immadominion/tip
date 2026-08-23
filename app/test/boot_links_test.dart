/// A tip link arriving from outside the app.
///
/// The case worth pinning is the awkward one: someone taps a tip link, has no
/// wallet, and is sent through onboarding. The link has to survive that.
/// Dropping it and making them dig it back out of their messages is the
/// obvious way to lose the person the whole feature exists for.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/activity/activity_entry.dart';
import 'package:tip/src/activity/activity_store.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_link.dart';
import 'package:tip/src/links/incoming_links.dart';
import 'package:tip/src/screens/boot_screen.dart';
import 'package:tip/src/security/app_lock.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_store.dart';

final _classHash = TipNetwork.sepolia.accountClassHash;

class _FakeStore extends WalletStore {
  _FakeStore({this.stored});

  String? stored;
  final writes = <String>[];

  @override
  Future<String?> readSeedPhrase() async => stored;

  @override
  Future<void> writeSeedPhrase(String mnemonic) async {
    writes.add(mnemonic);
    stored = mnemonic;
  }
}

class _MemoryActivityStore extends ActivityStore {
  @override
  Future<List<ActivityEntry>> read() async => const [];

  @override
  Future<void> write(List<ActivityEntry> next) async {}
}

/// The real one reaches for a platform channel that never answers in a widget
/// test, and an unsettled future stalls pumpAndSettle rather than failing.
class _NoLock extends AppLock {
  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> isEnabled() async => false;
}

class _FakeLinks extends IncomingLinks {
  _FakeLinks({this.launchLink});

  final Uri? launchLink;
  final _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> initial() async => launchLink;

  @override
  Stream<Uri> get stream => _controller.stream;

  void arrive(Uri uri) => _controller.add(uri);
}

Future<void> _pump(
  WidgetTester tester, {
  required WalletStore store,
  required IncomingLinks links,
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
        links: links,
        lock: _NoLock(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final key = ClaimLinks.create(accountClassHash: _classHash);

  testWidgets('a launch link opens the claim screen on an existing wallet',
      (tester) async {
    await _pump(
      tester,
      store: _FakeStore(stored: WalletFactory.generateMnemonic()),
      links: _FakeLinks(launchLink: key.link()),
    );

    expect(find.text('Claim a tip'), findsOneWidget);
  });

  testWidgets('the pasted field is prefilled from the link', (tester) async {
    await _pump(
      tester,
      store: _FakeStore(stored: WalletFactory.generateMnemonic()),
      links: _FakeLinks(launchLink: key.link()),
    );

    // Prefilled and already looked up, so the paste step is skipped entirely.
    expect(find.text('Claim a tip'), findsOneWidget);
    expect(find.textContaining('wrong length'), findsNothing);
  });

  testWidgets('a link that arrives while the app is open is picked up',
      (tester) async {
    final links = _FakeLinks();
    await _pump(
      tester,
      store: _FakeStore(stored: WalletFactory.generateMnemonic()),
      links: links,
    );
    expect(find.text('Claim a tip'), findsNothing);

    links.arrive(key.link());
    await tester.pumpAndSettle();

    expect(find.text('Claim a tip'), findsOneWidget);
  });

  testWidgets('a link that arrives with no wallet waits for onboarding',
      (tester) async {
    final store = _FakeStore();
    await _pump(
      tester,
      store: store,
      links: _FakeLinks(launchLink: key.link()),
    );

    // Onboarding first. The claim screen must not appear over it.
    expect(find.text('Create a wallet'), findsOneWidget);
    expect(find.text('Claim a tip'), findsNothing);

    await tester.tap(find.text('I already have a phrase'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      WalletFactory.generateMnemonic(),
    );
    await tester.pump();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(store.writes, hasLength(1));
    expect(find.text('Claim a tip'), findsOneWidget);
  });

  testWidgets('a link for another app is ignored', (tester) async {
    await _pump(
      tester,
      store: _FakeStore(stored: WalletFactory.generateMnemonic()),
      links: _FakeLinks(
        launchLink: Uri.parse('https://example.com/claim#${key.token}'),
      ),
    );

    expect(find.text('Claim a tip'), findsNothing);
    expect(find.text('Account'), findsOneWidget);
  });
}
