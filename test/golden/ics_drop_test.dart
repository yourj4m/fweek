import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:fweek/app_state.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/ui/planner_page.dart';

import 'harness.dart';

/// A calendar file dropped on the window: its events are added, and a card
/// says which, with a way to each of them.
void main() {
  late Directory folder;
  setUpAll(loadFonts);
  setUp(() => folder = Directory.systemTemp.createTempSync('fweek-drop'));
  tearDown(() => folder.deleteSync(recursive: true));

  String write(String name, List<List<String>> events) {
    final file = File('${folder.path}/$name')
      ..writeAsStringSync([
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        for (final event in events) ...['BEGIN:VEVENT', ...event, 'END:VEVENT'],
        'END:VCALENDAR',
        '',
      ].join('\r\n'));
    return file.path;
  }

  // Twelve and two o'clock on the 17th and 19th, whatever the machine's zone.
  String at(int day, int hour) {
    final utc = DateTime(2026, 11, day, hour).toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}00Z';
  }

  List<String> seminar() => [
        'UID:seminar@example.org',
        'SUMMARY:Séminaire ISTerre',
        'LOCATION:Amphithéâtre Killian',
        'DESCRIPTION:Coda Wave Interferometry',
        'DTSTART:${at(17, 10)}',
        'DTEND:${at(17, 11)}',
      ];
  List<String> defence() => [
        'UID:defence@example.org',
        'SUMMARY:Thesis defence',
        'DTSTART:${at(19, 14)}',
        'DTEND:${at(19, 16)}',
      ];

  Task named(PlannerStore store, String title) =>
      store.allTasks.firstWhere((t) => t.title == title);

  /// What the window's own code sends when files are dropped on it.
  Future<void> drop(WidgetTester tester, List<String> paths) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'fweek/drop',
      const StandardMethodCodec().encodeMethodCall(MethodCall('files', paths)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  desktopTest('adds its events and says which; each leads to its day and opens', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final app = tester.element(find.byType(PlannerPage)).readApp;
    await drop(tester, [write('invite.ics', [seminar(), defence()])]);

    expect(find.text('From invite.ics'), findsOneWidget);
    expect(find.text('2 events added'), findsOneWidget);
    expect(find.text('Séminaire ISTerre'), findsOneWidget);
    expect(find.text('Tue, 17 Nov 2026 · 10:00 – 11:00'), findsOneWidget);
    expect(find.text('Thu, 19 Nov 2026 · 14:00 – 16:00'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ics_recap.png'));
    // They are in the planner already, as events.
    final seminarItem = named(store, 'Séminaire ISTerre');
    expect(seminarItem.date, Day(2026, 11, 17));
    expect(seminarItem.checkable, isFalse);

    // To one of them: its week, and its card.
    await tester.tap(find.text('Thesis defence'));
    await tester.pumpAndSettle();
    expect(find.text('From invite.ics'), findsNothing);
    expect(app.weekStart, Day(2026, 11, 16));
    expect(find.bySemanticsLabel('Add subtask'), findsOneWidget, reason: 'its card is open');
    expect(find.text('Thu, 19 Nov 2026'), findsOneWidget);
    expect(find.text('– 16:00'), findsOneWidget);
  });

  desktopTest('Undo takes them out again; the same file later brings them up to date',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final path = write('invite.ics', [seminar()]);
    await drop(tester, [path]);
    expect(find.text('one event added'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.allTasks.where((t) => t.title == 'Séminaire ISTerre'), isEmpty);
    expect(find.text('one event taken out again'), findsOneWidget);

    await drop(tester, [path]);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await drop(tester, [path]);
    expect(find.text('1 already there, brought up to date'), findsOneWidget);
    expect(find.text('Undo'), findsNothing, reason: 'nothing was added this time');
    expect(store.allTasks.where((t) => t.title == 'Séminaire ISTerre'), hasLength(1));
  });

  desktopTest('several files at once, and one that is no calendar', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final letter = File('${folder.path}/letter.ics')..writeAsStringSync('Dear all, …');
    await drop(tester, [
      write('a.ics', [seminar()]),
      write('b.ics', [defence()]),
      letter.path,
    ]);
    expect(find.text('From a.ics, b.ics'), findsOneWidget);
    expect(find.text('2 events added · letter.ics: not a calendar file'), findsOneWidget);
  });

  desktopTest('other files are not taken for calendars', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final before = store.allTasks.length;
    final photo = File('${folder.path}/photo.jpg')..writeAsBytesSync([0xff, 0xd8, 0xff]);
    await drop(tester, [photo.path, '${folder.path}/gone.ics']);
    expect(
        find.text('Drop a calendar file (.ics) to add its events, or a contacts file for birthdays'),
        findsOneWidget);
    expect(store.allTasks.length, before);
    await tester.pump(const Duration(seconds: 7));
  });
}
