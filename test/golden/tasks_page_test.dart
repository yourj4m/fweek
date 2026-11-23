import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, TextField;
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/ui/task_list.dart';
import 'package:fweek/ui/tasks_page.dart';
import 'package:fweek/ui/widgets/controls.dart';

import 'harness.dart';

/// The reference week with lists as someone would keep them: the first one
/// still without a name, a project and a list for the home. Some tasks have
/// a day, one a deadline that has passed, some are done.
PlannerStore listsStore({int more = 0}) {
  final store = seededStore();
  final today = store.today;
  final first = store.lists.first.id;
  store.addTask(ListSlot(first), 'Renew the passport');
  final bank = store.addTask(ListSlot(first), 'Call the bank')!;
  store.updateTask(bank, due: () => today.addDays(-2));
  final thesis = store.addList('Thesis');
  final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
  store.moveTask(figure, DaySlot(today));
  final draft = store.addTask(ListSlot(thesis), 'Chapter 2 draft')!;
  store.updateTask(draft, due: () => today.addDays(14), color: () => 'purple');
  final reply = store.addTask(ListSlot(thesis), 'Reply to the reviewers')!;
  store.moveTask(reply, DaySlot(today.addDays(4)));
  store.addTask(ListSlot(thesis), 'Slides for the committee');
  final outline = store.addTask(ListSlot(thesis), 'Outline of chapter 1')!;
  store.setDone(outline, true);
  final home = store.addList('Home');
  store.addTask(ListSlot(home), 'Fix the bike light');
  final bulbs = store.addTask(ListSlot(home), 'Buy bulbs')!;
  store.setDone(bulbs, true);
  for (var i = 0; i < more; i++) {
    final list = store.addList(['Films', 'Books', 'Trips', 'Garden', 'Gifts'][i % 5]);
    store.addTask(ListSlot(list), 'Something for later');
  }
  return store;
}

