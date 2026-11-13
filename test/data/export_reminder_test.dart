import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/export.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/data/recurrence.dart';
import 'package:weektodo/services/reminders.dart';

void main() {
  final today = Day(2026, 11, 13);
  final monday = Day(2026, 11, 9);

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => today, now: () => 1000)
      ..setSetting(Settings.rollover, false);
  }

  PlannerStore populated() {
    final store = newStore();
    final a = store.addTask(DaySlot(monday), 'Plain, with "quotes" and a comma')!;
    store.updateTask(
      a,
      note: 'line one\nline two',
      color: () => 'yellow',
      time: () => 9 * 60 + 5,
      subtasks: const [
        Subtask(id: 's1', text: 'first', done: true),
        Subtask(id: 's2', text: 'Section', heading: true),
      ],
      reminder: () => DateTime(2026, 11, 9, 8, 30),
    );
    final b = store.addTask(DaySlot(monday), 'Weekly sync')!;
    store.setRecurrence(b, const Recurrence(frequency: Frequency.weekly, weekdays: {1, 3}));
    store.deleteTask('$b@2026-11-11');
    final c = store.addTask(DaySlot(today), 'Done thing')!;
    store.setDone(c, true);
    final books = store.addList('Books');
    store.addTask(ListSlot(books), 'Dune');
    store.setSetting(Settings.theme, 'dark');
    return store;
  }

  group('backup', () {
    test('restores into an empty planner exactly', () {
      final source = populated();
      final text = Export.backup(source);
      final target = newStore();
      expect(Export.restore(target, text), 4);
      expect(Export.backup(target), text);
      expect(target.setting<String>(Settings.theme), 'dark');
      expect(target.tasksOn(Day(2026, 11, 16)).single.title, 'Weekly sync');
      expect(target.tasksOn(Day(2026, 11, 11)), isEmpty); // the deleted occurrence
    });

    test('restoring twice does not duplicate', () {
      final source = populated();
      final text = Export.backup(source);
      Export.restore(source, text);
      expect(Export.backup(source), text);
    });

    test('rejects files that are not backups, with a reason', () {
      final store = newStore();
      expect(() => Export.restore(store, 'not json'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('JSON'))));
      expect(() => Export.restore(store, '{"format":"other"}'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not a WeekToDo backup'))));
      expect(
        () => Export.restore(store, jsonEncode({'format': Export.backupFormat, 'version': 99})),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer version'))),
      );
      expect(store.allTasks, isEmpty);
    });
  });

  group('other formats', () {
    test('CSV quotes commas, quotes and newlines', () {
      final lines = const LineSplitter().convert(Export.csv(populated()).replaceAll('\r\n', '\n'));
      expect(lines.first, 'date,list,time,title,done,color,repeats,note,subtasks');
      final row = Export.csv(populated()).split('\r\n')[1];
      expect(row, startsWith('2026-11-09,,09:05,"Plain, with ""quotes"" and a comma",no,yellow,,"line one'));
    });

    test('plain text groups by day and list', () {
      final text = Export.text(populated());
      expect(text, contains('2026-11-09\n[ ] 09:05 Plain'));
      expect(text, contains('    [x] first\n      Section\n    > line one\n    > line two'));
      expect(text, contains('2026-11-13\n[x] Done thing'));
      expect(text, contains('Books\n[ ] Dune'));
    });

    test('iCalendar has one VTODO per task, a rule and exceptions, folded lines', () {
      final store = populated();
      store.addTask(DaySlot(today), 'x' * 120);
      final ics = Export.ics(store, now: DateTime.utc(2026, 11, 13, 12));
      expect('BEGIN:VTODO'.allMatches(ics), hasLength(5));
      expect(ics, contains('RRULE:FREQ=WEEKLY;BYDAY=MO,WE'));
      expect(ics, contains('EXDATE;VALUE=DATE:20261111'));
      expect(ics, contains('DUE:20261109T090500'));
      expect(ics, contains(r'SUMMARY:Plain\, with "quotes" and a comma'));
      expect(ics, contains(r'DESCRIPTION:line one\nline two'));
      expect(ics, contains('STATUS:COMPLETED'));
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      // Folded lines unfold back to the original content.
      expect(ics.replaceAll('\r\n ', ''), contains('SUMMARY:${'x' * 120}'));
    });
  });

  group('reminders', () {
    late DateTime clock;
    late List<String> fired;
    ReminderService service(PlannerStore store) {
      final s = ReminderService(
        store,
        notify: (due) => fired.add('${due.task.title}@${due.at.toIso8601String()}'),
        clock: () => clock,
      );
      addTearDown(s.dispose);
      return s;
    }

    setUp(() {
      fired = [];
      clock = DateTime(2026, 11, 13, 8, 0);
    });

    test('fires when due, and only once', () {
      final store = newStore();
      final id = store.addTask(DaySlot(today), 'Call')!;
      store.updateTask(id, reminder: () => DateTime(2026, 11, 13, 9, 0));
      final s = service(store)..check();
      expect(fired, isEmpty);
      clock = DateTime(2026, 11, 13, 9, 0, 1);
      s.check();
      s.check();
      expect(fired, ['Call@2026-11-13T09:00:00.000']);
      // A fresh service on the same database remembers it too.
      service(store).check();
      expect(fired, hasLength(1));
    });

    test('catches up on recent misses but not old ones, and skips done tasks', () {
      final store = newStore();
      final recent = store.addTask(DaySlot(today), 'Recent')!;
      store.updateTask(recent, reminder: () => DateTime(2026, 11, 13, 1, 0));
      final old = store.addTask(DaySlot(monday), 'Old')!;
      store.updateTask(old, reminder: () => DateTime(2026, 11, 9, 9, 0));
      final done = store.addTask(DaySlot(today), 'Done')!;
      store.updateTask(done, reminder: () => DateTime(2026, 11, 13, 7, 0));
      store.setDone(done, true);
      service(store).check();
      expect(fired, ['Recent@2026-11-13T01:00:00.000']);
    });

    test('repeating tasks remind on each occurrence, except removed ones', () {
      final store = newStore();
      final id = store.addTask(DaySlot(monday), 'Pills')!;
      store.updateTask(id, reminder: () => DateTime(2026, 11, 9, 7, 30));
      store.setRecurrence(id, Recurrence.daily);
      final s = service(store);
      clock = DateTime(2026, 11, 13, 7, 31);
      s.check();
      expect(fired, ['Pills@2026-11-13T07:30:00.000']);
      store.deleteTask('$id@2026-11-14');
      clock = DateTime(2026, 11, 14, 7, 31);
      s.check();
      expect(fired, hasLength(1));
      clock = DateTime(2026, 11, 15, 7, 31);
      s.check();
      expect(fired.last, 'Pills@2026-11-15T07:30:00.000');
    });
  });
}
