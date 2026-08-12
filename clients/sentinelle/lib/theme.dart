import 'package:flutter/material.dart';

/// What the user picked in Settings.
enum AppThemeMode {
  /// Follow whatever the operating system is set to.
  system,
  light,
  dark;

  static AppThemeMode parse(String? name) => AppThemeMode.values.firstWhere(
        (m) => m.name == name,
        orElse: () => AppThemeMode.system,
      );

  String get label => switch (this) {
        AppThemeMode.system => 'System',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };

  IconData get icon => switch (this) {
        AppThemeMode.system => Icons.brightness_auto_rounded,
        AppThemeMode.light => Icons.light_mode_rounded,
        AppThemeMode.dark => Icons.dark_mode_rounded,
      };

  ThemeMode get material => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };
}

/// Which palette [VeilColors] is currently handing out.
///
/// The tokens are read from static getters all over the app rather than from an
/// InheritedWidget, so the active brightness has to live somewhere global. It
/// is set once per frame from the app root, before anything builds.
class VeilTheme {
  VeilTheme._();

  static Brightness _brightness = Brightness.dark;

  static Brightness get brightness => _brightness;
  static bool get isDark => _brightness == Brightness.dark;

  static void apply(Brightness b) => _brightness = b;

  /// The brightness [mode] means, given what the platform is currently set to.
  static Brightness resolve(AppThemeMode mode, Brightness platform) =>
      switch (mode) {
        AppThemeMode.system => platform,
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
      };
}

/// Veil design tokens.
///
/// The dark values are ported 1:1 from the `Veil Client.html` mockup; the light
/// ones mirror each token's *role* rather than inverting the hex, which is what
/// keeps a light window recognisably the same product.
///
/// The light palette is deliberately *warm* — paper rather than paper-white.
/// It started life as a cool blue-grey built around `#FFFFFF` surfaces, which
/// is the brightest thing a screen can emit and reads as glare in anything but
/// a bright room. Every light token now carries a little yellow: the page is a
/// warm off-white, cards are cream rather than pure white, and the greys are
/// mixed towards brown instead of blue. Contrast ratios are unchanged.
///
/// Getters rather than constants: the whole app reads these directly, so this
/// is the one place a theme switch can happen without threading a context
/// through fifteen thousand lines.
class VeilColors {
  static T _p<T>(T dark, T light) => VeilTheme.isDark ? dark : light;

  // Accent (mockup: oklch(78% 0.13 175)).
  //
  // The light accent is deliberately darker: the mockup's teal is a lovely
  // glow on near-black and an unreadable 1.6:1 as text on white.
  static Color get accent => _p(const Color(0xFF41D2B3), const Color(0xFF007A67));
  static Color get accentHi => _p(const Color(0xFF5AE8C8), const Color(0xFF00947C));
  static Color get accentLo => _p(const Color(0xFF00A488), const Color(0xFF005A4C));
  static Color get accentTint =>
      _p(const Color(0x2441D2B3), const Color(0x1F007A67));
  static Color get accentSoft =>
      _p(const Color(0x3841D2B3), const Color(0x38007A67));

  /// Foreground on an accent-filled surface.
  static Color get onAccent =>
      _p(const Color(0xFF04211B), const Color(0xFFFFFFFF));

  // Surfaces
  static Color get bg => _p(const Color(0xFF07090C), const Color(0xFFF3EEE4));
  static Color get surface => _p(const Color(0xFF11151C), const Color(0xFFFCF9F3));
  static Color get surface2 => _p(const Color(0xFF161B23), const Color(0xFFF0EBE0));
  static Color get elev => _p(const Color(0xFF1A212B), const Color(0xFFFFFCF6));
  static Color get border => _p(const Color(0xFF232A35), const Color(0xFFDCD4C6));
  static Color get borderSoft =>
      _p(const Color(0xFF1D242E), const Color(0xFFE8E1D4));

  // Text
  static Color get text => _p(const Color(0xFFEBEEF2), const Color(0xFF1A1612));
  static Color get text2 => _p(const Color(0xFFB6BCC7), const Color(0xFF524B41));
  static Color get muted => _p(const Color(0xFF7C828D), const Color(0xFF7A7266));

