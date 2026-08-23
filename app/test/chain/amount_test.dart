/// Amount formatting and parsing.
///
/// These are the tests that matter most in the app. Everything else shows the
/// user something; this decides how much money moves.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/token.dart';

final strk = TipTokens.strk;
final usdc = TipTokens.usdcMainnet;

/// A whole-unit token, to cover the zero-decimals path.
final points = TipToken(
  address: Felt.fromHexString('0x1'),
  symbol: 'PTS',
  name: 'Points',
  decimals: 0,
);

TokenAmount strkUnits(String digits) => TokenAmount(BigInt.parse(digits), strk);

void main() {
  group('format', () {
    test('renders whole units', () {
      expect(TokenAmount.parse('1', strk).format(), equals('1'));
      expect(TokenAmount.parse('0', strk).format(), equals('0'));
    });

    test('trims trailing zeros in the fraction', () {
      expect(TokenAmount.parse('1.500000', strk).format(), equals('1.5'));
      expect(TokenAmount.parse('1.0', strk).format(), equals('1'));
    });

    test('groups thousands', () {
      expect(
        TokenAmount.parse('1234567.25', strk).format(),
        equals('1,234,567.25'),
      );
      expect(TokenAmount.parse('999', strk).format(), equals('999'));
      expect(TokenAmount.parse('1000', strk).format(), equals('1,000'));
    });

    test('can be asked not to group', () {
      expect(
        TokenAmount.parse('1234567', strk).format(groupThousands: false),
        equals('1234567'),
      );
    });

    test('truncates rather than rounding, so a balance is never overstated', () {
      // Rounding would show 2, and a user who then tries to send 2 fails.
      expect(TokenAmount.parse('1.9999999', strk).format(), equals('1.999999'));
      expect(TokenAmount.parse('0.9999999', strk).format(), equals('0.999999'));
    });

    test('shows dust as less-than rather than as zero', () {
      expect(strkUnits('1').format(), equals('<0.000001'));
      expect(TokenAmount.parse('0.0000001', strk).format(), equals('<0.000001'));
    });

    test('the dust threshold is exactly the last displayed digit', () {
      expect(TokenAmount.parse('0.000001', strk).format(), equals('0.000001'));
    });

    test('honours a requested precision', () {
      final amount = TokenAmount.parse('1.23456789', strk);
      expect(amount.format(maxFractionDigits: 2), equals('1.23'));
      expect(amount.format(maxFractionDigits: 4), equals('1.2345'));
    });

    test('zero fraction digits truncates to whole units', () {
      expect(
        TokenAmount.parse('1.9', strk).format(maxFractionDigits: 0),
        equals('1'),
      );
      expect(
        TokenAmount.parse('0.9', strk).format(maxFractionDigits: 0),
        equals('<1'),
      );
    });

    test('keeps the sign on a negative difference', () {
      final diff = TokenAmount.parse('1', strk) - TokenAmount.parse('2.5', strk);
      expect(diff.format(), equals('-1.5'));
    });

    test('a six-decimal token shows every digit it has', () {
      expect(TokenAmount(BigInt.one, usdc).format(), equals('0.000001'));
      expect(TokenAmount.parse('1.5', usdc).format(), equals('1.5'));
      expect(TokenAmount.parse('1234.56', usdc).format(), equals('1,234.56'));
    });

    test('a zero-decimal token has no fraction at all', () {
      expect(TokenAmount(BigInt.from(1500), points).format(), equals('1,500'));
    });

    test('formatExact keeps every decimal place', () {
      expect(
        strkUnits('1').formatExact(),
        equals('0.000000000000000001'),
      );
      expect(
        TokenAmount.parse('1.5', strk).formatExact(),
        equals('1.5'),
      );
    });

    test('formatWithSymbol appends the symbol', () {
      expect(
        TokenAmount.parse('2.5', strk).formatWithSymbol(),
        equals('2.5 STRK'),
      );
    });
  });

  group('parse', () {
    test('scales by the token decimals', () {
      expect(
        TokenAmount.parse('1', strk).raw,
        equals(BigInt.parse('1000000000000000000')),
      );
      expect(TokenAmount.parse('1', usdc).raw, equals(BigInt.from(1000000)));
    });

    test('accepts a fraction shorter than the token supports', () {
      expect(
        TokenAmount.parse('1.5', strk).raw,
        equals(BigInt.parse('1500000000000000000')),
      );
    });

    test('accepts the full precision the token supports', () {
      expect(
        TokenAmount.parse('0.000000000000000001', strk).raw,
        equals(BigInt.one),
      );
    });

    test('accepts pasted grouping separators and spaces', () {
      expect(
        TokenAmount.parse('1,234.5', strk),
        equals(TokenAmount.parse('1234.5', strk)),
      );
      expect(
        TokenAmount.parse(' 12 34 ', strk),
        equals(TokenAmount.parse('1234', strk)),
      );
    });

    test('accepts a leading or trailing decimal point', () {
      expect(TokenAmount.parse('.5', strk), equals(TokenAmount.parse('0.5', strk)));
      expect(TokenAmount.parse('1.', strk), equals(TokenAmount.parse('1', strk)));
    });

    test('rejects an empty amount', () {
      expect(
        () => TokenAmount.parse('   ', strk),
        throwsA(isA<AmountFormatException>()),
      );
    });

    test('rejects a negative amount', () {
      expect(
        () => TokenAmount.parse('-1', strk),
        throwsA(isA<AmountFormatException>()),
      );
    });

    test('rejects more than one decimal point', () {
      expect(
        () => TokenAmount.parse('1.2.3', strk),
        throwsA(isA<AmountFormatException>()),
      );
    });

    test('rejects anything that is not a number', () {
      for (final input in ['abc', '1e5', '0x10', '1..', '½']) {
        expect(
          () => TokenAmount.parse(input, strk),
          throwsA(isA<AmountFormatException>()),
          reason: 'accepted $input',
        );
      }
    });

    test('rejects more precision than the token has, instead of truncating', () {
      // Truncating here would send a different amount than the one on screen.
      expect(
        () => TokenAmount.parse('1.1234567', usdc),
        throwsA(isA<AmountFormatException>()),
      );
      expect(
        () => TokenAmount.parse('0.0000000000000000001', strk),
        throwsA(isA<AmountFormatException>()),
      );
    });

    test('the error names the token and its precision', () {
      expect(
        () => TokenAmount.parse('1.1234567', usdc),
        throwsA(
          predicate(
            (e) => e is AmountFormatException && e.message.contains('USDC'),
          ),
        ),
      );
    });

    test('tryParse returns null rather than throwing', () {
      expect(TokenAmount.tryParse('nope', strk), isNull);
      expect(TokenAmount.tryParse('1.5', strk), isNotNull);
    });

    test('round-trips through the exact format', () {
      for (final input in ['0', '1', '1.5', '0.000000000000000001', '1234.25']) {
        final amount = TokenAmount.parse(input, strk);
        expect(
          TokenAmount.parse(amount.formatExact(), strk),
          equals(amount),
          reason: 'round trip failed for $input',
        );
      }
    });
  });

  group('arithmetic', () {
    test('adds and subtracts', () {
      final a = TokenAmount.parse('1.5', strk);
      final b = TokenAmount.parse('0.25', strk);
      expect((a + b).formatExact(), equals('1.75'));
      expect((a - b).formatExact(), equals('1.25'));
    });

    test('compares', () {
      final a = TokenAmount.parse('1.5', strk);
      final b = TokenAmount.parse('2', strk);
      expect(a < b, isTrue);
      expect(b > a, isTrue);
      expect(a >= a, isTrue);
      expect(a <= a, isTrue);
    });

    test('refuses to mix tokens', () {
      expect(
        () => TokenAmount.parse('1', strk) + TokenAmount.parse('1', usdc),
        throwsArgumentError,
      );
      expect(
        () => TokenAmount.parse('1', strk) < TokenAmount.parse('1', usdc),
        throwsArgumentError,
      );
    });

    test('zero is zero', () {
      expect(TokenAmount.zero(strk).isZero, isTrue);
      expect(TokenAmount.zero(strk).format(), equals('0'));
    });
  });
}
