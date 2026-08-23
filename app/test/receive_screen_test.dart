/// The receive screen.
///
/// The QR is the part that cannot be checked by eye once it ships, so what is
/// tested here is that it encodes the canonical address and that a testnet
/// address says so. Someone scanning a code has no other way to tell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:tip/src/chain/address.dart';
import 'package:tip/src/screens/receive_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/widgets/address_qr.dart';

const _address =
    '0x30a7cef4289ca32268279642bfb19fcf924a8b34a919210f79920b366e1d0cc';

Future<void> _pump(WidgetTester tester, {String? networkLabel}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: TipTheme.light,
        home: ReceiveScreen(address: _address, networkLabel: networkLabel),
      ),
    );

void main() {
  testWidgets('the QR carries the canonical, fully padded address',
      (tester) async {
    await _pump(tester);

    final qr = tester.widget<AddressQr>(find.byType(AddressQr));
    expect(qr.data.length, equals(66));
    expect(
      qr.data,
      equals(StarknetAddress.canonical(StarknetAddress.parse(_address))),
    );
    // Same address either way, which is the point of padding it.
    expect(
      StarknetAddress.parse(qr.data),
      equals(StarknetAddress.parse(_address)),
    );
  });

  testWidgets('a testnet address says so, and mainnet says nothing',
      (tester) async {
    await _pump(tester, networkLabel: 'Sepolia testnet');
    expect(find.textContaining('Do not send real funds'), findsOneWidget);

    await _pump(tester);
    expect(find.textContaining('Do not send real funds'), findsNothing);
  });

  testWidgets('it says the payments are public', (tester) async {
    await _pump(tester);
    expect(find.text('Payments here are public'), findsOneWidget);
  });

  testWidgets('the address itself is selectable, not only scannable',
      (tester) async {
    await _pump(tester);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  test('an address fits in a QR without pushing it to an unscannable size', () {
    // Version 40 modules would be far too small on a phone. A 66 character
    // payload should land nowhere near it.
    final code = QrCode(
      payload: QrPayload.fromString(
        StarknetAddress.canonical(StarknetAddress.parse(_address)),
      ),
    );
    expect(code.typeNumber, lessThan(10));
    expect(QrImage(code).moduleCount, equals(code.typeNumber * 4 + 17));
  });

  test('the encoding is deterministic', () {
    String render(String data) {
      final image = QrImage(QrCode(payload: QrPayload.fromString(data)));
      return [
        for (var r = 0; r < image.moduleCount; r++)
          for (var c = 0; c < image.moduleCount; c++)
            image.isDark(r, c) ? '1' : '0',
      ].join();
    }

    final canonical =
        StarknetAddress.canonical(StarknetAddress.parse(_address));
    expect(render(canonical), equals(render(canonical)));
    expect(render(canonical), isNot(equals(render('0x1'))));
  });
}
