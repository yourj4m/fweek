import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/theme/app_theme.dart';

/// Readability of every theme and every highlight colour, by the measures
/// of the Web Content Accessibility Guidelines: text needs a contrast of
/// 4.5 to 1 against what it stands on, large text and the parts that make
/// up a control 3 to 1.

/// [top] as it looks on [under], for colours that are partly transparent.
Color over(Color top, Color under) => Color.alphaBlend(top, under);

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

double distance(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  for (final theme in AppTheme.all) {
    group('theme ${theme.name}', () {
      final page = theme.background;
      final card = theme.dialog;
      final menu = over(theme.popover, page);

      test('text reads on the page, on cards and in menus', () {
        for (final surface in [page, card, menu]) {
          expect(contrast(theme.text, surface), greaterThanOrEqualTo(7),
              reason: 'text on $surface');
          // The muted text used for details and explanations.
          expect(contrast(over(theme.ink(60), surface), surface), greaterThanOrEqualTo(4.5),
              reason: 'muted text on $surface');
        }
      });

      test('the accent stands out: today\'s heading, the progress bar', () {
        // Today's date is set large and bold in the accent colour.
        expect(contrast(theme.accent, page), greaterThanOrEqualTo(3));
        expect(contrast(theme.onAccent, theme.accent), greaterThanOrEqualTo(4.5));
      });

      test('buttons show their icons', () {
        expect(contrast(theme.navButtonIcon, theme.navButton), greaterThanOrEqualTo(4.5));
        expect(contrast(const Color(0xFF000000), theme.menuButton), greaterThanOrEqualTo(4.5));
        expect(contrast(theme.menuButton, page), greaterThanOrEqualTo(1.5));
      });

      test('ruled lines are faint but there', () {
        final rule = over(theme.rule, page);
        expect(contrast(rule, page), greaterThan(1.1));
        expect(contrast(rule, page), lessThan(2));
      });

      test('every highlight colour is told from the page', () {
        for (final color in TaskColor.palette) {
          final fill = color.key == 'black' ? theme.text : color.fill;
          expect(contrast(fill, page), greaterThan(1.15),
              reason: '${color.name} pill on the ${theme.name} page');
        }
      });
    });
  }

  group('highlight colours', () {
    test('carry their text', () {
      for (final color in TaskColor.palette) {
        expect(contrast(color.onFill, color.fill), greaterThanOrEqualTo(4.5),
            reason: color.name);
      }
    });

    test('are told from one another', () {
      for (final a in TaskColor.palette) {
        for (final b in TaskColor.palette) {
          if (a.key.compareTo(b.key) >= 0) continue;
          expect(distance(a.fill, b.fill), greaterThan(40), reason: '${a.name} / ${b.name}');
        }
      }
    });

    test('none is a neon: no colour at full strength beside a weak one', () {
      // What made the old lilac and green glare: one channel at its maximum
      // with another far below it.
      for (final color in TaskColor.palette) {
        if (color.key == 'black') continue;
        final c = color.fill;
        final channels = [c.r, c.g, c.b];
        final high = channels.reduce(math.max), low = channels.reduce(math.min);
        final saturation = high == 0 ? 0.0 : (high - low) / high;
        expect(saturation, lessThan(0.72), reason: '${color.name} is too saturated');
      }
    });

    test('keep the keys that stored tasks refer to', () {
      expect([for (final c in TaskColor.palette) c.key], [
        'red', 'yellow', 'blue', 'green', 'orange', 'purple', 'lilac', 'cyan', //
        'lavender', 'grey', 'black',
      ]);
    });
  });

  test('themes are grouped: light, dark, semi-dark, and each id is unique', () {
    expect({for (final t in AppTheme.all) t.id}, hasLength(AppTheme.all.length));
    final semiDark = [
      for (final t in AppTheme.all)
        if (t.group == ThemeGroup.semiDark) t,
    ];
    expect([for (final t in semiDark) t.name], ['Wine', 'Plum', 'Forest', 'Midnight', 'Cocoa']);
    for (final theme in semiDark) {
      expect(theme.isDark, isTrue);
      // Deep, not black: the page has a colour of its own.
      expect(theme.background.computeLuminance(), inInclusiveRange(0.006, 0.03));
    }
    expect(AppTheme.resolve('wine', Brightness.light).id, 'wine');
    expect(AppTheme.resolve('gone', Brightness.light).id, 'light');
  });
}
