import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';
import 'package:weektodo/sync/webdav.dart';

/// A small WebDAV server that answers the way Nextcloud does: Basic auth,
/// `d:`-prefixed multistatus listings with percent-encoded hrefs, 405 for an
/// existing collection, 409 for a missing parent, 412 for If-None-Match.
class FakeNextcloud {
  FakeNextcloud(this._server);

  static const user = 'jonas', password = 'app-pass word';
  static const prefix = '/remote.php/dav/files/$user';

  final HttpServer _server;
  final Map<String, Uint8List> files = {};
  final Set<String> dirs = {''};
  final List<String> requests = [];

  static Future<FakeNextcloud> start() async {
    final fake = FakeNextcloud(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
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
    final expected = 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
    if (request.headers.value('authorization') != expected) {
      response.statusCode = 401;
      response.headers.set('www-authenticate', 'Basic realm="Nextcloud"');
      return response.close();
    }
    if (!path.startsWith(prefix)) {
      response.statusCode = 404;
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
}
