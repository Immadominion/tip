/// Typography, shape, and the assembled themes.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'palette.dart';

class TipTheme {
  TipTheme._();

  /// Corner radii. Generous and consistent: the whole surface reads as soft,
  /// which is what keeps a privacy tool from feeling like a security console.
  static const radiusSmall = 12.0;
  static const radiusMedium = 18.0;
  static const radiusLarge = 24.0;
  static const radiusPill = 999.0;

  static const spaceXs = 4.0;
  static const spaceSm = 8.0;
  static const spaceMd = 16.0;
  static const spaceLg = 24.0;
  static const spaceXl = 32.0;
  static const space2xl = 48.0;

  static TextTheme _text(Color primary, Color muted) {
    // Figtree for everything. One family, weight doing the work of hierarchy.
    final base = GoogleFonts.figtreeTextTheme();
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontSize: 52,
        height: 1.05,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.6,
        color: primary,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontSize: 40,
        height: 1.1,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        color: primary,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: 26,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: primary,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: primary,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 16,
        height: 1.45,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 15,
        height: 1.45,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.1,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: muted,
      ),
    );
  }

  static ThemeData get light {
    final text = _text(TipPalette.ink, TipPalette.inkMuted);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: TipPalette.surface,
      textTheme: text,
      colorScheme: const ColorScheme.light(
        primary: TipPalette.accent,
        onPrimary: Colors.white,
        secondary: TipPalette.accentDeep,
        surface: TipPalette.surface,
        onSurface: TipPalette.ink,
        error: TipPalette.negative,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: text.titleLarge,
        iconTheme: const IconThemeData(color: TipPalette.ink),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: TipPalette.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(58),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusPill),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TipPalette.ink,
          minimumSize: const Size.fromHeight(58),
          side: const BorderSide(color: TipPalette.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusPill),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      cardTheme: CardThemeData(
        color: TipPalette.surfaceRaised,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: const BorderSide(color: TipPalette.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TipPalette.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spaceMd,
          vertical: spaceMd,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: TipPalette.accent, width: 1.5),
        ),
        hintStyle: text.bodyMedium?.copyWith(color: TipPalette.inkFaint),
      ),
    );
  }

  static ThemeData get dark {
    final text = _text(TipPalette.inkInverse, TipPalette.inkInverseMuted);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: TipPalette.surfaceDark,
      textTheme: text,
      colorScheme: const ColorScheme.dark(
        primary: TipPalette.accentBright,
        onPrimary: Colors.white,
        secondary: TipPalette.accent,
        surface: TipPalette.surfaceDark,
        onSurface: TipPalette.inkInverse,
        error: TipPalette.negative,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: text.titleLarge,
        iconTheme: const IconThemeData(color: TipPalette.inkInverse),
      ),
      cardTheme: CardThemeData(
        color: TipPalette.surfaceDarkRaised,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: const BorderSide(color: TipPalette.borderDark),
        ),
      ),
    );
  }
}