  // Semantic
  static Color get upload => _p(const Color(0xFF4BAEED), const Color(0xFF1173BE));
  static Color get danger => _p(const Color(0xFFFC5855), const Color(0xFFC33A2A));
  static Color get warn => _p(const Color(0xFFF2A618), const Color(0xFF97650A));

  // Map
  static Color get land => _p(const Color(0xFF151B25), const Color(0xFFE4DCCC));
  static Color get landStroke =>
      _p(const Color(0xFF212934), const Color(0xFFCCC1AD));

  /// The "you are here" blue, distinct from the accent used for servers.
  static Color get info => upload;

  /// A wash over whatever is underneath — the subtle "raised" fill used on
  /// icon chips and progress tracks. White lifts a dark surface; on a light one
  /// it is invisible, so it has to darken instead — with a brown rather than a
  /// neutral black, or the wash pulls the warm surfaces back towards grey.
  static Color tint(double alpha) => (VeilTheme.isDark
          ? Colors.white
          : const Color(0xFF4A3F30))
      .withValues(alpha: alpha);

  /// Foreground on a warn-filled surface — the connect orb while it is dialling.
  static Color get onWarn =>
      _p(const Color(0xFF1A1004), const Color(0xFFFFFFFF));

  /// Panel behind a failure message: a wash of [danger] over the page rather
  /// than a fixed maroon, which was unreadable the moment the page went light.
  static Color get dangerSurface =>
      _p(const Color(0xFF2A1416), const Color(0xFFFAE7E0));

  /// The connect orb at rest, and the ring around it. Its own tokens because it
  /// is the one element that is a *material* rather than a surface — a flat
  /// near-black sphere on a white page reads as a hole in the screen.
  static Color get orbIdleFrom =>
      _p(const Color(0xFF2A2F38), const Color(0xFFEFE8DA));
  static Color get orbIdleTo =>
      _p(const Color(0xFF15181D), const Color(0xFFD5CBB8));
  static Color get orbIdleRing =>
      _p(const Color(0xFF3A3F47), const Color(0xFFC4B9A4));

  /// Glyph on the resting orb, and the knob of an "off" switch.
  static Color get onIdle =>
      _p(const Color(0xFF9AA0AC), const Color(0xFF7B7264));

  /// The far end of the connect orb's gradient, past [accentLo] / [warn].
  static Color get accentDeep =>
      _p(const Color(0xFF00614F), const Color(0xFF004437));
  static Color get warnDeep =>
      _p(const Color(0xFFB06A00), const Color(0xFF7A4F05));

  /// Drop shadows. Softer on a light page, where a heavy black shadow reads as
  /// grime rather than depth.
  static Color shadow(double alpha) =>
      Colors.black.withValues(alpha: VeilTheme.isDark ? alpha : alpha * 0.35);

  // Protocol chips
  static Color get vless => _p(const Color(0xFF4FDCC0), const Color(0xFF00806C));
  static Color get vmess => _p(const Color(0xFF7FB0F5), const Color(0xFF2C63B4));
  static Color get trojan => _p(const Color(0xFFF08A6E), const Color(0xFFB2532F));
  static Color get shadowsocks =>
      _p(const Color(0xFFE9BE5A), const Color(0xFF8A6608));

  static Color protoColor(String proto) {
    switch (proto.toLowerCase()) {
      case 'vless':
        return vless;
      case 'vmess':
        return vmess;
      case 'trojan':
        return trojan;
      case 'shadowsocks':
      case 'ss':
        return shadowsocks;
      default:
        return text2;
    }
  }
}

/// Typography helpers. The bundled fonts are variable, so weights are applied
/// through [FontVariation] — declaring them in pubspec alone would only get us
/// a synthesised bold.
class VeilText {
  static const _display = 'SpaceGrotesk';
  static const _ui = 'DMSans';
  static const _mono = 'JetBrainsMono';

