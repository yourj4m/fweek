import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';

import 'harness.dart';

/// Events of a subscribed calendar in the planner.
void main() {
  setUpAll(loadFonts);

  final monday = referenceToday.startOfWeek();
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  desktopTest('events sit above the tasks of their day', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    expect(find.text('9:00 Group seminar'), findsOneWidget);
    expect(find.text('14:30 Thesis committee'), findsOneWidget);
    // An event over two whole days shows on both, without a time.
    expect(find.text('Conference'), findsNWidgets(2));
    // Above the day's first task.
    expect(tester.getTopLeft(find.text('10:00 Team meeting')).dy,
        lessThan(tester.getTopLeft(find.textContaining('Buy oat milk')).dy));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_1440_events.png'));
  });

  desktopTest('an event opens to its details and cannot be completed', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    await tester.tap(find.text('10:00 Team meeting'));
    await tester.pumpAndSettle();
    expect(find.text('Mon, 9 Nov 2026 · 10:00 – 11:00'), findsOneWidget);
    expect(find.text('Room 204'), findsOneWidget);
    expect(find.text('Bring the draft.'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    // It is not a task: no task card opened, nothing was stored.
    expect(find.bySemanticsLabel('Add subtask'), findsNothing);
    expect(titles(store.tasksOn(monday)), hasLength(3));
  });

  desktopTest('a task dropped on a day with events lands among its tasks', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    final from = tester.getCenter(find.text('Tap and edit'));
    // Onto Monday's second task row; the event row above must not shift it.
    final target = tester.getCenter(find.text('Second task')) - const Offset(0, 14);
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(-20, 10));
    await tester.pump();
    await mouse.moveTo(target + const Offset(60, 0));
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(monday)).indexOf('Tap and edit'), 1);
  });

  desktopTest('the month shows events before tasks', (tester) async {
    final store = seededStore()..setSetting(Settings.view, 'month');
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    // The weekly seminar: the four Wednesdays from its start on 4 November,
    // and 2 December in the month's last row.
    expect(find.text('9:00 Group seminar'), findsNWidgets(5));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/month_1440_events.png'));
  });

  desktopTest('the settings list the calendar and what was read', (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Add calendar'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Work'), findsOneWidget);
    expect(find.textContaining('4 events'), findsOneWidget);
    // Removing it takes its events out of the week.
    await tester.tap(find.bySemanticsLabel('Remove Work'));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions, isEmpty);
    expect(find.textContaining('4 events'), findsNothing);
  });

  phoneTest('on a phone events are rows of their day, sized like tasks', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store,
        size: const Size(411, 914), calendars: await calendarWith(tester, store));
    expect(find.text('14:30 Thesis committee'), findsOneWidget);
    expect(find.text('Conference'), findsWidgets);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_week_events.png'));
  });
}
