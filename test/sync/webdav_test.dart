import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/sync/secrets.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';
import 'package:weektodo/sync/sync_service.dart';
import 'package:weektodo/sync/webdav.dart';

/// A small WebDAV server that answers the way Nextcloud does: Basic auth,
/// `d:`-prefixed multistatus listings with percent-encoded hrefs, 405 for an
/// existing collection, 409 for a missing parent, 412 for If-None-Match.
///
/// Like Nextcloud 34 (measured against one backed by LDAP): the account's
/// files live under its [id], which need not be the login name; an app
/// password works only with the login name it was created under (401
/// otherwise); another account's files answer 403 to MKCOL and 404 to
/// PROPFIND; `current-user-principal` names the id; [throttled] answers 429.
class FakeNextcloud {
  FakeNextcloud(this._server, this.id);

  static const user = 'jonas', password = 'app-pass word';

  /// The id the account's files are filed under.
  final String id;
  String get prefix => '/remote.php/dav/files/$id';

  /// Every request is refused as by brute-force protection.
  bool throttled = false;

  final HttpServer _server;
  final Map<String, Uint8List> files = {};
  final Set<String> dirs = {''};
  final List<String> requests = [];

  /// The Authorization user of every request, in order.
  final List<String> logins = [];

  static Future<FakeNextcloud> start({String id = user}) async {
    final fake = FakeNextcloud(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), id);
    fake._server.listen(fake._handle);
    return fake;
  }

  Uri get address => Uri.parse('http://127.0.0.1:${_server.port}');
  Future<void> stop() => _server.close(force: true);

  String _href(String path, {bool dir = false}) {
    final segments = [
      ...prefix.split('/').where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ].map(Uri.encodeComponent).join('/');
    return '/$segments${dir ? '/' : ''}';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final path = Uri.decodeComponent(request.uri.path);
    requests.add('${request.method} $path');
    final auth = request.headers.value('authorization') ?? '';
    final credentials = auth.startsWith('Basic ')
        ? utf8.decode(base64Decode(auth.substring(6)), allowMalformed: true)
        : '';
    logins.add(credentials.split(':').first);
    if (throttled) {
      response.statusCode = 429;
      return response.close();
    }
    if (credentials != '$user:$password') {
      response.statusCode = 401;
      response.headers.set('www-authenticate', 'Basic realm="Nextcloud"');
      return response.close();
    }
    if (path == '/remote.php/dav/' && request.method == 'PROPFIND') {
      response.statusCode = 207;
      response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
      response.write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" '
          'xmlns:s="http://sabredav.org/ns"><d:response><d:href>/remote.php/dav/</d:href>'
          '<d:propstat><d:prop><d:current-user-principal><d:href>'
          '/remote.php/dav/principals/users/${Uri.encodeComponent(id)}/'
          '</d:href></d:current-user-principal></d:prop>'
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>');
      return response.close();
    }
    if (path != prefix && !path.startsWith('$prefix/')) {
      // Another account's files, or nothing at all.
      response.statusCode =
          path.startsWith('/remote.php/dav/files/') && request.method == 'MKCOL' ? 403 : 404;
      return response.close();
    }
    final rel = path.substring(prefix.length).split('/').where((s) => s.isNotEmpty).join('/');
    final parent = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
    switch (request.method) {
      case 'MKCOL':
        response.statusCode = dirs.contains(rel)
            ? 405
            : dirs.contains(parent)
                ? 201
                : 409;
        if (response.statusCode == 201) dirs.add(rel);
      case 'PROPFIND':
        if (!dirs.contains(rel)) {
          response.statusCode = 404;
          break;
        }
        final entries = StringBuffer();
        void entry(String href, {required bool dir, int size = 0}) => entries.write(
            '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '${dir ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:resourcetype/>'}'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
        entry(_href(rel, dir: true), dir: true);
        for (final d in dirs) {
          if (d.isNotEmpty && (d.contains('/') ? d.substring(0, d.lastIndexOf('/')) : '') == rel) {
            entry(_href(d, dir: true), dir: true);
          }
        }
        for (final f in files.keys) {
          if ((f.contains('/') ? f.substring(0, f.lastIndexOf('/')) : '') == rel) {
            entry(_href(f), dir: false, size: files[f]!.length);
          }
        }
        response.statusCode = 207;
        response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        response.write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" '
            'xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" '
            'xmlns:nc="http://nextcloud.org/ns">$entries</d:multistatus>');
      case 'PUT':
        if (!dirs.contains(parent)) {
          response.statusCode = 409;
        } else if (request.headers.value('if-none-match') == '*' && files.containsKey(rel)) {
          response.statusCode = 412;
        } else {
          response.statusCode = files.containsKey(rel) ? 204 : 201;
          files[rel] = Uint8List.fromList(body);
        }
      case 'GET':
        final bytes = files[rel];
        if (bytes == null) {
          response.statusCode = 404;
        } else {
          response.add(bytes);
        }
      case 'DELETE':
        response.statusCode = files.remove(rel) != null ? 204 : 404;
      default:
        response.statusCode = 405;
    }
    return response.close();
  }
}

