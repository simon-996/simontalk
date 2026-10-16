import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF245C45),
        brightness: brightness,
      ).copyWith(
        primary: Color(dark ? 0xFFA4D6B0 : 0xFF245C45),
        onPrimary: Color(dark ? 0xFF113822 : 0xFFFFFFFF),
        surface: Color(dark ? 0xFF1D2821 : 0xFFFFFFFF),
        surfaceContainerLow: Color(dark ? 0xFF27382D : 0xFFEAF0E8),
        onSurface: Color(dark ? 0xFFE7EEE7 : 0xFF18251D),
        onSurfaceVariant: Color(dark ? 0xFFBBC9BD : 0xFF526157),
        outline: Color(dark ? 0xFF84948A : 0xFF718177),
        outlineVariant: Color(dark ? 0xFF384B3D : 0xFFDCE5DC),
        error: Color(dark ? 0xFFFFB4AB : 0xFFAF332D),
        onError: Color(dark ? 0xFF641B18 : 0xFFFFFFFF),
        errorContainer: Color(dark ? 0xFF641B18 : 0xFFFCE9E7),
        onErrorContainer: Color(dark ? 0xFFFFB4AB : 0xFFAF332D),
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: kIsWeb ? 'NotoSansSC' : null,
  );
  const radius = BorderRadius.all(Radius.circular(16));
  return base.copyWith(
    scaffoldBackgroundColor: Color(dark ? 0xFF151C18 : 0xFFF5F7F2),
    textTheme: base.textTheme
        .copyWith(
          headlineMedium: TextStyle(
            fontSize: 28,
            height: 36 / 28,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          titleLarge: TextStyle(
            fontSize: 22,
            height: 30 / 22,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          bodyLarge: TextStyle(
            fontSize: 16,
            height: 26 / 16,
            color: scheme.onSurface,
          ),
          bodyMedium: TextStyle(
            fontSize: 16,
            height: 26 / 16,
            color: scheme.onSurface,
          ),
          bodySmall: TextStyle(
            fontSize: 14,
            height: 22 / 14,
            color: scheme.onSurfaceVariant,
          ),
          labelLarge: TextStyle(
            fontSize: 16,
            height: 1.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        )
        .apply(fontFamily: kIsWeb ? 'NotoSansSC' : null),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: const OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorMaxLines: 4,
      helperMaxLines: 4,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 32),
  );
}
