// Runs against a real Nextcloud server when these are set, and is skipped
// otherwise:
//
//   NEXTCLOUD_TEST_URL       e.g. http://127.0.0.1:8089
//   NEXTCLOUD_TEST_USER      the login name
//   NEXTCLOUD_TEST_PASSWORD  an app password
//   NEXTCLOUD_TEST_USER_ID   optional: the account's id, when it differs
//                            from the login name (an LDAP account); checks
//                            that the app finds it on its own
//
// Everything happens inside a folder created for the run and removed after.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/data/recurrence.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_engine.dart';
import 'package:fweek/sync/sync_service.dart';
import 'package:fweek/sync/webdav.dart';

void main() {
  final url = Platform.environment['NEXTCLOUD_TEST_URL'];
  final user = Platform.environment['NEXTCLOUD_TEST_USER'];
  final password = Platform.environment['NEXTCLOUD_TEST_PASSWORD'];
  final expectedId = Platform.environment['NEXTCLOUD_TEST_USER_ID'];
  final configured = url != null && user != null && password != null;
  final skip = configured ? null : 'no NEXTCLOUD_TEST_* environment';

  final today = Day(2026, 11, 13), monday = Day(2026, 11, 9);
  final folder = 'fweek test ${Random().nextInt(1 << 32).toRadixString(16)}/nested';
  late WebDavStorage storage;
  late String id;

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => today);
  }

  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  setUpAll(() async {
    if (!configured) return;
    // The files may be under an id other than the login name.
    id = await discoverNextcloudUserId(server: url, login: user, password: password) ?? user;
    storage = WebDavStorage(
      root: nextcloudFilesRoot(url, id),
      user: user,
      password: password,
    );
  });

  tearDownAll(() async {
    if (!configured) return;
    // Remove the run's folder (a DELETE on a folder removes its contents).
    await storage.delete(folder.split('/').first);
    storage.close();
  });

  test('storage operations behave as the engine expects', () async {
    expect(await storage.list('$folder/changes'), isEmpty);
    await storage.createDir('$folder/changes');
    await storage.createDir('$folder/changes');
    final bytes = Uint8List.fromList(utf8.encode('{"x":"ä ✓"}'));
    await storage.write('$folder/changes/first file.json', bytes);
    await expectLater(
      storage.write('$folder/changes/first file.json', Uint8List(1)),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.exists)),
    );
    expect(await storage.list('$folder/changes'), ['first file.json']);
    expect(await storage.list(folder), isEmpty, reason: 'sub-folders are not files');
    expect(await storage.read('$folder/changes/first file.json'), bytes);
    expect(await storage.read('$folder/changes/missing.json'), isNull);
    await storage.delete('$folder/changes/first file.json');
    await storage.delete('$folder/changes/first file.json');
    expect(await storage.list('$folder/changes'), isEmpty);
  }, skip: skip);

  test('the account id is found from the login name', () async {
    if (expectedId != null) expect(id, expectedId);
    expect(await storage.list(''), isA<List<String>>());
  }, skip: skip);

  test('the settings form connects with the login name and app password', () async {
    final store = newStore()..addTask(DaySlot(monday), 'Connected');
    final service = SyncService(store, MemorySecretStore());
    addTearDown(service.dispose);
    final error = await service.connect(
        server: url!, user: user!, password: password!, folder: '${folder.split('/').first}/form');
    expect(error, isNull);
    expect(service.config!.root.pathSegments, contains(id));
    expect(await storage.list('${folder.split('/').first}/form/changes'), hasLength(1));
  }, skip: skip);

  test('the id is not a login name, and that is not mistaken for a refused folder', () async {
    if (expectedId == null || expectedId == user) return;
    // As the app used to do it: login name as the id, the server accepts
    // the login and refuses the place.
    final asLogin = WebDavStorage(
      root: nextcloudFilesRoot(url!, user!),
      user: user,
      password: password!,
    );
    addTearDown(asLogin.close);
    await expectLater(
      asLogin.createDir(folder),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.forbidden)),
    );
    // The id itself is rejected as a login.
    await expectLater(
      discoverNextcloudUserId(server: url, login: expectedId, password: password),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.unauthorized)),
    );
  }, skip: skip);

  test('a wrong password is reported as such', () async {
    final wrong = WebDavStorage(
      root: nextcloudFilesRoot(url!, id),
      user: user!,
      password: 'definitely-not-the-password',
    );
    addTearDown(wrong.close);
    await expectLater(
      wrong.list(folder),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.unauthorized)),
    );
  }, skip: skip);

  test('two planners sync through the server, including file merging', () async {
    final a = newStore(), b = newStore();
    final syncA = SyncEngine(a, storage, folder: folder, compactAbove: 4);
    final syncB = SyncEngine(b, storage, folder: folder, compactAbove: 4);
    final id = a.addTask(DaySlot(monday), 'Über Nextcloud ✓')!;
    a.updateTask(id, note: 'line one\nline two', color: () => 'yellow');
    final daily = a.addTask(DaySlot(monday), 'Daily')!;
    a.setRecurrence(daily, Recurrence.weekdaysOnly);
    await syncA.sync();
    final first = await syncB.sync();
    expect(first.received, greaterThan(0));
    expect(b.task(id)!.title, 'Über Nextcloud ✓');
    expect(b.task(id)!.note, 'line one\nline two');
    expect(b.tasksOn(monday.addDays(1)).single.title, 'Daily');

    // Offline edits on both sides, then several rounds to force merging.
    b.setDone(id, true);
    b.addTask(DaySlot(today), 'Added on B');
    a.updateTask(id, title: 'Renamed on A');
    var merged = false;
    for (var i = 0; i < 6; i++) {
      a.addTask(DaySlot(monday.addDays(i)), 'Round $i');
      merged = (await syncA.sync()).compacted || merged;
      await syncB.sync();
    }
    await syncA.sync();
    expect(merged, isTrue);
    expect(a.task(id)!.done, isTrue);
    expect(b.task(id)!.title, 'Renamed on A');
    expect(titles(a.tasksOn(today)), contains('Added on B'));
    expect(a.allTasks.length, b.allTasks.length);

    // A device joining now gets everything from what is left in the folder.
    final c = newStore();
    await SyncEngine(c, storage, folder: folder).sync();
    expect(c.allTasks.length, a.allTasks.length);
    expect(c.task(id)!.title, 'Renamed on A');
    final files = await storage.list('$folder/changes');
    expect(files.length, lessThanOrEqualTo(8));
  }, skip: skip);
}
