import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 2026 tonal system from the approved prototype:
/// Cloud Dancer base · clay/terracotta accent · sage support.
class RecallColors {
  static const bg = Color(0xFFF6F5F1); // Cloud Dancer
  static const bg2 = Color(0xFFEFEDE7);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF211D19);
  static const ink2 = Color(0xFF5C564E);
  static const ink3 = Color(0xFF96907F);
  static const clay = Color(0xFFC65F43);
  static const clayDeep = Color(0xFFA84A32);
  static const clayTint = Color(0xFFF7E4DD);
  static const sage = Color(0xFF5E7D5A);
  static const sageTint = Color(0xFFE4EBE0);

  // dark
  static const dBg = Color(0xFF141210);
  static const dSurface = Color(0xFF201D1A);
  static const dInk = Color(0xFFF1EEE8);
  static const dInk2 = Color(0xFFB9B2A6);
  static const dClay = Color(0xFFE07A5C);
  static const dClayTint = Color(0xFF3A2A24);
}

ThemeData recallTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme(
    brightness: b,
    primary: dark ? RecallColors.dClay : RecallColors.clay,
    onPrimary: Colors.white,
    secondary: RecallColors.sage,
    onSecondary: Colors.white,
    error: const Color(0xFFB3261E),
    onError: Colors.white,
    surface: dark ? RecallColors.dSurface : RecallColors.surface,
    onSurface: dark ? RecallColors.dInk : RecallColors.ink,
    surfaceContainerHighest: dark ? RecallColors.dClayTint : RecallColors.clayTint,
    onSurfaceVariant: dark ? RecallColors.dInk2 : RecallColors.ink2,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final body = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  return base.copyWith(
    scaffoldBackgroundColor: dark ? RecallColors.dBg : RecallColors.bg,
    textTheme: body.copyWith(
      headlineMedium: GoogleFonts.fraunces(
        fontSize: 30, fontWeight: FontWeight.w600,
        color: scheme.onSurface, letterSpacing: -0.5,
      ),
      headlineSmall: GoogleFonts.fraunces(
        fontSize: 22, fontWeight: FontWeight.w600,
        color: scheme.onSurface, letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      margin: EdgeInsets.zero,
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide.none,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.inter(fontSize: 16.5, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.inter(fontSize: 16.5, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
