import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, TextField;
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/data/recurrence.dart';
import 'package:fweek/ui/widgets/controls.dart';

import 'harness.dart';

/// The reference week with events of the planner's own that run over
/// several days: a trip into the weekend and beyond, a short course early
/// in the week, and one with times.
PlannerStore spansStore() {
  final store = seededStore();
  final monday = store.today.startOfWeek();
  store.addItem(day: monday, endDay: monday.addDays(2), title: 'Python course');
  store.addItem(day: monday.addDays(2), endDay: monday.addDays(4), title: 'Visit from Ana');
  store.addItem(
    day: monday.addDays(3),
    endDay: monday.addDays(8),
    title: 'Trip to Lyon',
    color: 'green',
  );
  store.addItem(
    day: monday.addDays(1),
    endDay: monday.addDays(2),
    title: 'Night shift',
    time: 22 * 60,
    end: 6 * 60,
  );
  return store;
}

void main() {
  setUpAll(loadFonts);

  /// The form's title.
  final titleField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Event title');

  group('pictures', () {
    desktopTest('the form for a new event', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.tap(find.bySemanticsLabel('New event (N)'));
      await tester.pumpAndSettle();
      await tester.enterText(titleField, 'Dinner with Ana');
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/event_form.png'));
    });

    desktopTest('the form with a time, over several days', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      await tester.enterText(titleField, 'Conference');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('All day'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(RegExp('^End day')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('17').last);
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/event_form_timed.png'));
    });

    phoneTest('the form on a phone', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await tester.tap(find.bySemanticsLabel('New event'));
      await tester.pumpAndSettle();
      await tester.enterText(titleField, 'Dinner with Ana');
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/event_form_phone.png'));
    });

    desktopTest('events of the planner over several days lie in the band', (tester) async {
      final store = spansStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/week_own_spans.png'));
    });

    desktopTest('and in the month', (tester) async {
      final store = spansStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/month_own_spans.png'));
    });

    phoneTest('on a phone each day says which day of the event it is', (tester) async {
      final store = spansStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/phone_own_spans.png'));
    });
  });

  final today = referenceToday; // Friday 13 November 2026

  Task named(PlannerStore store, String title) =>
      store.allTasks.singleWhere((t) => t.title == title);
  bool has(PlannerStore store, String title) => store.allTasks.any((t) => t.title == title);

  Finder field(String hint) =>
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

  /// The form is open.
  final form = find.text('Add event');

  Future<void> open(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(form, findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  group('a new event', () {
    desktopTest('the header\'s button opens the form; Enter adds the event to today, all day',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tap(tester, find.bySemanticsLabel('New event (N)'));
      expect(form, findsOneWidget);
      // Nothing to add before it has a title.
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Add event')).onTap, isNull);
      expect(find.bySemanticsLabel('Start day, Fri, 13 Nov 2026'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Start time')), findsNothing);

      await tester.enterText(titleField, 'Dinner with Ana');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      final dinner = named(store, 'Dinner with Ana');
      expect((dinner.date, dinner.kind, dinner.time, dinner.endDay),
          (today, ItemKind.event, null, null));
      // It is there, in today's column, and can be taken back.
      expect(find.text('Dinner with Ana'), findsOneWidget);
      expect(find.text('Event added'), findsOneWidget);
      await tap(tester, find.text('Undo'));
      expect(has(store, 'Dinner with Ana'), isFalse);
    });

    desktopTest('Escape and Cancel drop it; a click beside the form keeps what has a title',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Dropped');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      expect(has(store, 'Dropped'), isFalse);

      await open(tester);
      await tester.enterText(titleField, 'Dropped too');
      await tester.pump();
      await tap(tester, find.text('Cancel'));
      expect(form, findsNothing);
      expect(has(store, 'Dropped too'), isFalse);

      // Beside the form with nothing typed: closed, and nothing made.
      final before = store.allTasks.length;
      await open(tester);
      await tester.tapAt(const Offset(60, 500));
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      expect(store.allTasks.length, before);
      expect(find.text('Event added'), findsNothing);

      // With a title: kept, as a card keeps what was typed into it.
      await open(tester);
      await tester.enterText(titleField, 'Kept');
      await tester.pump();
      await tester.tapAt(const Offset(60, 500));
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      expect(named(store, 'Kept').date, today);
      expect(find.text('Event added'), findsOneWidget);
      // Once, not twice.
      expect(store.allTasks.where((t) => t.title == 'Kept'), hasLength(1));
    });

    desktopTest('with a time: from the next full hour for an hour; the end follows the start',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Call');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      // 9:36 in these tests.
      expect(find.bySemanticsLabel('Start time, 10:00'), findsOneWidget);
      expect(find.bySemanticsLabel('End time, 11:00'), findsOneWidget);
      await tap(tester, find.bySemanticsLabel('Start time, 10:00'));
      await tap(tester, find.text('11:30'));
      expect(find.bySemanticsLabel('End time, 12:30'), findsOneWidget);
      await tap(tester, find.bySemanticsLabel('End time, 12:30'));
      // Only later times, each with how long that makes it.
      expect(find.text('30 min'), findsOneWidget);
      await tap(tester, find.text('13:00'));
      await tap(tester, form);
      final call = named(store, 'Call');
      expect((call.time, call.end, call.endDay), (11 * 60 + 30, 13 * 60, null));
      expect(find.text('11:30 Call'), findsOneWidget);

      // All day again: the times are not kept on the event.
      await open(tester);
      await tester.enterText(titleField, 'Fair');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, find.bySemanticsLabel('All day'));
      expect(find.bySemanticsLabel(RegExp('^Start time')), findsNothing);
      await tap(tester, form);
      expect((named(store, 'Fair').time, named(store, 'Fair').end), (null, null));
    });

    desktopTest('an end can be left out; no start time makes it all day', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Open end');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, find.bySemanticsLabel('End time, 11:00'));
      await tap(tester, find.widgetWithText(MenuRow, 'No end time'));
      expect(find.bySemanticsLabel('End time, No end time'), findsOneWidget);
      await tap(tester, form);
      expect((named(store, 'Open end').time, named(store, 'Open end').end), (600, null));

      await open(tester);
      await tester.enterText(titleField, 'Whole day');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, find.bySemanticsLabel('Start time, 10:00'));
      // At the top of the list of times.
      await tester.drag(find.text('10:00').last, const Offset(0, 900));
      await tester.pumpAndSettle();
      await tap(tester, find.widgetWithText(MenuRow, 'All day'));
      expect(find.bySemanticsLabel(RegExp('^Start time')), findsNothing);
      await tap(tester, form);
      expect(named(store, 'Whole day').time, isNull);
    });

    desktopTest('over several days: an end day is picked, and the event is a bar over them',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Trip to Lyon');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('End day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('15'));
      expect(find.bySemanticsLabel('End day, Sun, 15 Nov 2026'), findsOneWidget);
      // Another start day moves the whole of it.
      await tap(tester, find.bySemanticsLabel('Start day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('12'));
      expect(find.bySemanticsLabel('Start day, Thu, 12 Nov 2026'), findsOneWidget);
      expect(find.bySemanticsLabel('End day, Sat, 14 Nov 2026'), findsOneWidget);
      await tap(tester, form);
      final trip = named(store, 'Trip to Lyon');
      expect((trip.date, trip.endDay), (Day(2026, 11, 12), Day(2026, 11, 14)));
      // Thursday to Saturday: a bar over the weekdays and one over the
      // weekend, in the row of its own under them.
      expect(find.bySemanticsLabel('Event over several days: Trip to Lyon'), findsNWidgets(2));
    });

    desktopTest('an end day before the start puts the event on that day', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Earlier');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('End day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('10'));
      expect(find.bySemanticsLabel('Start day, Tue, 10 Nov 2026'), findsOneWidget);
      await tap(tester, form);
      expect((named(store, 'Earlier').date, named(store, 'Earlier').endDay),
          (Day(2026, 11, 10), null));
    });

    desktopTest('with times over several days, the end is a time of the last day',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Night train');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, find.bySemanticsLabel('End day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('14'));
      // Any time now, also one before the start's.
      await tap(tester, find.bySemanticsLabel('End time, 11:00'));
      await tap(tester, find.widgetWithText(MenuRow, '9:30'));
      await tap(tester, form);
      final train = named(store, 'Night train');
      expect((train.time, train.end, train.endDay), (600, 570, Day(2026, 11, 14)));

      // Back to one day in the form: an end before the start is mended.
      await open(tester);
      await tester.enterText(titleField, 'Short');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, find.bySemanticsLabel('End day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('14'));
      await tap(tester, find.bySemanticsLabel('End time, 11:00'));
      await tap(tester, find.widgetWithText(MenuRow, '9:30'));
      await tap(tester, find.bySemanticsLabel('End day, Sat, 14 Nov 2026'));
      await tap(tester, find.text('13'));
      expect(find.bySemanticsLabel('End time, 11:00'), findsOneWidget);
    });

    desktopTest('repeat, reminder, colour, place and notes go with it', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Seminar');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('Repeat, Does not repeat'));
      await tap(tester, find.text('Weekly'));
      expect(find.bySemanticsLabel('Repeat, Every week on Fri'), findsOneWidget);
      await tap(tester, find.bySemanticsLabel('Colour, None'));
      await tap(tester, find.bySemanticsLabel('Green'));
      expect(find.bySemanticsLabel('Colour, Green'), findsOneWidget);
      await tap(tester, find.bySemanticsLabel('Reminder, None'));
      await tap(tester, find.text('Set reminder'));
      expect(find.bySemanticsLabel('Reminder, Fri, 13 Nov 2026, 9:00'), findsOneWidget);
      await tester.enterText(field('Add a place'), 'Room 2');
      await tester.enterText(field('Add some notes…'), 'Bring the slides');
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/event_form_full.png'));
      await tap(tester, form);

      final seminar = named(store, 'Seminar');
      expect(seminar.recurrence, Recurrence.weekly);
      expect((seminar.color, seminar.location, seminar.note),
          ('green', 'Room 2', 'Bring the slides'));
      expect(seminar.reminder, DateTime(2026, 11, 13, 9));
      // Next week too.
      expect([for (final t in store.tasksOn(today.addDays(7))) t.title], ['Seminar']);
    });

    desktopTest('a reminder set before the day is changed moves along with it', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Dentist');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('Reminder, None'));
      await tap(tester, find.text('Set reminder'));
      await tap(tester, find.bySemanticsLabel('Start day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('17'));
      expect(find.bySemanticsLabel('Reminder, Tue, 17 Nov 2026, 9:00'), findsOneWidget);
    });

    desktopTest('added on a day out of sight, the message leads there', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await open(tester);
      await tester.enterText(titleField, 'Later');
      await tester.pump();
      await tap(tester, find.bySemanticsLabel('Start day, Fri, 13 Nov 2026'));
      await tap(tester, find.text('26').last);
      await tap(tester, form);
      expect(named(store, 'Later').date, Day(2026, 11, 26));
      expect(find.text('Added on Thu, 26 Nov 2026'), findsOneWidget);
      await tap(tester, find.text('Show'));
      expect(find.text('W48'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    });

    desktopTest('while another week is on show, a new event starts on its first day',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tap(tester, find.bySemanticsLabel('Next'));
      await open(tester);
      expect(find.bySemanticsLabel('Start day, Mon, 16 Nov 2026'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // From the Tasks page: today, with the way to it.
      await tap(tester, find.bySemanticsLabel('Tasks'));
      await open(tester);
      expect(find.bySemanticsLabel('Start day, Fri, 13 Nov 2026'), findsOneWidget);
      await tester.enterText(titleField, 'From the lists');
      await tester.pump();
      await tap(tester, form);
      expect(find.text('Added on Fri, 13 Nov 2026'), findsOneWidget);
    });

    desktopTest('the menu has it too, and typing a task is not disturbed by N', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tap(tester, find.bySemanticsLabel('Menu'));
      await tap(tester, find.text('New event'));
      expect(form, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(form, findsNothing);
    });

    phoneTest('on a phone: a sheet; the keyboard\'s key puts the keyboard away, the button adds',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await tap(tester, find.bySemanticsLabel('New event'));
      expect(form, findsOneWidget);
      await tester.enterText(titleField, 'Dinner with Ana');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(form, findsOneWidget, reason: 'the rest of the form is still to be seen to');
      expect(has(store, 'Dinner with Ana'), isFalse);
      await tap(tester, find.bySemanticsLabel('All day'));
      await tap(tester, form);
      final dinner = named(store, 'Dinner with Ana');
      expect((dinner.date, dinner.time, dinner.end), (today, 600, 660));
      // The message that says so stands above the bar of pages, which
      // stays in reach.
      final message = tester.getRect(find.text('Event added'));
      final bar = tester.getRect(find.bySemanticsLabel('Tasks'));
      expect(message.bottom, lessThan(bar.top));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/phone_event_added.png'));
    });
  });

  group('the card of an event', () {
    desktopTest('gives an event of the planner a last day, changes it, and takes it away',
        (tester) async {
      final store = seededStore();
      final id = store.addItem(day: today, title: 'Fair');
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tap(tester, find.text('Fair'));
      // Without a time it takes the day.
      expect(find.text('All day'), findsOneWidget);
      await tap(tester, find.text('Fri, 13 Nov 2026'));
      await tap(tester, find.text('Ends on another day…'));
      await tap(tester, find.text('15'));
      expect(store.task(id)!.lastDay, Day(2026, 11, 15));
      expect(find.text('Fri, 13 – Sun, 15 Nov 2026'), findsOneWidget);

      await tap(tester, find.text('Fri, 13 – Sun, 15 Nov 2026'));
      await tap(tester, find.text('Last day, 15 Nov'));
      await tap(tester, find.text('16'));
      expect(store.task(id)!.lastDay, Day(2026, 11, 16));

      // A new first day moves the whole of it.
      await tap(tester, find.text('Fri, 13 – Mon, 16 Nov 2026'));
      await tap(tester, find.text('12'));
      expect((store.task(id)!.date, store.task(id)!.lastDay),
          (Day(2026, 11, 12), Day(2026, 11, 15)));

      await tap(tester, find.text('Thu, 12 – Sun, 15 Nov 2026'));
      await tap(tester, find.text('One day only'));
      expect(store.task(id)!.endDay, isNull);
      expect(find.text('Thu, 12 Nov 2026'), findsOneWidget);

      // Over several days it is a bar across them; within one, a row.
      store.updateTask(id, endDay: () => Day(2026, 11, 13));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Event over several days: Fair'), findsOneWidget);
      expect(find.text('Fair'), findsOneWidget);
    });

    desktopTest('a task has no last day to set', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tap(tester, find.text('Water the plants'));
      expect(find.text('All day'), findsNothing);
      await tap(tester, find.text('Fri, 13 Nov 2026'));
      expect(find.text('Ends on another day…'), findsNothing);
    });

    desktopTest('a bar opens the card; with times, the end says which day it is on',
        (tester) async {
      final store = seededStore();
      final id = store.addItem(
          day: today, endDay: today.addDays(1), title: 'Night train', time: 22 * 60, end: 7 * 60);
      await pumpApp(tester, store, size: const Size(1536, 790));
      // Friday into Saturday: its bar over the weekdays.
      final bar = find.bySemanticsLabel('Event over several days: 22:00 Night train').first;
      await tap(tester, bar);
      expect(find.text('Fri, 13 – Sat, 14 Nov 2026'), findsOneWidget);
      expect(find.text('– Sat 7:00'), findsOneWidget);
      // Its end is picked among all times of that day.
      await tap(tester, find.text('– Sat 7:00'));
      expect(find.text('30 min'), findsNothing, reason: 'not counted from the start');
      await tap(tester, find.text('6:00'));
      expect(store.task(id)!.end, 6 * 60);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/event_card_span.png'));
    });

    desktopTest('a bar\'s menu moves the event whole, and deletes it with a way back',
        (tester) async {
      final store = seededStore();
      final id = store.addItem(day: today, endDay: today.addDays(2), title: 'Fair');
      await pumpApp(tester, store, size: const Size(1536, 790));
      // From Friday to Sunday: a bar in the band, and one under Sunday.
      final bar = find.bySemanticsLabel('Event over several days: Fair').first;
      expect(find.bySemanticsLabel('Event over several days: Fair'), findsNWidgets(2));
      await rightClick(tester, bar);
      await tap(tester, find.text('Move to'));
      await tap(tester, find.text('Tomorrow'));
      expect((store.task(id)!.date, store.task(id)!.lastDay),
          (today.addDays(1), today.addDays(3)));
      await rightClick(tester, bar);
      await tap(tester, find.text('Delete'));
      expect(store.task(id), isNull);
      await tap(tester, find.text('Undo'));
      expect(store.task(id)!.lastDay, today.addDays(3));
    });

    phoneTest('on a phone a long press on a bar opens its menu', (tester) async {
      final store = seededStore();
      store.addItem(day: today, endDay: today.addDays(2), title: 'Fair');
      await pumpApp(tester, store, size: const Size(393, 851));
      final bar = find.bySemanticsLabel('Event over several days: Fair').first;
      final finger = await tester.startGesture(tester.getCenter(bar), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 700));
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
    });
  });
}
