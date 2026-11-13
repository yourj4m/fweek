import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/data/recurrence.dart';

void main() {
  late PlannerDatabase db;
  late PlannerStore store;
  var today = Day(2026, 11, 13); // Friday
  final monday = Day(2026, 11, 9);

  setUp(() {
    today = Day(2026, 11, 13);
    db = PlannerDatabase.inMemory();
    store = PlannerStore(db, today: () => today, now: () => 1000);
  });
  tearDown(() => db.close());

  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  group('tasks', () {
    test('are added in order and blank titles are ignored', () {
      store.addTask(DaySlot(monday), 'one');
      store.addTask(DaySlot(monday), '  two  ');
      expect(store.addTask(DaySlot(monday), '   '), isNull);
      store.addTask(DaySlot(monday), 'zero', index: 0);
      expect(titles(store.tasksOn(monday)), ['zero', 'one', 'two']);
    });

    test('survive reopening the database', () {
      final id = store.addTask(DaySlot(monday), 'persist me')!;
      store.updateTask(
        id,
        note: 'details',
        color: () => 'yellow',
        time: () => 9 * 60 + 30,
        subtasks: const [Subtask(id: 's1', text: 'step', important: true)],
        reminder: () => DateTime(2026, 11, 9, 8, 45),
      );
      store.setDone(id, true);
      final reopened = PlannerStore(db, today: () => today);
      final task = reopened.task(id)!;
      expect(task.title, 'persist me');
      expect(task.note, 'details');
      expect(task.color, 'yellow');
      expect(task.time, 570);
      expect(task.done, isTrue);
      expect(task.subtasks.single.important, isTrue);
      expect(task.reminder, DateTime(2026, 11, 9, 8, 45));
    });

    test('move between days and lists at a chosen position', () {
      final a = store.addTask(DaySlot(monday), 'a')!;
      store.addTask(DaySlot(monday), 'b');
      final tuesday = monday.addDays(1);
      store.addTask(DaySlot(tuesday), 'x');
      store.addTask(DaySlot(tuesday), 'y');
      store.moveTask(a, DaySlot(tuesday), index: 1);
      expect(titles(store.tasksOn(monday)), ['b']);
      expect(titles(store.tasksOn(tuesday)), ['x', 'a', 'y']);
      // Reordering within the same day.
      store.moveTask(a, DaySlot(tuesday), index: 2);
      expect(titles(store.tasksOn(tuesday)), ['x', 'y', 'a']);
      store.moveTask(a, DaySlot(tuesday), index: 0);
      expect(titles(store.tasksOn(tuesday)), ['a', 'x', 'y']);
      // To Someday and back.
      final list = store.lists.single.id;
      store.moveTask(a, ListSlot(list));
      expect(titles(store.tasksIn(list)), ['a']);
      expect(store.task(a)!.date, isNull);
    });

    test('copy is independent, open and does not repeat', () {
      final id = store.addTask(DaySlot(monday), 'template')!;
      store.updateTask(id, subtasks: const [Subtask(id: 's', text: 'x', done: true)]);
      store.setRecurrence(id, Recurrence.daily);
      store.setDone('$id@${monday.addDays(1).iso}', true);
      final copy = store.copyTask(id, DaySlot(today));
      final copied = store.task(copy)!;
      expect(copied.recurrence, isNull);
      expect(copied.done, isFalse);
      expect(copied.subtasks.single.done, isFalse);
      store.updateTask(copy, title: 'changed');
      expect(store.task(id)!.title, 'template');
    });

    test('delete and restore', () {
      final id = store.addTask(DaySlot(monday), 'gone')!;
      store.deleteTask(id);
      expect(store.tasksOn(monday), isEmpty);
      expect(store.task(id), isNull);
      store.restoreTask(id);
      expect(titles(store.tasksOn(monday)), ['gone']);
    });

    test('done tasks can be sorted down or hidden', () {
      final a = store.addTask(DaySlot(monday), 'a')!;
      store.addTask(DaySlot(monday), 'b');
      store.setDone(a, true);
      expect(titles(store.tasksOn(monday)), ['a', 'b']);
      store.setSetting(Settings.sortDoneDown, true);
      expect(titles(store.tasksOn(monday)), ['b', 'a']);
      store.setSetting(Settings.hideDone, true);
      expect(titles(store.tasksOn(monday)), ['b']);
    });
  });

  group('repeating tasks', () {
    test('show on every matching day', () {
      final id = store.addTask(DaySlot(monday), 'standup')!;
      store.setRecurrence(id, Recurrence.weekdaysOnly);
      final week = store.tasksBetween(monday, monday.addDays(6));
      expect(week.keys.map((d) => d.weekday).toList()..sort(), [1, 2, 3, 4, 5]);
      expect(store.tasksOn(monday.addDays(7)).single.isOccurrence, isTrue);
    });

    test('completing one occurrence leaves the others open', () {
      final id = store.addTask(DaySlot(monday), 'water plants')!;
      store.setRecurrence(id, Recurrence.daily);
      final wednesday = monday.addDays(2);
      store.setDone('$id@${wednesday.iso}', true);
      expect(store.tasksOn(wednesday).single.done, isTrue);
      expect(store.tasksOn(wednesday).single.isOccurrence, isFalse);
      expect(store.tasksOn(monday.addDays(1)).single.done, isFalse);
      expect(store.tasksOn(monday.addDays(3)).single.done, isFalse);
      // Exactly one task that day: the split-off one replaces the occurrence.
      expect(store.tasksOn(wednesday), hasLength(1));
    });

    test('editing text changes the whole series, moving changes one day', () {
      final id = store.addTask(DaySlot(monday), 'run')!;
      store.setRecurrence(id, Recurrence.daily);
      final tuesday = monday.addDays(1), wednesday = monday.addDays(2);
      store.updateTask('$id@${tuesday.iso}', title: 'run 5k');
      expect(titles(store.tasksOn(wednesday)), ['run 5k']);
      store.moveTask('$id@${tuesday.iso}', DaySlot(wednesday));
      expect(store.tasksOn(tuesday), isEmpty);
      expect(store.tasksOn(wednesday), hasLength(2));
    });

    test('deleting one occurrence or the whole series', () {
      final id = store.addTask(DaySlot(monday), 'report')!;
      store.setRecurrence(id, Recurrence.daily);
      final tuesday = monday.addDays(1);
      store.deleteTask('$id@${tuesday.iso}');
      expect(store.tasksOn(tuesday), isEmpty);
      expect(store.tasksOn(monday.addDays(2)), hasLength(1));
      store.deleteTask('$id@${monday.addDays(2).iso}', wholeSeries: true);
      expect(store.tasksBetween(monday, monday.addDays(30)), isEmpty);
    });

    test('"never" on a later occurrence ends the series there', () {
      final id = store.addTask(DaySlot(monday), 'course')!;
      store.setRecurrence(id, Recurrence.daily);
      final thursday = monday.addDays(3);
      final kept = store.setRecurrence('$id@${thursday.iso}', null);
      expect(store.task(kept)!.recurrence, isNull);
      expect(store.tasksOn(thursday), hasLength(1));
      expect(store.tasksOn(monday.addDays(2)), hasLength(1));
      expect(store.tasksOn(monday.addDays(4)), isEmpty);
    });

    test('a reminder follows each occurrence', () {
      final id = store.addTask(DaySlot(monday), 'pills')!;
      store.setRecurrence(id, Recurrence.daily);
      final wednesday = monday.addDays(2);
      // Set from Wednesday's occurrence: stored relative to the first day.
      store.updateTask('$id@${wednesday.iso}',
          reminder: () => DateTime(2026, 11, 11, 7, 30));
      expect(store.task(id)!.reminder, DateTime(2026, 11, 9, 7, 30));
      expect(store.tasksOn(monday.addDays(4)).single.reminder,
          DateTime(2026, 11, 13, 7, 30));
    });
  });

  group('rollover', () {
    test('moves unfinished past tasks to the top of today, once a day', () {
      store.addTask(DaySlot(monday), 'old 1');
      final done = store.addTask(DaySlot(monday), 'old done')!;
      store.setDone(done, true);
      store.addTask(DaySlot(monday.addDays(1)), 'old 2');
      store.addTask(DaySlot(today), 'today');
      store.addTask(DaySlot(today.addDays(1)), 'tomorrow');
      final repeating = store.addTask(DaySlot(monday), 'daily')!;
      store.setRecurrence(repeating, Recurrence.weekly);

      expect(store.rollOver(), 2);
      expect(titles(store.tasksOn(today)), ['old 1', 'old 2', 'today']);
      expect(titles(store.tasksOn(monday)), ['old done', 'daily']);
      expect(titles(store.tasksOn(today.addDays(1))), ['tomorrow']);
      // Second run the same day does nothing, even with new overdue tasks.
      store.addTask(DaySlot(monday), 'added late');
      expect(store.rollOver(), 0);
      today = today.addDays(1);
      expect(store.rollOver(), 4);
    });

    test('works when today is still empty', () {
      store.addTask(DaySlot(monday), 'old');
      expect(store.rollOver(), 1);
      expect(titles(store.tasksOn(today)), ['old']);
    });

    test('on a brand-new planner there is nothing to move', () {
      expect(store.rollOver(), 0);
    });

    test('does nothing when switched off', () {
      store.setSetting(Settings.rollover, false);
      store.addTask(DaySlot(monday), 'old');
      expect(store.rollOver(), 0);
      expect(titles(store.tasksOn(monday)), ['old']);
    });
  });

  group('lists and search', () {
    test('a default list exists and deleting the last one recreates it', () {
      expect(store.lists, hasLength(1));
      final second = store.addList('Books');
      store.addTask(ListSlot(second), 'Dune');
      expect(store.lists.map((l) => l.title), ['', 'Books']);
      store.deleteList(second);
      expect(store.search('dune'), isEmpty);
      store.deleteList(store.lists.single.id);
      expect(store.lists, hasLength(1));
    });

    test('search matches title, note and subtasks, and filters by colour', () {
      final a = store.addTask(DaySlot(monday), 'Call Anna')!;
      final b = store.addTask(DaySlot(today), 'Groceries')!;
      store.updateTask(b, note: 'anna likes oat milk', color: () => 'yellow');
      final c = store.addTask(ListSlot(store.lists.single.id), 'Trip')!;
      store.updateTask(c, subtasks: const [Subtask(id: 's', text: 'email ANNA')]);
      expect(store.search('anna').map((t) => t.id), [b, a, c]);
      expect(store.search('anna', color: 'yellow').map((t) => t.id), [b]);
      expect(store.search(''), isEmpty);
    });
  });

  group('change log', () {
    test('two devices converge whatever order changes arrive in', () async {
      final dbA = PlannerDatabase.inMemory(), dbB = PlannerDatabase.inMemory();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final a = PlannerStore(dbA, today: () => today);
      final b = PlannerStore(dbB, today: () => today);
      final id = a.addTask(DaySlot(monday), 'shared')!;
      dbB.apply(dbA.changesSince(null));
      b.refresh({('tasks', id)});
      // Concurrent edits to different fields both survive…
      a.updateTask(id, title: 'renamed on A');
      b.updateTask(id, color: () => 'yellow');
      // …and for the same field the later edit wins on both sides.
      a.updateTask(id, note: 'first');
      // "Later" means a later clock reading; make sure there is one.
      await Future<void>.delayed(const Duration(milliseconds: 3));
      b.updateTask(id, note: 'second');
      final fromA = dbA.changesSince(null), fromB = dbB.changesSince(null);
      dbA.apply(fromB.reversed);
      dbB.apply(fromA);
      final ra = PlannerStore(dbA).task(id)!, rb = PlannerStore(dbB).task(id)!;
      expect([ra.title, ra.color, ra.note], [rb.title, rb.color, rb.note]);
      expect(ra.title, 'renamed on A');
      expect(ra.color, 'yellow');
      expect(ra.note, 'second');
      // Applying the same changes again changes nothing.
      expect(dbA.apply(fromB), isEmpty);
    });

    test('changes to unknown columns are kept but not applied', () {
      const future = Change(
        hlc: 'ffffffffffff-0000-zzzzzzzz',
        table: 'tasks',
        row: 'x',
        column: 'from_the_future',
        value: 1,
      );
      expect(db.apply([future]), isEmpty);
      expect(db.changesSince(null).map((c) => c.column), contains('from_the_future'));
    });
  });
}
