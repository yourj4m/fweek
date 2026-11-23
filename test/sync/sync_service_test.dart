import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_engine.dart';
import 'package:fweek/sync/sync_service.dart';

/// Memory storage that can be made to reject every request.
class SwitchableStorage implements SyncStorage {
  SwitchableStorage(this.inner);

  final MemoryStorage inner;
  SyncException? failWith;
  int calls = 0;

  T _check<T>(T Function() run) {
    calls++;
    if (failWith != null) throw failWith!;
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

void main() {
  final today = Day(2026, 11, 13);
  final monday = Day(2026, 11, 9);
  const unauthorized = SyncException(
      SyncFailure.unauthorized, 'The server did not accept the user name or password.');
  const offline = SyncException(SyncFailure.offline, 'Could not reach cloud.example.com.');

  late Map<String, MemoryStorage> servers; // one per target folder
  late SwitchableStorage current;
  late MemorySecretStore secrets;
  late List<String> passwordsUsed;
  final services = <SyncService>[];

  PlannerStore newStore() {
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    return PlannerStore(db, today: () => today)..setSetting(Settings.rollover, false);
  }

  SyncService newService(PlannerStore store) {
    late final SyncService service;
    service = SyncService(
      store,
      secrets,
      storageFor: (config, password) {
        passwordsUsed.add(password);
        final memory = servers.putIfAbsent(config.target, MemoryStorage.new);
        return current = SwitchableStorage(memory)
          ..failWith = password == 'right' ? null : unauthorized;
      },
      clock: () => DateTime(2026, 11, 13, 12),
    );
    services.add(service);
    return service;
  }

  // The test framework checks for leftover timers when the test body ends,
  // before tear-downs run, so services are stopped inside the body.
  void serviceTest(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final service in services) {
          service.dispose();
        }
        services.clear();
      }
    });
  }

  Future<String?> connect(SyncService service,
          {String password = 'right', String folder = 'fweek'}) =>
      service.connect(
          server: 'cloud.example.com', user: 'jonas', password: password, folder: folder);

  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  setUp(() {
    servers = {};
    secrets = MemorySecretStore();
    passwordsUsed = [];
  });

  serviceTest('connect validates, proves the connection, then saves', (tester) async {
    final store = newStore();
    store.addTask(DaySlot(monday), 'Existing');
    final service = newService(store);

    expect(await service.connect(server: '', user: 'jonas', password: 'right', folder: 'x'),
        contains('server address'));
    expect(await service.connect(server: 'c.example.com', user: 'jonas', password: '', folder: 'x'),
        contains('app password'));
    expect(await connect(service, password: 'wrong'), contains('did not accept'));
    expect(service.configured, isFalse);
    expect(secrets.values, isEmpty);
    expect(store.db.meta('sync.config'), isNull);

    expect(await connect(service), isNull);
    expect(service.state, SyncState.idle);
    expect(service.config!.folder, 'fweek');
    expect(service.lastSync, DateTime(2026, 11, 13, 12));
    expect(secrets.values.values.single, 'right');
    // The existing planner went up.
    final files = servers.values.single.files;
    expect(files.keys.single, startsWith('fweek/changes/${store.db.deviceId}-'));
  });

  serviceTest('the folder left as offered joins a planner kept under the earlier name',
      (tester) async {
    SyncService serviceOn(PlannerStore store, MemoryStorage account) {
      final service = SyncService(
        store,
        MemorySecretStore(),
        storageFor: (config, password) => account,
        clock: () => DateTime(2026, 11, 13, 12),
      );
      services.add(service);
      return service;
    }

    Future<String?> join(SyncService service, String folder) => service.connect(
        server: 'cloud.example.com', user: 'jonas', password: 'right', folder: folder);

    // A device set up while the app was called WeekToDo.
    final account = MemoryStorage();
    final before = newStore()..addTask(DaySlot(monday), 'From before');
    expect(await join(serviceOn(before, account), earlierSyncFolder), isNull);

    // Another one connected today, the folder left as the form offers it:
    // it joins the planner instead of starting an empty folder beside it.
    final fresh = newStore();
    final service = serviceOn(fresh, account);
    expect(await join(service, defaultSyncFolder), isNull);
    expect(service.config!.folder, earlierSyncFolder);
    expect(titles(fresh.tasksOn(monday)), ['From before']);
    expect(account.files.keys.where((name) => name.startsWith('$defaultSyncFolder/')), isEmpty);

    // A folder typed by hand is taken as typed.
    final apart = serviceOn(newStore(), account);
    expect(await join(apart, 'Elsewhere'), isNull);
    expect(apart.config!.folder, 'Elsewhere');

    // An account with nothing in it gets the folder offered, and once that
    // holds a planner it is the one joined, whatever else is there.
    final empty = MemoryStorage();
    final first = serviceOn(newStore()..addTask(DaySlot(monday), 'New'), empty);
    expect(await join(first, defaultSyncFolder), isNull);
    expect(first.config!.folder, defaultSyncFolder);
    expect(await join(serviceOn(newStore()..addTask(DaySlot(monday), 'Old'), empty),
        earlierSyncFolder), isNull);
    final second = serviceOn(newStore(), empty);
    expect(await join(second, defaultSyncFolder), isNull);
    expect(second.config!.folder, defaultSyncFolder);
  });

  serviceTest('edits are uploaded shortly after, and remote changes arrive on a timer',
      (tester) async {
    final a = newStore(), b = newStore();
    final serviceA = newService(a);
    await connect(serviceA);
    final shared = servers.values.single;

    a.addTask(DaySlot(monday), 'typed');
    a.addTask(DaySlot(monday), 'typed again');
    final before = shared.files.length;
    await tester.pump(const Duration(seconds: 7));
    expect(shared.files.length, before, reason: 'still within the quiet period');
    await tester.pump(const Duration(seconds: 2));
    expect(shared.files.length, before + 1, reason: 'one upload for the burst');

    // Another device puts something in the folder.
    b.addTask(DaySlot(monday), 'from the phone');
    await SyncEngine(b, shared, folder: 'fweek').sync();
    expect(titles(a.tasksOn(monday)), isNot(contains('from the phone')));
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    expect(titles(a.tasksOn(monday)), contains('from the phone'));
    // Receiving does not trigger an upload of its own.
    final settled = shared.files.length;
    await tester.pump(const Duration(seconds: 30));
    expect(shared.files.length, settled);
  });

  serviceTest('a per-device setting does not cause an upload', (tester) async {
    final store = newStore();
    final service = newService(store);
    await connect(service);
    final files = servers.values.single.files.length;
    final calls = current.calls;
    store.setSetting(Settings.theme, 'dark');
    await tester.pump(const Duration(seconds: 20));
    expect(servers.values.single.files.length, files);
    expect(current.calls, calls);
  });

  serviceTest('offline errors are retried; a rejected password is not', (tester) async {
    final store = newStore();
    final service = newService(store);
    await connect(service);

    current.failWith = offline;
    store.addTask(DaySlot(monday), 'while offline');
    await tester.pump(const Duration(seconds: 9));
    expect(service.state, SyncState.error);
    expect(service.message, contains('Could not reach'));
    current.failWith = null;
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    expect(service.state, SyncState.idle);
    expect(servers.values.single.files.length, 2);

    current.failWith = unauthorized;
    await service.syncNow();
    expect(service.state, SyncState.error);
    final calls = current.calls;
    store.addTask(DaySlot(monday), 'while locked out');
    await tester.pump(const Duration(minutes: 16));
    expect(current.calls, calls, reason: 'no automatic retries with a rejected password');
    // Asking explicitly tries again, and recovers once the password works.
    current.failWith = null;
    await service.syncNow();
    expect(service.state, SyncState.idle);
    expect(servers.values.single.files.length, 3);
  });

  serviceTest('a throttled run is retried on the timer', (tester) async {
    // Nextcloud refuses a throttled login before it checks the password, so
    // retrying adds no failed attempt, and the saved password goes through
    // once the block lifts.
    final store = newStore();
    final service = newService(store);
    await connect(service);
    current.failWith = const SyncException(SyncFailure.throttled, 'too many failed attempts');
    await service.syncNow();
    expect(service.state, SyncState.error);
    final calls = current.calls;
    current.failWith = null;
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    expect(current.calls, greaterThan(calls));
    expect(service.state, SyncState.idle);
  });

  serviceTest('the files are found under the id the server reports', (tester) async {
    final store = newStore();
    String? reported = 'f00d-1d';
    SyncException? refusal;
    final seen = <String>[];
    final service = SyncService(
      store,
      secrets,
      storageFor: (config, password) {
        seen.add(config.root.toString());
        return MemoryStorage();
      },
      findUserId: (config, password) async {
        if (refusal != null) throw refusal;
        return reported;
      },
    );
    services.add(service);
    const pasted = 'https://cloud.example.com/remote.php/dav/files/from-address/';

    refusal = unauthorized;
    expect(await service.connect(server: pasted, user: 'jonas', password: 'right', folder: 'W'),
        unauthorized.message);
    expect(seen, isEmpty, reason: 'nothing is tried once the login is refused');
    expect(store.db.meta('sync.config'), isNull);

    refusal = null;
    expect(await service.connect(server: pasted, user: 'jonas', password: 'right', folder: 'W'),
        isNull);
    expect(seen.last, 'https://cloud.example.com/remote.php/dav/files/f00d-1d/');
    expect(service.config!.user, 'jonas');

    // A server that does not say: the id in a pasted address, else the login.
    reported = null;
    await service.connect(server: pasted, user: 'jonas', password: 'right', folder: 'W');
    expect(service.config!.userId, 'from-address');
    await service.connect(server: 'cloud.example.com', user: 'jonas', password: 'right', folder: 'W');
    expect(service.config!.userId, isNull);
    expect(seen.last, 'https://cloud.example.com/remote.php/dav/files/jonas/');
  });

  serviceTest('a saved connection is restored on start', (tester) async {
    final store = newStore();
    await connect(newService(store));
    final other = newStore()..addTask(DaySlot(monday), 'waiting on the server');
    await SyncEngine(other, servers.values.single, folder: 'fweek').sync();

    final restarted = newService(store);
    await restarted.load();
    await tester.pump();
    expect(restarted.configured, isTrue);
    expect(restarted.state, SyncState.idle);
    expect(passwordsUsed.last, 'right');
    expect(titles(store.tasksOn(monday)), ['waiting on the server']);

    // Without the keyring entry it says so instead of failing silently.
    secrets.values.clear();
    final broken = newService(store);
    await broken.load();
    expect(broken.state, SyncState.error);
    expect(broken.message, contains('Connect again'));
    secrets.failure = StateError('keyring locked');
    final locked = newService(store);
    await locked.load();
    expect(locked.message, contains('keyring'));
  });

  serviceTest('disconnect forgets the connection but keeps the data', (tester) async {
    final store = newStore();
    store.addTask(DaySlot(monday), 'kept');
    final service = newService(store);
    await connect(service);
    final remote = servers.values.single.files.length;
    await service.disconnect();
    expect(service.configured, isFalse);
    expect(service.state, SyncState.off);
    expect(secrets.values, isEmpty);
    expect(store.db.meta('sync.config'), isNull);
    expect(servers.values.single.files.length, remote);
    expect(titles(store.tasksOn(monday)), ['kept']);
    store.addTask(DaySlot(monday), 'after disconnecting');
    await tester.pump(const Duration(minutes: 10));
    expect(servers.values.single.files.length, remote);
  });

  serviceTest('pointing at another folder uploads the whole planner there', (tester) async {
    final store = newStore();
    store.addTask(DaySlot(monday), 'one');
    final service = newService(store);
    await connect(service);
    store.addTask(DaySlot(monday), 'two');
    await service.syncNow();
    await connect(service, folder: 'Elsewhere');
    expect(servers.keys, hasLength(2));
    final fresh = newStore();
    await SyncEngine(fresh, servers.values.last, folder: 'Elsewhere').sync();
    expect(titles(fresh.tasksOn(monday)), ['one', 'two']);
    // And going back to the first folder still works.
    store.addTask(DaySlot(monday), 'three');
    await connect(service);
    final back = newStore();
    await SyncEngine(back, servers.values.first, folder: 'fweek').sync();
    expect(titles(back.tasksOn(monday)), ['one', 'two', 'three']);
  });

  serviceTest('while the app is out of sight it does not go online by the clock', (tester) async {
    final store = newStore();
    final service = newService(store);
    expect(await connect(service), isNull);
    final before = current.calls;
    // A phone that has not put the hidden app to sleep yet: timers still run.
    service.leaving();
    await tester.pump(const Duration(minutes: 16));
    expect(current.calls, before);
    // Back in view, the five-minute rhythm resumes.
    service.resumed();
    await tester.pump(const Duration(minutes: 6));
    expect(current.calls, greaterThan(before));
  });
}
