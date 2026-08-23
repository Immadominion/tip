/// Signing in.
///
/// The screen is checked for one thing above the rest: that it never suggests
/// signing in is what holds the money. A user who believes Google is custodian
/// of their wallet makes decisions that cost them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/auth/auth_config.dart';
import 'package:tip/src/auth/auth_service.dart';
import 'package:tip/src/screens/sign_in_screen.dart';
import 'package:tip/src/theme/theme.dart';

Future<void> _pump(WidgetTester tester, AuthService auth) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: TipTheme.light,
      home: SignInScreen(auth: auth, onSignedIn: () {}),
    ),
  );
  await tester.pump();
}

void main() {
  group('the email check', () {
    test('accepts ordinary addresses', () {
      for (final value in [
        'a@b.co',
        'someone@example.com',
        'first.last+tag@sub.domain.org',
      ]) {
        expect(looksLikeEmail(value), isTrue, reason: value);
      }
    });

    test('catches the obvious slips before spending a round trip', () {
      for (final value in [
        '',
        'nope',
        '@example.com',
        'someone@',
        'someone@example',
        'someone@.com',
        'someone@example.',
        'some one@example.com',
      ]) {
        expect(looksLikeEmail(value), isFalse, reason: '"$value"');
      }
    });
  });

  group('the screen', () {
    testWidgets('offers all three ways in', (tester) async {
      await _pump(tester, AuthService());

      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with X'), findsOneWidget);
      expect(find.text('Continue with email'), findsOneWidget);
    });

    testWidgets('says outright that signing in does not hold the money',
        (tester) async {
      await _pump(tester, AuthService());
      expect(
        find.text('Signing in does not hold your money'),
        findsOneWidget,
      );
      expect(find.textContaining('stay on it'), findsOneWidget);
    });

    testWidgets('the email step will not send without an address',
        (tester) async {
      await _pump(tester, AuthService());
      await tester.tap(find.text('Continue with email'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      await tester.enterText(find.byType(TextField), 'someone@example.com');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('going back from the email step returns to the choices',
        (tester) async {
      await _pump(tester, AuthService());
      await tester.tap(find.text('Continue with email'));
      await tester.pumpAndSettle();
      expect(find.text('Continue with Google'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
    });
  });

  group('configuration', () {
    test('the OAuth redirect uses the scheme the app actually registers', () {
      // Both platforms register `tip`. A mismatch here is a round trip that
      // ends in a browser tab the app never hears about.
      expect(AuthConfig.oauthRedirect, startsWith('tip://'));
    });

    test('a build with no backend reports sign-in as unavailable', () {
      // The wallet works without a backend, so this must be answerable
      // without one rather than throwing.
      expect(() => AuthService().isAvailable, returnsNormally);
    });
  });
}
