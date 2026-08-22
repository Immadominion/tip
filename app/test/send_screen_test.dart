/// The send screen's preview: what it composes, and how it fails.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/screens/send_screen.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart';

final _classHash = Felt.fromHexString(
  '0x01a736d6ed154502257f02b1ccdf4d9d1089f80811cd6acad48e6b6a9d1f2003',
);

final _token = BigInt.parse('1234', radix: 16);

WalletKeys _keys() => WalletFactory(
  accountClassHash: _classHash,
).deriveFrom(WalletFactory.generateMnemonic());

SpendableNote _note(int amount, {int index = 0}) => SpendableNote(
  channelKey: BigInt.from(0xdef),
  token: _token,
  index: index,
  amount: BigInt.from(amount),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<SpendableNote> notes,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SendScreen(keys: _keys(), notes: notes, token: _token),
    ),
  );
}

Future<void> _fillAndPreview(
  WidgetTester tester, {
  required String recipient,
  required String amount,
}) async {
  await tester.enterText(find.byType(TextField).first, recipient);
  await tester.enterText(find.byType(TextField).last, amount);
  await tester.tap(find.text('Preview transfer'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('previews a transfer that has change', (tester) async {
    await _pump(tester, notes: [_note(100)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '70');

    // Spend one note, pay the recipient, keep the change.
    expect(find.text('Spend a note'), findsOneWidget);
    expect(find.text('Create a note'), findsNWidgets(2));
    expect(find.textContaining('1 nullifier and 2 new notes'), findsOneWidget);
  });

  testWidgets('an exact spend produces no change note', (tester) async {
    await _pump(tester, notes: [_note(100)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '100');

    expect(find.text('Create a note'), findsOneWidget);
    expect(find.textContaining('1 nullifier and 1 new note'), findsOneWidget);
  });

  testWidgets('spending two notes is surfaced as two nullifiers', (
    tester,
  ) async {
    // Worth showing: more nullifiers is a more distinctive on-chain event.
    await _pump(tester, notes: [_note(30, index: 0), _note(40, index: 1)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '65');

    expect(find.text('Spend a note'), findsNWidgets(2));
    expect(find.textContaining('2 nullifiers'), findsOneWidget);
  });

  testWidgets('reports a shortfall with real numbers', (tester) async {
    await _pump(tester, notes: [_note(10)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '100');

    expect(
      find.text('You have 10 available but tried to send 100.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty balance fails rather than previewing', (tester) async {
    await _pump(tester, notes: const []);
    await _fillAndPreview(tester, recipient: '0x456', amount: '5');

    expect(find.textContaining('0 available'), findsOneWidget);
    expect(find.text('Spend a note'), findsNothing);
  });

  testWidgets('rejects a malformed address', (tester) async {
    await _pump(tester, notes: [_note(100)]);
    await _fillAndPreview(tester, recipient: 'not-an-address', amount: '10');

    expect(find.text('That is not a valid address.'), findsOneWidget);
  });

  testWidgets('rejects a zero amount', (tester) async {
    await _pump(tester, notes: [_note(100)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '0');

    expect(find.text('Enter an amount greater than zero.'), findsOneWidget);
  });

  testWidgets('states that sender, recipient, and amount stay hidden', (
    tester,
  ) async {
    await _pump(tester, notes: [_note(100)]);
    await _fillAndPreview(tester, recipient: '0x456', amount: '70');

    expect(
      find.textContaining('sender, recipient, and amount are not visible'),
      findsOneWidget,
    );
  });
}
