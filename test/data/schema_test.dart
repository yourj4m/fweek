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

/// The tables as the first released version created them.
const _version1 = '''
  create table tasks(
    id text primary key, list_id text, date text,
    position text not null default '', title text not null default '',
    note text not null default '', color text, time integer,
    done integer not null default 0, done_at integer,
    subtasks text not null default '[]', recurrence text,
    exdates text not null default '[]', series_id text, series_date text,
    reminder text, created_at integer not null default 0,
    deleted integer not null default 0
  );
  create index tasks_date on tasks(date);
  create table lists(id text primary key, title text not null default '',
    position text not null default '', deleted integer not null default 0);
  create table settings(id text primary key, value text);
  create table changes(hlc text primary key, tbl text not null, row text not null,
    col text not null, value text);
  create table cell_clock(tbl text not null, row text not null, col text not null,
    hlc text not null, primary key (tbl, row, col));
  create table meta(key text primary key, value text);
  pragma user_version = 1;
''';

void main() {
  final friday = Day(2026, 11, 13);
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('weektodo-schema'));
  tearDown(() => folder.deleteSync(recursive: true));

  group('a planner written by the first version', () {
    String oldFile() {
      final path = '${folder.path}/planner.db';
      final db = sqlite3.open(path)..execute(_version1);
      db.execute("insert into meta(key, value) values('device_id', 'aaaaaaaa')");
      db.execute("insert into meta(key, value) values('sync.config', '{\"server\":\"cloud.example.org\",\"user\":\"me\",\"folder\":\"/WeekToDo\"}')");
      db.execute("insert into meta(key, value) values('local.calendars', '[{\"id\":\"c1\",\"name\":\"Work\",\"color\":\"blue\"}]')");
      db.execute(
          "insert into tasks(id, date, position, title) values('t1', '2026-11-13', 'V', 'Buy oat milk')");
      db.execute("insert into lists(id, title, position) values('someday', '', 'V')");
      void logged(String hlc, String table, String row, String column, Object? value) => db.execute(
          'insert into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
          [hlc, table, row, column, jsonEncode(value)]);
      // What a newer device had synced before this one was updated: kept in
      // the log by the old version, which knew neither column nor table.
      logged('01a000000001-0000-bbbbbbbb', 'tasks', 't1', 'location', 'Corner shop');
      logged('01a000000001-0001-bbbbbbbb', 'tasks', 't1', 'geo', '45.1,5.7');
      logged('01a000000002-0000-bbbbbbbb', 'events', 'e1', 'hidden', true);
      logged('01a000000002-0001-bbbbbbbb', 'events', 'e1', 'note', 'From the phone');
      logged('01a000000003-0000-bbbbbbbb', 'calendars', 'k1', 'name', 'Lab');
      logged('01a000000003-0001-bbbbbbbb', 'calendars', 'k1', 'hidden', true);
      db.close();
      return path;
    }

    test('opens with its tasks, lists and connection, and gains what is new', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      expect(store.tasksOn(friday).single.title, 'Buy oat milk');
      expect(store.lists.single.id, 'someday');
      expect(store.db.deviceId, 'aaaaaaaa');
      expect(store.db.meta('sync.config'), contains('cloud.example.org'));
      expect(store.db.meta('local.calendars'), contains('Work'));
      // New things work on it.
      final id = store.addTask(DaySlot(friday), 'New task')!;
      store.updateTask(id, location: 'Library');
      expect(store.task(id)!.location, 'Library');
    });

    test('what a newer device had already sent takes effect', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      final task = store.tasksOn(friday).single;
      expect(task.location, 'Corner shop');
      expect(task.geo, '45.1,5.7');
      expect(store.eventOverride('e1')!.hidden, isTrue);
      expect(store.eventOverride('e1')!.note, 'From the phone');
      expect(store.calendarRow('k1')!.name, 'Lab');
      expect(store.calendarRow('k1')!.hidden, isTrue);
    });

    test('opening it again changes nothing more', () {
      final path = oldFile();
      PlannerDatabase.open(path).close();
      final db = PlannerDatabase.open(path);
      addTearDown(db.close);
      expect(db.changeCount, 6);
      expect(db.row('tasks', 't1')!['location'], 'Corner shop');
    });
  });

  test('a file from a newer version is refused, not damaged', () {
    final path = '${folder.path}/future.db';
    sqlite3.open(path)
      ..execute(_version1)
      ..execute('pragma user_version = 99')
      ..close();
    expect(() => PlannerDatabase.open(path), throwsStateError);
  });

  group('store', () {
    late PlannerStore store;
    setUp(() => store = PlannerStore(PlannerDatabase.inMemory(), today: () => friday));

    test('a task has a place, with or without a position', () {
      final id = store.addTask(DaySlot(friday), 'Coffee with Anna')!;
      store.updateTask(id, location: ' Café de la Table Ronde ', geo: () => '45.1929,5.7281');
      expect(store.task(id)!.location, 'Café de la Table Ronde');
      expect(store.task(id)!.geo, '45.1929,5.7281');
      expect(store.task(id)!.hasLocation, isTrue);
      expect(store.search('table ronde').single.id, id);
      store.updateTask(id, location: '', geo: () => null);
      expect(store.task(id)!.hasLocation, isFalse);
      expect(store.task(id)!.geo, isNull);
    });

    test('a copy and a split-off occurrence keep the place', () {
      final id = store.addTask(DaySlot(friday), 'Swim')!;
      store.updateTask(id, location: 'Pool');
      expect(store.task(store.copyTask(id, DaySlot(friday.addDays(1))))!.location, 'Pool');
    });

    test('lists can be added, moved, deleted and brought back with their tasks', () {
      final reading = store.addList('Reading');
      final home = store.addList('Home');
      store.addTask(ListSlot(home), 'Fix the tap');
      List<String> order() => [for (final l in store.lists) l.title];
      expect(order(), ['', 'Reading', 'Home']);
      store.moveList(home, -1);
      expect(order(), ['', 'Home', 'Reading']);
      store.moveList(home, -1);
      expect(order(), ['Home', '', 'Reading']);
      store.moveList(home, -1); // already first
      store.moveList(reading, 1); // already last
      expect(order(), ['Home', '', 'Reading']);

      final tasks = store.deleteList(home);
      expect(order(), ['', 'Reading']);
      expect(tasks, hasLength(1));
      store.restoreList(home, tasks);
      expect(order(), ['Home', '', 'Reading']);
      expect(store.tasksIn(home).single.title, 'Fix the tap');
    });

    test('one day of a repeating task can be taken out and put back', () {
      final id = store.addTask(DaySlot(friday), 'Water plants')!;
      store.setRecurrence(id, Recurrence.daily);
      final saturday = friday.addDays(1);
      store.deleteTask(store.tasksOn(saturday).single.id);
      expect(store.tasksOn(saturday), isEmpty);
      store.restoreOccurrence(id, saturday);
      expect(store.tasksOn(saturday).single.title, 'Water plants');
      // Putting back a day that was never taken out changes nothing.
      store.restoreOccurrence(id, friday.addDays(3));
      expect(store.tasksOn(friday.addDays(3)), hasLength(1));
    });

    test('the tasks of a range are worked out once per change', () {
      store.addTask(DaySlot(friday), 'One');
      final first = store.tasksBetween(friday, friday.addDays(6));
      expect(identical(store.tasksBetween(friday, friday.addDays(6)), first), isTrue);
      store.addTask(DaySlot(friday), 'Two');
      final second = store.tasksBetween(friday, friday.addDays(6));
      expect(identical(second, first), isFalse);
      expect(second[friday], hasLength(2));
    });
  });

  group('backup', () {
    test('carries places, the calendar list and the changes to events, and reads back', () {
      final store = PlannerStore(PlannerDatabase.inMemory(), today: () => friday);
      final id = store.addTask(DaySlot(friday), 'Coffee')!;
      store.updateTask(id, location: 'Café', geo: () => '45.1,5.7');
      store.setCalendar('k1', name: 'Work', color: 'green', hidden: true);
      store.refresh(store.db.apply(store.db.stamp('events', 'e1', {
        'cal': 'k1',
        'origin': '2026-11-13',
        'note': 'Mine',
        'color': 'red',
        'date': '2026-11-14',
        'hidden': true,
      })));
      final backup = Export.backup(store);
      expect(jsonDecode(backup)['version'], 2);

      final copy = PlannerStore(PlannerDatabase.inMemory(), today: () => friday);
      Export.restore(copy, backup);
      expect(copy.task(id)!.location, 'Café');
      expect(copy.task(id)!.geo, '45.1,5.7');
      expect(copy.calendarRow('k1')!.name, 'Work');
      expect(copy.calendarRow('k1')!.hidden, isTrue);
      final change = copy.eventOverride('e1')!;
      expect(change.note, 'Mine');
      expect(change.color, 'red');
      expect(change.date, Day(2026, 11, 14));
      expect(change.hidden, isTrue);
      expect(change.calendar, 'k1');
    });

    test('a backup made by the first version still restores', () {
      final store = PlannerStore(PlannerDatabase.inMemory(), today: () => friday);
      final count = Export.restore(
        store,
        jsonEncode({
          'format': 'weektodo-backup',
          'version': 1,
          'lists': [
            {'id': 'someday', 'title': '', 'position': 'V'},
          ],
          'tasks': [
            {'id': 't1', 'date': '2026-11-13', 'position': 'V', 'title': 'Old task', 'created_at': 1},
          ],
          'settings': {'week_start': 7},
        }),
      );
      expect(count, 1);
      expect(store.tasksOn(friday).single.title, 'Old task');
      expect(store.tasksOn(friday).single.location, '');
      expect(store.weekStart, 7);
    });

    test('other formats name the place', () {
      final store = PlannerStore(PlannerDatabase.inMemory(), today: () => friday);
      final id = store.addTask(DaySlot(friday), 'Coffee')!;
      store.updateTask(id, location: 'Café, Grenoble', geo: () => '45.1,5.7');
      expect(Export.csv(store), contains('"Café, Grenoble"'));
      expect(Export.text(store), contains('@ Café, Grenoble'));
      expect(Export.ics(store), contains(r'LOCATION:Café\, Grenoble'));
      expect(Export.ics(store), contains('GEO:45.1;5.7'));
    });
  });
}
