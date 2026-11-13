import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'storage.dart';

/// The WebDAV address of a Nextcloud account's files.
///
/// [server] may be typed loosely: `cloud.example.com`,
/// `https://cloud.example.com/`, an install in a subdirectory such as
/// `https://example.com/nextcloud`, or a full WebDAV address copied from
/// Nextcloud's Files settings. Throws [FormatException] with a message for
/// the user if it is not usable.
Uri nextcloudFilesRoot(String server, String user) {
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
  if (user.trim().isEmpty) throw const FormatException('Enter the user name.');

  var segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
  final dav = segments.indexOf('remote.php');
  if (dav >= 0) segments = segments.sublist(0, dav);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [...segments, 'remote.php', 'dav', 'files', user.trim(), ''],
  );
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
    _client.userAgent = 'WeekToDo';
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
      if (status == 401 || status == 403) {
        throw const SyncException(
          SyncFailure.unauthorized,
          'The server did not accept the user name or password.',
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
