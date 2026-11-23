import 'package:flutter/material.dart';

/// Colour tokens from the "Real Estate AI" design (light and dark sets).
/// Teal = in progress / actionable. Green is reserved for verified outcomes
/// (posted, completion verified, closed in FUB). Approved uses teal so it never
/// reads as posted.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.pg,
    required this.bg,
    required this.sf,
    required this.sf2,
    required this.bd,
    required this.tx,
    required this.mu,
    required this.nv,
    required this.ac,
    required this.onac,
    required this.acs,
    required this.ok,
    required this.oks,
    required this.wa,
    required this.was,
    required this.er,
    required this.ers,
    required this.na,
    required this.nas,
    required this.sel,
    required this.onsel,
  });

  final Color pg, bg, sf, sf2, bd, tx, mu, nv, ac, onac, acs, ok, oks, wa, was, er, ers, na, nas, sel, onsel;

  static const light = AppTokens(
    pg: Color(0xFFE7E2D8),
    bg: Color(0xFFF6F3EC),
    sf: Color(0xFFFFFFFF),
    sf2: Color(0xFFFBF9F5),
    bd: Color(0xFFE3DDD1),
    tx: Color(0xFF17202C),
    mu: Color(0xFF5A6270),
    nv: Color(0xFF13233B),
    ac: Color(0xFF0D7570),
    onac: Color(0xFFFFFFFF),
    acs: Color(0xFFDDEFEC),
    ok: Color(0xFF1D7344),
    oks: Color(0xFFE3F1E8),
    wa: Color(0xFF8F5409),
    was: Color(0xFFFBEFD9),
    er: Color(0xFFB42318),
    ers: Color(0xFFFBE5E2),
    na: Color(0xFF5F6673),
    nas: Color(0xFFECEAE5),
    sel: Color(0xFF13233B),
    onsel: Color(0xFFFFFFFF),
  );

  static const dark = AppTokens(
    pg: Color(0xFF070C14),
    bg: Color(0xFF0D1520),
    sf: Color(0xFF152030),
    sf2: Color(0xFF1A2738),
    bd: Color(0xFF283850),
    tx: Color(0xFFE7ECF3),
    mu: Color(0xFFA3AFC0),
    nv: Color(0xFF0A111B),
    ac: Color(0xFF5CC6BD),
    onac: Color(0xFF06201E),
    acs: Color(0xFF133A3A),
    ok: Color(0xFF74D19C),
    oks: Color(0xFF14301F),
    wa: Color(0xFFF0B45A),
    was: Color(0xFF3A2A12),
    er: Color(0xFFF28B82),
    ers: Color(0xFF3D1A18),
    na: Color(0xFFA9B1BE),
    nas: Color(0xFF222C3A),
    sel: Color(0xFF5CC6BD),
    onsel: Color(0xFF06201E),
  );

  (Color bg, Color fg) tone(Tone t) => switch (t) {
        Tone.ac => (acs, ac),
        Tone.ok => (oks, ok),
        Tone.wa => (was, wa),
        Tone.er => (ers, er),
        Tone.na => (nas, na),
      };

  Color fg(Tone t) => tone(t).$2;

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) => (other is AppTokens && t > .5) ? other : this;
}

/// Semantic tones: accent (in progress), ok (verified), warning (needs review),
/// error, neutral (unavailable / inactive).
enum Tone { ac, ok, wa, er, na }

/// Bottom navigation colours are fixed in both themes.
class NavColors {
  static const active = Color(0xFF9FE3DC);
  static const inactive = Color(0xFFB9C4D3);
  static const pill = Color(0x335CC6BD);
  static const toastBg = Color(0xFF1C2738);
  static const toastFg = Color(0xFFF2F5F9);
  static const toastIcon = Color(0xFF7FD6CE);
  static const brandMark = Color(0xFF5CC6BD);
  static const onBrandMark = Color(0xFF06201E);
  static const signInSub = Color(0xFFC9D3E0);
}

const kSans = 'IBMPlexSans';
const kMono = 'IBMPlexMono';
const tabular = [FontFeature.tabularFigures()];

extension TokensX on BuildContext {
  AppTokens get t => Theme.of(this).extension<AppTokens>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.dark ? AppTokens.dark : AppTokens.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.ac,
    onPrimary: t.onac,
    primaryContainer: t.acs,
    onPrimaryContainer: t.ac,
    secondary: t.nv,
    onSecondary: Colors.white,
    error: t.er,
    onError: Colors.white,
    surface: t.bg,
    onSurface: t.tx,
    onSurfaceVariant: t.mu,
    surfaceContainerHighest: t.nas,
    surfaceContainerHigh: t.sf2,
    surfaceContainer: t.sf,
    surfaceContainerLow: t.sf,
    outline: t.bd,
    outlineVariant: t.bd,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kSans,
    scaffoldBackgroundColor: t.bg,
    extensions: [t],
  );
  final text = base.textTheme.apply(bodyColor: t.tx, displayColor: t.tx);
  RoundedRectangleBorder r(double v) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(v));
  return base.copyWith(
    textTheme: text,
    dividerTheme: DividerThemeData(color: t.bd, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: t.sf,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.bd)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        backgroundColor: t.ac,
        foregroundColor: t.onac,
        disabledBackgroundColor: t.nas,
        disabledForegroundColor: t.mu,
        shape: r(12),
        textStyle: const TextStyle(fontFamily: kSans, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: t.sf,
        foregroundColor: t.tx,
        side: BorderSide(color: t.bd),
        shape: r(12),
        textStyle: const TextStyle(fontFamily: kSans, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.ac,
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(fontFamily: kSans, fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.sf,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      hintStyle: TextStyle(color: t.mu),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bd)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bd)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.ac, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.er)),
      focusedErrorBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.er, width: 1.5)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: NavColors.toastBg,
      contentTextStyle: TextStyle(fontFamily: kSans, color: NavColors.toastFg, fontSize: 14),
      insetPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    dialogTheme: DialogThemeData(backgroundColor: t.sf, shape: r(20)),
    datePickerTheme: DatePickerThemeData(backgroundColor: t.sf),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.ac),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.ac : Colors.transparent),
      side: BorderSide(color: t.mu, width: 1.5),
    ),
  );
}
