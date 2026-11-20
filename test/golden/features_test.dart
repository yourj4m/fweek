import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, TextField;
import 'package:weektodo/app_state.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/services/places.dart';
import 'package:weektodo/theme/app_theme.dart';
import 'package:weektodo/ui/composer.dart';
import 'package:weektodo/ui/day_progress.dart';
import 'package:weektodo/ui/note_field.dart';
import 'package:weektodo/ui/planner_page.dart';
import 'package:weektodo/ui/task_list.dart';

import 'harness.dart';

/// Menus, lists, places, links, the day's progress, themes and the phone's
/// editing bar.
void main() {
  setUpAll(loadFonts);

  final today = referenceToday;
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];
  Task named(PlannerStore store, String title) =>
      store.allTasks.firstWhere((t) => t.title == title);

  group('the menu of a task', () {
    desktopTest('right-click: move it, delete it, undo', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Water the plants'));
      expect(find.text('Duplicate'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/task_menu.png'));

      await tester.tap(find.text('Move to'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomorrow'));
      await tester.pumpAndSettle();
      expect(titles(store.tasksOn(today.addDays(1))), contains('Water the plants'));

      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Water the plants'), findsNothing);
      expect(find.text('Task deleted'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(titles(store.tasksOn(today.addDays(1))), contains('Water the plants'));
      expect(find.text('Task deleted'), findsNothing);
    });

    desktopTest('colour, time and note are one step away', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Orange'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').color, 'orange');

      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7:30'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').time, 7 * 60 + 30);

      await rightClick(tester, find.text('7:30 Water the plants'));
      await tester.tap(find.text('Add a note'));
      await tester.pumpAndSettle();
      // The card opens with the cursor in the notes.
      tester.testTextInput.enterText('Only the ferns');
      await tester.pump(const Duration(milliseconds: 600));
      expect(named(store, 'Water the plants').note, 'Only the ferns');
    });

    desktopTest('a screen reader hears the message, and Undo is a button of its own',
        (tester) async {
      final handle = tester.ensureSemantics();
      final store = seededStore();
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // Exactly "Undo": not the message, and not said twice.
      expect(find.bySemanticsLabel('Undo'), findsOneWidget);
      final message = tester.getSemantics(find.text('Task deleted'));
      expect(message.label, 'Task deleted');
      expect(message.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    desktopTest('a click beside the card closes it; a click on the card does not',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      final subtask = find.bySemanticsLabel('Add subtask');
      expect(subtask, findsOneWidget);
      // On the card, where nothing is: it stays.
      await tester.tapAt(tester.getTopLeft(subtask) - const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(subtask, findsOneWidget);
      // Beside it, on the dimmed page.
      await tester.tapAt(const Offset(30, 450));
      await tester.pumpAndSettle();
      expect(subtask, findsNothing);
      // And the card can still be closed with the keyboard.
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(subtask, findsNothing);
    });

    desktopTest('typing in the card is saved when a click beside it closes it', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      // The card's title is the one field holding the task's text.
      final title = find.byWidgetPredicate(
          (w) => w is EditableText && w.controller.text == 'Water the plants');
      await tester.enterText(title, 'Water the ferns');
      await tester.tapAt(const Offset(30, 450));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Add subtask'), findsNothing);
      expect(store.allTasks.where((t) => t.title == 'Water the ferns'), hasLength(1));
    });

    phoneTest('on a phone a tap above the sheet closes it', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      final subtask = find.bySemanticsLabel('Add subtask');
      expect(subtask, findsOneWidget);
      await tester.tapAt(const Offset(200, 60));
      await tester.pumpAndSettle();
      expect(subtask, findsNothing);
    });

    desktopTest('the settings and the search close on a click beside them too', (tester) async {
      await pumpApp(tester, seededStore());
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      final open = find.text('Week starts on');
      expect(open, findsOneWidget);
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      expect(open, findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final field = find.byType(EditableText);
      final before = tester.widgetList(field).length;
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      expect(tester.widgetList(field).length, lessThan(before));
    });

    desktopTest('a message goes away by itself', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      expect(store.allTasks.where((t) => t.title == 'Water the plants'), isEmpty);
    });

    desktopTest('with the keyboard: Tab to a row, Space completes, the menu key opens the menu',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      Task? focused() => FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TaskRow>()
          ?.task;
      for (var i = 0; i < 40 && focused() == null; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      final task = focused();
      expect(task, isNotNull, reason: 'Tab reaches the task rows');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(store.task(task!.id)!.done, !task.done);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
      // The menu's first entry has the focus; Enter opens the card.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Add subtask'), findsOneWidget);
    });

    phoneTest('a long press and letting go opens it; moving on drags instead', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      final at = tester.getCenter(find.text('Water the plants'));
      var finger = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 700));
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
      expect(titles(store.tasksOn(today)), ['Water the plants']);
      await tester.tapAt(const Offset(390, 880)); // beside the menu
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsNothing);

      // The same press, then a move: the task goes to the next day.
      finger = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 700));
      await finger.moveBy(const Offset(0, 40));
      await tester.pump();
      await finger.moveTo(tester.getCenter(find.text('Mark me complete')));
      await tester.pumpAndSettle();
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsNothing);
      expect(titles(store.tasksOn(today.addDays(1))), contains('Water the plants'));
    });
  });

  group('lists', () {
    desktopTest('there is always a place to start a new list', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      // Said plainly, not only under the mouse.
      expect(find.text('New list'), findsOneWidget);
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'List name'), 'Reading');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect([for (final l in store.lists) l.title], ['', 'Reading']);

      // A full row of three used to leave no way to add a fourth.
      store.addList('Home');
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(3));
      expect(find.text('New list'), findsOneWidget);
      await tester.ensureVisible(find.text('New list'));
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'List name'), 'Travel');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect([for (final l in store.lists) l.title], ['', 'Reading', 'Home', 'Travel']);
    });

    desktopTest('typing a task into the blank column also starts a list', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      final blank = find.descendant(
        of: find.byWidgetPredicate((w) =>
            w is TaskListBody && w.slot is ListSlot && w.tasks.isEmpty && w.onAdd != null),
        matching: find.byType(TextField),
      );
      await tester.enterText(blank.first, 'Book flights');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(2));
      expect(titles(store.tasksIn(store.lists.last.id)), ['Book flights']);
    });

    desktopTest('a list is moved and deleted from its menu, and comes back on Undo',
        (tester) async {
      final store = seededStore();
      final home = store.addList('Home');
      store.addTask(ListSlot(home), 'Fix the tap');
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Home'));
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      expect(store.lists.first.id, home);

      await rightClick(tester, find.text('Home'));
      await tester.tap(find.text('Delete list and 1 tasks'));
      await tester.pumpAndSettle();
      expect(store.list(home), isNull);
      expect(find.text('Home and 1 task deleted'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.list(home)!.title, 'Home');
      expect(titles(store.tasksIn(home)), ['Fix the tap']);
    });

    desktopTest('the menu creates a list and asks for its name', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      // The menu's entry, not the blank column behind it.
      await tester.tap(find.text('New list').last);
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(2));
      tester.testTextInput.enterText('Groceries');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.lists.last.title, 'Groceries');
    });

    phoneTest('on a phone a button under the lists creates one', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      // To the end of the week's page (the pages beside it have a button
      // of their own, out of sight).
      await tester.drag(find.byType(PageView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('New list').hitTestable());
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(2));
      tester.testTextInput.enterText('Films');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.lists.last.title, 'Films');
    });
  });

  group('the day\'s progress', () {
    double filled(WidgetTester tester) {
      final bar = find.byType(DayProgress);
      final fill = find.descendant(
        of: find.descendant(of: bar, matching: find.byType(FractionallySizedBox)),
        matching: find.byType(ColoredBox),
      );
      return tester.getSize(fill).width / tester.getSize(bar).width;
    }

    desktopTest('a bar under today fills from left to right; nothing else is shown',
        (tester) async {
      // 9:36 in the morning: two fifths of the day.
      await pumpApp(tester, seededStore());
      expect(find.byType(DayProgress), findsOneWidget);
      expect(filled(tester), closeTo(0.4, 0.001));
      // Across today's column, under its heading.
      final bar = tester.getRect(find.byType(DayProgress));
      final heading = tester.getRect(find.text('13 Nov'));
      expect(bar.left, closeTo(heading.left, 1));
      expect(bar.top, greaterThanOrEqualTo(heading.bottom - 1));
      expect(bar.height, 3);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('9:36'), findsNothing);
    });

    test('a dot where an item starts, a pill from start to end, and stretches where they overlap',
        () {
      const red = Color(0xFFCC0000), blue = Color(0xFF0000CC), green = Color(0xFF00AA00);
      // A bar 240 wide: ten per hour. Marks 6 high.
      final rects = markRects(const [
        DayMark(start: 9 * 60, color: red),
        DayMark(start: 12 * 60, end: 14 * 60, color: blue),
      ], 240, 6);
      // The dot is centred on nine o'clock and as wide as it is high.
      expect(rects[0], const Rect.fromLTRB(87, 0, 93, 6));
      // The pill reaches from twelve to two.
      expect(rects[1], const Rect.fromLTRB(120, 0, 140, 6));

      // Two that overlap from one to two, and a dot inside the first.
      final segments = markSegments(const [
        DayMark(start: 12 * 60, end: 14 * 60, color: blue),
        DayMark(start: 13 * 60, end: 15 * 60, color: green),
        DayMark(start: 12 * 60 + 30, color: red),
      ], 240, 6);
      expect([for (final s in segments) (s.left, s.right)],
          [(120.0, 122.0), (122.0, 128.0), (128.0, 130.0), (130.0, 140.0), (140.0, 150.0)]);
      expect([for (final s in segments) s.colors], [
        [blue],
        [blue, red],
        [blue],
        [blue, green],
        [green],
      ]);

      // Nothing is narrower than a dot, and nothing hangs off the bar.
      final edge = markRects(const [
        DayMark(start: 0, color: red),
        DayMark(start: 23 * 60 + 58, color: red),
        DayMark(start: 10 * 60, end: 10 * 60 + 5, color: blue),
      ], 240, 6);
      expect(edge[0], const Rect.fromLTRB(0, 0, 6, 6));
      expect(edge[1], const Rect.fromLTRB(234, 0, 240, 6));
      expect(edge[2].width, 6);
    });

    desktopTest('the day\'s timed items are marked on it, in their colours', (tester) async {
      final store = seededStore();
      final swim = store.addTask(DaySlot(today), 'Swim')!;
      store.updateTask(swim, time: () => 7 * 60, color: () => 'green');
      final lunch = store.addTask(DaySlot(today), 'Lunch', kind: ItemKind.event)!;
      store.updateTask(lunch, time: () => 12 * 60, end: () => 13 * 60 + 30, color: () => 'orange');
      final call = store.addTask(DaySlot(today), 'Call')!;
      store.updateTask(call, time: () => 13 * 60, end: () => 14 * 60);
      store.addTask(DaySlot(today), 'No time, no mark');
      await pumpApp(tester, store, calendars: await calendarWith(tester, store));
      // Three of the planner's own and the calendar's committee at 14:30.
      expect(find.bySemanticsLabel('Progress of the day, with 4 timed items marked'),
          findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/progress_marks.png'));
    });

    desktopTest('it moves on with the clock, and to the next day at midnight', (tester) async {
      var now = DateTime(2026, 11, 13, 18);
      final store = PlannerStore(
        seededStore().db,
        today: () => Day.fromDateTime(now),
        now: () => now.millisecondsSinceEpoch,
      );
      await pumpApp(tester, store);
      expect(filled(tester), closeTo(0.75, 0.001));
      now = DateTime(2026, 11, 13, 21);
      await tester.pump(const Duration(seconds: 61));
      expect(filled(tester), closeTo(0.875, 0.001));

      now = DateTime(2026, 11, 14, 0, 0, 30);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      // The bar is under Saturday now, at its start.
      expect(tester.getRect(find.byType(DayProgress)).left,
          closeTo(tester.getRect(find.text('14 Nov')).left, 1));
      expect(filled(tester), lessThan(0.01));
    });

    desktopTest('the month marks today\'s cell with it', (tester) async {
      final store = seededStore()..setSetting(Settings.view, 'month');
      await pumpApp(tester, store);
      expect(find.byType(DayProgress), findsOneWidget);
      expect(filled(tester), closeTo(0.4, 0.001));
    });
  });

  group('links', () {
    desktopTest('a link in a note opens in the browser; a click beside it edits',
        (tester) async {
      final store = seededStore();
      final opened = <String>[];
      store.updateTask(named(store, 'Water the plants').id,
          note: 'https://example.org/care is the guide.\nAsk anna@example.org too.');
      await pumpApp(tester, store, opener: recordingOpener(opened));
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/note_links.png'));

      final note = tester.getRect(find.byType(LinkedText));
      await tester.tapAt(note.topLeft + const Offset(30, 10));
      await tester.pumpAndSettle();
      expect(opened, ['https://example.org/care']);
      // On the second line: the mail address.
      await tester.tapAt(note.topLeft + const Offset(60, 32));
      await tester.pumpAndSettle();
      expect(opened.last, 'mailto:anna@example.org');

      // Beside the text: typing starts, and the links stay marked.
      await tester.tapAt(note.topRight + const Offset(-10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(LinkedText), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
      );
      expect(opened, hasLength(2));
    });

    desktopTest('links in a calendar\'s description open too', (tester) async {
      final store = seededStore();
      final opened = <String>[];
      final calendars = await calendarWith(tester, store,
          feed: referenceFeed.replaceFirst(
              'DESCRIPTION:Bring the draft.',
              'DESCRIPTION:<a href="https://example.org/draft">The draft</a> is here.'));
      await pumpApp(tester, store, calendars: calendars, opener: recordingOpener(opened));
      await tester.tap(find.text('10:00 Team meeting'));
      await tester.pumpAndSettle();
      final text = find.byType(LinkedText);
      expect(tester.widget<LinkedText>(text).text,
          'The draft (https://example.org/draft) is here.');
      await tester.tapAt(tester.getRect(text).topLeft + const Offset(120, 8));
      await tester.pumpAndSettle();
      expect(opened, ['https://example.org/draft']);
    });
  });

  group('places', () {
    const cafe = Place(
      name: 'Café de la Table Ronde',
      detail: '7 Place Saint-André, 38000 Grenoble, France',
      lat: 45.1929,
      lon: 5.7281,
    );

    desktopTest('suggested while typing; a picked place knows where it is and opens in the map',
        (tester) async {
      final store = seededStore();
      final opened = <String>[];
      final places = FakePlaces([cafe]);
      await pumpApp(tester, store, places: places, opener: recordingOpener(opened));
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Add a place'));
      await tester.pumpAndSettle();

      final field = find.widgetWithText(TextField, 'Add a place');
      await tester.enterText(field, 'ta');
      await tester.pump(const Duration(milliseconds: 500));
      expect(places.asked, isEmpty, reason: 'two letters are too few to ask about');
      await tester.enterText(field, 'table r');
      await tester.pump(const Duration(milliseconds: 100));
      expect(places.asked, isEmpty, reason: 'not on every keystroke');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(places.asked, ['table r']);
      expect(find.text('Café de la Table Ronde'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/place_suggestions.png'));
      // What is typed is kept even before anything is picked.
      expect(named(store, 'Water the plants').location, 'table r');

      await tester.tap(find.text('Café de la Table Ronde'));
      await tester.pumpAndSettle();
      final task = named(store, 'Water the plants');
      expect(task.location, cafe.label);
      expect(task.geo, '45.192900,5.728100');

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Open .* in the map app$')));
      await tester.pumpAndSettle();
      expect(opened.single, startsWith('geo:45.192900,5.728100?q=45.192900,5.728100('));

      // The row in the week names the place under the task.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Café de la Table Ronde'), findsOneWidget);
    });

    desktopTest('the card has a button for it', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Add a place'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Add a place'));
      await tester.pumpAndSettle();
      tester.testTextInput.enterText('Balcony');
      await tester.pump();
      expect(named(store, 'Water the plants').location, 'Balcony');
      expect(find.bySemanticsLabel('Place'), findsOneWidget);
    });

    desktopTest('with suggestions switched off nothing is asked, and the text is kept',
        (tester) async {
      final store = seededStore()..setSetting(Settings.placeSearch, false);
      final places = FakePlaces([cafe]);
      await pumpApp(tester, store, places: places);
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Add a place'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Add a place'), 'table ronde');
      await tester.pump(const Duration(seconds: 1));
      expect(places.asked, isEmpty);
      expect(named(store, 'Water the plants').location, 'table ronde');
      expect(named(store, 'Water the plants').geo, isNull);
    });

    desktopTest('the search server is set in the settings, over https only', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(1440, 2800));
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, PlaceSearch.defaultServer);
      await tester.enterText(field, 'http://photon.example.org');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Use an https address.'), findsOneWidget);
      expect(store.setting<String>(Settings.placeServer), '');
      await tester.enterText(field, 'photon.example.org');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.setting<String>(Settings.placeServer), 'https://photon.example.org');
    });
  });

  group('themes', () {
    for (final theme in AppTheme.all) {
      desktopTest('${theme.name} draws the week, a card and a menu', (tester) async {
        final store = seededStore()..setSetting(Settings.theme, theme.id);
        await pumpApp(tester, store, calendars: await calendarWith(tester, store));
        await rightClick(tester, find.text('Water the plants'));
        expect(find.text('Duplicate'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.text('9:30 Call dentist'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Add subtask'), findsOneWidget);
        if (theme.group == ThemeGroup.semiDark) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await expectLater(
              find.byType(MaterialApp), matchesGoldenFile('goldens/theme_${theme.id}.png'));
        }
      });
    }

    desktopTest('the settings offer them in three rows', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      double row(String name) =>
          tester.getCenter(find.bySemanticsLabel(RegExp('^$name theme'))).dy;
      expect(row('Light'), row('Sage'));
      expect(row('Dark'), row('Slate'));
      expect(row('Wine'), row('Cocoa'));
      expect(row('Dark'), greaterThan(row('Light')));
      expect(row('Wine'), greaterThan(row('Dark')));
      await tester.tap(find.bySemanticsLabel(RegExp('^Plum theme')));
      await tester.pumpAndSettle();
      expect(store.setting<String>(Settings.theme), 'plum');
    });
  });

  group('the phone\'s editing bar', () {
    Finder todaysLine() => find.descendant(
          of: find.byWidgetPredicate((w) => w is TaskListBody && w.slot == DaySlot(today)),
          matching: find.byType(TextField),
        );

    phoneTest('shows while a task is typed, and what it adds goes with the task', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      expect(find.byType(ComposerBar), findsOneWidget);
      expect(find.bySemanticsLabel('Time'), findsNothing, reason: 'nothing is being typed');

      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Time'), findsOneWidget);
      expect(find.bySemanticsLabel('Place'), findsOneWidget);
      expect(find.bySemanticsLabel('Note'), findsOneWidget);
      expect(find.bySemanticsLabel('Colour'), findsOneWidget);

      // A time: the wheels open with one set already.
      await tester.tap(find.bySemanticsLabel('Time'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Hours'), findsOneWidget);
      expect(find.bySemanticsLabel('Minutes'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_editing_bar.png'));
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      // A colour.
      await tester.tap(find.bySemanticsLabel('Colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Green'));
      await tester.pumpAndSettle();

      // A place: its field takes the keyboard for a moment and gives it back.
      await tester.tap(find.bySemanticsLabel('Place'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Where?'), 'Library');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.allTasks.where((t) => t.title.isEmpty), isEmpty,
          reason: 'lending the keyboard to the bar creates nothing');

      await tester.enterText(todaysLine(), 'Return books');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final task = named(store, 'Return books');
      expect(task.date, today);
      expect(task.time, isNotNull);
      expect(task.time! % 60, 0);
      expect(task.color, 'green');
      expect(task.location, 'Library');
      // Ready for the next task, with nothing carried over.
      expect(find.bySemanticsLabel('Time'), findsOneWidget);
      await tester.enterText(todaysLine(), 'Plain one');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(named(store, 'Plain one').time, isNull);
      expect(named(store, 'Plain one').color, isNull);
    });

    phoneTest('"All details" makes the task and opens its sheet', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      await tester.enterText(todaysLine(), 'Plan the trip');
      await tester.tap(find.bySemanticsLabel('All details'));
      await tester.pumpAndSettle();
      expect(named(store, 'Plan the trip').date, today);
      expect(find.bySemanticsLabel('Add subtask'), findsOneWidget);
    });

    desktopTest('a desktop has no such bar', (tester) async {
      await pumpApp(tester, seededStore(), size: const Size(390, 844));
      expect(find.byType(ComposerBar), findsNothing);
    });

    phoneTest('the time of a task is set with wheels, to the minute', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Time'));
      await tester.pumpAndSettle();
      await tester.drag(find.bySemanticsLabel('Minutes'), const Offset(0, -40));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      final time = named(store, 'Water the plants').time;
      expect(time, isNotNull);
      expect(time! % 60, 1, reason: 'one step of the minutes wheel is one minute');
    });
  });

  group('selecting text', () {
    bool selectable(WidgetTester tester, Finder text) =>
        SelectionContainer.maybeOf(tester.element(text)) != null;

    desktopTest('what informs can be selected; what is pressed cannot', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      expect(selectable(tester, find.text('13 Nov')), isTrue);
      expect(selectable(tester, find.text('Water the plants')), isFalse);

      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      expect(selectable(tester, find.text('Settings')), isFalse);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(selectable(tester, find.textContaining('Once a day, tasks left open')), isTrue);
      expect(selectable(tester, find.text('Backup')), isFalse);
    });

    phoneTest('on a phone the week itself is left to swiping', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      expect(selectable(tester, find.text('13 Nov')), isFalse);
      // In a card, text can be selected on a phone too.
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(selectable(tester, find.textContaining('Once a day, tasks left open')), isTrue);
    });
  });

  group('tasks and events', () {
    Finder todaysLine() => find.descendant(
          of: find.byWidgetPredicate((w) => w is TaskListBody && w.slot == DaySlot(referenceToday)),
          matching: find.byType(TextField),
        );
    Finder rowOf(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TaskRow));
    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(todaysLine(), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    desktopTest('the line typed on says which is being made and switches: its mark, or Ctrl+E',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      expect(find.bySemanticsLabel(RegExp('switch to an event')), findsNothing);
      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('A task; switch to an event (Ctrl+E)'), findsOneWidget);
      await type(tester, 'Buy stamps');
      expect(named(store, 'Buy stamps').kind, ItemKind.task);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('An event; switch to a task (Ctrl+E)'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/add_event.png'));
      // Several in a row.
      await type(tester, 'Seminar');
      await type(tester, 'Lab meeting');
      expect(named(store, 'Seminar').kind, ItemKind.event);
      expect(named(store, 'Lab meeting').kind, ItemKind.event);
      // An event's row has nothing to tick; a task's has.
      expect(find.descendant(of: rowOf('Seminar'), matching: find.byType(CheckToggle)), findsNothing);
      expect(find.descendant(of: rowOf('Buy stamps'), matching: find.byType(CheckToggle)),
          findsOneWidget);

      // The mark switches back, and the line keeps the keyboard.
      await tester.tap(find.bySemanticsLabel('An event; switch to a task (Ctrl+E)'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('A task; switch to an event (Ctrl+E)'), findsOneWidget);
      await type(tester, 'Post the letter');
      expect(named(store, 'Post the letter').kind, ItemKind.task);
    });

    desktopTest('the switch is for the typing at hand: the next time, it is what the settings say',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      await type(tester, 'Buy stamps');
      expect(named(store, 'Buy stamps').kind, ItemKind.task);
    });

    desktopTest('the settings choose what new items are', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('New items are'), findsOneWidget);
      await tester.ensureVisible(find.text('Events'));
      await tester.tap(find.text('Events'));
      await tester.pumpAndSettle();
      expect(store.newItemKind, ItemKind.event);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('An event; switch to a task (Ctrl+E)'), findsOneWidget);
      await type(tester, 'Seminar');
      expect(named(store, 'Seminar').kind, ItemKind.event);
      // And the other way for one item.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await type(tester, 'Buy stamps');
      expect(named(store, 'Buy stamps').kind, ItemKind.task);
    });

    phoneTest('on a phone the first button of the bar above the keyboard switches', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      await tester.tap(todaysLine());
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('A task; tap to make it an event'));
      await tester.pumpAndSettle();
      // The bar says so in a word while it is not the usual.
      expect(find.text('Event'), findsOneWidget);
      await type(tester, 'Seminar');
      expect(named(store, 'Seminar').kind, ItemKind.event);
      expect(find.descendant(of: rowOf('Seminar'), matching: find.byType(CheckToggle)), findsNothing);
      // It holds for what is typed next, until typing ends.
      await type(tester, 'Lab meeting');
      expect(named(store, 'Lab meeting').kind, ItemKind.event);
      // (Its label is followed by the word it shows.)
      await tester.tap(find.bySemanticsLabel(RegExp('^An event; tap to make it a task')));
      await tester.pumpAndSettle();
      expect(find.text('Event'), findsNothing);
      await type(tester, 'Buy stamps');
      expect(named(store, 'Buy stamps').kind, ItemKind.task);
    });

    desktopTest('the card turns a task into an event and back, and gives it an end', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mark as done'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn into an event'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').kind, ItemKind.event);
      expect(find.bySemanticsLabel('Mark as done'), findsNothing);

      // No end without a start.
      expect(find.bySemanticsLabel(RegExp('^Add an end time')), findsNothing);
      await tester.tap(find.bySemanticsLabel('Time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7:30'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(RegExp('^Add an end time')));
      await tester.pumpAndSettle();
      // Only later times, each with how long that makes it.
      expect(find.text('No end'), findsOneWidget);
      expect(find.text('7:30'), findsOneWidget, reason: 'the start, on the card only');
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('1.5 h'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_end_time.png'));
      await tester.tap(find.text('9:00'));
      await tester.pumpAndSettle();
      expect((named(store, 'Water the plants').time, named(store, 'Water the plants').end), (450, 540));
      expect(find.text('– 9:00'), findsOneWidget);
      // The week behind shows the start only.
      expect(find.text('7:30 Water the plants'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(RegExp('^End time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No end'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').end, isNull);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn into a task'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mark as done'), findsOneWidget);
    });

    desktopTest('an event of today turns faint the minute it ends', (tester) async {
      var clock = DateTime(referenceToday.year, referenceToday.month, referenceToday.day, 9, 36);
      final store = PlannerStore(PlannerDatabase.inMemory(),
          today: () => referenceToday, now: () => clock.millisecondsSinceEpoch)
        ..setSetting(Settings.rollover, false);
      final id = store.addTask(DaySlot(referenceToday), 'Stand-up', kind: ItemKind.event)!;
      store.updateTask(id, time: () => 9 * 60 + 40, end: () => 9 * 60 + 50);
      store.addTask(DaySlot(referenceToday), 'Stays as it is');
      await pumpApp(tester, store);
      double ink(String label) => tester.widget<Text>(find.text(label)).style!.color!.a;
      expect(ink('9:40 Stand-up'), 1);
      clock = clock.add(const Duration(minutes: 13));
      await tester.pump(const Duration(minutes: 13));
      expect(ink('9:40 Stand-up'), 1, reason: 'a minute to go');
      clock = clock.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      expect(ink('9:40 Stand-up'), lessThan(0.5));
      expect(ink('Stays as it is'), 1);
    });
  });

  group('a task moved to today unfinished', () {
    final yesterday = referenceToday.addDays(-1);

    /// Yesterday: three tasks, the middle one left unticked; then the daily
    /// move of the next morning.
    PlannerStore moved() {
      final store = seededStore();
      final first = store.addTask(DaySlot(yesterday), 'Morning swim')!;
      store.addTask(DaySlot(yesterday), 'Evening run');
      final last = store.addTask(DaySlot(yesterday), 'Read a chapter')!;
      store.setDone(first, true);
      store.setDone(last, true);
      store.setSetting(Settings.rollover, true);
      expect(store.rollOver(), greaterThan(0));
      return store;
    }

    Finder rowOf(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TaskRow));
    Finder yes() => find.bySemanticsLabel(RegExp('^Done on 12 Nov: put it back there'));
    Finder no() => find.bySemanticsLabel('Still to do: keep it on today');

    desktopTest('shows a green check and a red cross in place of the circle, without hovering',
        (tester) async {
      final store = moved();
      await pumpApp(tester, store);
      expect(named(store, 'Evening run').date, referenceToday);
      final row = rowOf('Evening run');
      expect(find.descendant(of: row, matching: find.byType(MovedAnswer)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byType(CheckToggle)), findsNothing);
      expect(find.descendant(of: row, matching: yes()), findsOneWidget);
      expect(find.descendant(of: row, matching: no()), findsOneWidget);
      // A task that was on today anyway has its circle.
      expect(find.descendant(of: rowOf('Water the plants'), matching: find.byType(MovedAnswer)),
          findsNothing);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_moved_task.png'));
    });

    desktopTest('green: it was done that day; back where it stood, ticked, and Undo brings it back',
        (tester) async {
      final store = moved();
      await pumpApp(tester, store);
      await tester.tap(find.descendant(of: rowOf('Evening run'), matching: yes()));
      await tester.pumpAndSettle();
      final task = named(store, 'Evening run');
      expect((task.date, task.done), (yesterday, true));
      expect([for (final t in store.tasksOn(yesterday)) t.title],
          ['Morning swim', 'Evening run', 'Read a chapter']);
      expect(find.text('Ticked on 12 Nov'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect((named(store, 'Evening run').date, named(store, 'Evening run').done),
          (referenceToday, false));
      expect(find.descendant(of: rowOf('Evening run'), matching: find.byType(MovedAnswer)),
          findsOneWidget);
    });

    desktopTest('red: still to do; it stays on today with the usual circle', (tester) async {
      final store = moved();
      await pumpApp(tester, store);
      await tester.tap(find.descendant(of: rowOf('Evening run'), matching: no()));
      await tester.pumpAndSettle();
      final task = named(store, 'Evening run');
      expect((task.date, task.done, task.waitsForWord), (referenceToday, false, false));
      final row = rowOf('Evening run');
      expect(find.descendant(of: row, matching: find.byType(MovedAnswer)), findsNothing);
      expect(find.descendant(of: row, matching: find.byType(CheckToggle)), findsOneWidget);
    });

    desktopTest('the menu and the card ask the same', (tester) async {
      final store = moved();
      await pumpApp(tester, store);
      await rightClick(tester, find.text('Evening run'));
      expect(find.text('Done on 12 Nov'), findsOneWidget);
      expect(find.text('Still to do'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Evening run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not ticked on Thu, 12 Nov 2026'), findsOneWidget);
      // The card's own pair, beside the title.
      final inCard = find.descendant(
          of: find.ancestor(
              of: find.textContaining('Not ticked on'), matching: find.byType(Column)).first,
          matching: yes());
      expect(inCard, findsOneWidget);
      await tester.tap(inCard);
      await tester.pumpAndSettle();
      expect((named(store, 'Evening run').date, named(store, 'Evening run').done), (yesterday, true));
      // The card stays on the task, which is a ticked task now.
      expect(find.bySemanticsLabel('Mark as not done'), findsOneWidget);
    });

    phoneTest('on a phone both buttons are there to tap', (tester) async {
      final store = moved();
      await pumpApp(tester, store, size: const Size(411, 914));
      final row = rowOf('Evening run');
      expect(find.descendant(of: row, matching: yes()), findsOneWidget);
      await tester.tap(find.descendant(of: row, matching: no()));
      await tester.pumpAndSettle();
      expect(named(store, 'Evening run').waitsForWord, isFalse);
      expect(named(store, 'Evening run').date, referenceToday);
    });
  });

  group('search', () {
    desktopTest('finds events too and opens them', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, calendars: await calendarWith(tester, store));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'committee');
      await tester.pumpAndSettle();
      // Behind the search card the week shows it as well.
      expect(find.text('14:30 Thesis committee'), findsNWidgets(2));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // Its card: from when to when, and from which calendar.
      expect(find.text('14:30'), findsOneWidget);
      expect(find.text('– 16:00'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
    });
  });

  group('what is redrawn', () {
    setUp(debugBuildCounts.clear);
    int built(String name) => debugBuildCounts[name] ?? 0;

    phoneTest('turning the week redraws no row of the weeks already built', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      // The weeks beside the visible one are built a moment after start.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      debugBuildCounts.clear();
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('16 Nov'), findsOneWidget);
      // Nothing was built during the swipe: not this week, not the next,
      // and the week after next (which the pager now wants ready) waits
      // until the swipe is over.
      expect(built('TaskRow'), 0);
      expect(built('TaskListBody'), 0);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      // Seven empty days and the Someday list with its one task.
      expect(built('TaskRow'), 1);
      expect(built('TaskListBody'), 8);
    });

    phoneTest('a week swiped to before it was prepared is built at once', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      // No rest between start and swipe, nor between two swipes.
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('16 Nov'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('23 Nov'), findsOneWidget);
      expect(find.text('Keep tasks here without a date', skipOffstage: false), findsWidgets);
    });

    phoneTest('the keyboard sliding in redraws nothing of the week', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      debugBuildCounts.clear();
      for (final inset in [80.0, 160.0, 240.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
      }
      addTearDown(tester.view.resetViewInsets);
      expect(built('TaskRow'), 0);
      expect(built('TaskListBody'), 0);
    });

    desktopTest('a dragged task redraws rows when its target changes, not as it moves',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      final mouse = await tester.startGesture(tester.getCenter(find.text('Water the plants')),
          kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(4, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      debugBuildCounts.clear();
      // Twenty small moves within the same row of the same day.
      for (var i = 0; i < 20; i++) {
        await mouse.moveBy(Offset(i.isEven ? 2 : -2, 0));
        await tester.pump();
      }
      expect(built('TaskRow'), 0);
      expect(built('TaskListBody'), 0);
      await mouse.up();
      await tester.pumpAndSettle();
    });

    phoneTest('a task dragged to the next day redraws those two days, not the weeks',
        (tester) async {
      final store = seededStore();
      await pumpApp(tester, store, size: const Size(411, 914));
      // The weeks beside this one are in place, as on a phone at rest.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      final finger =
          await tester.startGesture(tester.getCenter(find.text('Water the plants')));
      debugBuildCounts.clear();
      await tester.pump(const Duration(milliseconds: 700));
      // Picked up: only the list it was taken from is drawn again.
      expect(built('TaskListBody'), 1);
      debugBuildCounts.clear();
      await finger.moveBy(const Offset(0, 30));
      await tester.pump();
      await finger.moveTo(tester.getCenter(find.text('Mark me complete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // Crossing into the next day: the day left and the day entered, each
      // a few times over as the gap closes there and opens here. Three
      // weeks of eight lists each would be dozens.
      expect(built('TaskListBody'), lessThanOrEqualTo(8));
      await finger.up();
      await tester.pumpAndSettle();
      expect(store.tasksOn(today.addDays(1)).map((t) => t.title), contains('Water the plants'));
    });

    desktopTest('sync and calendar news redraw no row', (tester) async {
      final store = seededStore();
      final calendars = await calendarWith(tester, store);
      await pumpApp(tester, store, calendars: calendars);
      debugBuildCounts.clear();
      // A refresh that finds nothing new.
      await tester.runAsync(calendars.refresh);
      await tester.pump();
      expect(built('TaskRow'), 0);
    });

    desktopTest('the page around the week being rebuilt leaves the week alone', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      debugBuildCounts.clear();
      (tester.element(find.byType(PlannerPage)) as StatefulElement).markNeedsBuild();
      await tester.pump();
      expect(built('TaskRow'), 0);
      expect(built('TaskListBody'), 0);
    });

    desktopTest('lighting up a search result redraws no row', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      debugBuildCounts.clear();
      final app = AppScope.read(tester.element(find.byType(PlannerPage))).controller;
      app.show(today, highlight: named(store, 'Water the plants').id);
      await tester.pump();
      expect(built('TaskRow'), 0);
      expect(app.highlightedTask, isNotNull);
    });
  });
}
