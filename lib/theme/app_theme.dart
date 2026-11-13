import 'package:flutter/widgets.dart';

/// Sizes shared across the interface. See docs/design-spec.md.
abstract final class Dim {
  /// Below this window width the days stack in a single column.
  static const breakpoint = 1024.0;

  static const pagePadding = 24.0;
  static const narrowPadding = 24.0;
  static const columnGap = 24.0;

  /// Height of one ruled row.
  static const row = 42.0;
  static const dayHeader = 42.0;
  static const listHeading = 53.0;
  static const headerHeight = 48.0;
  static const headerGap = 72.0;
  static const somedayGap = 32.0;

  static const weekdayRows = 10;
  static const weekendRows = 4;
  static const somedayRows = 2;

  static const dialogWidth = 512.0;
  static const dialogRadius = 24.0;
  static const dialogTop = 88.0;

  static const radiusS = 6.0;
  static const radiusM = 12.0;
  static const radiusL = 16.0;
  static const radiusXl = 24.0;

  static const controlSmall = 32.0;
  static const controlInline = 36.0;
  static const controlMedium = 40.0;
  static const controlLarge = 44.0;

  static const fast = Duration(milliseconds: 100);
  static const medium = Duration(milliseconds: 200);
}

/// A highlight colour a task can carry.
class TaskColor {
  const TaskColor(this.key, this.name, this.fill, {this.lightText = false});

  /// Stored on the task.
  final String key;
  final String name;
  final Color fill;

  /// Whether text on this colour is white rather than black.
  final bool lightText;

  Color get onFill =>
      lightText ? const Color(0xFFFFFFFF) : const Color(0xFF000000);

  static const palette = <TaskColor>[
    TaskColor('red', 'Red', Color(0xFFCD2C54), lightText: true),
    TaskColor('yellow', 'Yellow', Color(0xFFFEEE5D)),
    TaskColor('blue', 'Blue', Color(0xFF5167F4), lightText: true),
    TaskColor('green', 'Green', Color(0xFF23FFA1)),
    TaskColor('orange', 'Orange', Color(0xFFFFB022)),
    TaskColor('purple', 'Purple', Color(0xFFBE9CF3)),
    TaskColor('lilac', 'Lilac', Color(0xFFD85DFD)),
    TaskColor('cyan', 'Cyan', Color(0xFF98F4F9)),
    TaskColor('lavender', 'Lavender', Color(0xFFDCE1FD)),
    TaskColor('grey', 'Grey', Color(0xFFC2C2C2)),
    TaskColor('black', 'Black', Color(0xFF000000), lightText: true),
  ];

  /// Resolves a stored colour: a palette key or a `#RRGGBB` custom colour.
  /// Returns null for no colour or anything unrecognised.
  static TaskColor? resolve(String? stored) {
    if (stored == null) return null;
    for (final c in palette) {
      if (c.key == stored) return c;
    }
    final fill = parseHex(stored);
    if (fill == null) return null;
    return TaskColor(stored, stored.toUpperCase(), fill,
        lightText: fill.computeLuminance() < 0.4);
  }

  static Color? parseHex(String text) {
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(text.trim());
    return m == null ? null : Color(0xFF000000 | int.parse(m[1]!, radix: 16));
  }

