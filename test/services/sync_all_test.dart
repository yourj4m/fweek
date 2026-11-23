import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/calendar_service.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/local_backups.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/services/sync_all.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_service.dart';

/// A calendar served from this machine.
class LocalCalendar {
  late HttpServer _server;
  int status = 200;
  int requests = 0;
  String title = 'Dentist';

  String get address => 'http://127.0.0.1:${_server.port}/basic.ics';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests++;
      final response = request.response..statusCode = status;
      if (status == 200) {
        response.headers.contentType = ContentType('text', 'calendar', charset: 'utf-8');
        response.add(utf8.encode([
          'BEGIN:VCALENDAR',
          'VERSION:2.0',
          'BEGIN:VEVENT',
          'UID:one@test',
          'SUMMARY:$title',
          'DTSTART;VALUE=DATE:20261113',
          'END:VEVENT',
          'END:VCALENDAR',
          '',
        ].join('\r\n')));
      }
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  final monday = Day(2026, 11, 9), friday = Day(2026, 11, 13);
  const offline = SyncException(SyncFailure.offline, 'Could not reach cloud.example.com.');
  late Directory folder;
  late MemoryStorage account;
  SyncException? cloudDown;

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => monday)..setSetting(Settings.rollover, false);
  }

  SyncService syncFor(PlannerStore store) {
    final service = SyncService(
      store,
      MemorySecretStore(),
      storageFor: (config, password) => _Gate(account, () => cloudDown),
    );
    addTearDown(service.dispose);
    return service;
  }

  CalendarService calendarsFor(PlannerStore store) {
    final service = CalendarService(store, MemorySecretStore(), MemoryCalendarCache());
    addTearDown(service.dispose);
    return service;
  }

  Future<void> connect(SyncService service) async => expect(
      await service.connect(
          server: 'cloud.example.com', user: 'me', password: 'right', folder: 'fweek'),
      isNull);

  setUp(() {
    folder = Directory.systemTemp.createTempSync('fweek-syncall-');
    account = MemoryStorage();
    cloudDown = null;
  });
  tearDown(() => folder.deleteSync(recursive: true));

  test('with nothing set up it keeps a copy of the planner, and says so', () async {
    final store = newStore()..addTask(DaySlot(monday), 'Only here');
    final copies = LocalBackups(folder);
    final all = SyncAll(
        store: store, sync: syncFor(store), calendars: calendarsFor(store), backups: copies);
    final states = <bool>[];
    all.addListener(() => states.add(all.running));

    final result = await all.run();
    expect(result.ok, isTrue);
    expect(result.message, 'A copy of the planner was kept on this device');
    expect(copies.list(), hasLength(1));
    // Listeners hear of the start and of the end.
    expect(states, [true, false]);
    expect(all.last, same(result));

    // Without a place for copies there is nothing to do, which is said too.
    final bare = SyncAll(store: store, sync: syncFor(store), calendars: calendarsFor(store));
    expect((await bare.run()).message, 'Nothing to sync yet');
  });

  test('it syncs with Nextcloud, reads the calendars again, then keeps a copy', () async {
    final server = LocalCalendar();
    await server.start();
    addTearDown(server.stop);

    // Another device put a task into the folder.
    final other = newStore()..addTask(DaySlot(monday), 'From the phone');
    final phone = syncFor(other);
    await connect(phone);

    final store = newStore();
    final sync = syncFor(store);
    await connect(sync);
    final calendars = calendarsFor(store);
    expect(await calendars.add(address: server.address, name: 'Work'), isNull);
    final copies = LocalBackups(folder);
    final all = SyncAll(store: store, sync: sync, calendars: calendars, backups: copies);
    // Since then the phone added a task, and the calendar changed.
    other.addTask(DaySlot(monday), 'Added later');
    await phone.syncNow();
    server.title = 'Dentist, moved';
    final before = server.requests;

    // Two presses are one run.
    final first = all.run(), second = all.run();
    expect(second, same(first));
    final result = await first;
    expect(result.ok, isTrue);
    expect(result.message, 'Nextcloud in sync · calendar read · copy kept');
    expect([for (final t in store.tasksOn(monday)) t.title],
        containsAll(['From the phone', 'Added later']));
    expect(server.requests, before + 1);
    expect(calendars.eventsBetween(friday, friday).byDay[friday]!.single.title, 'Dentist, moved');
    // The copy was made last: it holds what arrived.
    expect(copies.list().single.file.readAsStringSync(), contains('Added later'));
  });

  test('what fails is named, and the rest is still done', () async {
    final server = LocalCalendar();
    await server.start();
    addTearDown(server.stop);
    final store = newStore()..addTask(DaySlot(monday), 'Mine');
    final sync = syncFor(store);
    await connect(sync);
    final calendars = calendarsFor(store);
    expect(await calendars.add(address: server.address, name: 'Work'), isNull);
    final copies = LocalBackups(folder);
    final all = SyncAll(store: store, sync: sync, calendars: calendars, backups: copies);

    cloudDown = offline;
    var result = await all.run();
    expect(result.ok, isFalse);
    expect(result.message, 'Nextcloud: Could not reach cloud.example.com.');
    expect(result.done, ['calendar read', 'copy kept']);
    expect(copies.list(), hasLength(1));

    cloudDown = null;
    server.status = 500;
    result = await all.run();
    expect(result.done, ['Nextcloud in sync', 'copy kept']);
    expect(result.failed.single, startsWith('Work: '));

    server.status = 200;
    expect((await all.run()).ok, isTrue);
  });
}

/// Memory storage that fails while [down] says so.
class _Gate implements SyncStorage {
  _Gate(this.inner, this.down);

  final MemoryStorage inner;
  final SyncException? Function() down;

  T _check<T>(T Function() run) {
    final failure = down();
    if (failure != null) throw failure;
    return run();
  }

  @override
  Future<List<String>> list(String dir) async => _check(() => inner.list(dir));
  @override
  Future<Uint8List?> read(String path) async => _check(() => inner.read(path));
  @override
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false}) async =>
      _check(() => inner.write(path, bytes, overwrite: overwrite));
  @override
  Future<void> delete(String path) async => _check(() => inner.delete(path));
  @override
  Future<void> createDir(String dir) async => _check(() => inner.createDir(dir));
}
