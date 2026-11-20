import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, TextField;
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/ui/event_rows.dart';
import 'package:weektodo/ui/task_list.dart';

import 'harness.dart';

/// Events of a subscribed calendar in the planner: shown with the tasks,
/// and handled like them.
void main() {
  setUpAll(loadFonts);

  final monday = referenceToday.startOfWeek();
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  /// The one change the user made to an event so far.
  EventOverride changeIn(PlannerStore store) => store.eventOverrides.single;

  desktopTest('events sit above the tasks of their day', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    expect(find.text('9:00 Group seminar'), findsOneWidget);
    expect(find.text('14:30 Thesis committee'), findsOneWidget);
    // Above the day's first task.
    expect(tester.getTopLeft(find.text('10:00 Team meeting')).dy,
        lessThan(tester.getTopLeft(find.textContaining('Buy oat milk')).dy));
    // An event is a row like a task, but with nothing to tick: a task has
    // the circle, an event does not.
    final row = find.ancestor(
        of: find.text('10:00 Team meeting'), matching: find.byType(TaskRow));
    expect(find.descendant(of: row, matching: find.byType(CheckToggle)), findsNothing);
    final task = find.ancestor(
        of: find.textContaining('Buy oat milk'), matching: find.byType(TaskRow));
    expect(find.descendant(of: task, matching: find.byType(CheckToggle)), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_1440_events.png'));
  });

  desktopTest('an event is dragged between tasks, under them, and to a place on another day',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    List<String> shown(Day day) => [for (final t in store.itemsOn(day)) t.title.split(' and ').first];
    expect(shown(monday), ['Team meeting', 'Buy oat milk', 'Second task', 'Call dentist']);

    // Picks [what] up and lets it go on the line with number [index] of
    // [day]: the gap that opens for it follows the pointer line by line.
    Future<void> drag(String what, Day day, int index) async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.text(what)), kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(8, 10));
      await tester.pumpAndSettle();
      final list = tester.getRect(
          find.byWidgetPredicate((w) => w is TaskListBody && w.slot == DaySlot(day)));
      await gesture.moveTo(list.topLeft + Offset(60, (index + 0.5) * 42));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // Between "Second task" and "Call dentist".
    await drag('10:00 Team meeting', monday, 2);
    expect(shown(monday), ['Buy oat milk', 'Second task', 'Team meeting', 'Call dentist']);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/week_1440_event_placed.png'));

    // Below the last task.
    await drag('10:00 Team meeting', monday, 3);
    expect(shown(monday), ['Buy oat milk', 'Second task', 'Call dentist', 'Team meeting']);

    // A task goes above an event nobody placed (Friday's committee).
    await drag('Water the plants', referenceToday, 0);
    expect(shown(referenceToday), ['Water the plants', 'Thesis committee']);

    // To another day, between that day's tasks.
    await drag('10:00 Team meeting', monday.addDays(5), 1);
    final saturday = monday.addDays(5);
    expect(shown(saturday), ['Mark me complete', 'Team meeting', 'Tap', 'Drag to the next day']);
    expect(store.itemsOn(monday).any((t) => t.title == 'Team meeting'), isFalse);
  });

  desktopTest('an event turned into a task gets the circle, and the change is the user\'s',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    final row = find.ancestor(
        of: find.text('10:00 Team meeting'), matching: find.byType(TaskRow));
    await rightClick(tester, find.text('10:00 Team meeting'));
    expect(find.text('Mark as done'), findsNothing);
    await tester.tap(find.text('Turn into a task'));
    await tester.pumpAndSettle();
    expect(changeIn(store).kind, ItemKind.task);
    expect(find.descendant(of: row, matching: find.byType(CheckToggle)), findsOneWidget);

    await rightClick(tester, find.text('10:00 Team meeting'));
    await tester.tap(find.text('Mark as done'));
    await tester.pumpAndSettle();
    expect(changeIn(store).done, isTrue);

    await rightClick(tester, find.text('10:00 Team meeting'));
    await tester.tap(find.text('Turn into an event'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.byType(CheckToggle)), findsNothing);
  });

  desktopTest('an event that is over is faint, and one of today turns faint when it ends',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    Color inkOf(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    // Monday's meeting lies behind (it is Friday), Friday's committee ahead
    // (14:30, and it is 9:36).
    expect(inkOf('10:00 Team meeting').a, lessThan(0.5));
    expect(inkOf('14:30 Thesis committee').a, 1);
    // Not struck through: it is past, not done.
    expect(tester.widget<Text>(find.text('10:00 Team meeting')).style!.decoration,
        TextDecoration.none);
  });

  desktopTest('an event over several days is one bar under the headings, across its days',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    // Friday and Saturday: one bar, not a row on each day.
    expect(find.text('Conference'), findsOneWidget);
    final bar = tester.getRect(
        find.ancestor(of: find.text('Conference'), matching: find.byType(SpanBar)));
    final friday = tester.getRect(find.text('13 Nov'));
    final saturday = tester.getRect(find.text('Sat'));
    expect(bar.left, closeTo(friday.left, 1));
    expect(bar.right, closeTo(saturday.right, 1));
    // Directly under the headings and above every day's rows.
    expect(bar.top, greaterThan(friday.bottom));
    expect(bar.bottom, lessThan(tester.getRect(find.text('14:30 Thesis committee')).top));
    expect(bar.bottom, lessThan(tester.getRect(find.textContaining('Buy oat milk')).top));
  });

  desktopTest('an event opens as a card: day, time from start to end and calendar on top, '
      'then the title, the calendar\'s note, the place', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    await tester.tap(find.text('10:00 Team meeting'));
    await tester.pumpAndSettle();
    expect(store.eventOverrides, isEmpty, reason: 'looking changes nothing');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/event_card.png'));
    final card = find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == 'Team meeting'); // the title
    // Along the top, in this order: the day, the start, the end, the calendar.
    final day = tester.getRect(find.text('Mon, 9 Nov 2026'));
    final start = tester.getRect(find.text('10:00'));
    final end = tester.getRect(find.text('– 11:00'));
    final calendar = tester.getRect(find.text('Work'));
    expect(day.right, lessThan(start.left));
    expect(start.right, lessThan(end.left));
    // The calendar follows where there is room beside them, or begins the
    // next line of the top (this card is a narrow one).
    expect(end.right < calendar.left || calendar.top >= end.bottom - 12, isTrue);
    for (final part in [day, start, end, calendar]) {
      expect(part.bottom, lessThan(tester.getRect(card).top));
    }
    // The time is said once.
    expect(find.textContaining('10:00 – 11:00'), findsNothing);
    // Under the title what the calendar says, as the note; under it the
    // place (which shows on the row behind the card too); no second,
    // empty field for notes.
    final note = find.byWidgetPredicate((w) =>
        w is EditableText && w.controller.text.startsWith('Bring the draft.'));
    expect(note, findsOneWidget);
    expect(find.text('Add notes of your own…'), findsNothing);
    expect(find.text('Room 204'), findsNWidgets(2));
    final place = tester.getRect(find.bySemanticsLabel('Open Room 204 in the map app'));
    expect(tester.getRect(card).bottom, lessThan(tester.getRect(note).top));
    expect(tester.getRect(note).bottom, lessThan(place.top));
    expect(place.bottom, lessThan(tester.getRect(find.bySemanticsLabel('Add subtask')).top));
    // Nothing to tick.
    expect(find.bySemanticsLabel('Mark as done'), findsNothing);

    // The note is edited where it stands, and the edit is the user's.
    await tester.enterText(note, 'Bring the draft.\nAsk about the budget');
    await tester.pump(const Duration(milliseconds: 600));
    expect(changeIn(store).note, 'Bring the draft.\nAsk about the budget');
    expect(changeIn(store).title, isNull, reason: 'the title still follows the calendar');

    // Another end.
    await tester.tap(find.text('– 11:00'));
    await tester.pumpAndSettle();
    expect(find.text('No end'), findsOneWidget);
    await tester.tap(find.text('11:30'));
    await tester.pumpAndSettle();
    expect(changeIn(store).end, 11 * 60 + 30);
    expect(find.text('– 11:30'), findsOneWidget);

    // Everything changed here can be dropped again.
    await tester.tap(find.text('Edited · Reset'));
    await tester.pumpAndSettle();
    expect(changeIn(store).edits, isFalse);
    expect(find.text('Edited · Reset'), findsNothing);
    // It never became a task.
    expect(titles(store.tasksOn(monday)), hasLength(3));
  });

  desktopTest('right-click on an event: recolour, hide, undo', (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);

    await rightClick(tester, find.text('10:00 Team meeting'));
    expect(find.text('Hide Work'), findsOneWidget);
    await tester.tap(find.text('Colour'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Green'));
    await tester.pumpAndSettle();
    expect(changeIn(store).color, 'green');

    await rightClick(tester, find.text('10:00 Team meeting'));
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(find.text('10:00 Team meeting'), findsNothing);
    expect(changeIn(store).hidden, isTrue);
    expect(find.text('Event hidden'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    expect(changeIn(store).hidden, isFalse);
    expect(changeIn(store).color, 'green', reason: 'the colour stays');
  });

  desktopTest('hidden events can be shown again from the menu', (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);
    final meeting = calendars.eventsBetween(monday, monday).on(monday).single;
    store.setEventHidden(meeting.id, true);
    await tester.pumpAndSettle();
    expect(find.text('10:00 Team meeting'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show hidden events'));
    await tester.pumpAndSettle();
    expect(find.text('10:00 Team meeting'), findsOneWidget);

    await rightClick(tester, find.text('10:00 Team meeting'));
    await tester.tap(find.text('Show again'));
    await tester.pumpAndSettle();
    expect(changeIn(store).hidden, isFalse);
  });

  desktopTest('dragging an event moves it to another day, for this planner only',
      (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);
    final from = tester.getCenter(find.text('10:00 Team meeting'));
    final target = tester.getCenter(find.text('12 Nov')) + const Offset(0, 60);
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(20, 10));
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pumpAndSettle();

    final thursday = monday.addDays(3);
    expect(changeIn(store).date, thursday);
    expect(titles(calendars.eventsBetween(monday, monday).on(monday)), isEmpty);
    expect(titles(calendars.eventsBetween(thursday, thursday).on(thursday)), ['Team meeting']);
    // Still an event of its calendar, at its own time.
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    expect(tester.getCenter(find.text('10:00 Team meeting')).dx,
        closeTo(tester.getCenter(find.text('12 Nov')).dx, 120));
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

  desktopTest('an event dropped on a list becomes a task there', (tester) async {
    final store = seededStore();
    // The lists beside the week.
    store.setSetting(Settings.listPanel, true);
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);
    final from = tester.getCenter(find.text('10:00 Team meeting'));
    final target = tester.getCenter(find.text('Keep tasks here without a date')) +
        const Offset(0, 30);
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(20, 10));
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pumpAndSettle();

    final list = store.lists.first.id;
    final made = store.tasksIn(list).firstWhere((t) => t.title == 'Team meeting');
    expect(made.time, 10 * 60);
    expect(made.location, 'Room 204');
    expect(made.note, 'Bring the draft.');
    expect(changeIn(store).hidden, isTrue);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(titles(store.tasksIn(list)), isNot(contains('Team meeting')));
    expect(changeIn(store).hidden, isFalse);
  });

  desktopTest('the month shows events before tasks', (tester) async {
    final store = seededStore()..setSetting(Settings.view, 'month');
    await pumpApp(tester, store, calendars: await calendarWith(tester, store));
    expect(find.text('10:00 Team meeting'), findsOneWidget);
    // The weekly seminar: the four Wednesdays from its start on 4 November,
    // and 2 December in the month's last row.
    expect(find.text('9:00 Group seminar'), findsNWidgets(5));
    // The two-day conference: a bar on each of its days, titled once.
    expect(find.byType(SpanBar), findsNWidgets(2));
    expect(find.text('Conference'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/month_1440_events.png'));
  });

  desktopTest('the menu shows and hides a whole calendar with one click', (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    await pumpApp(tester, store, calendars: calendars);
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calendars'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/menu_calendars.png'));

    await tester.tap(find.bySemanticsLabel(RegExp('^Hide Work')));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions.single.hidden, isTrue);
    expect(store.calendarRows.single.hidden, isTrue);
    expect(find.text('10:00 Team meeting'), findsNothing);
    expect(find.text('Conference'), findsNothing);

    await tester.tap(find.bySemanticsLabel(RegExp('^Show Work')));
    await tester.pumpAndSettle();
    expect(find.text('10:00 Team meeting'), findsOneWidget);
  });

  desktopTest('the settings list the calendar: hide, recolour, rename, remove', (tester) async {
    final store = seededStore();
    final calendars = await calendarWith(tester, store);
    // Tall enough for the whole settings card.
    await pumpApp(tester, store, calendars: calendars, size: const Size(1440, 2600));
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.textContaining('4 events'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Hide Work'));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions.single.hidden, isTrue);
    expect(find.textContaining('hidden · 4 events'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Show Work'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Change the colour of Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Orange'));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions.single.color, 'orange');
    expect(store.calendarRows.single.color, 'orange');

    await tester.tap(find.bySemanticsLabel(RegExp('^Rename Work')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name').first, 'Lab');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(calendars.subscriptions.single.name, 'Lab');
    expect(store.calendarRows.single.name, 'Lab');

    // Removing it takes its events out of the week.
    await tester.tap(find.bySemanticsLabel('Remove Lab'));
    await tester.pumpAndSettle();
    expect(calendars.subscriptions, isEmpty);
    expect(find.textContaining('4 events'), findsNothing);
  });

  phoneTest('on a phone events are rows of their day; one over several days is a bar on each',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store,
        size: const Size(411, 914), calendars: await calendarWith(tester, store));
    expect(find.text('14:30 Thesis committee'), findsOneWidget);
    // Friday heads the page: the conference's first day, of two.
    expect(find.text('Conference'), findsWidgets);
    expect(find.text('1/2'), findsOneWidget);
    final bar = tester.getRect(
        find.ancestor(of: find.text('1/2'), matching: find.byType(SpanBar)));
    expect(bar.top, greaterThan(tester.getRect(find.text('13 Nov')).bottom));
    expect(bar.bottom, lessThan(tester.getRect(find.text('14:30 Thesis committee')).top));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_week_events.png'));
  });

  phoneTest('a long press on an event: letting go opens its menu', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store,
        size: const Size(411, 914), calendars: await calendarWith(tester, store));
    final finger =
        await tester.startGesture(tester.getCenter(find.text('14:30 Thesis committee')));
    await tester.pump(const Duration(milliseconds: 700));
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('Turn into a task'), findsOneWidget);
    expect(find.text('Mark as done'), findsNothing);
    expect(find.text('Hide Work'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_event_menu.png'));
  });
}
