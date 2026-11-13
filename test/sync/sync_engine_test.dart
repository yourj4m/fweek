import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/data/recurrence.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';

void main() {
  final today = Day(2026, 11, 13);
  final monday = Day(2026, 11, 9);

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => today)
      ..setSetting(Settings.rollover, false);
  }

  /// A comparable picture of everything a user can see.
  String snapshot(PlannerStore store) {
    final tasks = store.allTasks.toList()..sort((a, b) => a.id.compareTo(b.id));
    return jsonEncode({
      'lists': [for (final l in store.lists) [l.id, l.title, l.position]],
      'tasks': [
        for (final t in tasks)
          [
            t.id, t.title, t.note, t.date?.iso, t.listId, t.position, t.color,
            t.time, t.done, t.recurrence?.toJson(),
            (t.exdates.map((d) => d.iso).toList()..sort()),
            [for (final s in t.subtasks) s.toJson()],
          ],
      ],
      'theme': store.setting<String>(Settings.theme),
    });
  }

  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  group('two devices', () {
    late MemoryStorage storage;
    late PlannerStore a, b;
    late SyncEngine syncA, syncB;

    setUp(() {
      storage = MemoryStorage();
      a = newStore();
      b = newStore();
      syncA = SyncEngine(a, storage, folder: 'WeekToDo');
      syncB = SyncEngine(b, storage, folder: 'WeekToDo');
    });

    test('a new device receives everything', () async {
      final id = a.addTask(DaySlot(monday), 'From A')!;
      a.updateTask(id, note: 'with a note', color: () => 'yellow');
      a.addList('Books');
      final first = await syncA.sync();
      expect(first.sent, greaterThan(0));
      expect(first.received, 0);
      final second = await syncB.sync();
      expect(second.received, greaterThan(0));
      await syncA.sync();
      expect(snapshot(b), snapshot(a));
      expect(titles(b.tasksOn(monday)), ['From A']);
    });

    test('edits on both sides merge, and the later edit of a field wins', () async {
      final id = a.addTask(DaySlot(monday), 'Shared')!;
      await syncA.sync();
      await syncB.sync();
      // Offline edits on both devices.
      a.updateTask(id, title: 'Renamed on A');
      b.updateTask(id, color: () => 'green');
      b.addTask(DaySlot(monday), 'Added on B');
      a.updateTask(id, note: 'older note');
      // "Later" means a later clock reading; make sure there is one.
      await Future<void>.delayed(const Duration(milliseconds: 3));
      b.updateTask(id, note: 'newer note');
      await syncA.sync();
      await syncB.sync();
      await syncA.sync();
      expect(snapshot(a), snapshot(b));
      final task = a.task(id)!;
      expect(task.title, 'Renamed on A');
      expect(task.color, 'green');
      expect(task.note, 'newer note');
      expect(titles(a.tasksOn(monday)), containsAll(['Renamed on A', 'Added on B']));
    });

    test('moves, completion, deletion and repeating tasks carry over', () async {
      final keep = a.addTask(DaySlot(monday), 'Keep')!;
      final gone = a.addTask(DaySlot(monday), 'Delete me')!;
      final daily = a.addTask(DaySlot(monday), 'Daily')!;
      a.setRecurrence(daily, Recurrence.daily);
      await syncA.sync();
      await syncB.sync();
      b.moveTask(keep, DaySlot(today), index: 0);
      b.setDone(keep, true);
      b.deleteTask(gone);
      b.setDone('$daily@${monday.addDays(2).iso}', true);
      await syncB.sync();
      await syncA.sync();
      expect(snapshot(a), snapshot(b));
      expect(a.task(keep)!.date, today);
      expect(a.task(keep)!.done, isTrue);
      expect(a.task(gone), isNull);
      final wednesday = a.tasksOn(monday.addDays(2));
      expect(wednesday.single.done, isTrue);
      expect(a.tasksOn(monday.addDays(3)).single.done, isFalse);
    });

    test('syncing with nothing new writes nothing', () async {
      a.addTask(DaySlot(monday), 'Once');
      await syncA.sync();
      await syncB.sync();
      final before = storage.files.length;
      for (var i = 0; i < 3; i++) {
        expect((await syncA.sync()).sent, 0);
        expect((await syncB.sync()).received, 0);
      }
      expect(storage.files.length, before);
    });

    test('no file is ever overwritten', () async {
      a.addTask(DaySlot(monday), 'one');
      await syncA.sync();
      b.addTask(DaySlot(monday), 'two');
      await syncB.sync();
      a.addTask(DaySlot(monday), 'three');
      await syncA.sync();
      final writes = storage.log.where((l) => l.startsWith('write ')).toList();
      expect(writes.toSet().length, writes.length);
    });

    test('an interrupted upload is completed by the next sync', () async {
      a.addTask(DaySlot(monday), 'Must arrive');
      storage.failNext = (op, path) => op == 'write';
      await expectLater(syncA.sync(), throwsA(isA<SyncException>()));
      await syncB.sync();
      expect(b.tasksOn(monday), isEmpty);
      await syncA.sync();
      await syncB.sync();
      expect(titles(b.tasksOn(monday)), ['Must arrive']);
    });

    test('an interrupted download is completed by the next sync', () async {
      for (var i = 0; i < 3; i++) {
        a.addTask(DaySlot(monday), 'Task $i');
        await syncA.sync();
      }
      var reads = 0;
      storage.failNext = (op, path) => op == 'read' && ++reads == 2;
      await expectLater(syncB.sync(), throwsA(isA<SyncException>()));
      await syncB.sync();
      expect(snapshot(b), snapshot(a));
    });

    test('a damaged or foreign file stops the sync with an explanation', () async {
      a.addTask(DaySlot(monday), 'ok');
      await syncA.sync();
      storage.files['WeekToDo/changes/ffffffff-00000001.json'] =
          Uint8List.fromList(utf8.encode('{"format":"something-else"}'));
      await expectLater(
        syncB.sync(),
        throwsA(isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.incompatible)
            .having((e) => e.message, 'message', contains('not a WeekToDo file'))),
      );
      storage.files['WeekToDo/changes/ffffffff-00000001.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode({'format': SyncEngine.format, 'version': 99, 'changes': []})),
      );
      await expectLater(
        syncB.sync(),
        throwsA(isA<SyncException>()
            .having((e) => e.message, 'message', contains('newer version'))),
      );
    });

    test('unrelated files in the folder are ignored', () async {
      storage.files['WeekToDo/changes/notes.txt'] = Uint8List(3);
      storage.files['WeekToDo/changes/.DS_Store'] = Uint8List(3);
      a.addTask(DaySlot(monday), 'fine');
      await syncA.sync();
      await syncB.sync();
      expect(titles(b.tasksOn(monday)), ['fine']);
    });
  });

  test('a new device does not reset a renamed first list', () async {
    final storage = MemoryStorage();
    final a = newStore();
    final first = a.lists.single.id;
    a.renameList(first, 'Inbox');
    a.addTask(ListSlot(first), 'Idea');
    await SyncEngine(a, storage, folder: 'p').sync();
    // B starts later, with a default first list of its own.
    final b = newStore();
    expect(b.lists.single.title, '');
    await SyncEngine(b, storage, folder: 'p').sync();
    await SyncEngine(a, storage, folder: 'p').sync();
    expect(a.lists.single.title, 'Inbox');
    expect(b.lists.single.title, 'Inbox');
    expect(titles(b.tasksIn(first)), ['Idea']);
  });

  test('theme and view stay on the device', () async {
    final storage = MemoryStorage();
    final a = newStore(), b = newStore();
    a.setSetting(Settings.theme, 'dark');
    a.setSetting(Settings.view, 'month');
    a.setSetting(Settings.weekStart, 7);
    await SyncEngine(a, storage, folder: 'p').sync();
    await SyncEngine(b, storage, folder: 'p').sync();
    expect(b.setting<String>(Settings.theme), 'system');
    expect(b.setting<String>(Settings.view), 'week');
    expect(b.weekStart, 7);
    // And they survive reopening the database.
    expect(PlannerStore(a.db, today: () => today).setting<String>(Settings.theme), 'dark');
  });

  test('three devices converge after syncing in a ring', () async {
    final storage = MemoryStorage();
    final stores = [newStore(), newStore(), newStore()];
    final engines = [for (final s in stores) SyncEngine(s, storage, folder: 'p')];
    final shared = stores[0].addTask(DaySlot(monday), 'Shared')!;
    for (final e in engines) {
      await e.sync();
    }
    for (var round = 0; round < 4; round++) {
      for (var i = 0; i < 3; i++) {
        stores[i].addTask(DaySlot(monday.addDays(round)), 'Device $i round $round');
        stores[i].updateTask(shared, note: 'note from $i in round $round');
      }
      // Each device syncs once, in a different order every round.
      for (var k = 0; k < 3; k++) {
        await engines[(k + round) % 3].sync();
      }
    }
    for (var pass = 0; pass < 2; pass++) {
      for (final e in engines) {
        await e.sync();
      }
    }
    expect(snapshot(stores[1]), snapshot(stores[0]));
    expect(snapshot(stores[2]), snapshot(stores[0]));
    expect(stores[0].allTasks, hasLength(13));
  });

  group('merging a device\'s files', () {
    test('keeps the folder small without losing anything', () async {
      final storage = MemoryStorage();
      final a = newStore(), b = newStore();
      final syncA = SyncEngine(a, storage, folder: 'p', compactAbove: 5);
      final syncB = SyncEngine(b, storage, folder: 'p', compactAbove: 5);
      final id = a.addTask(DaySlot(monday), 'Edited often')!;
      var merges = 0;
      for (var i = 0; i < 40; i++) {
        a.updateTask(id, note: 'revision $i');
        if (i % 7 == 0) a.addTask(DaySlot(monday), 'Extra $i');
        if ((await syncA.sync()).compacted) merges++;
        // B follows along only now and then.
        if (i % 9 == 0) await syncB.sync();
        expect(storage.files.length, lessThanOrEqualTo(7));
      }
      expect(merges, greaterThan(3));
      await syncB.sync();
      expect(snapshot(b), snapshot(a));
      // A device that joins after all that merging still gets everything.
      final c = newStore();
      await SyncEngine(c, storage, folder: 'p').sync();
      expect(snapshot(c), snapshot(a));
    });
  });

  test('a database restored from an older copy recovers its place', () async {
    final storage = MemoryStorage();
    final dir = Directory.systemTemp.createTempSync('weektodo-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/planner.db';

    var db = PlannerDatabase.open(path);
    var store = PlannerStore(db, today: () => today)..setSetting(Settings.rollover, false);
    store.addTask(DaySlot(monday), 'Before the copy');
    await SyncEngine(store, storage, folder: 'p').sync();
    db.close();
    final copy = '${dir.path}/copy.db';
    File(path).copySync(copy);

    db = PlannerDatabase.open(path);
    store = PlannerStore(db, today: () => today);
    store.addTask(DaySlot(monday), 'After the copy');
    await SyncEngine(store, storage, folder: 'p').sync();
    db.close();

    // Back to the older copy: it has forgotten its last upload.
    final restoredDb = PlannerDatabase.open(copy);
    addTearDown(restoredDb.close);
    final restored = PlannerStore(restoredDb, today: () => today);
    restored.addTask(DaySlot(monday), 'On the restored copy');
    await SyncEngine(restored, storage, folder: 'p').sync();
    expect(
      titles(restored.tasksOn(monday)),
      containsAll(['Before the copy', 'After the copy', 'On the restored copy']),
    );
    final other = newStore();
    await SyncEngine(other, storage, folder: 'p').sync();
    expect(titles(other.tasksOn(monday)), hasLength(3));
  });

  test('a local folder works as storage', () async {
    final dir = Directory.systemTemp.createTempSync('weektodo-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    final storage = LocalFolderStorage(dir);
    final a = newStore(), b = newStore();
    a.addTask(DaySlot(monday), 'Through a folder');
    await SyncEngine(a, storage, folder: 'WeekToDo').sync();
    await SyncEngine(b, storage, folder: 'WeekToDo').sync();
    expect(titles(b.tasksOn(monday)), ['Through a folder']);
    // One file per device: each has written only under its own name.
    final names = [
      for (final f in Directory('${dir.path}/WeekToDo/changes').listSync())
        f.uri.pathSegments.last,
    ]..sort();
    expect(names, hasLength(2));
    expect(names, everyElement(endsWith('-00000001.json')));
    expect(names.map((n) => n.substring(0, 8)).toSet(),
        {a.db.deviceId, b.db.deviceId});
    await expectLater(
      storage.write('WeekToDo/changes/x.json', Uint8List(1)).then(
            (_) => storage.write('WeekToDo/changes/x.json', Uint8List(1)),
          ),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.exists)),
    );
  });
}
