import 'package:flutter/material.dart';

import 'pattern.dart';
import 'scoring.dart';

abstract final class Palette {
  static const bg = Color(0xFF0F1013);
  static const surface = Color(0xFF181A1F);
  static const surfaceHigh = Color(0xFF22252C);
  static const line = Color(0xFF2E323A);
  static const text = Color(0xFFECE8E1);
  static const muted = Color(0xFF8B909A);
  static const brass = Color(0xFFE8B04B);
  static const skin = Color(0xFF2A2620);
  static const rim = Color(0xFF7FB8E8);
  static const good = Color(0xFF4FC3A1);
  static const ok = Color(0xFFE8B04B);
  static const off = Color(0xFFFF8A4C);
  static const bad = Color(0xFFFF6B5B);

  static Color stroke(Stroke s) => switch (s) {
    Stroke.dum => brass,
    Stroke.tek => rim,
    Stroke.ka => const Color(0xFFB5D6F2),
    Stroke.rest => muted,
  };

  static Color grade(Grade g) => switch (g) {
    Grade.good => good,
    Grade.ok => ok,
    Grade.off => off,
    Grade.miss || Grade.extra => bad,
  };

  /// Colour for an accuracy share.
  static Color accuracy(double a) => a.isNaN ? muted : (a >= 0.85 ? good : (a >= 0.6 ? ok : off));
}

const tabular = [FontFeature.tabularFigures()];

String pct(double x) => x.isFinite ? '${(x * 100).round()}%' : '—';

String ms(double x, {bool sign = false}) {
  if (!x.isFinite) return '—';
  final r = x.round();
  return '${sign && r > 0 ? '+' : ''}$r мс';
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Palette.brass, brightness: Brightness.dark).copyWith(
    primary: Palette.brass,
    onPrimary: const Color(0xFF241A05),
    surface: Palette.bg,
    surfaceContainerLowest: Palette.bg,
    surfaceContainerLow: Palette.surface,
    surfaceContainer: Palette.surface,
    surfaceContainerHigh: Palette.surfaceHigh,
    surfaceContainerHighest: Palette.surfaceHigh,
    onSurface: Palette.text,
    onSurfaceVariant: Palette.muted,
    outline: Palette.line,
    outlineVariant: Palette.line,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.bg,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Palette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Palette.line),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Palette.surface,
      selectedColor: Palette.brass.withValues(alpha: 0.18),
      side: const BorderSide(color: Palette.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Palette.brass,
      foregroundColor: Color(0xFF241A05),
      elevation: 2,
    ),
    dividerTheme: const DividerThemeData(color: Palette.line, space: 1),
  );
}