  static TextStyle display({
    double size = 22,
    int weight = 600,
    Color? color,
    double? height,
    double letterSpacing = -0.4,
  }) =>
      TextStyle(
        fontFamily: _display,
        fontSize: size,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontWeight: _fw(weight),
        fontVariations: [FontVariation('wght', weight.toDouble())],
      );

  static TextStyle ui({
    double size = 13.5,
    int weight = 400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: _ui,
        fontSize: size,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontWeight: _fw(weight),
        fontVariations: [FontVariation('wght', weight.toDouble())],
      );

  static TextStyle mono({
    double size = 12,
    int weight = 400,
    Color? color,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: _mono,
        fontSize: size,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: _fw(weight),
        fontVariations: [FontVariation('wght', weight.toDouble())],
      );

  /// Small uppercase label used all over the mockup.
  static TextStyle label({
    double size = 11,
    Color? color,
    int weight = 600,
  }) =>
      ui(size: size, weight: weight, color: color, letterSpacing: 1.1);

  static FontWeight _fw(int w) {
    const map = {
      100: FontWeight.w100,
      200: FontWeight.w200,
      300: FontWeight.w300,
      400: FontWeight.w400,
      500: FontWeight.w500,
      600: FontWeight.w600,
      700: FontWeight.w700,
      800: FontWeight.w800,
      900: FontWeight.w900,
    };
    return map[(w ~/ 100) * 100] ?? FontWeight.w400;
  }
}

/// Turns the desktop pointer into a hand over a hand-built tappable.
///
/// Material's own buttons and `InkWell` already do this; every control in the
/// app that is a bare `GestureDetector` — the connect button, the switches, the
/// filter tabs, the server rows — kept the plain arrow, which on a desktop
/// reads as "this is not clickable". Lives in the theme rather than in
/// `widgets/common.dart` so the leaf widgets that only import the palette can
/// use it without picking up a dependency on the whole widget library.
class Clickable extends StatelessWidget {
  const Clickable({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// A disabled control should not promise a click it will not honour.
  final bool enabled;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: child,
      );
}

class VeilRadius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 22.0;
  static const pill = 999.0;
}

/// Builds the Material theme for [brightness].
///
/// [VeilTheme.apply] must have been called with the same brightness first: the
/// tokens below are read from the global palette, not passed in.
ThemeData buildVeilTheme([Brightness brightness = Brightness.dark]) {
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: VeilColors.bg,
    canvasColor: VeilColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: VeilColors.accent,
      secondary: VeilColors.accent,
      surface: VeilColors.surface,
      error: VeilColors.danger,
      onPrimary: VeilColors.onAccent,
      onSurface: VeilColors.text,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: 'DMSans',
      bodyColor: VeilColors.text,
      displayColor: VeilColors.text,
    ),
    dividerColor: VeilColors.borderSoft,
    splashFactory: InkSparkle.splashFactory,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: VeilColors.elev,
        borderRadius: BorderRadius.circular(VeilRadius.sm),
        border: Border.all(color: VeilColors.border),
      ),
      textStyle: VeilText.ui(size: 12, color: VeilColors.text2),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: VeilColors.elev,
      contentTextStyle: VeilText.ui(size: 13, color: VeilColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        side: BorderSide(color: VeilColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VeilColors.surface2,
      hintStyle: VeilText.ui(size: 13.5, color: VeilColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        borderSide: BorderSide(color: VeilColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        borderSide: BorderSide(color: VeilColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        borderSide: BorderSide(color: VeilColors.accent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        borderSide: BorderSide(color: VeilColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VeilRadius.md),
        borderSide: BorderSide(color: VeilColors.danger, width: 1.4),
      ),
    ),
  );
}

/// Radial glow used behind the connect orb on every platform.
BoxDecoration veilPageGlow({double opacity = 0.10}) => BoxDecoration(
      color: VeilColors.bg,
      gradient: RadialGradient(
        center: const Alignment(0, -0.55),
        radius: 1.1,
        colors: [
          VeilColors.accent.withValues(alpha: opacity),
          VeilColors.bg.withValues(alpha: 0),
        ],
      ),
    );
