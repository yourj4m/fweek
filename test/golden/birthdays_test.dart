import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:fweek/app_state.dart';
import 'package:fweek/calendar/calendar_service.dart';
import 'package:fweek/ui/planner_page.dart';

import 'harness.dart';

/// Contacts' birthdays: a contacts file read on this device becomes a
/// calendar of its own.
void main() {
  late Directory folder;
  setUpAll(loadFonts);
  setUp(() => folder = Directory.systemTemp.createTempSync('fweek-contacts-'));
  tearDown(() => folder.deleteSync(recursive: true));

  // The pictured week is 9 to 15 November 2026.
  String contacts() => (File('${folder.path}/contacts.vcf')
        ..writeAsStringSync([
          'BEGIN:VCARD', 'VERSION:3.0', 'FN:Ada Lovelace', 'BDAY:19901113', 'END:VCARD',
          'BEGIN:VCARD', 'VERSION:3.0', 'FN:Grace Hopper', 'BDAY:--1114',
          'item1.X-ABDATE:20100613', r'item1.X-ABLabel:_$!<Anniversary>!$_', 'END:VCARD',
          'BEGIN:VCARD', 'VERSION:3.0', 'FN:Nobody Dated', 'END:VCARD',
          '',
        ].join('\r\n')))
      .path;

  /// What the window's own code sends when files are dropped on it.
  Future<void> drop(WidgetTester tester, List<String> paths) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'fweek/drop',
      const StandardMethodCodec().encodeMethodCall(MethodCall('files', paths)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  desktopTest('a contacts file dropped on the window becomes the Birthdays calendar',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final CalendarService calendars =
        tester.element(find.byType(PlannerPage)).readCalendars;
    expect(calendars.subscriptions, isEmpty);

    final path = contacts();
    await drop(tester, [path]);
    expect(find.text('Birthdays: 3 dates from contacts.vcf'), findsOneWidget);
    expect(calendars.birthdays!.contacts!.path, path);
    // This week's two are in the week, as events.
    expect(find.text("Ada Lovelace's birthday"), findsOneWidget);
    expect(find.text("Grace Hopper's birthday"), findsOneWidget);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/week_birthdays.png'));

    // One opens like any event; the year of birth is its note.
    await tester.tap(find.text("Ada Lovelace's birthday"));
    await tester.pumpAndSettle();
    expect(find.text('Born 13 November 1990'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Birthdays')), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // It is a calendar among the calendars: hidden and shown from the menu.
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calendars'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Birthdays'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text("Ada Lovelace's birthday"), findsNothing);
    calendars.setHidden(calendars.birthdays!.id, false);
    await tester.pumpAndSettle();

    // The same file dropped again fills the one calendar anew.
    await drop(tester, [path]);
    expect(calendars.subscriptions, hasLength(1));
    expect(find.text("Ada Lovelace's birthday"), findsOneWidget);

    // A file that is no contacts file says so and changes nothing.
    final other = File('${folder.path}/table.csv')..writeAsStringSync('a,b\n1,2\n');
    await drop(tester, [other.path]);
    expect(find.textContaining('This is not a contacts file'), findsOneWidget);
    expect(calendars.birthdays!.events, 3);
  });

  desktopTest('the settings explain where birthdays come from and list the calendar',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    await openSettings(tester, 'Calendars');
    expect(find.text('Read a contacts file…'), findsOneWidget);
    expect(find.textContaining('Google Calendar gives out no address for its Birthdays'),
        findsOneWidget);

    final calendars = tester.element(find.byType(PlannerPage)).readCalendars;
    await calendars.setBirthdays(
        text: File(contacts()).readAsStringSync(), file: 'contacts.vcf');
    await tester.pumpAndSettle();
    expect(find.text('Birthdays'), findsNWidgets(2)); // the calendar and the heading
    expect(find.textContaining('3 dates from contacts.vcf'), findsOneWidget);
    expect(find.text('Read a contacts file again…'), findsOneWidget);
    await tester.ensureVisible(find.text('Read a contacts file again…'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/settings_birthdays.png'));

    // Removed like any calendar.
    await tester.ensureVisible(find.bySemanticsLabel('Remove Birthdays'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Remove Birthdays'));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions, isEmpty);
    expect(find.text('Read a contacts file…'), findsOneWidget);
  });
}
