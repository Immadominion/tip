/// tip's colour system.
///
/// The structure follows the pattern that works well for consumer wallets: a
/// light surface for the places people spend most of their time, a dark surface
/// for dense utility screens, and one accent used consistently across both so
/// the app still reads as a single product.
///
/// The accent is deliberately violet. The two products nearest this one in the
/// mind of anyone judging it are Umbra Privacy, which owns a cyan blue, and
/// Umbra by ScopeLift, which owns a gold. Landing on either would invite a
/// comparison this project does not need. Violet also sidesteps green, which in
/// a wallet is already spoken for by positive balance changes.
///
/// Everything below is a token. Changing the brand means changing this file and
/// nothing else.
library;

import 'package:flutter/material.dart';

class TipPalette {
  TipPalette._();

  // Accent
  static const accent = Color(0xFF6D4AE8);
  static const accentBright = Color(0xFF7F5DF5);
  static const accentDeep = Color(0xFF5638C4);
  static const accentWash = Color(0xFFE9E3FD);
  static const accentGlow = Color(0xFFD6CBFB);

  // Light surfaces
  static const surface = Color(0xFFFBFAFE);
  static const surfaceRaised = Color(0xFFFFFFFF);
  static const surfaceSunken = Color(0xFFF2F0F8);
  static const border = Color(0xFFE6E3EF);

  // Dark surfaces
  static const surfaceDark = Color(0xFF15131C);
  static const surfaceDarkRaised = Color(0xFF1D1A26);
  static const surfaceDarkSunken = Color(0xFF110F17);
  static const borderDark = Color(0xFF2C2836);

  // Text
  static const ink = Color(0xFF16141D);
  static const inkMuted = Color(0xFF6B6779);
  static const inkFaint = Color(0xFF9C98A8);
  static const inkInverse = Color(0xFFFBFAFE);
  static const inkInverseMuted = Color(0xFFA5A1B3);

  // Semantic
  static const positive = Color(0xFF1FA971);
  static const negative = Color(0xFFD2453F);
  static const warning = Color(0xFFD98A0B);

  /// Wash behind the balance on the home screen.
  static const heroGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [accentWash, surface],
  );

  /// Fill for the primary action.
  static const actionGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [accentBright, accent],
  );
}