void main() {
  group('server address', () {
    test('accepts the forms people type', () {
      const expected = 'https://cloud.example.com/remote.php/dav/files/jonas/';
      for (final typed in [
        'cloud.example.com',
        'https://cloud.example.com',
        ' https://cloud.example.com/ ',
        'https://cloud.example.com/remote.php/dav/files/jonas/',
        'https://cloud.example.com/remote.php/webdav',
      ]) {
        expect(nextcloudFilesRoot(typed, 'jonas').toString(), expected, reason: typed);
      }
      expect(
        nextcloudFilesRoot('https://example.com:8443/nextcloud/', 'j.m@example.com').toString(),
        'https://example.com:8443/nextcloud/remote.php/dav/files/j.m@example.com/',
      );
      expect(nextcloudFilesRoot('http://localhost:8080', 'admin').toString(),
          'http://localhost:8080/remote.php/dav/files/admin/');
    });

    test('rejects what cannot work, saying why', () {
      expect(() => nextcloudFilesRoot('', 'jonas'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('server address'))));
      expect(() => nextcloudFilesRoot('ftp://x', 'jonas'), throwsFormatException);
      expect(() => nextcloudFilesRoot('cloud.example.com', ' '),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('user name'))));
      expect(normalizeFolder(' /Apps//WeekToDo/ '), 'Apps/WeekToDo');
      expect(() => normalizeFolder(' / '), throwsFormatException);
      expect(() => normalizeFolder('../..'), throwsFormatException);
    });

    test('finds the WebDAV service in pasted WebDAV and web interface addresses', () {
      const id = '0f1e2d3c-4b5a-1069-8877-665544332211';
      for (final typed in [
        'cloud.example.com',
        'https://cloud.example.com/remote.php/dav/files/$id',
        'https://cloud.example.com/remote.php/dav/files/$id/Documents/',
        'https://cloud.example.com/remote.php/webdav/',
        'https://cloud.example.com/index.php/apps/files/?dir=/',
        'https://cloud.example.com/apps/files/files?dir=/',
      ]) {
        expect(nextcloudDavBase(typed).toString(), 'https://cloud.example.com/remote.php/dav/',
            reason: typed);
      }
      // An install in a subdirectory keeps it, even one called `apps`.
      expect(nextcloudDavBase('https://example.com/apps/nextcloud/').toString(),
          'https://example.com/apps/nextcloud/remote.php/dav/');
      expect(nextcloudDavBase('https://example.com/nc/index.php/login').toString(),
          'https://example.com/nc/remote.php/dav/');
      // The files root is built from the id, whatever the address held.
      expect(nextcloudFilesRoot('https://cloud.example.com/remote.php/dav/files/$id', 'other')
          .toString(), 'https://cloud.example.com/remote.php/dav/files/other/');

      expect(nextcloudUserIdInAddress('https://cloud.example.com/remote.php/dav/files/$id'), id);
      expect(nextcloudUserIdInAddress('https://x/nc/remote.php/dav/files/j%20m/Notes/'), 'j m');
      expect(nextcloudUserIdInAddress('cloud.example.com'), isNull);
      expect(nextcloudUserIdInAddress('https://x/remote.php/webdav/'), isNull);
      expect(nextcloudUserIdInAddress('https://x/remote.php/dav/'), isNull);
    });
  });

  test('parses a Nextcloud listing: files only, names decoded', () {
    const body = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response><d:href>/remote.php/dav/files/jonas/WeekToDo/changes/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/jonas/WeekToDo/changes/0a1b2c3d-00000001.json</d:href>
  <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/jonas/WeekToDo/changes/My%20notes%20%c3%a4.txt</d:href>
  <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/jonas/WeekToDo/changes/old/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''';
    final names = WebDavStorage.parseListing(
      body,
      Uri.parse('https://cloud.example.com/remote.php/dav/files/jonas/WeekToDo/changes/'),
    );
    expect(names, ['0a1b2c3d-00000001.json', 'My notes ä.txt']);
    // Other servers use other prefixes or a default namespace.
    final plain = body.replaceAll('d:', 'D:').replaceAll('xmlns:d=', 'xmlns:D=');
    expect(
      WebDavStorage.parseListing(plain,
          Uri.parse('https://x/remote.php/dav/files/jonas/WeekToDo/changes/')),
      hasLength(2),
    );
    expect(
      () => WebDavStorage.parseListing('<html>Login', Uri.parse('https://x/a/')),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.incompatible)),
    );
  });

  group('against a server', () {
    late FakeNextcloud server;
    late WebDavStorage storage;

    setUp(() async {
      server = await FakeNextcloud.start();
      storage = WebDavStorage(
        root: nextcloudFilesRoot(server.address.toString(), FakeNextcloud.user),
        user: FakeNextcloud.user,
        password: FakeNextcloud.password,
      );
    });
    tearDown(() async {
      storage.close();
      await server.stop();
    });

    test('creates nested folders, writes, lists, reads and deletes', () async {
      expect(await storage.list('Apps/WeekToDo/changes'), isEmpty);
      await storage.createDir('Apps/WeekToDo/changes');
      expect(server.dirs, containsAll(['Apps', 'Apps/WeekToDo', 'Apps/WeekToDo/changes']));
      await storage.createDir('Apps/WeekToDo/changes'); // again: no error
      final bytes = Uint8List.fromList(utf8.encode('{"hello":"wörld"}'));
      await storage.write('Apps/WeekToDo/changes/a b.json', bytes);
      await storage.write('Apps/WeekToDo/changes/second.json', Uint8List(0));
      expect(await storage.list('Apps/WeekToDo/changes'),
          unorderedEquals(['a b.json', 'second.json']));
      expect(await storage.list('Apps/WeekToDo'), isEmpty); // only a sub-folder
      expect(await storage.read('Apps/WeekToDo/changes/a b.json'), bytes);
      expect(await storage.read('Apps/WeekToDo/changes/missing.json'), isNull);
      await storage.delete('Apps/WeekToDo/changes/a b.json');
      await storage.delete('Apps/WeekToDo/changes/a b.json'); // again: no error
      expect(await storage.list('Apps/WeekToDo/changes'), ['second.json']);
    });

    test('refuses to replace a file unless asked to', () async {
      await storage.createDir('p');
      await storage.write('p/f.json', Uint8List.fromList([1]));
      await expectLater(
        storage.write('p/f.json', Uint8List.fromList([2])),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.exists)),
      );
      expect(server.files['p/f.json'], [1]);
      await storage.write('p/f.json', Uint8List.fromList([3]), overwrite: true);
      expect(server.files['p/f.json'], [3]);
    });

    test('reports a wrong password, a missing folder and an unreachable server', () async {
      final wrong = WebDavStorage(
        root: storage.root,
        user: FakeNextcloud.user,
        password: 'nope',
      );
      addTearDown(wrong.close);
      await expectLater(
        wrong.list('x'),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.unauthorized)),
      );
      await expectLater(
        storage.write('no-such-folder/f.json', Uint8List(1)),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.notFound)),
      );
      final port = server.address.port;
      await server.stop();
      final gone = WebDavStorage(
        root: Uri.parse('http://127.0.0.1:$port/remote.php/dav/files/jonas/'),
        user: 'jonas',
        password: 'x',
      );
      addTearDown(gone.close);
      await expectLater(
        gone.list('x'),
        throwsA(isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.offline)
            .having((e) => e.message, 'message', contains('127.0.0.1'))),
      );
    });

    test('two planners sync through it', () async {
      final today = Day(2026, 11, 13), monday = Day(2026, 11, 9);
      PlannerStore newStore() {
        final db = PlannerDatabase.inMemory();
        addTearDown(db.close);
        return PlannerStore(db, today: () => today);
      }

      final a = newStore(), b = newStore();
      final syncA = SyncEngine(a, storage, folder: 'WeekToDo');
      final syncB = SyncEngine(b, storage, folder: 'WeekToDo');
      final id = a.addTask(DaySlot(monday), 'Über WebDAV ✓')!;
      await syncA.sync();
      await syncB.sync();
      expect(b.task(id)!.title, 'Über WebDAV ✓');
      b.updateTask(id, note: 'reply from B');
      b.setDone(id, true);
      await syncB.sync();
      await syncA.sync();
      expect(a.task(id)!.note, 'reply from B');
      expect(a.task(id)!.done, isTrue);
      // The folder is only created once per device.
      expect(server.requests.where((r) => r.startsWith('MKCOL')).length, lessThanOrEqualTo(6));
      expect(server.files.keys, everyElement(startsWith('WeekToDo/changes/')));
    });
  });

  // Accounts that come from a directory (LDAP), as on many university
  // servers, log in with a name such as `jdoe` but have their files under
  // a generated id such as a UUID. The app used to put the login name in
  // both places.
  group('an account whose login name is not its id', () {
    const id = '0f1e2d3c-4b5a-1069-8877-665544332211';
    final monday = Day(2026, 11, 9);
    late FakeNextcloud server;

    setUp(() async => server = await FakeNextcloud.start(id: id));
    tearDown(() => server.stop());

    TypeMatcher<SyncException> failure(SyncFailure expected) =>
        isA<SyncException>().having((e) => e.failure, 'failure', expected);

    PlannerStore newStore() {
      final db = PlannerDatabase.inMemory();
      addTearDown(db.close);
      return PlannerStore(db, today: () => monday);
    }

    Future<String?> discover({String login = FakeNextcloud.user, String? password, String? at}) =>
        discoverNextcloudUserId(
          server: at ?? '${server.address}',
          login: login,
          password: password ?? FakeNextcloud.password,
        );

    test('the server reports the id once logged in with the login name', () async {
      expect(await discover(), id);
      expect(server.requests, ['PROPFIND /remote.php/dav/']);
      // An app password belongs to its login name: the id does not log in.
      await expectLater(discover(login: id), throwsA(failure(SyncFailure.unauthorized)));
      await expectLater(discover(password: 'nope'), throwsA(failure(SyncFailure.unauthorized)));
      await expectLater(discover(at: '${server.address}/elsewhere'),
          throwsA(failure(SyncFailure.notFound)));
    });

    test('a refused location and throttling are not reported as a wrong password', () async {
      // What the app used to do: the login name as the files' id.
      final asBefore = WebDavStorage(
        root: nextcloudFilesRoot('${server.address}', FakeNextcloud.user),
        user: FakeNextcloud.user,
        password: FakeNextcloud.password,
      );
      addTearDown(asBefore.close);
      await expectLater(
        asBefore.createDir('WeekToDo/changes'),
        throwsA(failure(SyncFailure.forbidden).having(
            (e) => e.message, 'message', allOf(contains('accepted the login'), isNot(contains('password'))))),
      );
      server.throttled = true;
      await expectLater(
        asBefore.list('WeekToDo/changes'),
        throwsA(failure(SyncFailure.throttled)
            .having((e) => e.message, 'message', contains('too many failed attempts'))),
      );
    });

    test('connecting needs only what Nextcloud shows: login name and app password', () async {
      final store = newStore()..addTask(DaySlot(monday), 'from here');
      final secrets = MemorySecretStore();
      final service = SyncService(store, secrets);
      // Copied with the line break after it.
      final error = await service.connect(
        server: '${server.address}',
        user: FakeNextcloud.user,
        password: '${FakeNextcloud.password}\n',
        folder: 'WeekToDo',
      );
      service.dispose();
      expect(error, isNull);
      expect(service.config!.root.path, '/remote.php/dav/files/$id/');
      expect(server.logins.toSet(), {FakeNextcloud.user}, reason: 'the id never logs in');
      expect(server.files.keys.single, startsWith('WeekToDo/changes/'));
      expect(jsonDecode(store.db.meta('sync.config')!), {
        'server': '${server.address}',
        'user': FakeNextcloud.user,
        'folder': 'WeekToDo',
        'userId': id,
      });
      expect(secrets.values.values.single, FakeNextcloud.password);

      // Started again, it uses what was saved, without asking again.
      server.requests.clear();
      final again = SyncService(store, secrets);
      await again.load();
      await again.syncNow();
      again.dispose();
      expect(again.state, SyncState.idle);
      expect(server.requests, isNot(contains('PROPFIND /remote.php/dav/')));
      expect(server.requests, everyElement(contains('/remote.php/dav/files/$id/')));
    });

    test('a pasted WebDAV address is fine; the id as user name is explained', () async {
      final store = newStore();
      final service = SyncService(store, MemorySecretStore());
      addTearDown(service.dispose);
      final asId = await service.connect(
        server: '${server.address}/remote.php/dav/files/$id',
        user: id,
        password: FakeNextcloud.password,
        folder: 'WeekToDo',
      );
      expect(asId, allOf(contains('did not accept the login name'),
          contains('login name Nextcloud shows'), isNot(contains(FakeNextcloud.password))));
      expect(store.db.meta('sync.config'), isNull);

      expect(
        await service.connect(
          server: '${server.address}/remote.php/dav/files/$id/',
          user: FakeNextcloud.user,
          password: FakeNextcloud.password,
          folder: 'WeekToDo',
        ),
        isNull,
      );
      expect(service.config!.user, FakeNextcloud.user);
      expect(service.config!.userId, id);

      server.throttled = true;
      expect(
        await service.connect(
            server: '${server.address}', user: FakeNextcloud.user,
            password: FakeNextcloud.password, folder: 'WeekToDo'),
        contains('too many failed attempts'),
      );
    });
  });

  test('a connection saved by the previous version keeps working as it was', () async {
    final server = await FakeNextcloud.start(); // login name and id the same
    addTearDown(server.stop);
    final db = PlannerDatabase.inMemory();
    addTearDown(db.close);
    final store = PlannerStore(db, today: () => Day(2026, 11, 9));
    final address = '${server.address}';
    final target = '$address/remote.php/dav/files/jonas/WeekToDo';
    db.setMeta('sync.config',
        jsonEncode({'server': address, 'user': 'jonas', 'folder': 'WeekToDo'}));
    db.setMeta('sync.target', target);
    db.setMeta('sync.seen', '{"0a1b2c3d":4}');
    final secrets = MemorySecretStore()..values['nextcloud-app-password'] = FakeNextcloud.password;

    final service = SyncService(store, secrets);
    await service.load();
    await service.syncNow();
    service.dispose();
    expect(service.state, SyncState.idle);
    expect(service.config!.userId, isNull);
    // Same folder, so this device's bookkeeping is kept rather than reset.
    expect(db.meta('sync.target'), target);
    expect(db.meta('sync.seen'), '{"0a1b2c3d":4}');
    expect(server.requests, everyElement(contains('/remote.php/dav/files/jonas/')));
  });

  test('a principal that is not an address leaves the id to the fallbacks', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = 207
        ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
        ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response>'
            '<d:href>/remote.php/dav/</d:href><d:propstat><d:prop><d:current-user-principal>'
            '<d:href>http://[broken/principals/users/x/</d:href></d:current-user-principal>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            '</d:multistatus>');
      await request.response.close();
    });
    expect(
      await discoverNextcloudUserId(
          server: 'http://127.0.0.1:${server.port}', login: 'jonas', password: 'x'),
      isNull,
    );
  });
}
