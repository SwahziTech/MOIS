import 'package:flutter/material.dart';

/*
 * The web's design tokens (web/src/styles/index.css :root and [data-theme='dark']) and font
 * (Google Sans Flex). Screens use these names, as the web's CSS does.
 */
class C {
  static const charcoal = Color(0xFF2B2B2B);
  static const khaki = Color(0xFFB7A57A);
  static const khakiLight = Color(0xFFD4C4A0);
  static const khakiDark = Color(0xFF8A7A56);
  static const coffee = Color(0xFF4B3621);
  static const success = Color(0xFF2E7D52);
  static const warning = Color(0xFFB45309);
  static const error = Color(0xFFC0392B);
  static const info = Color(0xFF1565A8);
}

class Tokens {
  const Tokens({
    required this.canvas, required this.surface, required this.soft, required this.sidebar, required this.sidebarHover,
    required this.sidebarActive, required this.textPrimary, required this.textSecondary, required this.textMuted,
    required this.textLabel, required this.border, required this.borderStrong, required this.accentSoft,
    required this.bgSuccess, required this.bgWarning, required this.bgError, required this.bgInfo, required this.dark,
  });
  final Color canvas, surface, soft, sidebar, sidebarHover, sidebarActive, textPrimary, textSecondary, textMuted, textLabel,
      border, borderStrong, accentSoft, bgSuccess, bgWarning, bgError, bgInfo;
  final bool dark;

  static const light = Tokens(
    canvas: Color(0xFFFDFCFA), surface: Color(0xFFFFFFFF), soft: Color(0xFFF5F2EC),
    sidebar: Color(0xFFF8F7F4), sidebarHover: Color(0xFFEFECE6), sidebarActive: Color(0xFFF1EDE5),
    textPrimary: Color(0xFF111111), textSecondary: Color(0xFF2E2B27), textMuted: Color(0xFF5C5750), textLabel: Color(0xFF2E2B27),
    border: Color(0xFFE8E5E0), borderStrong: Color(0xFFCFCBC4), accentSoft: Color(0x24B7A57A),
    bgSuccess: Color(0xFFEBF5EF), bgWarning: Color(0xFFFEF3C7), bgError: Color(0xFFFDECEA), bgInfo: Color(0xFFE8F0FD), dark: false,
  );
  static const darkT = Tokens(
    canvas: Color(0xFF1B1A18), surface: Color(0xFF222120), soft: Color(0xFF2A2825),
    sidebar: Color(0xFF1F1E1C), sidebarHover: Color(0xFF2B2926), sidebarActive: Color(0xFF302D29),
    textPrimary: Color(0xFFEEEAE3), textSecondary: Color(0xFFBEB8AE), textMuted: Color(0xFF8D877D), textLabel: C.khaki,
    border: Color(0xFF34312D), borderStrong: Color(0xFF46423C), accentSoft: Color(0x24B7A57A),
    bgSuccess: Color(0x2E2E7D52), bgWarning: Color(0x2EB45309), bgError: Color(0x2EC0392B), bgInfo: Color(0x2E1565A8), dark: true,
  );
}

const font = 'GoogleSans';

/// --text-xs … --text-xl
class Fs {
  static const xs = 11.0, sm = 13.0, base = 14.0, md = 16.0, lg = 20.0, xl = 24.0;
}

ThemeData appTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final t = dark ? Tokens.darkT : Tokens.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: C.khaki, brightness: b,
    primary: dark ? C.khaki : C.charcoal, onPrimary: dark ? C.charcoal : Colors.white,
    secondary: C.khaki, surface: t.surface, onSurface: t.textPrimary, error: C.error, outline: t.border,
  );
  final text = (dark ? Typography.whiteMountainView : Typography.blackMountainView)
      .apply(fontFamily: font, bodyColor: t.textPrimary, displayColor: t.textPrimary);
  OutlineInputBorder box(Color c, [double w = 1]) => OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c, width: w));
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    fontFamily: font,
    textTheme: text,
    scaffoldBackgroundColor: t.canvas,
    dividerColor: t.border,
    appBarTheme: AppBarTheme(
      backgroundColor: t.sidebar, foregroundColor: t.textPrimary, surfaceTintColor: Colors.transparent,
      elevation: 0, scrolledUnderElevation: 0, shape: Border(bottom: BorderSide(color: t.border)),
      titleTextStyle: TextStyle(fontFamily: font, fontSize: Fs.sm, fontWeight: FontWeight.w600, color: t.textPrimary),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: t.sidebar, surfaceTintColor: Colors.transparent, width: 280, shape: const RoundedRectangleBorder()),
    cardTheme: CardThemeData(
      color: t.surface, surfaceTintColor: Colors.transparent, elevation: 0, margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: box(t.borderStrong), enabledBorder: box(t.borderStrong), focusedBorder: box(C.khaki, 1.5),
      disabledBorder: box(t.border), errorBorder: box(C.error),
      filled: true, fillColor: t.surface, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: TextStyle(color: t.textMuted, fontSize: Fs.sm), hintStyle: TextStyle(color: t.textMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(64, 42), textStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w600, fontSize: Fs.sm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(40, 40), foregroundColor: t.textPrimary, side: BorderSide(color: t.borderStrong),
      textStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w500, fontSize: Fs.sm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)))),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: t.textPrimary, textStyle: const TextStyle(fontFamily: font, fontSize: Fs.sm))),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: dark ? C.khaki : C.charcoal, foregroundColor: dark ? C.charcoal : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: t.surface, surfaceTintColor: Colors.transparent, showDragHandle: true),
    dialogTheme: DialogThemeData(backgroundColor: t.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: t.surface, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(backgroundColor: dark ? C.khaki : C.charcoal, behavior: SnackBarBehavior.floating,
        contentTextStyle: TextStyle(fontFamily: font, color: dark ? C.charcoal : Colors.white)),
    checkboxTheme: CheckboxThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? (dark ? C.khaki : C.charcoal) : null)),
    extensions: [TokensExt(t)],
  );
}

class TokensExt extends ThemeExtension<TokensExt> {
  const TokensExt(this.t);
  final Tokens t;
  @override
  TokensExt copyWith({Tokens? t}) => TokensExt(t ?? this.t);
  @override
  TokensExt lerp(TokensExt? other, double v) => v < 0.5 ? this : (other ?? this);
}

extension TokensOf on BuildContext {
  Tokens get tk => Theme.of(this).extension<TokensExt>()?.t ?? Tokens.light;
}
