import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/export.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/data/recurrence.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';

/// Items made in the planner: tasks, which are ticked off, and events, which
/// are not; and the end time either can have.
void main() {
  final friday = Day(2026, 11, 13);
  PlannerStore planner({Day? today}) =>
      PlannerStore(PlannerDatabase.inMemory(), today: () => today ?? friday);

  group('a new item', () {
    test('is a task unless made an event', () {
      final store = planner();
      final task = store.task(store.addTask(DaySlot(friday), 'Buy oat milk')!)!;
      expect(task.kind, ItemKind.task);
      expect(task.checkable, isTrue);
      final event = store.task(store.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event)!)!;
      expect(event.kind, ItemKind.event);
      expect(event.checkable, isFalse);
    });

    test('is what the setting says, which can be said otherwise per item', () {
      final store = planner();
      expect(store.newItemKind, ItemKind.task);
      store.setSetting(Settings.newItems, 'event');
      expect(store.newItemKind, ItemKind.event);
      expect(store.task(store.addTask(DaySlot(friday), 'Seminar')!)!.kind, ItemKind.event);
      expect(store.task(store.addTask(DaySlot(friday), 'Buy oat milk', kind: ItemKind.task)!)!.kind,
          ItemKind.task);
      // Something unreadable in the setting means tasks.
      store.setSetting(Settings.newItems, 'whatever');
      expect(store.newItemKind, ItemKind.task);
    });
  });

  group('an event', () {
    test('is not ticked off, and gets a tick it had back when made a task again', () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Call the bank')!;
      store.setDone(id, true);
      store.setKind(id, ItemKind.event);
      expect(store.task(id)!.done, isFalse);
      store.setDone(id, true);
      expect(store.task(id)!.done, isFalse);
      store.setKind(id, ItemKind.task);
      expect(store.task(id)!.done, isTrue);
    });

    test('stays on its day when unfinished tasks move to today', () {
      final store = planner();
      final yesterday = friday.addDays(-1);
      final task = store.addTask(DaySlot(yesterday), 'Buy oat milk')!;
      final event = store.addTask(DaySlot(yesterday), 'Seminar', kind: ItemKind.event)!;
      expect(store.rollOver(), 1);
      expect(store.task(task)!.date, friday);
      expect(store.task(event)!.date, yesterday);
    });

    test('is not hidden or sorted down with completed tasks', () {
      final store = planner();
      final done = store.addTask(DaySlot(friday), 'Done thing')!;
      store.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event);
      store.addTask(DaySlot(friday), 'Open thing');
      store.setDone(done, true);
      store.setSetting(Settings.sortDoneDown, true);
      expect([for (final t in store.tasksOn(friday)) t.title], ['Seminar', 'Open thing', 'Done thing']);
      store.setSetting(Settings.hideDone, true);
      expect([for (final t in store.tasksOn(friday)) t.title], ['Seminar', 'Open thing']);
    });

    test('of a repeating item: every occurrence is one', () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Lab meeting')!;
      store.setRecurrence(id, const Recurrence(frequency: Frequency.weekly));
      final next = store.tasksOn(friday.addDays(7)).single;
      store.setKind(next.id, ItemKind.event);
      expect(store.tasksOn(friday).single.kind, ItemKind.event);
      expect(store.tasksOn(friday.addDays(14)).single.kind, ItemKind.event);
    });

    test('is over when its day has passed or, today, its end (an hour after the start without one)',
        () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event)!;
      // No time: over when the day is.
      expect(store.task(id)!.overAt(DateTime(2026, 11, 13, 23, 59)), isFalse);
      expect(store.task(id)!.overAt(DateTime(2026, 11, 14)), isTrue);
      store.updateTask(id, time: () => 10 * 60);
      expect(store.task(id)!.overAt(DateTime(2026, 11, 13, 10, 59)), isFalse);
      expect(store.task(id)!.overAt(DateTime(2026, 11, 13, 11)), isTrue);
      store.updateTask(id, end: () => 12 * 60 + 30);
      expect(store.task(id)!.overAt(DateTime(2026, 11, 13, 12, 29)), isFalse);
      expect(store.task(id)!.overAt(DateTime(2026, 11, 13, 12, 30)), isTrue);
      // A task is never over; a list has no day to pass.
      store.setKind(id, ItemKind.task);
      expect(store.task(id)!.overAt(DateTime(2026, 12, 1)), isFalse);
      final someday = store.addTask(ListSlot(store.lists.first.id), 'Trip', kind: ItemKind.event)!;
      expect(store.task(someday)!.overAt(DateTime(2030)), isFalse);
    });
  });

  group('an end time', () {
    test('needs a start and lies after it', () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Seminar')!;
      store.updateTask(id, end: () => 11 * 60);
      expect(store.task(id)!.end, isNull);
      store.updateTask(id, time: () => 10 * 60, end: () => 11 * 60);
      expect((store.task(id)!.time, store.task(id)!.end), (600, 660));
      store.updateTask(id, end: () => 9 * 60);
      expect(store.task(id)!.end, isNull);
    });

    test('moves with the start, and goes with it', () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Seminar')!;
      store.updateTask(id, time: () => 10 * 60, end: () => 11 * 60 + 30);
      store.updateTask(id, time: () => 14 * 60);
      expect(store.task(id)!.end, 15 * 60 + 30);
      // Past midnight there is no end to show.
      store.updateTask(id, time: () => 23 * 60);
      expect(store.task(id)!.end, isNull);
      store.updateTask(id, time: () => 10 * 60, end: () => 11 * 60);
      store.updateTask(id, time: () => null);
      expect((store.task(id)!.time, store.task(id)!.end), (null, null));
    });

    test('a copy keeps it, and what the item is', () {
      final store = planner();
      final id = store.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event)!;
      store.updateTask(id, time: () => 600, end: () => 660);
      final copy = store.task(store.copyTask(id, DaySlot(friday.addDays(1))))!;
      expect((copy.kind, copy.time, copy.end), (ItemKind.event, 600, 660));
    });
  });

  test('both travel between devices', () async {
    final desk = planner(), phone = planner();
    final folder = MemoryStorage();
    Future<void> sync(PlannerStore store) => SyncEngine(store, folder, folder: 'WeekToDo').sync();
    final id = desk.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event)!;
    desk.updateTask(id, time: () => 600, end: () => 690);
    desk.setSetting(Settings.newItems, 'event');
    await sync(desk);
    await sync(phone);
    expect((phone.task(id)!.kind, phone.task(id)!.end), (ItemKind.event, 690));
    expect(phone.newItemKind, ItemKind.event);
    phone.setKind(id, ItemKind.task);
    await sync(phone);
    await sync(desk);
    expect(desk.task(id)!.kind, ItemKind.task);
  });

  group('exports', () {
    PlannerStore populated() {
      final store = planner();
      final seminar = store.addTask(DaySlot(friday), 'Seminar', kind: ItemKind.event)!;
      store.updateTask(seminar, time: () => 600, end: () => 690, location: 'Room 2');
      store.addTask(DaySlot(friday), 'Open day', kind: ItemKind.event);
      final milk = store.addTask(DaySlot(friday), 'Buy oat milk')!;
      store.setDone(milk, true);
      return store;
    }

    test('a backup carries them and reads back', () {
      final store = populated();
      final backup = Export.backup(store);
      expect(jsonDecode(backup)['version'], 3);
      final copy = planner();
      Export.restore(copy, backup);
      final seminar = copy.tasksOn(friday).firstWhere((t) => t.title == 'Seminar');
      expect((seminar.kind, seminar.time, seminar.end), (ItemKind.event, 600, 690));
      expect(copy.tasksOn(friday).firstWhere((t) => t.title == 'Buy oat milk').done, isTrue);
    });

    test('a backup from before them restores as tasks', () {
      final copy = planner();
      Export.restore(
        copy,
        jsonEncode({
          'format': Export.backupFormat,
          'version': 2,
          'tasks': [
            {'id': 'a', 'date': '2026-11-13', 'position': 'V', 'title': 'Old', 'time': 600},
          ],
        }),
      );
      expect((copy.task('a')!.kind, copy.task('a')!.end), (ItemKind.task, null));
    });

    test('CSV says what each is and when it ends', () {
      final rows = const LineSplitter().convert(Export.csv(populated()).replaceAll('\r\n', '\n'));
      expect(rows[1], '2026-11-13,,10:00,Seminar,,,,,,Room 2,event,11:30');
      expect(rows[3], '2026-11-13,,,Buy oat milk,yes,,,,,,task,');
    });

    test('plain text gives tasks a box and events a dash', () {
      final text = Export.text(populated());
      expect(text, contains(' -  10:00–11:30 Seminar\n    @ Room 2'));
      expect(text, contains(' -  Open day'));
      expect(text, contains('[x] Buy oat milk'));
    });

    test('iCalendar writes events as VEVENT with start and end, tasks as VTODO', () {
      final ics = Export.ics(populated(), now: DateTime.utc(2026, 11, 13));
      expect('BEGIN:VEVENT'.allMatches(ics), hasLength(2));
      expect('BEGIN:VTODO'.allMatches(ics), hasLength(1));
      expect(ics, contains('SUMMARY:Seminar\r\nLOCATION:Room 2\r\nDTSTART:20261113T100000\r\nDTEND:20261113T113000'));
      expect(ics, contains('SUMMARY:Open day\r\nDTSTART;VALUE=DATE:20261113\r\nDTEND;VALUE=DATE:20261114'));
      expect(ics, contains('STATUS:COMPLETED'));
    });
  });
}
