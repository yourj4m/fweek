import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/export.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/data/recurrence.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_engine.dart';

/// The lists of the Tasks page: tasks that have no day yet, tasks that were
/// given one and stay in their list, and deadlines.
void main() {
  var today = Day(2026, 11, 13); // Friday
  var clock = 1000;
  PlannerStore planner() =>
      PlannerStore(PlannerDatabase.inMemory(), today: () => today, now: () => clock++);

  setUp(() {
    today = Day(2026, 11, 13);
    clock = 1000;
  });

  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  group('a task from a list, given a day', () {
    test('stays in its list too and shows in both places', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      store.addTask(ListSlot(thesis), 'Outline');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.addTask(ListSlot(thesis), 'Slides');
      store.addTask(DaySlot(today), 'Water the plants');

      store.moveTask(figure, DaySlot(today));
      final task = store.task(figure)!;
      expect((task.listId, task.date), (thesis, today));
      // On its day, after what was there; in its list, where it stood.
      expect(titles(store.tasksOn(today)), ['Water the plants', 'Redraw figure 3']);
      expect(titles(store.openIn(thesis)), ['Outline', 'Redraw figure 3', 'Slides']);

      // Each place keeps an order of its own.
      store.moveTask(figure, DaySlot(today), index: 0);
      expect(titles(store.tasksOn(today)), ['Redraw figure 3', 'Water the plants']);
      expect(titles(store.openIn(thesis)), ['Outline', 'Redraw figure 3', 'Slides']);
      store.moveTask(figure, ListSlot(thesis), index: 2, keepDay: true);
      expect(titles(store.openIn(thesis)), ['Outline', 'Slides', 'Redraw figure 3']);
      expect(titles(store.tasksOn(today)), ['Redraw figure 3', 'Water the plants']);

      // Ticked in one place, it is ticked in the other: it is one task.
      store.setDone(figure, true);
      expect(store.tasksOn(today).first.done, isTrue);
      expect(titles(store.openIn(thesis)), ['Outline', 'Slides']);
      expect(titles(store.doneIn(thesis)), ['Redraw figure 3']);
    });

    test('leaves its list when that is the setting', () {
      final store = planner();
      store.setSetting(Settings.keepInList, false);
      final thesis = store.addList('Thesis');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.moveTask(figure, DaySlot(today));
      expect((store.task(figure)!.listId, store.task(figure)!.date), (null, today));
      expect(store.openIn(thesis), isEmpty);
      expect(titles(store.tasksOn(today)), ['Redraw figure 3']);
    });

    test('one that already is in both stays in both when moved to another day', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.moveTask(figure, DaySlot(today));
      // The setting is about the moment a task is first given a day.
      store.setSetting(Settings.keepInList, false);
      store.moveTask(figure, DaySlot(today.addDays(3)));
      expect((store.task(figure)!.listId, store.task(figure)!.date), (thesis, today.addDays(3)));
    });

    test('can lose its day again, and is in its list only', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.moveTask(figure, DaySlot(today));
      store.unplan(figure);
      expect((store.task(figure)!.listId, store.task(figure)!.date), (thesis, null));
      expect(store.tasksOn(today), isEmpty);
      // A task that is in no list has to stay on its day.
      final plants = store.addTask(DaySlot(today), 'Water the plants')!;
      store.unplan(plants);
      expect(store.task(plants)!.date, today);
    });

    test('moves along when it is left unfinished, and can go back ticked', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.moveTask(figure, DaySlot(today));
      final from = today;
      today = today.addDays(1);
      expect(store.rollOver(), 1);
      expect((store.task(figure)!.date, store.task(figure)!.listId), (today, thesis));
      store.doneWhereItWas(figure);
      final back = store.task(figure)!;
      expect((back.date, back.listId, back.done), (from, thesis, true));
    });
  });

  group('between the week and the lists', () {
    test('a task taken from its day into a list has no day any more', () {
      final store = planner();
      final home = store.addList('Home');
      final bulbs = store.addTask(DaySlot(today), 'Buy bulbs')!;
      store.updateTask(bulbs, time: () => 600);
      store.moveTask(bulbs, ListSlot(home));
      expect((store.task(bulbs)!.listId, store.task(bulbs)!.date), (home, null));
      expect(store.tasksOn(today), isEmpty);
    });

    test('from list to list a task keeps the day it is planned for', () {
      final store = planner();
      final thesis = store.addList('Thesis'), home = store.addList('Home');
      final figure = store.addTask(ListSlot(thesis), 'Redraw figure 3')!;
      store.moveTask(figure, DaySlot(today));
      store.moveTask(figure, ListSlot(home), keepDay: true);
      expect((store.task(figure)!.listId, store.task(figure)!.date), (home, today));
      expect(store.openIn(thesis), isEmpty);
    });

    test('a task is put into a list, and taken out, without touching its day', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      store.addTask(ListSlot(thesis), 'Outline');
      final plants = store.addTask(DaySlot(today), 'Water the plants')!;
      store.setList(plants, thesis);
      expect((store.task(plants)!.listId, store.task(plants)!.date), (thesis, today));
      expect(titles(store.openIn(thesis)), ['Outline', 'Water the plants']);
      store.setList(plants, null);
      expect((store.task(plants)!.listId, store.task(plants)!.date), (null, today));
      // Without a day it has to be in some list.
      final outline = store.openIn(thesis).single;
      store.setList(outline.id, null);
      expect(store.task(outline.id)!.listId, thesis);
    });

    test('what repeats is in no list', () {
      final store = planner();
      final home = store.addList('Home');
      final plants = store.addTask(ListSlot(home), 'Water the plants')!;
      // Without a day there is nothing to repeat.
      store.setRecurrence(plants, Recurrence.daily);
      expect(store.task(plants)!.repeats, isFalse);
      store.moveTask(plants, DaySlot(today));
      store.setRecurrence(plants, Recurrence.daily);
      expect((store.task(plants)!.repeats, store.task(plants)!.listId), (true, null));
      store.setList(plants, home);
      expect(store.task(plants)!.listId, isNull);
    });
  });

  group('a list', () {
    test('holds tasks, whatever new items are set to be', () {
      final store = planner();
      store.setSetting(Settings.newItems, 'event');
      final home = store.addList('Home');
      final id = store.addTask(ListSlot(home), 'Fix the bike light', kind: ItemKind.event)!;
      expect(store.task(id)!.kind, ItemKind.task);
      // A copy of an event that goes to a list is a task there.
      final seminar = store.addTask(DaySlot(today), 'Seminar')!;
      expect(store.task(seminar)!.kind, ItemKind.event);
      expect(store.task(store.copyTask(seminar, ListSlot(home)))!.kind, ItemKind.task);
    });

    test('keeps its done tasks apart, the one ticked last first, and clears them', () {
      final store = planner();
      final home = store.addList('Home');
      final a = store.addTask(ListSlot(home), 'a')!;
      final b = store.addTask(ListSlot(home), 'b')!;
      final c = store.addTask(ListSlot(home), 'c')!;
      store.addTask(ListSlot(home), 'd');
      store.moveTask(c, DaySlot(today));
      store.setDone(a, true);
      store.setDone(c, true);
      store.setDone(b, true);
      expect(titles(store.openIn(home)), ['d']);
      expect(titles(store.doneIn(home)), ['b', 'c', 'a']);
      expect(titles(store.tasksIn(home)), ['d', 'b', 'c', 'a']);
      // The settings for done tasks are about the days of the week.
      store.setSetting(Settings.hideDone, true);
      expect(titles(store.doneIn(home)), ['b', 'c', 'a']);
      store.setSetting(Settings.hideDone, false);

      // Cleared: gone, except the one that is on a day, which stays there.
      final cleared = store.clearDone(home);
      expect(cleared.deleted.toSet(), {a, b});
      expect(cleared.detached, [c]);
      expect(store.doneIn(home), isEmpty);
      expect((store.task(a), store.task(b)), (null, null));
      expect((store.task(c)!.date, store.task(c)!.listId), (today, null));
      store.restoreList(cleared);
      expect(titles(store.doneIn(home)), ['b', 'c', 'a']);
      expect(store.task(c)!.listId, home);
    });

    test('deleted takes its tasks without a day along; those on a day stay there', () {
      final store = planner();
      final home = store.addList('Home');
      store.addTask(ListSlot(home), 'Fix the bike light');
      final bulbs = store.addTask(ListSlot(home), 'Buy bulbs')!;
      store.moveTask(bulbs, DaySlot(today));
      final removal = store.deleteList(home);
      expect(store.list(home), isNull);
      expect(removal.deleted, hasLength(1));
      expect(removal.detached, [bulbs]);
      expect((store.task(bulbs)!.date, store.task(bulbs)!.listId), (today, null));
      store.restoreList(removal);
      expect(titles(store.openIn(home)), ['Fix the bike light', 'Buy bulbs']);
    });

    test('goes by its title, or by a stand-in while it has none', () {
      final store = planner();
      final second = store.addList();
      final films = store.addList('Films');
      expect(
        [for (final l in store.lists) store.listName(l.id)],
        ['To do', 'Untitled list', 'Films'],
      );
      expect((store.listName(second), store.listName(films)), ('Untitled list', 'Films'));
    });

    test('counts what is still to do in all of them', () {
      final store = planner();
      final home = store.addList('Home');
      store.addTask(ListSlot(store.lists.first.id), 'a');
      final b = store.addTask(ListSlot(home), 'b')!;
      store.addTask(ListSlot(home), 'c');
      expect(store.openInLists, 3);
      store.setDone(b, true);
      expect(store.openInLists, 2);
    });
  });

  group('a deadline', () {
    test('is a day of its own, apart from the day a task is planned for', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      final draft = store.addTask(ListSlot(thesis), 'Chapter 2 draft')!;
      store.updateTask(draft, due: () => today.addDays(7));
      expect((store.task(draft)!.due, store.task(draft)!.date), (today.addDays(7), null));
      store.moveTask(draft, DaySlot(today.addDays(2)));
      expect((store.task(draft)!.due, store.task(draft)!.date),
          (today.addDays(7), today.addDays(2)));
      expect(titles(store.dueOn(today.addDays(7))), ['Chapter 2 draft']);
      expect(store.dueOn(today.addDays(2)), isEmpty);
      store.updateTask(draft, due: () => null);
      expect(store.task(draft)!.due, isNull);
      expect(store.dueOn(today.addDays(7)), isEmpty);
    });

    test('has passed the day after, unless the task is done', () {
      final store = planner();
      final id = store.addTask(DaySlot(today), 'Tax form')!;
      store.updateTask(id, due: () => today);
      expect(store.task(id)!.overdueAt(today), isFalse);
      expect(store.task(id)!.overdueAt(today.addDays(1)), isTrue);
      store.setDone(id, true);
      expect(store.task(id)!.overdueAt(today.addDays(1)), isFalse);
      // What is done is no longer due.
      expect(store.dueOn(today), isEmpty);
    });

    test('goes along with a copy, a backup, and to the other formats', () {
      final store = planner();
      final thesis = store.addList('Thesis');
      final draft = store.addTask(ListSlot(thesis), 'Chapter 2 draft')!;
      store.updateTask(draft, due: () => Day(2026, 11, 27));
      store.moveTask(draft, DaySlot(Day(2026, 11, 16)));
      expect(store.task(store.copyTask(draft, ListSlot(thesis)))!.due, Day(2026, 11, 27));

      final backup = Export.backup(store);
      expect(jsonDecode(backup)['version'], 6);
      final copy = planner();
      Export.restore(copy, backup);
      final restored = copy.task(draft)!;
      expect((restored.due, restored.date, restored.listId),
          (Day(2026, 11, 27), Day(2026, 11, 16), thesis));
      expect(titles(copy.openIn(thesis)), titles(store.openIn(thesis)));

      final csv = const LineSplitter().convert(Export.csv(store).replaceAll('\r\n', '\n'));
      expect(csv.first, endsWith(',due,last_day'));
      expect(csv[1], '2026-11-16,Thesis,,Chapter 2 draft,no,,,,,,task,,2026-11-27,');
      expect(Export.text(store), contains('    # Thesis\n    ! due 2026-11-27'));
      final ics = Export.ics(store);
      expect(ics, contains('DUE;VALUE=DATE:20261127'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261116'));
    });
  });

  test('all of it travels between devices', () async {
    final desk = planner(), phone = planner();
    final folder = MemoryStorage();
    Future<void> sync(PlannerStore store) => SyncEngine(store, folder, folder: 'fweek').sync();
    final thesis = desk.addList('Thesis');
    desk.addTask(ListSlot(thesis), 'Outline');
    final figure = desk.addTask(ListSlot(thesis), 'Redraw figure 3')!;
    desk.addTask(ListSlot(thesis), 'Slides');
    desk.moveTask(figure, DaySlot(today));
    desk.updateTask(figure, due: () => today.addDays(7));
    desk.setSetting(Settings.keepInList, false);
    await sync(desk);
    await sync(phone);
    final there = phone.task(figure)!;
    expect((there.listId, there.date, there.due), (thesis, today, today.addDays(7)));
    expect(titles(phone.openIn(thesis)), ['Outline', 'Redraw figure 3', 'Slides']);
    expect(phone.setting<bool>(Settings.keepInList), isFalse);
    // Which list is open, and the panel beside the week, are each device's own.
    desk.setSetting(Settings.listPanel, true);
    phone.moveTask(figure, ListSlot(thesis), index: 0, keepDay: true);
    await sync(phone);
    await sync(desk);
    expect(titles(desk.openIn(thesis)), ['Redraw figure 3', 'Outline', 'Slides']);
    expect(phone.setting<bool>(Settings.listPanel), isFalse);
  });
}
