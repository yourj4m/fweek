import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'storage.dart';

/// The server address as typed, parsed. Throws [FormatException] with a
/// message for the user if it is not usable.
Uri _parseServer(String server) {
  var text = server.trim();
  if (text.isEmpty) throw const FormatException('Enter the server address.');
  if (!text.contains('://')) text = 'https://$text';
  final Uri base;
  try {
    base = Uri.parse(text);
  } on FormatException {
    throw const FormatException('That is not a valid server address.');
  }
  if (base.host.isEmpty || (base.scheme != 'https' && base.scheme != 'http')) {
    throw const FormatException('That is not a valid server address.');
  }
  return base;
}

// Where Nextcloud's own paths start in an address copied from somewhere:
// the WebDAV address from the Files settings, or the browser's address bar
// (`index.php/apps/files`, or `apps/files` when the server hides index.php).
// What comes before is the install's own location (a subdirectory or none).
int _nextcloudPathStart(List<String> segments) {
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    if (s == 'remote.php' || s == 'index.php') return i;
    // Only with `files` after it: an install may live in a directory that
    // happens to be called `apps`.
    if (s == 'apps' && i + 1 < segments.length && segments[i + 1] == 'files') return i;
  }
  return -1;
}

/// The address of a Nextcloud install's WebDAV service, ending with `/`.
///
/// [server] may be typed loosely: `cloud.example.com`,
/// `https://cloud.example.com/`, an install in a subdirectory such as
/// `https://example.com/nextcloud`, a full WebDAV address copied from
/// Nextcloud's Files settings, or the address of a page of the web
/// interface. Throws [FormatException] with a message for the user if it is
/// not usable.
Uri nextcloudDavBase(String server) {
  final base = _parseServer(server);
  var segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
  final own = _nextcloudPathStart(segments);
  if (own >= 0) segments = segments.sublist(0, own);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [...segments, 'remote.php', 'dav', ''],
  );
}

/// The WebDAV address of a Nextcloud account's files.
///
/// [userId] is the id Nextcloud files the account under, the segment after
/// `files/` in the WebDAV address. It is not always the name used to log in:
/// accounts that come from a directory (LDAP), as at many universities, get
/// a generated id such as a UUID. [discoverNextcloudUserId] asks the server.
/// [server] is read as by [nextcloudDavBase].
Uri nextcloudFilesRoot(String server, String userId) {
  final base = nextcloudDavBase(server);
  if (userId.trim().isEmpty) throw const FormatException('Enter the user name.');
  return base.replace(pathSegments: [
    ...base.pathSegments.where((s) => s.isNotEmpty),
    'files',
    userId.trim(),
    '',
  ]);
}

/// The account id in a WebDAV address pasted as the server, such as
/// `https://cloud.example.com/remote.php/dav/files/<id>/`, or null if there
/// is none. Only a fallback: the id the server reports after logging in is
/// the one that counts, and the pasted one may belong to another account.
String? nextcloudUserIdInAddress(String server) {
  final Uri base;
  try {
    base = _parseServer(server);
  } on FormatException {
    return null;
  }
  final segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
  final dav = segments.indexOf('remote.php');
  if (dav < 0 || segments.length < dav + 4) return null;
  if (segments[dav + 1] != 'dav' || segments[dav + 2] != 'files') return null;
  return segments[dav + 3];
}

/// Logs in to the Nextcloud at [server] and returns the id it files the
/// account under (see [nextcloudFilesRoot]), or null if the server does not
/// say. Throws [SyncException]: [SyncFailure.unauthorized] when the login
/// name or password is rejected, [SyncFailure.notFound] when there is no
/// Nextcloud at that address, and the usual failures otherwise.
///
/// Nextcloud accepts an app password only together with the login name it
/// was created under, so [login] is that name, not the id.
Future<String?> discoverNextcloudUserId({
  required String server,
  required String login,
  required String password,
  HttpClient? client,
}) async {
  final dav = WebDavStorage(
    root: nextcloudDavBase(server),
    user: login,
    password: password,
    client: client,
  );
  try {
    final principal = await dav.currentUserPrincipal();
    if (principal == null) return null;
    // `/remote.php/dav/principals/users/<id>/`; ids may contain characters
    // that are percent-encoded there (spaces, `@`).
    final List<String> segments;
    try {
      segments = Uri.parse(principal).pathSegments.where((s) => s.isNotEmpty).toList();
    } on FormatException {
      // Not an address at all. Connecting must end with a message, not an
      // exception that would leave the settings form waiting forever, so
      // leave the id to the fallbacks.
      return null;
    }
    final users = segments.lastIndexOf('users');
    if (users < 0 || users != segments.length - 2) return null;
    return segments.last;
  } finally {
    dav.close();
  }
}

