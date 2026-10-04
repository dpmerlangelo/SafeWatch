import 'package:flutter/material.dart';

@immutable
class AppColorsExt extends ThemeExtension<AppColorsExt> {
  final Color bg;
  final Color card;
  final Color sunken;
  final Color textMain;
  final Color textMuted;
  final Color border;

  const AppColorsExt({
    required this.bg,
    required this.card,
    required this.sunken,
    required this.textMain,
    required this.textMuted,
    required this.border,
  });

  static const dark = AppColorsExt(
    bg: AppColors.bgDark,
    card: AppColors.cardDark,
    sunken: AppColors.sunkenDark,
    textMain: AppColors.textMainDark,
    textMuted: AppColors.textMutedDark,
    border: AppColors.borderDark,
  );

  static const light = AppColorsExt(
    bg: AppColors.bgLight,
    card: AppColors.cardLight,
    sunken: AppColors.sunkenLight,
    textMain: AppColors.textMainLight,
    textMuted: AppColors.textMutedLight,
    border: AppColors.borderLight,
  );

  @override
  AppColorsExt copyWith({
    Color? bg,
    Color? card,
    Color? sunken,
    Color? textMain,
    Color? textMuted,
    Color? border,
  }) {
    return AppColorsExt(
      bg: bg ?? this.bg,
      card: card ?? this.card,
      sunken: sunken ?? this.sunken,
      textMain: textMain ?? this.textMain,
      textMuted: textMuted ?? this.textMuted,
      border: border ?? this.border,
    );
  }

  @override
  AppColorsExt lerp(ThemeExtension<AppColorsExt>? other, double t) {
    if (other is! AppColorsExt) return this;
    return AppColorsExt(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      sunken: Color.lerp(sunken, other.sunken, t)!,
      textMain: Color.lerp(textMain, other.textMain, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      border: Color.lerp(border, other.border, t)!,
    );
  }
}

class AppColors {
  AppColors._(); // no instances

  // ---- Dark ----
  static const Color bgDark        = Color(0xFF11161D);
  static const Color cardDark      = Color(0xFF1C2126);
  static const Color sunkenDark    = Color(0xFF0C0F13);
  static const Color textMainDark  = Color(0xFFE9EAED);
  static const Color textMutedDark = Color(0xFF939DA9);
  static const Color borderDark    = Color(0xFF2A323C);

  // ---- Light ----
  static const Color bgLight        = Color(0xFFF1F4F7);
  static const Color cardLight      = Color(0xFFFFFFFF);
  static const Color sunkenLight    = Color(0xFFE9EDF1);
  static const Color textMainLight  = Color(0xFF23262B);
  static const Color textMutedLight = Color(0xFF5B6472);
  static const Color borderLight    = Color(0xFFDCE1E6);

  // ---- Accents (shared across both modes) ----
  static const Color accentBlue   = Color(0xFF2563C7);
  static const Color accentRed    = Color(0xFFD93636);
  static const Color accentGreen  = Color(0xFF0B8F68);
  static const Color accentOrange = Color(0xFFC9820A);
  static const Color accentPurple = Color(0xFF8064D9);

  /// Theme-aware helpers — now pull from the animated ThemeExtension
  /// instead of hard-branching on Brightness, so they interpolate
  /// smoothly during theme transitions.
  static Color bg(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.bg;

  static Color card(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.card;

  static Color sunken(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.sunken;

  static Color textMain(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.textMain;

  static Color textMuted(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.textMuted;

  static Color border(BuildContext context) =>
      Theme.of(context).extension<AppColorsExt>()!.border;
}