void main() {
  setUpAll(loadFonts);

  /// The Tasks page is on show.
  final onTasks = find.byType(TasksBody);

  Future<void> toTasks(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
  }

  group('the Tasks page', () {
    desktopTest('columns side by side when the window has room for them', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_board.png'));
    });

    desktopTest('names at the left, one list open, when it has not', (tester) async {
      final store = listsStore(more: 3);
      await pumpApp(tester, store, size: const Size(1100, 760));
      await toTasks(tester);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_names.png'));
    });

    phoneTest('tabs at the top on a phone, the bar at the bottom', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_phone.png'));
    });

    phoneTest('the week on a phone: the month in full, the bar', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/phone_week_bar.png'));
    });

    desktopTest('the lists beside the week', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/week_panel.png'));
    });

    desktopTest('the week without the lists under it fills the window', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/week_1536_fill.png'));
    });
  });

  final today = referenceToday;
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];
  Task named(PlannerStore store, String title) =>
      store.allTasks.firstWhere((t) => t.title == title);
  String listNamed(PlannerStore store, String title) =>
      store.lists.firstWhere((l) => l.title == title).id;

  /// Drags with the mouse from [from] to [to], resting [hold] at [via] on
  /// the way if that is given.
  Future<void> drag(WidgetTester tester, Offset from, Offset to,
      {Offset? via, Duration hold = const Duration(milliseconds: 800)}) async {
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(12, 8));
    await tester.pump();
    if (via != null) {
      await mouse.moveTo(via);
      await tester.pump();
      await tester.pump(hold);
      await tester.pumpAndSettle();
    }
    await mouse.moveTo(to);
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pumpAndSettle();
  }

  desktopTest('columns while every list has room for one, else one list at a time', (tester) async {
    // 1536 wide: six columns of at least 220 with their gaps.
    expect(TasksBody.columnsThatFit(1536), 6);
    expect(TasksBody.layoutFor(1536, 6), ListsLayout.board);
    expect(TasksBody.layoutFor(1536, 7), ListsLayout.names);
    expect(TasksBody.layoutFor(1100, 4), ListsLayout.board);
    expect(TasksBody.layoutFor(1100, 5), ListsLayout.names);
    expect(TasksBody.layoutFor(768, 3), ListsLayout.board);
    expect(TasksBody.layoutFor(768, 4), ListsLayout.names);
    // Too narrow for names beside a list.
    expect(TasksBody.layoutFor(500, 1), ListsLayout.tabs);
  });

  group('lists', () {
    desktopTest('the blank column starts a list, named where it stands', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      // Nothing of the lists is under the week any more.
      expect(find.text('Keep tasks here without a date'), findsNothing);
      await toTasks(tester);
      expect(find.text('Keep tasks here without a date'), findsOneWidget);
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'List name'), 'Reading');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect([for (final l in store.lists) l.title], ['', 'Reading']);
      expect(find.text('New list'), findsOneWidget);
    });

    desktopTest('the menu creates a list from anywhere and asks for its name', (tester) async {
      final store = seededStore();
      await pumpApp(tester, store);
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      // The Tasks page, the new list waiting for its name.
      expect(onTasks, findsOneWidget);
      expect(store.lists, hasLength(2));
      tester.testTextInput.enterText('Groceries');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.lists.last.title, 'Groceries');
    });

    desktopTest('a list is moved and deleted from its menu, and comes back on Undo',
        (tester) async {
      final store = seededStore();
      final home = store.addList('Home');
      store.addTask(ListSlot(home), 'Fix the tap');
      final bulbs = store.addTask(ListSlot(home), 'Buy bulbs')!;
      store.moveTask(bulbs, DaySlot(today));
      await pumpApp(tester, store);
      await toTasks(tester);
      await rightClick(tester, find.text('Home'));
      await tester.tap(find.text('Move left'));
      await tester.pumpAndSettle();
      expect(store.lists.first.id, home);

      await rightClick(tester, find.text('Home'));
      // The task that is on a day is not deleted with the list.
      await tester.tap(find.text('Delete list and 1 tasks'));
      await tester.pumpAndSettle();
      expect(store.list(home), isNull);
      expect(find.text('Home and 1 task deleted; 1 with a day stays in the week'),
          findsOneWidget);
      expect((store.task(bulbs)!.date, store.task(bulbs)!.listId), (today, null));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.list(home)!.title, 'Home');
      expect(titles(store.openIn(home)), ['Fix the tap', 'Buy bulbs']);
    });

    desktopTest('what is typed on a list\'s line is a task, whatever new items are set to be',
        (tester) async {
      final store = seededStore()..setSetting(Settings.newItems, 'event');
      final first = store.lists.first.id;
      await pumpApp(tester, store);
      await toTasks(tester);
      final line = find.descendant(
        of: find.byWidgetPredicate((w) => w is TaskListBody && w.slot == ListSlot(first)),
        matching: find.byType(TextField),
      );
      await tester.tap(line);
      await tester.pumpAndSettle();
      // No switch to an event on this line.
      expect(find.bySemanticsLabel(RegExp('switch to')), findsNothing);
      await tester.enterText(line, 'Book flights');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final made = named(store, 'Book flights');
      expect((made.kind, made.listId, made.date), (ItemKind.task, first, null));
    });

    desktopTest('done tasks fold away under the list; they open, and are cleared with a way back',
        (tester) async {
      final store = listsStore();
      final thesis = listNamed(store, 'Thesis');
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      expect(find.text('Outline of chapter 1'), findsNothing);
      store.setDone(named(store, 'Slides for the committee').id, true);
      await tester.pumpAndSettle();
      expect(find.text('Slides for the committee'), findsNothing);
      await tester.tap(find.text('2 done'));
      await tester.pumpAndSettle();
      expect(find.text('Slides for the committee'), findsOneWidget);
      expect(find.text('Outline of chapter 1'), findsOneWidget);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_done_open.png'));

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('2 done tasks cleared from Thesis'), findsOneWidget);
      expect(store.doneIn(thesis), isEmpty);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(titles(store.doneIn(thesis)),
          unorderedEquals(['Slides for the committee', 'Outline of chapter 1']));
    });
  });

  group('planning a task of a list', () {
    desktopTest('its menu gives it a day: it stays in its list, marked with the day',
        (tester) async {
      final store = listsStore();
      final thesis = listNamed(store, 'Thesis');
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      await rightClick(tester, find.text('Slides for the committee'));
      // A list's row plans; it has no event to turn into and no time yet.
      expect(find.text('Turn into an event'), findsNothing);
      expect(find.text('Time'), findsNothing);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_row_menu.png'));
      await tester.tap(find.text('Plan for'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomorrow'));
      await tester.pumpAndSettle();
      var slides = named(store, 'Slides for the committee');
      expect((slides.date, slides.listId), (today.addDays(1), thesis));
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(titles(store.tasksOn(today.addDays(1))), contains('Slides for the committee'));

      // And takes the day away again.
      await rightClick(tester, find.text('Slides for the committee'));
      await tester.tap(find.text('Plan for'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No day'));
      await tester.pumpAndSettle();
      slides = named(store, 'Slides for the committee');
      expect((slides.date, slides.listId), (null, thesis));
      expect(find.text('Tomorrow'), findsNothing);
    });

    desktopTest('with the setting the other way it leaves its list for the week',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Leaves its list'));
      await tester.tap(find.text('Leaves its list'));
      await tester.pumpAndSettle();
      expect(store.setting<bool>(Settings.keepInList), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await toTasks(tester);
      await rightClick(tester, find.text('Slides for the committee'));
      await tester.tap(find.text('Plan for'));
      await tester.pumpAndSettle();
      // The menu's entry (a task planned for today says "Today" as well).
      await tester.tap(find.text('Today').last);
      await tester.pumpAndSettle();
      final slides = named(store, 'Slides for the committee');
      expect((slides.date, slides.listId), (today, null));
      expect(find.text('Slides for the committee'), findsNothing);
    });

    desktopTest('dragged to another list it keeps its day; within its list it changes place',
        (tester) async {
      final store = listsStore();
      final thesis = listNamed(store, 'Thesis'), home = listNamed(store, 'Home');
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      // "Redraw figure 3" is planned for today.
      await drag(
        tester,
        tester.getCenter(find.text('Redraw figure 3')),
        tester.getCenter(find.text('Fix the bike light')) + const Offset(0, 30),
      );
      final figure = named(store, 'Redraw figure 3');
      expect((figure.listId, figure.date), (home, today));
      expect(titles(store.openIn(home)), ['Fix the bike light', 'Redraw figure 3']);

      await drag(
        tester,
        tester.getCenter(find.text('Slides for the committee')),
        tester.getCenter(find.text('Chapter 2 draft')) - const Offset(0, 14),
      );
      expect(titles(store.openIn(thesis)),
          ['Slides for the committee', 'Chapter 2 draft', 'Reply to the reviewers']);
    });

    desktopTest('held on the header\'s name of a view, a task is taken there and dropped',
        (tester) async {
      final store = listsStore();
      final first = store.lists.first.id;
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      final tuesday = today.startOfWeek().addDays(1);
      // The page turns under the held task; Tuesday's column is the second.
      await drag(
        tester,
        tester.getCenter(find.text('Renew the passport')),
        const Offset(390, 300),
        via: tester.getCenter(find.bySemanticsLabel('Week')),
      );
      expect(find.text('November 2026'), findsOneWidget);
      final passport = named(store, 'Renew the passport');
      expect((passport.date, passport.listId), (tuesday, first));

      // And from the week to the lists the same way.
      await drag(
        tester,
        tester.getCenter(find.text('Water the plants')),
        const Offset(1000, 400),
        via: tester.getCenter(find.bySemanticsLabel('Tasks')),
      );
      expect(onTasks, findsOneWidget);
      final plants = named(store, 'Water the plants');
      expect((plants.date, plants.listId), (null, listNamed(store, 'Home')));
    });

    desktopTest('beside the week: from a list onto a day, and from the day back into a list',
        (tester) async {
      final store = listsStore();
      final first = store.lists.first.id;
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(store.setting<bool>(Settings.listPanel), isTrue);
      expect(find.text('Lists'), findsOneWidget);
      final thursday = today.startOfWeek().addDays(3);
      await drag(
        tester,
        tester.getCenter(find.text('Renew the passport')),
        tester.getCenter(find.text('12 Nov')) + const Offset(0, 60),
      );
      var passport = named(store, 'Renew the passport');
      expect((passport.date, passport.listId), (thursday, first));
      // It shows twice now: on Thursday, and in its list with that day.
      expect(find.text('Renew the passport'), findsNWidgets(2));

      // Its row on the day, taken back to a list: no day any more.
      await drag(
        tester,
        tester.getCenter(find.text('Renew the passport').first),
        tester.getCenter(find.text('Fix the bike light')) + const Offset(0, 30),
      );
      passport = named(store, 'Renew the passport');
      expect((passport.date, passport.listId), (null, listNamed(store, 'Home')));

      // A folded list takes what is dropped on its name.
      await tester.tap(find.text('Thesis'));
      await tester.pumpAndSettle();
      expect(find.text('Chapter 2 draft'), findsNothing);
      await drag(
        tester,
        tester.getCenter(find.text('9:30 Call dentist')),
        tester.getCenter(find.text('Thesis')),
        hold: Duration.zero,
      );
      expect(named(store, 'Call dentist').listId, listNamed(store, 'Thesis'));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(find.text('Lists'), findsNothing);
    });

    desktopTest('one list at a time: a name takes a dropped task, and opens when held over',
        (tester) async {
      final store = listsStore(more: 3);
      final home = listNamed(store, 'Home');
      await pumpApp(tester, store, size: const Size(1100, 760));
      await toTasks(tester);
      // The first list is open.
      await drag(
        tester,
        tester.getCenter(find.text('Renew the passport')),
        tester.getCenter(find.text('Home')),
        hold: Duration.zero,
      );
      expect(named(store, 'Renew the passport').listId, home);
      // Held over a name, that list opens under the task.
      await drag(
        tester,
        tester.getCenter(find.text('Call the bank')),
        const Offset(600, 300),
        via: tester.getCenter(find.text('Home')),
      );
      expect(find.bySemanticsLabel('Rename Home'), findsOneWidget);
      expect(named(store, 'Call the bank').listId, home);

      // The arrow keys turn to the neighbouring lists.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Rename Films'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Rename Thesis'), findsOneWidget);
    });
  });

  group('on a phone', () {
    const phone = Size(393, 851);

    phoneTest('the bar leads to the tasks and back, and so does going back', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: phone);
      expect(find.text('November'), findsOneWidget);
      expect(find.text('2026 · W46'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(find.text('8 to do'), findsOneWidget);
      expect(find.text('Renew the passport'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('November'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Week'));
      await tester.pumpAndSettle();
      expect(find.text('November'), findsOneWidget);
    });

    phoneTest('the names are tabs, a swipe turns to the next list, a new one is named in a card',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: phone);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('To do, 3 to do, open'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Home, 1 to do'));
      await tester.pumpAndSettle();
      expect(find.text('Fix the bike light'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Thesis, 4 to do, open'), findsOneWidget);
      expect(find.text('Chapter 2 draft'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('New list'));
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(4));
      await tester.enterText(find.widgetWithText(TextField, 'List name'), 'Films');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.lists.last.title, 'Films');
      expect(find.bySemanticsLabel('Films, 0 to do, open'), findsOneWidget);

      // The open list's menu is at the end of the row of names.
      await tester.tap(find.bySemanticsLabel('List options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete list'));
      await tester.pumpAndSettle();
      expect(store.lists, hasLength(3));
    });

    phoneTest('a long press anywhere on a row picks the task up; let go, it opens its menu',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: phone);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      // Beside the short title, where the row is blank.
      final row = tester.getRect(find.text('Call the bank'));
      final finger = await tester.startGesture(Offset(row.right + 120, row.center.dy),
          kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 900));
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.text('Plan for'), findsOneWidget);
      expect(find.bySemanticsLabel('Add subtask'), findsNothing);
      await tester.tap(find.text('Plan for'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomorrow'));
      await tester.pumpAndSettle();
      expect(named(store, 'Call the bank').date, today.addDays(1));

      // Held on, and carried to the other tab of the bar, it is taken to
      // the week, where it is dropped on a day.
      final from = tester.getCenter(find.text('Renew the passport'));
      final carry = await tester.startGesture(from, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 700));
      await carry.moveBy(const Offset(10, 30));
      await tester.pump();
      await carry.moveTo(tester.getCenter(find.bySemanticsLabel('Week')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.text('November'), findsOneWidget);
      await carry.moveTo(tester.getCenter(find.text('Water the plants')) + const Offset(0, 40));
      await tester.pumpAndSettle();
      await carry.up();
      await tester.pumpAndSettle();
      final passport = named(store, 'Renew the passport');
      expect((passport.date, passport.listId), (today, store.lists.first.id));
    });

    phoneTest('a task typed in a list gets a note and a colour from the bar, but no time',
        (tester) async {
      final store = listsStore();
      final first = store.lists.first.id;
      await pumpApp(tester, store, size: phone);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      final line = find.descendant(
        of: find.byWidgetPredicate((w) => w is TaskListBody && w.slot == ListSlot(first)),
        matching: find.byType(TextField),
      );
      await tester.tap(line);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Time'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('tap to make it')), findsNothing);
      expect(find.bySemanticsLabel('Place'), findsOneWidget);
      await tester.enterText(line, 'Book flights');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(named(store, 'Book flights').listId, first);
    });
  });

  group('a deadline', () {
    desktopTest('is set in the card; a flag marks the task, and the day it is due',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      await tester.tap(find.text('Slides for the committee'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Deadline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('14'));
      await tester.pumpAndSettle();
      expect(named(store, 'Slides for the committee').due, today.addDays(1));
      expect(find.text('Due Sat, 14 Nov 2026'), findsOneWidget);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/tasks_card_deadline.png'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Due tomorrow'), findsOneWidget);
      // One that has passed says so.
      expect(find.bySemanticsLabel('Due 11 nov, passed'), findsOneWidget);

      // In the week, the day it is due carries a flag, though the task is
      // not planned for that day.
      await toTasks(tester);
      await tester.tap(find.bySemanticsLabel('One task is due 14 Nov'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Slides for the committee'));
      await tester.pumpAndSettle();
      expect(find.text('Due Sat, 14 Nov 2026'), findsOneWidget);
    });

    desktopTest('the menu sets and removes one', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await rightClick(tester, find.text('Water the plants'));
      await tester.tap(find.text('Deadline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').due, today.addDays(7));
      await rightClick(tester, find.text('Water the plants'));
      expect(find.text('Change deadline'), findsOneWidget);
      await tester.tap(find.text('No deadline'));
      await tester.pumpAndSettle();
      expect(named(store, 'Water the plants').due, isNull);
    });
  });

  group('the card', () {
    desktopTest('says which list a task is in, and puts it into another or none',
        (tester) async {
      final store = listsStore();
      final thesis = listNamed(store, 'Thesis'), home = listNamed(store, 'Home');
      await pumpApp(tester, store, size: const Size(1536, 790));
      // A task of the week that is in no list.
      await tester.tap(find.text('Water the plants'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Put into a list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      var plants = named(store, 'Water the plants');
      expect((plants.listId, plants.date), (home, today));
      await tester.tap(find.bySemanticsLabel('List, Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No list'));
      await tester.pumpAndSettle();
      plants = named(store, 'Water the plants');
      expect((plants.listId, plants.date), (null, today));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // A list's task planned for today: its card can take the day away.
      await tester.tap(find.text('Redraw figure 3'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('List, Thesis'), findsOneWidget);
      await tester.tap(find.text('Fri, 13 Nov 2026'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No day'));
      await tester.pumpAndSettle();
      final figure = named(store, 'Redraw figure 3');
      expect((figure.listId, figure.date), (thesis, null));
      expect(find.bySemanticsLabel('Plan for a day, No day'), findsOneWidget);
    });
  });

  group('the header', () {
    /// Where the three names of the switch and the buttons after it stand.
    List<Offset> places(WidgetTester tester) => [
          for (final label in ['Week', 'Month', 'Tasks', 'New event (N)', 'Menu'])
            tester.getCenter(find.bySemanticsLabel(label)),
        ];

    bool selected(WidgetTester tester, String label) => tester
        .getSemantics(find.bySemanticsLabel(label))
        .flagsCollection
        .isSelected
        .toBoolOrNull() ==
        true;

    desktopTest('names the three views, marks the one on show, and leads to each',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      expect(selected(tester, 'Week'), isTrue);
      expect(selected(tester, 'Tasks'), isFalse);
      final before = places(tester);

      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(onTasks, findsOneWidget);
      expect(selected(tester, 'Tasks'), isTrue);
      // Nothing has moved: the next click needs no aiming.
      expect(places(tester), before);

      await tester.tap(find.bySemanticsLabel('Month'));
      await tester.pumpAndSettle();
      expect(onTasks, findsNothing);
      expect(store.setting<String>(Settings.view), 'month');
      expect(selected(tester, 'Month'), isTrue);
      expect(places(tester), before);

      await tester.tap(find.bySemanticsLabel('Week'));
      await tester.pumpAndSettle();
      expect(store.setting<String>(Settings.view), 'week');
      expect(places(tester), before);
    });

    desktopTest('the name of the view on show leads back to today', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.tap(find.bySemanticsLabel('Next'));
      await tester.pumpAndSettle();
      expect(find.text('W47'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Week'));
      await tester.pumpAndSettle();
      expect(find.text('W46'), findsOneWidget);
    });

    desktopTest('one button shows the lists beside the week, one on the panel hides them',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      final show = find.bySemanticsLabel('Show the lists beside the week (P)');
      final hide = find.bySemanticsLabel('Hide the lists (P)');
      expect((show.evaluate().length, hide.evaluate().length), (1, 0));

      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.byType(ListPanel), findsOneWidget);
      // The panel has the one button that shuts it; the header has none
      // for it now, and the way to the Tasks page is said once, by name.
      expect((show.evaluate().length, hide.evaluate().length), (0, 1));
      expect(find.bySemanticsLabel('Tasks'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Tasks page')), findsNothing);
      expect(
        find.descendant(of: find.byType(ListPanel), matching: find.byType(AppButton)),
        findsOneWidget,
      );

      await tester.tap(hide);
      await tester.pumpAndSettle();
      expect(find.byType(ListPanel), findsNothing);
      expect((show.evaluate().length, hide.evaluate().length), (1, 0));
      // Neither on the month nor on the Tasks page.
      await tester.tap(find.bySemanticsLabel('Month'));
      await tester.pumpAndSettle();
      expect(show, findsNothing);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(show, findsNothing);
    });

    desktopTest('a button that is only an icon says what it does when the pointer rests on it',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      const hint = 'Show the lists beside the week (P)';
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 400));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.bySemanticsLabel(hint)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(hint), findsNothing, reason: 'not at once');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text(hint), findsOneWidget);
      // Inside the window, under the button.
      final label = tester.getRect(find.text(hint));
      expect(label.top, greaterThan(tester.getRect(find.bySemanticsLabel(hint)).bottom));
      expect(label.right, lessThan(1536));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/header_hint.png'));
      // Gone when the pointer moves on; another button says its own.
      await mouse.moveTo(tester.getCenter(find.bySemanticsLabel('New event (N)')));
      await tester.pump();
      expect(find.text(hint), findsNothing);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text('New event (N)'), findsOneWidget);
      // Pressed, a button does its thing and says no more.
      await tester.tap(find.bySemanticsLabel('New event (N)'));
      await tester.pumpAndSettle();
      expect(find.text('New event (N)'), findsNothing);
    });

    phoneTest('on a phone the header\'s arrows turn the lists too', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(find.text('Fix the bike light'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Next list'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Next list'));
      await tester.pumpAndSettle();
      expect(store.setting<String?>(Settings.openList), store.lists[2].id);
      expect(find.text('Fix the bike light'), findsOneWidget);
    });

    desktopTest('on the Tasks page the arrows turn to the next list where one shows at a time',
        (tester) async {
      // Seven lists in a window with room for six columns: one list open.
      final store = listsStore(more: 4);
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      AppButton arrow(String label) => tester.widget<AppButton>(
          find.ancestor(of: find.bySemanticsLabel(label), matching: find.byType(AppButton)));
      expect(arrow('Previous list').onTap, isNull, reason: 'the first list is open');
      await tester.tap(find.bySemanticsLabel('Next list'));
      await tester.pumpAndSettle();
      expect(store.setting<String?>(Settings.openList), store.lists[1].id);
      await tester.tap(find.bySemanticsLabel('Previous list'));
      await tester.pumpAndSettle();
      expect(store.setting<String?>(Settings.openList), store.lists[0].id);
    });

    desktopTest('where every list shows, the arrows have nothing to turn', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      for (final label in ['Previous list', 'Next list']) {
        final arrow = tester.widget<AppButton>(
            find.ancestor(of: find.bySemanticsLabel(label), matching: find.byType(AppButton)));
        expect(arrow.onTap, isNull);
      }
    });

    desktopTest('a tight window shows the views by icon, the tightest as one button',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(620, 760));
      // By icon: still three, still by name for a screen reader.
      expect(find.text('Month'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      expect(onTasks, findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Week'));
      await tester.pumpAndSettle();
      expect(onTasks, findsNothing);

      await pumpApp(tester, store, size: const Size(440, 760));
      expect(find.bySemanticsLabel('Month'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Tasks (L)'));
      await tester.pumpAndSettle();
      expect(onTasks, findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Back to the week (L)'));
      await tester.pumpAndSettle();
      expect(onTasks, findsNothing);
      expect(tester.takeException(), isNull);
    });

    phoneTest('a phone has the bar for the views; its header adds events and turns weeks',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(393, 851));
      expect(find.bySemanticsLabel('Month'), findsNothing);
      expect(find.bySemanticsLabel('New event'), findsOneWidget);
      expect(find.bySemanticsLabel('Next'), findsOneWidget);
    });
  });

  group('finding the way', () {
    desktopTest('search leads to a task in its list', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'bike');
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(onTasks, findsOneWidget);
      expect(find.text('Fix the bike light'), findsOneWidget);
    });

    desktopTest('after Escape on a line that was typed on, the shortcuts work at once',
        (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      final line = find.descendant(
        of: find.byWidgetPredicate((w) => w is TaskListBody && w.slot == DaySlot(today)),
        matching: find.byType(TextField),
      );
      await tester.tap(line);
      await tester.pumpAndSettle();
      await tester.enterText(line, 'Typed and kept');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await toTasks(tester);
      expect(onTasks, findsOneWidget);
    });

    desktopTest('L turns to the tasks and back; T and M lead to the planner', (tester) async {
      final store = listsStore();
      await pumpApp(tester, store, size: const Size(1536, 790));
      await toTasks(tester);
      expect(onTasks, findsOneWidget);
      // The arrows are for lists on this page, not for weeks.
      expect(find.bySemanticsLabel('Next'), findsNothing);
      expect(find.bySemanticsLabel('Next list'), findsOneWidget);
      await toTasks(tester);
      expect(find.text('November 2026'), findsOneWidget);
      await toTasks(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(store.setting<String>(Settings.view), 'month');
      expect(find.text('November 2026'), findsOneWidget);
      await toTasks(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pumpAndSettle();
      expect(find.text('November 2026'), findsOneWidget);
    });
  });
}
