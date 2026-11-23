import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/export.dart';
import 'package:fweek/data/local_backups.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';

void main() {
  final monday = Day(2026, 11, 9);
  late Directory folder;

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => monday)..setSetting(Settings.rollover, false);
  }

  setUp(() => folder = Directory.systemTemp.createTempSync('fweek-copies-'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('a copy is the backup file, one for each day, the latest of that day', () async {
    var now = DateTime(2026, 11, 9, 8, 30);
    final copies = LocalBackups(Directory('${folder.path}/backups'), clock: () => now);
    expect(copies.list(), isEmpty);

    final store = newStore()..addTask(DaySlot(monday), 'Morning');
    final first = await copies.make(store);
    expect(first.day, monday);
    expect(first.file.path, endsWith('planner-2026-11-09.json'));

    // Later the same day: the same file, with what there is now.
    now = DateTime(2026, 11, 9, 18);
    store.addTask(DaySlot(monday), 'Evening');
    await copies.make(store);
    expect(copies.list().single.day, monday);
    expect(copies.list().single.file.readAsStringSync(), Export.backup(store));
    // Nothing half-written is left behind.
    expect([for (final f in copies.directory.listSync()) f.path.split('/').last],
        ['planner-2026-11-09.json']);

    // It is read back like any backup.
    final other = newStore();
    expect(Export.restore(other, copies.list().single.file.readAsStringSync()), 2);
    expect([for (final t in other.tasksOn(monday)) t.title], ['Morning', 'Evening']);
  });

  test('the oldest copies go once there are more than are kept; nothing else is touched',
      () async {
    var now = DateTime(2026, 11, 1, 12);
    final copies = LocalBackups(folder, keep: 3, clock: () => now);
    final store = newStore()..addTask(DaySlot(monday), 'Kept');
    File('${folder.path}/notes.txt').writeAsStringSync('mine');
    File('${folder.path}/planner-not-a-day.json').writeAsStringSync('{}');
    for (var day = 1; day <= 5; day++) {
      now = DateTime(2026, 11, day, 12);
      await copies.make(store);
    }
    expect([for (final c in copies.list()) c.day.iso],
        ['2026-11-05', '2026-11-04', '2026-11-03']);
    expect(File('${folder.path}/notes.txt').readAsStringSync(), 'mine');
    expect(File('${folder.path}/planner-not-a-day.json').existsSync(), isTrue);
  });
}
