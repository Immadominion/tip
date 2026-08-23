/// Token amounts, and the conversion between what a chain stores and what a
/// person reads.
///
/// A chain stores an integer of smallest units. A person types "1.5". Every
/// wallet bug that costs someone real money lives somewhere in that gap, so
/// this file is deliberately strict: it never rounds a displayed balance up,
/// and it never silently reinterprets an amount the user typed.
library;

import 'token.dart';

/// Thrown when a typed amount cannot be turned into an exact number of units.
class AmountFormatException implements Exception {
  const AmountFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TokenAmount implements Comparable<TokenAmount> {
  const TokenAmount(this.raw, this.token);

  TokenAmount.zero(this.token) : raw = BigInt.zero;

  /// The on-chain integer, in the token's smallest unit.
  final BigInt raw;

  final TipToken token;

  bool get isZero => raw == BigInt.zero;
  bool get isNegative => raw.isNegative;

  BigInt get _unit => BigInt.from(10).pow(token.decimals);

  /// How many fraction digits to show when the caller does not say.
  ///
  /// Six is enough to see dust on a stablecoin and enough to distinguish
  /// amounts on an 18-decimal token, without turning a balance into a wall of
  /// digits. Anything finer is noise on a phone screen.
  int get _defaultFractionDigits =>
      token.decimals <= 6 ? token.decimals : 6;

  /// Renders the amount for display.
  ///
  /// Truncates rather than rounds, so a displayed balance is never larger than
  /// the real one. An amount too small to show at the requested precision
  /// renders as `<0.000001` rather than as zero, because telling someone they
  /// have nothing when they have something is the worse of the two errors.
  String format({int? maxFractionDigits, bool groupThousands = true}) {
    final digits = maxFractionDigits ?? _defaultFractionDigits;
    final sign = raw.isNegative ? '-' : '';
    final magnitude = raw.abs();

    final whole = magnitude ~/ _unit;
    final fraction = magnitude % _unit;

    final wholeText = groupThousands ? _group(whole.toString()) : whole.toString();

    if (token.decimals == 0 || digits <= 0) {
      if (whole == BigInt.zero && fraction > BigInt.zero) return '$sign<1';
      return '$sign$wholeText';
    }

    var fractionText = fraction
        .toString()
        .padLeft(token.decimals, '0')
        .substring(0, digits < token.decimals ? digits : token.decimals);

    while (fractionText.isNotEmpty && fractionText.endsWith('0')) {
      fractionText = fractionText.substring(0, fractionText.length - 1);
    }

    if (fractionText.isEmpty) {
      if (whole == BigInt.zero && fraction > BigInt.zero) {
        final places = digits < token.decimals ? digits : token.decimals;
        return '$sign<0.${'0' * (places - 1)}1';
      }
      return '$sign$wholeText';
    }

    return '$sign$wholeText.$fractionText';
  }

  String formatWithSymbol({int? maxFractionDigits}) =>
      '${format(maxFractionDigits: maxFractionDigits)} ${token.symbol}';

  /// The full, unrounded value. For the places where precision matters more
  /// than legibility: a confirmation screen, a copied value, a receipt.
  String formatExact() => format(
        maxFractionDigits: token.decimals,
        groupThousands: false,
      );

  /// Parses an amount a person typed.
  ///
  /// Accepts grouping separators and spaces, since people paste them. Rejects
  /// anything it cannot represent exactly, including more decimal places than
  /// the token has: silently dropping the tail would send a different amount
  /// than the one on screen.
  static TokenAmount parse(String input, TipToken token) {
    final cleaned = input.replaceAll(',', '').replaceAll(' ', '').trim();

    if (cleaned.isEmpty) {
      throw const AmountFormatException('Enter an amount');
    }
    if (cleaned.startsWith('-')) {
      throw const AmountFormatException('Amount cannot be negative');
    }

    final parts = cleaned.split('.');
    if (parts.length > 2) {
      throw const AmountFormatException('Amount has more than one decimal point');
    }

    final wholeText = parts[0].isEmpty ? '0' : parts[0];
    final fractionText = parts.length == 2 ? parts[1] : '';

    if (!_isDigits(wholeText) || (fractionText.isNotEmpty && !_isDigits(fractionText))) {
      throw const AmountFormatException('Amount must be a number');
    }
    if (fractionText.length > token.decimals) {
      throw AmountFormatException(
        '${token.symbol} supports at most ${token.decimals} decimal places',
      );
    }

    final padded = fractionText.padRight(token.decimals, '0');
    final raw = BigInt.parse(wholeText + padded);
    return TokenAmount(raw, token);
  }

  static TokenAmount? tryParse(String input, TipToken token) {
    try {
      return parse(input, token);
    } on AmountFormatException {
      return null;
    }
  }

  TokenAmount operator +(TokenAmount other) {
    _sameToken(other);
    return TokenAmount(raw + other.raw, token);
  }

  TokenAmount operator -(TokenAmount other) {
    _sameToken(other);
    return TokenAmount(raw - other.raw, token);
  }

  bool operator >(TokenAmount other) => compareTo(other) > 0;
  bool operator <(TokenAmount other) => compareTo(other) < 0;
  bool operator >=(TokenAmount other) => compareTo(other) >= 0;
  bool operator <=(TokenAmount other) => compareTo(other) <= 0;

  @override
  int compareTo(TokenAmount other) {
    _sameToken(other);
    return raw.compareTo(other.raw);
  }

  void _sameToken(TokenAmount other) {
    if (other.token != token) {
      throw ArgumentError(
        'Cannot combine ${token.symbol} with ${other.token.symbol}',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TokenAmount && other.raw == raw && other.token == token;

  @override
  int get hashCode => Object.hash(raw, token);

  @override
  String toString() => formatWithSymbol();
}

bool _isDigits(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return value.isNotEmpty;
}

/// Inserts thousands separators into an integer string.
String _group(String digits) {
  if (digits.length <= 3) return digits;
  final buffer = StringBuffer();
  final lead = digits.length % 3;
  if (lead > 0) buffer.write(digits.substring(0, lead));
  for (var i = lead; i < digits.length; i += 3) {
    if (buffer.isNotEmpty) buffer.write(',');
    buffer.write(digits.substring(i, i + 3));
  }
  return buffer.toString();
}
