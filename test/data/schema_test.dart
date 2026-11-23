import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/export.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/data/recurrence.dart';

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

/// What the second version added to them.
const _version2 = '''
  alter table tasks add column location text;
  alter table tasks add column geo text;
  create table events(id text primary key, cal text, origin text,
    hidden integer not null default 0, color text, title text, note text,
    location text, geo text, date text, time integer,
    done integer not null default 0, done_at integer, reminder text, subtasks text);
  create table calendars(id text primary key, name text, color text,
    hidden integer not null default 0, position text, ids text,
    deleted integer not null default 0);
  pragma user_version = 2;
''';

void main() {
  final friday = Day(2026, 11, 13);
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('fweek-schema'));
  tearDown(() => folder.deleteSync(recursive: true));

  group('a planner written by the first version', () {
    String oldFile() {
      final path = '${folder.path}/planner.db';
      final db = sqlite3.open(path)..execute(_version1);
      db.execute("insert into meta(key, value) values('device_id', 'aaaaaaaa')");
      db.execute("insert into meta(key, value) values('sync.config', '{\"server\":\"cloud.example.org\",\"user\":\"me\",\"folder\":\"/fweek\"}')");
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

    test('a copy of the file as it was is kept beside it', () {
      final path = oldFile();
      final store = PlannerStore(PlannerDatabase.open(path), today: () => friday);
      store.addTask(DaySlot(friday), 'Written by the new version');
      store.db.close();

      final copy = sqlite3.open('$path.v1');
      expect(copy.select('pragma user_version').first.columnAt(0), 1);
      expect(copy.select('select title from tasks').map((r) => r.columnAt(0)), ['Buy oat milk']);
      // As the first version wrote it: none of what the new one added.
      final columns = copy.select('pragma table_info(tasks)').map((r) => r['name']);
      expect(columns, isNot(contains('location')));
      expect(copy.select("select value from meta where key = 'sync.config'"), hasLength(1));
      copy.close();

      // Opening the upgraded file again leaves the copy alone.
      final before = File('$path.v1').lastModifiedSync();
      PlannerDatabase.open(path).close();
      expect(File('$path.v1').lastModifiedSync(), before);
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

  group('a planner written by the second version', () {
    String oldFile() {
      final path = '${folder.path}/planner.db';
      final db = sqlite3.open(path)..execute(_version1)..execute(_version2);
      db.execute("insert into meta(key, value) values('device_id', 'aaaaaaaa')");
      db.execute("insert into meta(key, value) values('sync.config', '{\"server\":\"cloud.example.org\"}')");
      db.execute("insert into tasks(id, date, position, title, time, done, location) "
          "values('t1', '2026-11-13', 'V', 'Seminar', 600, 1, 'Room 2')");
      db.execute("insert into tasks(id, date, position, title) values('t2', '2026-11-13', 'W', 'Buy oat milk')");
      db.execute("insert into lists(id, title, position) values('someday', '', 'V')");
      db.execute("insert into events(id, cal, origin, done, note) values('e1', 'k1', '2026-11-13', 1, 'Mine')");
      db.execute("insert into events(id, cal, origin, color) values('e2', 'k1', '2026-11-13', 'red')");
      void logged(String hlc, String table, String row, String column, Object? value) => db.execute(
          'insert into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
          [hlc, table, row, column, jsonEncode(value)]);
      // Sent by a device that was updated first, and kept in the log.
      logged('01a000000001-0000-bbbbbbbb', 'tasks', 't1', 'kind', 'event');
      logged('01a000000001-0001-bbbbbbbb', 'tasks', 't1', 'end_time', 690);
      logged('01a000000002-0000-bbbbbbbb', 'events', 'e2', 'kind', 'task');
      db.close();
      return path;
    }

    test('opens with everything it had; its items are tasks, as they were', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      expect(store.db.foundVersion, 2);
      expect(store.db.meta('sync.config'), contains('cloud.example.org'));
      final milk = store.task('t2')!;
      expect(milk.kind, ItemKind.task);
      expect(milk.end, isNull);
      expect(store.task('t1')!.location, 'Room 2');
      // An event that had been ticked off stays a ticked task.
      expect(store.eventOverride('e1')!.shownAs, ItemKind.task);
      expect(store.eventOverride('e1')!.note, 'Mine');
    });

    test('what a newer device had already sent takes effect', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      final seminar = store.task('t1')!;
      expect(seminar.kind, ItemKind.event);
      expect((seminar.time, seminar.end), (600, 690));
      // An event has no tick, whatever it had as a task.
      expect(seminar.done, isFalse);
      expect(store.eventOverride('e2')!.kind, ItemKind.task);
    });

    test('a copy of the file as it was is kept beside it', () {
      final path = oldFile();
      PlannerDatabase.open(path).close();
      final copy = sqlite3.open('$path.v2');
      expect(copy.select('pragma user_version').first.columnAt(0), 2);
      expect(copy.select('pragma table_info(tasks)').map((r) => r['name']), isNot(contains('kind')));
      copy.close();
      // Opened again, it is this version's file.
      final again = PlannerDatabase.open(path);
      expect(again.foundVersion, 6);
      again.close();
    });
  });

  group('a planner written by the third version', () {
    String oldFile() {
      final path = '${folder.path}/planner.db';
      final db = sqlite3.open(path)
        ..execute(_version1)
        ..execute(_version2)
        ..execute('''
          alter table tasks add column kind text;
          alter table tasks add column end_time integer;
          alter table events add column kind text;
          alter table events add column end_time integer;
          pragma user_version = 3;
        ''');
      db.execute("insert into meta(key, value) values('device_id', 'aaaaaaaa')");
      db.execute("insert into tasks(id, date, position, title, kind) "
          "values('t1', '2026-11-13', 'V', 'Seminar', 'event')");
      db.execute("insert into tasks(id, date, position, title) values('t2', '2026-11-13', 'W', 'Buy oat milk')");
      db.execute("insert into lists(id, title, position) values('someday', '', 'V')");
      db.execute("insert into events(id, cal, origin, kind) values('e1', 'k1', '2026-11-13', 'task')");
      void logged(String hlc, String table, String row, String column, Object? value) => db.execute(
          'insert into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
          [hlc, table, row, column, jsonEncode(value)]);
      // Sent by a device that was updated first, and kept in the log.
      logged('01a000000001-0000-bbbbbbbb', 'tasks', 't2', 'rolled_from', '2026-11-12');
      logged('01a000000001-0001-bbbbbbbb', 'tasks', 't2', 'rolled_pos', 'K');
      logged('01a000000002-0000-bbbbbbbb', 'events', 'e1', 'position', 'Vn');
      db.close();
      return path;
    }

    test('opens with what it had, and what a newer device had sent takes effect', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      expect(store.db.foundVersion, 3);
      expect(store.task('t1')!.kind, ItemKind.event);
      final milk = store.task('t2')!;
      expect((milk.rolledFrom, milk.rolledPosition), (Day(2026, 11, 12), 'K'));
      expect(milk.waitsForWord, isTrue);
      expect(store.eventOverride('e1')!.position, 'Vn');
      expect(store.eventOverride('e1')!.kind, ItemKind.task);
    });

    test('a copy of the file as it was is kept beside it', () {
      final path = oldFile();
      PlannerDatabase.open(path).close();
      final copy = sqlite3.open('$path.v3');
      expect(copy.select('pragma user_version').first.columnAt(0), 3);
      expect(copy.select('pragma table_info(tasks)').map((r) => r['name']), isNot(contains('rolled_from')));
      copy.close();
    });
  });

  group('a planner written by the fourth version', () {
    // Lists then held tasks without a day only, ordered by the same key a
    // day orders its tasks by.
    String oldFile() {
      final path = '${folder.path}/planner.db';
      final db = sqlite3.open(path)
        ..execute(_version1)
        ..execute(_version2)
        ..execute('''
          alter table tasks add column kind text;
          alter table tasks add column end_time integer;
          alter table events add column kind text;
          alter table events add column end_time integer;
          alter table tasks add column rolled_from text;
          alter table tasks add column rolled_pos text;
          alter table events add column position text;
          pragma user_version = 4;
        ''');
      db.execute("insert into meta(key, value) values('device_id', 'aaaaaaaa')");
      db.execute("insert into lists(id, title, position) values('someday', '', 'V')");
      db.execute("insert into lists(id, title, position) values('films', 'Films', 'W')");
      db.execute("insert into tasks(id, list_id, position, title) values('s1', 'someday', 'V', 'Renew passport')");
      db.execute("insert into tasks(id, list_id, position, title) values('s2', 'someday', 'K', 'Call the bank')");
      db.execute("insert into tasks(id, list_id, position, title, done, done_at) "
          "values('f1', 'films', 'V', 'Stalker', 1, 5)");
      db.execute("insert into tasks(id, date, position, title) values('d1', '2026-11-13', 'V', 'Buy oat milk')");
      void logged(String hlc, String table, String row, String column, Object? value) => db.execute(
          'insert into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
          [hlc, table, row, column, jsonEncode(value)]);
      // Sent by a device that was updated first, and kept in the log: the
      // milk was put into a list there and given a deadline.
      logged('01a000000001-0000-bbbbbbbb', 'tasks', 'd1', 'list_pos', 'c');
      logged('01a000000001-0001-bbbbbbbb', 'tasks', 'd1', 'due', '2026-11-20');
      db.close();
      return path;
    }

    test('its Someday lists are the lists of the Tasks page, in their order', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      expect(store.db.foundVersion, 4);
      expect([for (final l in store.lists) store.listName(l.id)], ['To do', 'Films']);
      // The order the tasks had under the week.
      expect([for (final t in store.openIn('someday')) t.title], ['Call the bank', 'Renew passport']);
      expect(store.doneIn('films').single.title, 'Stalker');
      // A task put between them stands there, old keys and new together.
      final id = store.addTask(ListSlot('someday'), 'Between', index: 1)!;
      expect([for (final t in store.openIn('someday')) t.title],
          ['Call the bank', 'Between', 'Renew passport']);
      expect(store.task(id)!.listPos, isNotEmpty);
    });

    test('what a newer device had already sent takes effect', () {
      final store = PlannerStore(PlannerDatabase.open(oldFile()), today: () => friday);
      addTearDown(store.db.close);
      final milk = store.task('d1')!;
      expect((milk.listPos, milk.due), ('c', Day(2026, 11, 20)));
    });

    test('a copy of the file as it was is kept beside it', () {
      final path = oldFile();
      PlannerDatabase.open(path).close();
      final copy = sqlite3.open('$path.v4');
      expect(copy.select('pragma user_version').first.columnAt(0), 4);
      expect(copy.select('pragma table_info(tasks)').map((r) => r['name']), isNot(contains('list_pos')));
      copy.close();
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

      final removal = store.deleteList(home);
      expect(order(), ['', 'Reading']);
      expect(removal.deleted, hasLength(1));
      store.restoreList(removal);
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
      expect(jsonDecode(backup)['version'], 6);

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