/// A folder name as typed, tidied into a relative path. Throws
/// [FormatException] if nothing is left.
String normalizeFolder(String folder) {
  final parts = folder
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != '.' && s != '..');
  if (parts.isEmpty) throw const FormatException('Enter a folder name.');
  return parts.join('/');
}

/// Files on a WebDAV server (Nextcloud or any other), under a root collection.
class WebDavStorage implements SyncStorage {
  WebDavStorage({
    required Uri root,
    required String user,
    required String password,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
  })  : root = root.path.endsWith('/') ? root : root.replace(path: '${root.path}/'),
        _authorization =
            'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.userAgent = 'fweek';
  }

  /// The collection all paths are relative to; ends with `/`.
  final Uri root;
  final Duration timeout;
  final String _authorization;
  final HttpClient _client;

  Uri _uri(String path, {bool directory = false}) {
    final segments = [
      ...root.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
      if (directory) '',
    ];
    return root.replace(pathSegments: segments);
  }

  Future<(int, Uint8List)> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await response.forEach(bytes.add).timeout(timeout);
      final status = response.statusCode;
      // Nextcloud answers 401 to a login it rejects and 403 to a login it
      // accepted for a place that account may not use (another account's
      // files, for one). Telling them apart matters: a 403 says nothing about
      // the password.
      if (status == 401) {
        throw const SyncException(
          SyncFailure.unauthorized,
          'The server did not accept the login name or app password. Use the '
          'login name Nextcloud shows when you create the app password.',
        );
      }
      if (status == 403) {
        throw SyncException(
          SyncFailure.forbidden,
          'The server accepted the login but refused access to '
          '${Uri.decodeFull(uri.path)}. If the app password was created '
          'without "Allow filesystem access", create one with it.',
        );
      }
      // Nextcloud's brute-force protection: after more than ten failed
      // logins from this network address within half an hour it refuses
      // every login from it, right ones included, until they age out.
      if (status == 429) {
        throw const SyncException(
          SyncFailure.throttled,
          'The server is refusing logins for now because of too many failed '
          'attempts. Wait about half an hour before trying again.',
        );
      }
      if (status >= 300 && status < 400) {
        throw SyncException(
          SyncFailure.notFound,
          'The server redirected the request; check the address '
          '(${response.headers.value(HttpHeaders.locationHeader) ?? 'no target given'}).',
        );
      }
      if (status >= 500) {
        throw SyncException(
          SyncFailure.server,
          'The server reported an error ($status).',
        );
      }
      return (status, bytes.takeBytes());
    } on SocketException catch (error) {
      throw SyncException(
        SyncFailure.offline,
        'Could not reach ${uri.host}: ${error.osError?.message ?? error.message}.',
      );
    } on HandshakeException {
      throw SyncException(
        SyncFailure.offline,
        'Could not make a secure connection to ${uri.host}.',
      );
    } on TlsException {
      throw SyncException(
        SyncFailure.offline,
        'The certificate of ${uri.host} could not be verified.',
      );
    } on TimeoutException {
      throw SyncException(
        SyncFailure.offline,
        '${uri.host} did not answer in time.',
      );
    } on HttpException catch (error) {
      throw SyncException(SyncFailure.offline, 'Connection problem: ${error.message}.');
    }
  }

  static const _propfind = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';

  @override
  Future<List<String>> list(String dir) async {
    final uri = _uri(dir, directory: true);
    final (status, body) = await _send(
      'PROPFIND',
      uri,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(_propfind),
    );
    if (status == 404) return [];
    if (status != 207) {
      throw SyncException(
        SyncFailure.server,
        'The server could not list the folder ($status).',
      );
    }
    return parseListing(utf8.decode(body, allowMalformed: true), uri);
  }

  static const _principalPropfind = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>';

  /// The address of the logged-in account's principal (RFC 5397), as the
  /// server writes it, or null if it does not say. Asked of [root], which
  /// for Nextcloud is the WebDAV service itself (see [nextcloudDavBase]).
  Future<String?> currentUserPrincipal() async {
    final (status, body) = await _send(
      'PROPFIND',
      root,
      headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(_principalPropfind),
    );
    if (status == 404) {
      throw SyncException(
        SyncFailure.notFound,
        'No Nextcloud answered at $root; check the server address.',
      );
    }
    if (status != 207) {
      throw SyncException(
        SyncFailure.server,
        'The server did not answer like a WebDAV server ($status); '
        'check the server address.',
      );
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(utf8.decode(body, allowMalformed: true));
    } on XmlException {
      throw const SyncException(
        SyncFailure.incompatible,
        'The server answered with something that is not a WebDAV reply.',
      );
    }
    // Only an href inside the property, not the response's own href.
    for (final principal
        in document.findAllElements('current-user-principal', namespaceUri: '*')) {
      final href = principal.getElement('href', namespaceUri: '*')?.innerText.trim();
      if (href != null && href.isNotEmpty) return href;
    }
    return null;
  }

  /// The names of the files in a PROPFIND `multistatus` answer for the
  /// collection at [collection]. Sub-collections and the collection itself
  /// are left out.
  static List<String> parseListing(String body, Uri collection) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException {
      throw const SyncException(
        SyncFailure.incompatible,
        'The server answered with something that is not a WebDAV listing.',
      );
    }
    List<String> segmentsOf(String path) =>
        Uri.parse(path).pathSegments.where((s) => s.isNotEmpty).toList();
    final own = collection.pathSegments.where((s) => s.isNotEmpty).toList();
    final names = <String>[];
    for (final response in document.findAllElements('response', namespaceUri: '*')) {
      final href = response.getElement('href', namespaceUri: '*')?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final isCollection = response
          .findAllElements('collection', namespaceUri: '*')
          .isNotEmpty;
      final segments = segmentsOf(href);
      if (isCollection || segments.length != own.length + 1) continue;
      names.add(segments.last);
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final (status, body) = await _send('GET', _uri(path));
    if (status == 404) return null;
    if (status != 200) {
      throw SyncException(SyncFailure.server, 'Could not read $path ($status).');
    }
    return body;
  }

  @override
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false}) async {
    final (status, _) = await _send(
      'PUT',
      _uri(path),
      headers: {
        'Content-Type': 'application/octet-stream',
        if (!overwrite) 'If-None-Match': '*',
      },
      body: bytes,
    );
    if (status == 412) {
      throw SyncException(SyncFailure.exists, '$path already exists.');
    }
    if (status == 404 || status == 409) {
      throw SyncException(
        SyncFailure.notFound,
        'The folder for $path does not exist on the server.',
      );
    }
    if (status != 200 && status != 201 && status != 204) {
      throw SyncException(SyncFailure.server, 'Could not save $path ($status).');
    }
  }

  @override
  Future<void> delete(String path) async {
    final (status, _) = await _send('DELETE', _uri(path));
    if (status != 200 && status != 204 && status != 404) {
      throw SyncException(SyncFailure.server, 'Could not remove $path ($status).');
    }
  }

  @override
  Future<void> createDir(String dir) async {
    // MKCOL only creates one level, so walk down from the root collection.
    final parts = dir.split('/').where((s) => s.isNotEmpty).toList();
    for (var depth = 0; depth <= parts.length; depth++) {
      final path = parts.take(depth).join('/');
      final (status, _) = await _send('MKCOL', _uri(path, directory: true));
      // 201 created; 405 already there. Anything else on the last level is a
      // real failure; on the way down a 409 means a parent is missing, which
      // the next iteration cannot fix either.
      if (status == 201 || status == 405) continue;
      if (status == 404 || status == 409) {
        throw SyncException(
          SyncFailure.notFound,
          'The folder ${path.isEmpty ? root.path : path} could not be created; '
          'check the server address and user name.',
        );
      }
      throw SyncException(
        SyncFailure.server,
        'Could not create the folder ${path.isEmpty ? root.path : path} ($status).',
      );
    }
  }

  void close() => _client.close(force: true);
}
