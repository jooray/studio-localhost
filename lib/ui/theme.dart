import 'package:flutter/material.dart';

/// Catalogue Sleeve: matte black ground, white hairline rules, engraved mono caps for labels, a
/// plain grotesk for words people write, and a five-colour code. Red marks the one active entry.
abstract final class Sleeve {
  static const ground = Color(0xFF0A0A0B);
  static const raised = Color(0xFF111112); // sheets; same matte, a hair lighter
  static const ink = Color(0xFFF2F2F0);
  static const inkSoft = Color(0xFFBEBEBB);
  static const inkMute = Color(0xFF8E8E8B); // 5.9:1 on ground
  static const rule = Color(0xFFBDBDBA);
  static const ruleFaint = Color(0xFF3B3B3B);
  static const grid = Color(0xFF6B6B6B);
  static const red = Color(0xFFC8553D);

  static const codeGrey = Color(0xFF7D7D7F);
  static const codeBlue = Color(0xFF3F6E8C);
  static const codeGold = Color(0xFFD8A461);
  static const codeRed = red;
  static const codeWhite = Color(0xFFF2F2F0);
  static const code = [codeGrey, codeBlue, codeGold, codeRed, codeWhite];

  static const mono = 'GeistMono';
  static const sans = 'Geist';

  static const hair = 1.0;

  // Motion: one grammar. Entries step in; nothing bounces.
  static const step = Duration(milliseconds: 260);
  static const quick = Duration(milliseconds: 140);
  static const ease = Cubic(0.16, 1, 0.3, 1); // exponential ease-out
}

/// The comp unit: the approved comp is 576 px wide; [u] scales its measurements to the window.
class SleeveScale extends InheritedWidget {
  const SleeveScale({super.key, required this.u, required super.child});

  final double u;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SleeveScale>()?.u ?? 1.0;

  @override
  bool updateShouldNotify(SleeveScale old) => old.u != u;
}

/// Type roles, measured from the comp (sizes in comp px, times [u]).
abstract final class SleeveType {
  /// Engraved status line: Geist Mono Light, cap 19.7 px.
  static TextStyle status(double u, {Color color = Sleeve.ink}) =>
      TextStyle(fontFamily: Sleeve.mono, fontWeight: FontWeight.w300, fontSize: 26.5 * u, height: 1.0, color: color, letterSpacing: -0.3 * u);

  /// Field labels (STYLE, LYRICS): mono caps at body size.
  static TextStyle label(double u, {Color color = Sleeve.ink}) =>
      TextStyle(fontFamily: Sleeve.mono, fontWeight: FontWeight.w300, fontSize: 24.5 * u, height: 1.0, color: color);

  /// Words people write: style and lyrics. Plain grotesk, cap 17.3 px.
  static TextStyle body(double u, {Color color = Sleeve.ink}) => TextStyle(
      fontFamily: Sleeve.sans, fontWeight: FontWeight.w300, fontSize: 22.5 * u, height: 26 / 22.5, color: color, letterSpacing: -0.15 * u);

  /// Catalogue index numerals: wide mono, regular.
  static TextStyle index(double u, {Color color = Sleeve.ink}) =>
      TextStyle(fontFamily: Sleeve.mono, fontWeight: FontWeight.w300, fontSize: 30 * u, height: 1.0, color: color);

  /// Small engraved caps, wide tracked (data labels, etched lines, cells).
  static TextStyle etched(double u, {Color color = Sleeve.inkSoft, double size = 13, FontWeight weight = FontWeight.w400}) {
    final px = floor(size * u);
    return TextStyle(fontFamily: Sleeve.mono, fontWeight: weight, fontSize: px, height: 1.2, color: color, letterSpacing: px * 0.16);
  }

  /// Nothing set in this world drops below 11 logical px.
  static double floor(double px) => px < 11 ? 11 : px;

  /// Values in data lists.
  static TextStyle value(double u, {Color color = Sleeve.ink, double size = 15}) =>
      TextStyle(fontFamily: Sleeve.mono, fontWeight: FontWeight.w400, fontSize: floor(size * u), height: 1.3, color: color, letterSpacing: floor(size * u) * 0.04);

  /// Display numerals (song detail heading).
  static TextStyle display(double u, {Color color = Sleeve.ink}) => TextStyle(
      fontFamily: Sleeve.sans, fontWeight: FontWeight.w300, fontSize: 64 * u, height: 1.0, color: color, letterSpacing: -0.02 * 64 * u);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Sleeve.ink,
    onPrimary: Sleeve.ground,
    secondary: Sleeve.inkSoft,
    onSecondary: Sleeve.ground,
    error: Sleeve.red,
    onError: Sleeve.ink,
    surface: Sleeve.ground,
    onSurface: Sleeve.ink,
    onSurfaceVariant: Sleeve.inkMute,
    outline: Sleeve.rule,
    outlineVariant: Sleeve.ruleFaint,
    surfaceContainerLowest: Sleeve.ground,
    surfaceContainerLow: Sleeve.ground,
    surfaceContainer: Sleeve.raised,
    surfaceContainerHigh: Sleeve.raised,
    surfaceContainerHighest: Sleeve.raised,
  );
  const sharp = RoundedRectangleBorder(borderRadius: BorderRadius.zero, side: BorderSide(color: Sleeve.rule, width: Sleeve.hair));
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Sleeve.ground,
    canvasColor: Sleeve.ground,
    fontFamily: Sleeve.sans,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: const Color(0x0FFFFFFF),
    focusColor: const Color(0x1FFFFFFF),
    dividerTheme: const DividerThemeData(color: Sleeve.ruleFaint, thickness: Sleeve.hair, space: Sleeve.hair),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Sleeve.ink,
      selectionColor: Color(0x66C8553D),
      selectionHandleColor: Sleeve.red,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(2),
      radius: Radius.zero,
      thumbColor: WidgetStatePropertyAll(Sleeve.inkMute.withValues(alpha: 0.6)),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Sleeve.ground, border: Border.fromBorderSide(BorderSide(color: Sleeve.rule, width: Sleeve.hair))),
      textStyle: TextStyle(fontFamily: Sleeve.mono, fontSize: 11, letterSpacing: 1.6, color: Sleeve.ink),
      waitDuration: Duration(milliseconds: 600),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Sleeve.ground,
      behavior: SnackBarBehavior.floating,
      shape: sharp,
      elevation: 0,
      contentTextStyle: TextStyle(fontFamily: Sleeve.mono, fontSize: 12, letterSpacing: 1.8, color: Sleeve.ink),
      actionTextColor: Sleeve.ink,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Sleeve.ground,
      modalBackgroundColor: Sleeve.ground,
      shape: Border(top: BorderSide(color: Sleeve.rule, width: Sleeve.hair)),
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Sleeve.ground, shape: sharp, elevation: 0),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Sleeve.ink, linearTrackColor: Sleeve.ruleFaint, linearMinHeight: 2),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: _SleeveTransition(),
      TargetPlatform.macOS: _SleeveTransition(),
      TargetPlatform.linux: _SleeveTransition(),
      TargetPlatform.windows: _SleeveTransition(),
      TargetPlatform.iOS: _SleeveTransition(),
    }),
  );
}

/// Pages step in: a short rise and fade with the exponential ease, nothing else moves.
class _SleeveTransition extends PageTransitionsBuilder {
  const _SleeveTransition();

  @override
  Duration get transitionDuration => Sleeve.step;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final a = CurvedAnimation(parent: animation, curve: Sleeve.ease, reverseCurve: Curves.easeIn);
    return FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.025), end: Offset.zero).animate(a), child: child),
    );
  }
}
