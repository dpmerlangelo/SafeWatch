import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bgDark,
        cardColor: AppColors.cardDark,
        dividerColor: AppColors.borderDark,
        extensions: const [AppColorsExt.dark],
        colorScheme: const ColorScheme.dark(
          surface: AppColors.cardDark,
          onSurface: AppColors.textMainDark,
          primary: AppColors.accentBlue,
          secondary: AppColors.accentGreen,
          error: AppColors.accentRed,
        ),
        textTheme: _textTheme(AppColors.textMainDark, AppColors.textMutedDark),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bgDark,
          foregroundColor: AppColors.textMainDark,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardDark,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.borderDark),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.cardDark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.sunkenDark,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.borderDark),
          ),
          hintStyle: const TextStyle(color: AppColors.textMutedDark),
        ),
        iconTheme: const IconThemeData(color: AppColors.textMainDark),
        dividerTheme: const DividerThemeData(color: AppColors.borderDark),
      );

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.bgLight,
        cardColor: AppColors.cardLight,
        dividerColor: AppColors.borderLight,
        extensions: const [AppColorsExt.light],
        colorScheme: const ColorScheme.light(
          surface: AppColors.cardLight,
          onSurface: AppColors.textMainLight,
          primary: AppColors.accentBlue,
          secondary: AppColors.accentGreen,
          error: AppColors.accentRed,
        ),
        textTheme:
            _textTheme(AppColors.textMainLight, AppColors.textMutedLight),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bgLight,
          foregroundColor: AppColors.textMainLight,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardLight,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.borderLight),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.cardLight,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.sunkenLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.borderLight),
          ),
          hintStyle: const TextStyle(color: AppColors.textMutedLight),
        ),
        iconTheme: const IconThemeData(color: AppColors.textMainLight),
        dividerTheme: const DividerThemeData(color: AppColors.borderLight),
      );

  static TextTheme _textTheme(Color main, Color muted) {
    return TextTheme(
      displayLarge: TextStyle(color: main),
      titleLarge: TextStyle(color: main, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(color: main, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(color: main),
      bodyMedium: TextStyle(color: main),
      bodySmall: TextStyle(color: muted),
      labelLarge: TextStyle(color: main),
    );
  }
}