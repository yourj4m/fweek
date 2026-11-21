import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/export.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/data/recurrence.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';

/// Events of the planner's own that run over several days, and the form's
/// one step that adds an event with all it has.
void main() {
  var today = Day(2026, 11, 13); // Friday
  var clock = 1000;
  PlannerStore planner() =>
      PlannerStore(PlannerDatabase.inMemory(), today: () => today, now: () => clock++);

  setUp(() {
    today = Day(2026, 11, 13);
    clock = 1000;
  });

  final monday = Day(2026, 11, 9);
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  group('an event added with all it has', () {
    test('is on its day with time, end, place, note, colour, repeat and reminder', () {
      final store = planner();
      final id = store.addItem(
        day: today,
        title: '  Dinner with Ana ',
        time: 19 * 60,
        end: 21 * 60,
        note: 'Bring the book',
        location: 'Chez Marius',
        geo: '45.19,5.72',
        color: 'green',
        recurrence: Recurrence.weekly,
        reminder: DateTime(2026, 11, 13, 18),
      );
      final event = store.tasksOn(today).single;
      expect(event.occurrenceOf, id);
      expect((event.title, event.kind, event.time, event.end),
          ('Dinner with Ana', ItemKind.event, 19 * 60, 21 * 60));
      expect((event.note, event.location, event.geo, event.color),
          ('Bring the book', 'Chez Marius', '45.19,5.72', 'green'));
      expect(event.reminder, DateTime(2026, 11, 13, 18));
      expect(event.spansDays, isFalse);
      expect(titles(store.tasksOn(today.addDays(7))), ['Dinner with Ana']);
      // One change of the planner: what Undo takes back is all of it.
      store.deleteTask(id, wholeSeries: true);
      expect(store.tasksOn(today), isEmpty);
    });

    test('without a time it has no end; an end before the start is dropped', () {
      final store = planner();
      final allDay = store.addItem(day: today, title: 'Open day', end: 600);
      final odd = store.addItem(day: today, title: 'Odd', time: 600, end: 540);
      expect((store.task(allDay)!.time, store.task(allDay)!.end), (null, null));
      expect((store.task(odd)!.time, store.task(odd)!.end), (600, null));
    });
  });

  group('over several days', () {
    test('it is one bar over its days and a row of none', () {
      final store = planner();
      store.addTask(DaySlot(today), 'Water the plants');
      final id = store.addItem(day: today, endDay: today.addDays(3), title: 'Trip to Lyon');
      final trip = store.task(id)!;
      expect((trip.date, trip.endDay, trip.lastDay), (today, today.addDays(3), today.addDays(3)));
      expect(trip.spansDays, isTrue);
      for (var d = 0; d <= 3; d++) {
        expect(titles(store.tasksOn(today.addDays(d))), d == 0 ? ['Water the plants'] : isEmpty);
      }
      expect(titles(store.spansBetween(monday, monday.addDays(6))), ['Trip to Lyon']);
      // The next week holds its last day: it shows there too.
      expect(titles(store.spansBetween(monday.addDays(7), monday.addDays(13))), ['Trip to Lyon']);
      expect(store.spansBetween(monday.addDays(8), monday.addDays(13)), isEmpty);
      expect(store.spansBetween(monday.addDays(-7), monday.addDays(-1)), isEmpty);
    });

    test('an end day that is not after the first is no end day', () {
      final store = planner();
      final same = store.addItem(day: today, endDay: today, title: 'One day');
      final before = store.addItem(day: today, endDay: today.addDays(-1), title: 'Before');
      expect((store.task(same)!.endDay, store.task(before)!.endDay), (null, null));
      expect(titles(store.tasksOn(today)), ['One day', 'Before']);
    });

    test('with times: it starts on the first day and ends on the last, at any time', () {
      final store = planner();
      final id = store.addItem(
          day: today, endDay: today.addDays(1), title: 'Night train', time: 22 * 60, end: 7 * 60);
      final train = store.task(id)!;
      expect((train.time, train.end), (22 * 60, 7 * 60));
      // The end stays where it is when the start changes: it is another day's.
      store.updateTask(id, time: () => 21 * 60);
      expect((store.task(id)!.time, store.task(id)!.end), (21 * 60, 7 * 60));
      // Back within one day, an end before the start has no meaning.
      store.updateTask(id, endDay: () => null);
      expect((store.task(id)!.endDay, store.task(id)!.time, store.task(id)!.end),
          (null, 21 * 60, null));
      expect(titles(store.tasksOn(today)), ['Night train']);
    });

    test('an end after the start is kept when it comes back within one day', () {
      final store = planner();
      final id = store.addItem(
          day: today, endDay: today.addDays(2), title: 'Course', time: 9 * 60, end: 17 * 60);
      store.updateTask(id, endDay: () => null);
      expect((store.task(id)!.time, store.task(id)!.end), (9 * 60, 17 * 60));
    });

    test('its last day is set, changed and taken away', () {
      final store = planner();
      final id = store.addItem(day: today, title: 'Conference');
      expect(store.task(id)!.spansDays, isFalse);
      store.updateTask(id, endDay: () => today.addDays(2));
      expect(store.task(id)!.lastDay, today.addDays(2));
      expect(store.tasksOn(today), isEmpty);
      store.updateTask(id, endDay: () => today.addDays(4));
      expect(store.task(id)!.lastDay, today.addDays(4));
      // A day before the first is none.
      store.updateTask(id, endDay: () => today.addDays(-3));
      expect(store.task(id)!.endDay, isNull);
      expect(titles(store.tasksOn(today)), ['Conference']);
    });

    test('moved or copied to a day, it runs as long from there', () {
      final store = planner();
      final id = store.addItem(day: today, endDay: today.addDays(2), title: 'Trip');
      store.moveTask(id, DaySlot(today.addDays(10)));
      var trip = store.task(id)!;
      expect((trip.date, trip.endDay), (today.addDays(10), today.addDays(12)));
      final copy = store.copyTask(id, DaySlot(monday));
      trip = store.task(copy)!;
      expect((trip.date, trip.endDay, trip.kind), (monday, monday.addDays(2), ItemKind.event));
    });

    test('it is over once its last day is', () {
      final store = planner();
      final id = store.addItem(
          day: today.addDays(-2), endDay: today, title: 'Course', time: 9 * 60, end: 17 * 60);
      final course = store.task(id)!;
      expect(course.overAt(DateTime(2026, 11, 13, 16, 59)), isFalse);
      expect(course.overAt(DateTime(2026, 11, 13, 17)), isTrue);
      expect(course.overAt(DateTime(2026, 11, 12, 23)), isFalse);
    });

    test('made a task, it keeps its days; the daily move leaves it where it is', () {
      final store = planner();
      final id = store.addItem(day: today.addDays(-3), endDay: today.addDays(-1), title: 'Report');
      store.setKind(id, ItemKind.task);
      store.setSetting(Settings.rollover, true);
      expect(store.rollOver(), 0);
      final report = store.task(id)!;
      expect((report.date, report.endDay, report.checkable),
          (today.addDays(-3), today.addDays(-1), true));
    });

    test('done tasks over several days hide with the others', () {
      final store = planner();
      final id = store.addItem(
          day: today, endDay: today.addDays(1), title: 'Report', kind: ItemKind.task);
      store.setDone(id, true);
      expect(titles(store.spansBetween(today, today)), ['Report']);
      store.setSetting(Settings.hideDone, true);
      expect(store.spansBetween(today, today), isEmpty);
    });
  });

  group('one that repeats', () {
    test('runs as long each time, also when it began before the days asked for', () {
      final store = planner();
      // Friday to Sunday, every week.
      final id = store.addItem(
        day: today,
        endDay: today.addDays(2),
        title: 'Weekend shift',
        recurrence: Recurrence.weekly,
      );
      final week = store.spansBetween(monday.addDays(7), monday.addDays(13));
      expect(week.single.id, '$id@${today.addDays(7).iso}');
      expect((week.single.date, week.single.lastDay), (today.addDays(7), today.addDays(9)));
      // Asked for the Sunday alone: the one that began on Friday covers it.
      final sunday = today.addDays(9);
      expect(store.spansBetween(sunday, sunday).single.date, today.addDays(7));
      // And the Monday after is free.
      expect(store.spansBetween(sunday.addDays(1), sunday.addDays(3)), isEmpty);
    });

    test('one time of it moved is an event of its own, as long, and still an event', () {
      final store = planner();
      final id = store.addItem(
        day: today,
        endDay: today.addDays(1),
        title: 'Shift',
        time: 20 * 60,
        end: 6 * 60,
        recurrence: Recurrence.weekly,
      );
      final next = '$id@${today.addDays(7).iso}';
      final moved = store.moveTask(next, DaySlot(today.addDays(10)));
      final own = store.task(moved)!;
      expect(own.id, isNot(next));
      expect((own.date, own.endDay), (today.addDays(10), today.addDays(11)));
      expect((own.kind, own.time, own.end), (ItemKind.event, 20 * 60, 6 * 60));
      // The series goes on without that week.
      final later = store.spansBetween(today.addDays(7), today.addDays(15));
      expect([for (final t in later) t.date], [today.addDays(10), today.addDays(14)]);
    });

    test('the length set on one time is the length of them all', () {
      final store = planner();
      final id = store.addItem(day: today, title: 'Fair', recurrence: Recurrence.weekly);
      store.updateTask('$id@${today.addDays(7).iso}', endDay: () => today.addDays(9));
      expect(store.task(id)!.endDay, today.addDays(2));
      expect(store.spansBetween(today.addDays(14), today.addDays(14)).single.lastDay,
          today.addDays(16));
    });

    test('a single event split from a repeating one is still an event', () {
      final store = planner();
      final id = store.addItem(
          day: today, title: 'Seminar', time: 600, end: 660, recurrence: Recurrence.weekly);
      final moved = store.moveTask('$id@${today.addDays(7).iso}', DaySlot(today.addDays(8)));
      final own = store.task(moved)!;
      expect((own.kind, own.time, own.end), (ItemKind.event, 600, 660));
    });
  });

  group('it goes along', () {
    PlannerStore populated() {
      final store = planner();
      store.addItem(day: today, endDay: today.addDays(2), title: 'Trip to Lyon');
      store.addItem(
          day: today, endDay: today.addDays(1), title: 'Night train', time: 22 * 60, end: 7 * 60);
      store.addItem(day: today, endDay: today.addDays(1), title: 'Camp', time: 15 * 60);
      return store;
    }

    test('in a backup, and back', () {
      final backup = Export.backup(populated());
      expect(jsonDecode(backup)['version'], 6);
      final copy = planner();
      Export.restore(copy, backup);
      final spans = copy.spansBetween(today, today);
      expect(titles(spans), ['Trip to Lyon', 'Camp', 'Night train']);
      expect(spans.first.lastDay, today.addDays(2));
      expect((spans.last.time, spans.last.end), (22 * 60, 7 * 60));
    });

    test('to the other formats', () {
      final store = populated();
      final csv = const LineSplitter().convert(Export.csv(store).replaceAll('\r\n', '\n'));
      expect(csv.first, endsWith(',end,due,last_day'));
      expect(csv, contains('2026-11-13,,,Trip to Lyon,,,,,,,event,,,2026-11-15'));
      expect(csv, contains('2026-11-13,,22:00,Night train,,,,,,,event,07:00,,2026-11-14'));

      final text = Export.text(store);
      expect(text, contains(' -  Trip to Lyon\n    → until 2026-11-15\n'));
      expect(text, contains(' -  22:00 Night train\n    → until 2026-11-14 07:00\n'));

      final ics = Export.ics(store);
      // Whole days end with the day after the last.
      expect(ics, contains('DTSTART;VALUE=DATE:20261113\r\nDTEND;VALUE=DATE:20261116'));
      expect(ics, contains('DTSTART:20261113T220000\r\nDTEND:20261114T070000'));
      // Without an end time: to the same time on the last day.
      expect(ics, contains('DTSTART:20261113T150000\r\nDTEND:20261114T150000'));
    });

    test('from one device to another', () async {
      final desk = planner(), phone = planner();
      final folder = MemoryStorage();
      Future<void> sync(PlannerStore store) =>
          SyncEngine(store, folder, folder: 'WeekToDo').sync();
      final id = desk.addItem(day: today, endDay: today.addDays(2), title: 'Trip to Lyon');
      await sync(desk);
      await sync(phone);
      expect(phone.task(id)!.lastDay, today.addDays(2));
      phone.updateTask(id, endDay: () => today.addDays(4));
      await sync(phone);
      await sync(desk);
      expect(desk.spansBetween(today.addDays(4), today.addDays(4)).single.id, id);
    });
  });

  group('a planner written by the fifth version', () {
    late Directory folder;
    setUp(() => folder = Directory.systemTemp.createTempSync('weektodo-spans'));
    tearDown(() => folder.deleteSync(recursive: true));

    test('opens as it was, takes what a newer device had sent, and keeps a copy', () {
      final path = '${folder.path}/planner.db';
      // Written by this build, then set back to how the fifth version left
      // it: without the column, and with a change it could not place yet.
      final first = PlannerStore(PlannerDatabase.open(path), today: () => today);
      final id = first.addItem(day: today, title: 'Conference');
      first.db.close();
      sqlite3.open(path)
        ..execute('alter table tasks drop column end_date')
        ..execute('pragma user_version = 5')
        ..execute(
          'insert into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
          ['zz0000000001-0000-bbbbbbbb', 'tasks', id, 'end_date', jsonEncode('2026-11-15')],
        )
        ..close();

      final store = PlannerStore(PlannerDatabase.open(path), today: () => today);
      addTearDown(store.db.close);
      expect(store.db.foundVersion, 5);
      final conference = store.task(id)!;
      expect((conference.title, conference.lastDay), ('Conference', Day(2026, 11, 15)));

      final copy = sqlite3.open('$path.v5');
      expect(copy.select('pragma user_version').first.columnAt(0), 5);
      expect(copy.select('pragma table_info(tasks)').map((r) => r['name']),
          isNot(contains('end_date')));
      copy.close();
    });
  });
}
