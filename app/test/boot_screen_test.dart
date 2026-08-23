/// What the app does on launch, depending on what it finds in the keystore.
///
/// The case worth guarding is the third one. Treating an unreadable keystore
/// as "no wallet yet" is the failure that walks a user into onboarding and
/// overwrites a seed that was only temporarily unavailable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/screens/boot_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip/src/wallet/wallet_store.dart';

class _FakeStore extends WalletStore {
  _FakeStore({this.stored, this.readThrows = false});

  String? stored;
  bool readThrows;
  final writes = <String>[];

  @override
  Future<String?> readSeedPhrase() async {
    if (readThrows) throw Exception('keystore locked');
    return stored;
  }

  @override
  Future<void> writeSeedPhrase(String mnemonic) async {
    writes.add(mnemonic);
    stored = mnemonic;
  }
}

Future<void> _pump(WidgetTester tester, WalletStore store) async {
  await tester.pumpWidget(
    MaterialApp(theme: TipTheme.light, home: BootScreen(store: store)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no stored phrase it offers to create a wallet',
      (tester) async {
    await _pump(tester, _FakeStore());
    expect(find.text('Create a wallet'), findsOneWidget);
  });

  testWidgets('with a stored phrase it opens the wallet', (tester) async {
    await _pump(
      tester,
      _FakeStore(stored: WalletFactory.generateMnemonic()),
    );
    expect(find.text('Create a wallet'), findsNothing);
    expect(find.text('Account'), findsOneWidget);
  });

  testWidgets('an unreadable keystore is an error, not a fresh start',
      (tester) async {
    await _pump(tester, _FakeStore(readThrows: true));

    expect(find.text('Could not open your wallet'), findsOneWidget);
    expect(find.text('Create a wallet'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a phrase that fails its checksum is reported, not replaced',
      (tester) async {
    // Twenty-four real words in an order that fails the checksum.
    final store = _FakeStore(stored: List.filled(24, 'abandon').join(' '));
    await _pump(tester, store);

    expect(find.text('Could not open your wallet'), findsOneWidget);
    expect(find.textContaining('checksum'), findsOneWidget);
    expect(store.writes, isEmpty, reason: 'must not overwrite the stored seed');
  });

  testWidgets('restoring a phrase saves it before the wallet appears',
      (tester) async {
    final store = _FakeStore();
    final phrase = WalletFactory.generateMnemonic();
    await _pump(tester, store);

    await tester.tap(find.text('I already have a phrase'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), phrase);
    await tester.pump();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(store.writes, equals([phrase]));
    expect(find.text('Account'), findsOneWidget);
  });

  testWidgets('a phrase with a bad word is refused with a reason',
      (tester) async {
    final store = _FakeStore();
    await _pump(tester, store);

    await tester.tap(find.text('I already have a phrase'));
    await tester.pumpAndSettle();

    // A real phrase with its first word swapped for another real word.
    final words = WalletFactory.generateMnemonic().split(' ');
    words[0] = words[0] == 'abandon' ? 'ability' : 'abandon';
    await tester.enterText(find.byType(TextField), words.join(' '));
    await tester.pump();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not check out'), findsOneWidget);
    expect(store.writes, isEmpty);
  });

  testWidgets('the wrong number of words says how many there were',
      (tester) async {
    await _pump(tester, _FakeStore());

    await tester.tap(find.text('I already have a phrase'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abandon ability able');
    await tester.pump();
    await tester.tap(find.text('Restore wallet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('has 3'), findsOneWidget);
  });
}
