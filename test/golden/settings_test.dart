import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, TextField;
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/ui/icons.dart';
import 'package:fweek/ui/widgets/controls.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  /// The heading of the section on show (beside the list of sections, or
  /// over a section in a narrow card).
  Finder heading(String title) => find.byWidgetPredicate(
      (w) => w is Text && w.data == title && w.style?.fontSize == 24);

  /// The card's own close button.
  Finder closeButton() => find.ancestor(
      of: find.byIcon(AppIcons.x), matching: find.byType(AppButton));

  group('on a desktop', () {
    desktopTest('the sections are listed beside the one on show', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await openSettings(tester);
      // They open on the first section.
      expect(heading('General'), findsOneWidget);
      expect(find.text('Week starts on'), findsOneWidget);
      expect(find.text('Sort completed tasks down'), findsNothing);
      final card = tester.getRect(find.bySemanticsLabel('General settings'));

      for (final (section, shows, golden) in [
        ('Appearance', 'Semi-dark', 'settings_appearance'),
        ('Tasks', 'Sort completed tasks down', 'settings_tasks'),
        ('Calendars', 'Add calendar', 'settings_calendars'),
        ('Sync', 'Connect', null),
        ('Data', 'Restore backup', 'settings_data'),
        ('Advanced', 'Show frame timing', null),
      ]) {
        await showSettings(tester, section);
        expect(heading(section), findsOneWidget);
        expect(find.text(shows), findsOneWidget);
        expect(find.text('Week starts on'), findsNothing);
        if (golden != null) {
          await expectLater(
              find.byType(MaterialApp), matchesGoldenFile('goldens/$golden.png'));
        }
      }
      // The list of sections stays where it is whatever is on show.
      expect(tester.getRect(find.bySemanticsLabel('General settings')), card);
    });

    desktopTest('a dark theme sets the list of sections off from the one on show',
        (tester) async {
      final store = seededStore()..setSetting(Settings.theme, 'slate');
      await pumpApp(tester, store);
      await openSettings(tester, 'General');
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/settings_dark.png'));
    });

    desktopTest('a line parts a section from its heading once it is scrolled',
        (tester) async {
      await pumpApp(tester, seededStore());
      await openSettings(tester, 'Calendars');
      Color line() => (tester
              .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
              .firstWhere((w) => w.constraints?.maxHeight == 1)
              .decoration! as BoxDecoration)
          .color!;
      expect(line().a, 0);
      await tester.ensureVisible(find.text('Read a contacts file…'));
      await tester.pumpAndSettle();
      expect(line().a, greaterThan(0));
      // Another section starts at its top, without the line.
      await showSettings(tester, 'Data');
      expect(line().a, 0);
      await showSettings(tester, 'Calendars');
      expect(line().a, greaterThan(0));
    });

    desktopTest('what was typed into a section is still there on coming back',
        (tester) async {
      await pumpApp(tester, seededStore());
      await openSettings(tester, 'Sync');
      final server = find.descendant(
          of: find.ancestor(of: find.text('Server'), matching: find.byType(Row)).first,
          matching: find.byType(TextField));
      await tester.enterText(server, 'files.example.org');
      await showSettings(tester, 'General');
      expect(find.text('files.example.org'), findsNothing);
      await showSettings(tester, 'Sync');
      expect(find.text('files.example.org'), findsOneWidget);
    });

    desktopTest('the settings open again where they were left', (tester) async {
      await pumpApp(tester, seededStore());
      await openSettings(tester, 'Tasks');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sort completed tasks down'), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(heading('Tasks'), findsOneWidget);
      expect(find.text('Sort completed tasks down'), findsOneWidget);
    });

    desktopTest('choices sit beside their names, and a switch changes its setting',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await openSettings(tester);
      expect(tester.getCenter(find.text('Week starts on')).dy,
          closeTo(tester.getCenter(find.text('Monday')).dy, 1));
      expect(tester.getCenter(find.text('Week starts on')).dx,
          lessThan(tester.getCenter(find.text('Monday')).dx));

      await showSettings(tester, 'Tasks');
      expect(store.setting<bool>(Settings.hideDone), isFalse);
      await tester.tap(find.descendant(
          of: find.ancestor(
              of: find.text('Hide completed tasks'), matching: find.byType(Row)).first,
          matching: find.byType(AppSwitch)));
      await tester.pumpAndSettle();
      expect(store.setting<bool>(Settings.hideDone), isTrue);
    });

    desktopTest('a short window makes the card shorter, and a section scrolls in it',
        (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(1100, 560));
      await openSettings(tester, 'Calendars');
      final close = tester.getRect(closeButton());
      expect(close.top, greaterThan(0));
      await tester.ensureVisible(find.text('Read a contacts file…'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Read a contacts file…')).bottom, lessThan(560));
      // The heading and the close button have stayed put.
      expect(tester.getRect(closeButton()), close);
    });

    desktopTest('in a narrow window the sections are a list that opens one of them',
        (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(700, 900));
      await openSettings(tester);
      expect(find.text('Week starts on'), findsNothing);
      expect(find.text('Week, time format, new items, places'), findsOneWidget);
      await showSettings(tester, 'General');
      expect(find.text('Week starts on'), findsOneWidget);
      // Too narrow for choices beside their names: they are under them.
      expect(tester.getCenter(find.text('Monday')).dy,
          greaterThan(tester.getRect(find.text('Week starts on')).bottom));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/settings_narrow.png'));
      // Escape leads back to the list, and from there out.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Week starts on'), findsNothing);
      expect(find.text('Week, time format, new items, places'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Week, time format, new items, places'), findsNothing);
    });
  });

  group('on a phone', () {
    phoneTest('the settings are a list of sections, each saying where it stands',
        (tester) async {
      final store = seededStore()..setSetting(Settings.theme, 'paper');
      await pumpApp(tester, store, size: const Size(411, 914));
      await openSettings(tester);
      expect(find.text('Theme: Paper'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Sort completed tasks down'), findsNothing);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/phone_settings.png'));

      await showSettings(tester, 'Tasks');
      expect(heading('Tasks'), findsOneWidget);
      expect(find.text('Sort completed tasks down'), findsOneWidget);
      expect(find.text('Not connected'), findsNothing);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/phone_settings_tasks.png'));

      // The arrow leads back to the list.
      await tester.tap(find.bySemanticsLabel('All settings'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Sort completed tasks down'), findsNothing);
    });

    phoneTest('the back button leaves a section for the list, and the list for the week',
        (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(411, 914));
      await openSettings(tester, 'Appearance');
      expect(find.text('Semi-dark'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Semi-dark'), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsNothing);
    });

    phoneTest('a tap beside the card closes the settings from a section too',
        (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(411, 914));
      await openSettings(tester, 'Data');
      expect(find.text('Restore backup'), findsOneWidget);
      await tester.tapAt(const Offset(6, 400));
      await tester.pumpAndSettle();
      expect(find.text('Restore backup'), findsNothing);
      expect(find.text('Not connected'), findsNothing);
    });

    phoneTest('the card keeps its place from the list to a section', (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(411, 914));
      await openSettings(tester);
      final close = tester.getRect(closeButton());
      await showSettings(tester, 'Advanced');
      expect(tester.getRect(closeButton()), close);
    });
  });
}