  static String toHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

/// One whole-app colour theme.
class AppTheme {
  const AppTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.text,
    this.accent = const Color(0xFF5167F4),
    required this.dialog,
    required this.popover,
    this.menuButton = const Color(0xFFBE9CF3),
    this.navButton = const Color(0xFF000000),
    this.navButtonIcon = const Color(0xFFFFFFFF),
  });

  final String id;
  final String name;
  final Brightness brightness;
  final Color background;
  final Color text;
  final Color accent;

  /// Surface of the task dialog and other cards.
  final Color dialog;

  /// Surface of menus and pickers (slightly translucent).
  final Color popover;

  final Color menuButton;
  final Color navButton;
  final Color navButtonIcon;

  bool get isDark => brightness == Brightness.dark;

  /// This theme with card content drawn on [surface] in [content] colour,
  /// for a task dialog tinted with the task's highlight colour.
  AppTheme onSurface(Color surface, Color content) => AppTheme(
        id: id,
        name: name,
        brightness: content.computeLuminance() > 0.5
            ? Brightness.dark
            : Brightness.light,
        background: surface,
        text: content,
        accent: accent,
        dialog: surface,
        popover: popover,
        menuButton: menuButton,
        navButton: content,
        navButtonIcon: surface,
      );

  static const danger = Color(0xFFDF525F);
  static const dangerPressed = Color(0xFFCD2C54);

  /// The text colour at a step of the neutral ramp. [step] is the light-theme
  /// percentage (5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 90); dark themes lift
  /// the faintest steps so they stay visible on black.
  Color ink(int step) {
    var percent = step;
    if (isDark) {
      percent = switch (step) { 5 => 12, 10 => 15, 15 => 20, 20 => 25, 25 => 30, _ => step };
    }
    return text.withValues(alpha: percent / 100);
  }

  Color get rule => text.withValues(alpha: 0.10);
  Color get hoverRule => accent.withValues(alpha: 0.40);
  Color get barrier =>
      const Color(0xFF000000).withValues(alpha: isDark ? 0.6 : 0.4);

  static const light = AppTheme(
    id: 'light',
    name: 'Light',
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    text: Color(0xFF000000),
    dialog: Color(0xFFFFFFFF),
    popover: Color(0xF2EFEFEF),
  );

  static const dark = AppTheme(
    id: 'dark',
    name: 'Dark',
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    text: Color(0xFFFFFFFF),
    dialog: Color(0xFF202023),
    popover: Color(0xF2202023),
    navButton: Color(0xFF27282B),
  );

  static const paper = AppTheme(
    id: 'paper',
    name: 'Paper',
    brightness: Brightness.light,
    background: Color(0xFFF6F2E9),
    text: Color(0xFF1B1A17),
    accent: Color(0xFFB4532A),
    dialog: Color(0xFFFFFDF8),
    popover: Color(0xF2ECE7DB),
    menuButton: Color(0xFFE6C9A8),
    navButton: Color(0xFF1B1A17),
  );

  static const ice = AppTheme(
    id: 'ice',
    name: 'Ice',
    brightness: Brightness.light,
    background: Color(0xFFEAF1FB),
    text: Color(0xFF0D1B2E),
    accent: Color(0xFF2563EB),
    dialog: Color(0xFFF8FBFF),
    popover: Color(0xF2DDE7F5),
    menuButton: Color(0xFFA9C7F5),
    navButton: Color(0xFF0D1B2E),
  );

  static const rose = AppTheme(
    id: 'rose',
    name: 'Rose',
    brightness: Brightness.light,
    background: Color(0xFFFBEDEE),
    text: Color(0xFF2A1215),
    accent: Color(0xFFC2264D),
    dialog: Color(0xFFFFF8F8),
    popover: Color(0xF2F3DFE1),
    menuButton: Color(0xFFF2B5BF),
    navButton: Color(0xFF2A1215),
  );

  static const sage = AppTheme(
    id: 'sage',
    name: 'Sage',
    brightness: Brightness.light,
    background: Color(0xFFEDF3EA),
    text: Color(0xFF14201A),
    accent: Color(0xFF2F7D4F),
    dialog: Color(0xFFF9FCF7),
    popover: Color(0xF2E0E8DC),
    menuButton: Color(0xFFB7D8BE),
    navButton: Color(0xFF14201A),
  );

  static const slate = AppTheme(
    id: 'slate',
    name: 'Slate',
    brightness: Brightness.dark,
    background: Color(0xFF171A21),
    text: Color(0xFFE8EAF0),
    accent: Color(0xFF8B9BFF),
    dialog: Color(0xFF242833),
    popover: Color(0xF2242833),
    menuButton: Color(0xFF8B9BFF),
    navButton: Color(0xFF2E3340),
  );

  static const all = [light, dark, paper, ice, rose, sage, slate];

  /// Resolves the stored theme setting. `system` follows the desktop's
  /// light/dark preference.
  static AppTheme resolve(String? id, Brightness platform) {
    if (id == null || id == 'system') {
      return platform == Brightness.dark ? dark : light;
    }
    return all.firstWhere((t) => t.id == id, orElse: () => light);
  }
}

/// Text styles. Sizes and line heights follow the measured scale; tracking is
/// tuned so Inter sets to about the same width as the reference face.
class AppText {
  const AppText(this.color);

  final Color color;

  static const family = 'Inter';

  TextStyle _style(
    double size,
    double lineHeight, {
    FontWeight weight = FontWeight.w400,
    double tracking = 0,
  }) =>
      TextStyle(
        fontFamily: family,
        fontFamilyFallback: const ['Noto Color Emoji', 'Noto Sans'],
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        letterSpacing: tracking,
        color: color,
        decoration: TextDecoration.none,
        leadingDistribution: TextLeadingDistribution.even,
      );

  TextStyle get title36 => _style(36, 48, weight: FontWeight.w700, tracking: -0.7);
  TextStyle get title31 => _style(31, 40, weight: FontWeight.w700, tracking: -0.6);
  TextStyle get title28 => _style(28, 34, weight: FontWeight.w700, tracking: -0.2);
  TextStyle get heading24 => _style(24, 28, weight: FontWeight.w700, tracking: -0.3);
  TextStyle get heading21 => _style(21, 28, weight: FontWeight.w700, tracking: -0.5);
  TextStyle get label21 => _style(21, 28, tracking: -0.4);
  TextStyle get heading18 => _style(18, 28, weight: FontWeight.w700, tracking: -0.4);
  TextStyle get label18 => _style(18, 28, tracking: -0.3);
  TextStyle get body17 => _style(17, 22, tracking: -0.1);
  TextStyle get bodyBold17 => _style(17, 22, weight: FontWeight.w700, tracking: -0.1);
  TextStyle get task16 => _style(16, 22, tracking: -0.15);
  TextStyle get small15 => _style(15, 20, tracking: -0.1);
  TextStyle get task14 => _style(14, 22, tracking: -0.12);
  TextStyle get caption14 => _style(14, 20, tracking: -0.1);
  TextStyle get tiny12 => _style(12, 18);
  TextStyle get badge12 => _style(12, 20, weight: FontWeight.w600);
}

/// Makes the active [AppTheme] available to the widget tree.
class ThemeScope extends InheritedWidget {
  const ThemeScope({super.key, required this.theme, required super.child});

  final AppTheme theme;

  static AppTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!.theme;

  @override
  bool updateShouldNotify(ThemeScope oldWidget) => oldWidget.theme != theme;
}

extension ThemeContext on BuildContext {
  AppTheme get theme => ThemeScope.of(this);

  /// Text styles in the theme's text colour.
  AppText get text => AppText(theme.text);
}
