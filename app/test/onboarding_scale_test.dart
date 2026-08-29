/// The first screen of the app, at the text sizes people actually use.
///
/// Roughly one person in twenty runs their phone at a large accessibility text
/// scale, and the welcome screen used to overflow by several hundred pixels at
/// 200% with all three buttons clipped off the bottom and no way to scroll to
/// them. That is not a cosmetic problem on the screen where the only actions
/// are "create a wallet", "sign in" and "I already have a phrase" — there is
/// nothing else to do and no way to do it.
///
/// The widget tests elsewhere use a 1000x2400 viewport, which is taller than
/// any real phone and hides exactly this class of bug. These deliberately use a
/// small one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/screens/onboarding_screen.dart';
import 'package:tip/src/theme/theme.dart';

/// A small phone, in logical pixels. An iPhone SE is 375x667.
const _smallPhone = Size(375, 667);

Future<void> _pump(
  WidgetTester tester, {
  required double textScale,
}) async {
  tester.view.physicalSize = _smallPhone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: OnboardingScreen(
          onReady: (_) async {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('the welcome screen does not overflow at ${scale}x',
        (tester) async {
      await _pump(tester, textScale: scale);
      // A RenderFlex overflow is reported through the exception channel rather
      // than by failing a matcher, so it has to be asked for explicitly.
      expect(tester.takeException(), isNull);
    });

    testWidgets('every way in is reachable at ${scale}x', (tester) async {
      await _pump(tester, textScale: scale);

      for (final label in [
        'Create a wallet',
        'Sign in',
        'I already have a phrase',
      ]) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '$label is missing at $scale x');

        // Present in the tree is not the same as reachable. Scroll it into
        // view and confirm it can actually be tapped, which is what was
        // broken: the buttons existed and were clipped off the bottom.
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
