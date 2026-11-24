import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'storage.dart';

/// The app's Google sign-in client, given to the build (see the README):
/// `--dart-define=FWEEK_GOOGLE_CLIENT_ID=… --dart-define=FWEEK_GOOGLE_CLIENT_SECRET=…`.
/// A build without them offers Nextcloud only.
///
/// It is a client of the "Desktop app" kind. Google does not treat the
/// secret of such a client as a secret: every copy of the program carries
/// it, and what protects a sign-in is the user's consent in their own
/// browser and the one-time code that only this device receives (PKCE).
class GoogleClient {
  const GoogleClient({required this.id, required this.secret});

  final String id;
  final String secret;

  /// The client this build was made with, or null.
  static GoogleClient? get configured {
    const id = String.fromEnvironment('FWEEK_GOOGLE_CLIENT_ID');
    const secret = String.fromEnvironment('FWEEK_GOOGLE_CLIENT_SECRET');
    if (id.isEmpty || secret.isEmpty) return null;
    return const GoogleClient(id: id, secret: secret);
  }
}

/// What the app asks a Google account for, and nothing more: who it is
/// (to show which account is connected) and the app's own hidden folder in
/// that account's Drive, which neither the user's files nor other apps'
/// folders are part of.
const googleScopes = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/drive.appdata',
];

const _driveScope = 'https://www.googleapis.com/auth/drive.appdata';

/// Where Google's services answer. Tests and test builds point them at a
/// stand-in on this machine.
class GoogleEndpoints {
  const GoogleEndpoints({
    required this.authorize,
    required this.token,
    required this.revoke,
    required this.drive,
    required this.upload,
  });

  final Uri authorize;
  final Uri token;
  final Uri revoke;

  /// The Drive API, files resource: `…/drive/v3/files`.
  final Uri drive;

  /// Uploads: `…/upload/drive/v3/files`.
  final Uri upload;

  static final google = GoogleEndpoints(
    authorize: Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
    token: Uri.parse('https://oauth2.googleapis.com/token'),
    revoke: Uri.parse('https://oauth2.googleapis.com/revoke'),
    drive: Uri.parse('https://www.googleapis.com/drive/v3/files'),
    upload: Uri.parse('https://www.googleapis.com/upload/drive/v3/files'),
  );

  /// All of them under one address, as the test stand-in serves them.
  factory GoogleEndpoints.at(Uri base) {
    Uri under(String path) => base.replace(path: '${base.path.replaceAll(RegExp(r'/$'), '')}$path');
    return GoogleEndpoints(
      authorize: under('/o/oauth2/v2/auth'),
      token: under('/token'),
      revoke: under('/revoke'),
      drive: under('/drive/v3/files'),
      upload: under('/upload/drive/v3/files'),
    );
  }

  /// Google's, unless this is a test: `FWEEK_GOOGLE_SERVER` (given to the
  /// build, or in the environment of a desktop test run) names a stand-in,
  /// which must be on this machine or, for the Android emulator, on the
  /// computer it runs on. Anything else is ignored, so that no setting can
  /// send a sign-in elsewhere.
  static GoogleEndpoints get current {
    const built = String.fromEnvironment('FWEEK_GOOGLE_SERVER');
    final given = built.isNotEmpty ? built : (Platform.environment['FWEEK_GOOGLE_SERVER'] ?? '');
    if (given.isEmpty) return google;
    final uri = Uri.tryParse(given);
    const local = {'127.0.0.1', 'localhost', '10.0.2.2'};
    if (uri == null || uri.scheme != 'http' || !local.contains(uri.host)) return google;
    return GoogleEndpoints.at(uri);
  }
}

/// A Google account the app may use: its address and the long-lived token
/// that stands for the user's consent.
class GoogleAccount {
  const GoogleAccount({required this.email, required this.refreshToken, this.access});

  final String email;
  final String refreshToken;

  /// An access token from the sign-in, to use until it expires.
  final GoogleAccess? access;
}

/// A short-lived access token.
class GoogleAccess {
  const GoogleAccess(this.token, this.expires);

  final String token;
  final DateTime expires;
}

/// A sign-in that did not come to an account; [message] is for the user.
class GoogleSignInException implements Exception {
  const GoogleSignInException(this.message, {this.cancelled = false});

  final String message;

  /// The user stopped it; nothing to report.
  final bool cancelled;

  @override
  String toString() => 'GoogleSignInException: $message';
}

/// Sends a request and reads the whole answer; the failures every Google
/// call shares become [SyncException]s.
Future<(int, Uint8List, HttpHeaders)> _send(
  HttpClient client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  List<int>? body,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final request = await client.openUrl(method, uri).timeout(timeout);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    } else if (method == 'POST' || method == 'PATCH') {
      request.contentLength = 0;
    }
    final response = await request.close().timeout(timeout);
    final bytes = BytesBuilder(copy: false);
    await response.forEach(bytes.add).timeout(timeout);
    return (response.statusCode, bytes.takeBytes(), response.headers);
  } on SocketException catch (error) {
    throw SyncException(
      SyncFailure.offline,
      'Could not reach Google: ${error.osError?.message ?? error.message}.',
    );
  } on HandshakeException {
    throw const SyncException(SyncFailure.offline, 'Could not make a secure connection to Google.');
  } on TlsException {
    throw const SyncException(SyncFailure.offline, 'Google\'s certificate could not be verified.');
  } on TimeoutException {
    throw const SyncException(SyncFailure.offline, 'Google did not answer in time.');
  } on HttpException catch (error) {
    throw SyncException(SyncFailure.offline, 'Connection problem: ${error.message}.');
  }
}

Object? _json(Uint8List bytes) {
  try {
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on FormatException {
    return null;
  }
}

String _form(Map<String, String> fields) =>
    fields.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

/// The account's address, from the identity token Google hands over with
/// the tokens. It comes straight from Google over a secure connection, in
/// answer to this device's own request, so it is read without checking its
/// signature (Google's guidance for this case).
String? _emailOf(Object? idToken) {
  if (idToken is! String) return null;
  final parts = idToken.split('.');
  if (parts.length < 2) return null;
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final email = claims is Map ? claims['email'] : null;
    return email is String && email.isNotEmpty ? email : null;
  } on FormatException {
    return null;
  }
}

/// Signs in to Google in the system's browser and returns the account.
///
/// The browser opens Google's own sign-in page, where the user picks an
/// account and allows what [googleScopes] ask for; the app never sees the
/// password. Google then sends the browser back to a one-time address on
/// this device (`http://127.0.0.1:<port>`), where the app takes the
/// one-time code and exchanges it for the account's tokens. A random
/// secret only this run knows (PKCE) makes a code worthless to anything
/// else that might catch it.
///
/// [open] shows an address in the browser; [cancel] completing stops
/// waiting. On a phone [returnTo] is a link back into the app, shown on
/// the page the browser lands on.
Future<GoogleAccount> signInWithGoogle({
  required GoogleClient client,
  required Future<bool> Function(String address) open,
  GoogleEndpoints? endpoints,
  Future<void>? cancel,
  String? returnTo,
  Duration timeout = const Duration(minutes: 10),
  HttpClient? http,
}) async {
  final at = endpoints ?? GoogleEndpoints.current;
  final random = Random.secure();
  String randomText(int bytes) =>
      base64Url.encode([for (var i = 0; i < bytes; i++) random.nextInt(256)]).replaceAll('=', '');
  final verifier = randomText(48);
  final challenge =
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
  final state = randomText(24);

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final redirect = 'http://127.0.0.1:${server.port}';
  final answer = Completer<Map<String, String>>();
  server.listen((request) async {
    final query = request.uri.queryParameters;
    // Browsers also ask for an icon; only Google's return counts.
    final ours = request.uri.path == '/' && query['state'] == state;
    final done = ours && query.containsKey('code');
    request.response
      ..statusCode = ours ? 200 : 404
      ..headers.contentType = ContentType.html
      ..write(_landingPage(done: done, error: query['error'], returnTo: returnTo));
    await request.response.close();
    if (ours && !answer.isCompleted) answer.complete(query);
  });

  try {
    final address = at.authorize.replace(queryParameters: {
      'client_id': client.id,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': googleScopes.join(' '),
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      // The account is chosen each time, and consent asked again, so that
      // Google always hands over a long-lived token.
      'prompt': 'select_account consent',
    }).toString();
    if (!await open(address)) {
      throw const GoogleSignInException('Could not open the browser for signing in to Google.');
    }
    final Map<String, String> query;
    try {
      query = await Future.any([
        answer.future,
        if (cancel != null)
          cancel.then<Map<String, String>>(
              (_) => throw const GoogleSignInException('Signing in was cancelled.', cancelled: true)),
      ]).timeout(timeout);
    } on TimeoutException {
      throw const GoogleSignInException('Signing in took too long. Try again.');
    }
    if (query['error'] case final error?) {
      throw GoogleSignInException(error == 'access_denied'
          ? 'Google sign-in was declined, so fweek has no access.'
          : 'Google sign-in failed ($error).');
    }
    final code = query['code'];
    if (code == null) throw const GoogleSignInException('Google sent no sign-in code back.');

    final client0 = http ?? HttpClient();
    try {
      final (status, body, _) = await _send(
        client0,
        'POST',
        at.token,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: utf8.encode(_form({
          'client_id': client.id,
          'client_secret': client.secret,
          'code': code,
          'code_verifier': verifier,
          'redirect_uri': redirect,
          'grant_type': 'authorization_code',
        })),
      );
      final json = _json(body);
      if (status != 200 || json is! Map) {
        final reason = json is Map ? json['error_description'] ?? json['error'] : null;
        throw GoogleSignInException('Google did not complete the sign-in (${reason ?? status}).');
      }
      final granted = '${json['scope'] ?? ''}'.split(' ');
      // Google lets the user untick a permission on its consent page.
      if (!granted.contains(_driveScope)) {
        throw const GoogleSignInException(
          'fweek needs to keep its files in your Google Drive. Connect again and '
          'tick "See, create, and delete its own configuration data in your Google Drive".',
        );
      }
      final refresh = json['refresh_token'];
      final accessToken = json['access_token'];
      final expiresIn = json['expires_in'];
      if (refresh is! String || refresh.isEmpty) {
        throw const GoogleSignInException('Google gave no lasting access. Try connecting again.');
      }
      return GoogleAccount(
        email: _emailOf(json['id_token']) ?? 'Google account',
        refreshToken: refresh,
        access: accessToken is String && expiresIn is num
            ? GoogleAccess(accessToken, DateTime.now().add(Duration(seconds: expiresIn.toInt() - 60)))
            : null,
      );
    } on SyncException catch (error) {
      throw GoogleSignInException(error.message);
    } finally {
      if (http == null) client0.close();
    }
  } finally {
    await server.close(force: true);
  }
}

String _landingPage({required bool done, String? error, String? returnTo}) {
  final title = done ? 'Signed in to fweek' : 'fweek was not signed in';
  final text = done
      ? 'You can close this tab and go back to fweek.'
      : error == 'access_denied'
          ? 'Google sign-in was declined. Close this tab; fweek has no access.'
          : 'Close this tab and try again in fweek.';
  final back = returnTo == null
      ? ''
      : '<p><a href="${const HtmlEscape().convert(returnTo)}">Back to fweek</a></p>';
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>$title</title><style>body{font-family:system-ui,sans-serif;max-width:32rem;'
      'margin:4rem auto;padding:0 1.5rem;line-height:1.5}a{font-weight:600}</style></head>'
      '<body><h1>$title</h1><p>$text</p>$back</body></html>';
}

/// Says goodbye to Google for an account: its tokens stop working, and the
/// app disappears from the account's list of connected apps. Best effort;
/// the user can also remove the app there themselves.
Future<void> revokeGoogle(String refreshToken, {GoogleEndpoints? endpoints, HttpClient? http}) async {
  final client = http ?? HttpClient();
  try {
    await _send(
      client,
      'POST',
      (endpoints ?? GoogleEndpoints.current).revoke,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: utf8.encode(_form({'token': refreshToken})),
      timeout: const Duration(seconds: 10),
    );
  } on SyncException {
    // Offline: the token stays valid at Google until the user removes the
    // app from their account, which the settings explain.
  } finally {
    if (http == null) client.close();
  }
}

/// Files in the app's own hidden folder of a Google account's Drive (the
/// "app data folder"), as a [SyncStorage].
///
/// The folder is flat: a file's name is its whole path
/// (`fweek/changes/<device>-<n>.json`). Drive allows two files of one name,
/// and two devices creating a folder at the same moment would each make
/// their own; with no folders there is nothing to create twice, and each
/// device only ever writes files named after itself (see [SyncEngine]).
class DriveStorage implements SyncStorage {
  DriveStorage({
    required this.client,
    required this.refreshToken,
    GoogleAccess? access,
    GoogleEndpoints? endpoints,
    HttpClient? http,
    DateTime Function()? clock,
  })  : _access = access, // ignore: prefer_initializing_formals
        _endpoints = endpoints ?? GoogleEndpoints.current,
        _http = http ?? HttpClient(),
        _ownsHttp = http == null,
        _clock = clock ?? DateTime.now {
    _http.connectionTimeout = const Duration(seconds: 15);
    _http.userAgent = 'fweek';
  }

  final GoogleClient client;
  final String refreshToken;
  final GoogleEndpoints _endpoints;
  final HttpClient _http;
  final bool _ownsHttp;
  final DateTime Function() _clock;
  GoogleAccess? _access;

  /// File ids by name, from the last listing.
  final Map<String, String> _ids = {};

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }

  Future<String> _token({bool fresh = false}) async {
    final access = _access;
    if (!fresh && access != null && access.expires.isAfter(_clock())) return access.token;
    final (status, body, _) = await _send(
      _http,
      'POST',
      _endpoints.token,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: utf8.encode(_form({
        'client_id': client.id,
        'client_secret': client.secret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      })),
    );
    final json = _json(body);
    if (status == 200 && json is Map && json['access_token'] is String) {
      final expiresIn = json['expires_in'];
      _access = GoogleAccess(
        json['access_token'] as String,
        _clock().add(Duration(seconds: (expiresIn is num ? expiresIn.toInt() : 3600) - 60)),
      );
      return _access!.token;
    }
    final error = json is Map ? json['error'] : null;
    if (error == 'invalid_grant' || error == 'unauthorized_client' || status == 401) {
      // The user removed the app from their account, changed their password
      // with "sign out everywhere", or the access lapsed.
      throw const SyncException(
        SyncFailure.unauthorized,
        'Google no longer accepts fweek\'s access to this account. Connect again.',
      );
    }
    if (status == 429) {
      throw const SyncException(SyncFailure.throttled, 'Google asks fweek to wait a moment.');
    }
    if (status >= 500) {
      throw SyncException(SyncFailure.server, 'Google reported an error ($status).');
    }
    throw SyncException(SyncFailure.server, 'Google refused to renew access (${error ?? status}).');
  }

  /// A Drive call with the account's access token; an expired token is
  /// renewed once.
  Future<(int, Uint8List)> _call(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    for (var attempt = 0;; attempt++) {
      final token = await _token(fresh: attempt > 0);
      final (status, bytes, _) = await _send(_http, method, uri,
          headers: {...headers, 'authorization': 'Bearer $token'}, body: body);
      if (status == 401 && attempt == 0) continue;
      if (status == 401) {
        throw const SyncException(
          SyncFailure.unauthorized,
          'Google no longer accepts fweek\'s access to this account. Connect again.',
        );
      }
      if (status == 403 || status == 429) {
        final json = _json(bytes);
        final error = json is Map ? json['error'] : null;
        final reasons = [
          if (error is Map && error['errors'] is List)
            for (final e in error['errors'] as List)
              if (e is Map && e['reason'] is String) e['reason'] as String,
        ];
        final message = error is Map ? error['message'] : null;
        if (status == 429 || reasons.any((r) => r.contains('RateLimitExceeded') || r == 'rateLimitExceeded')) {
          throw const SyncException(SyncFailure.throttled, 'Google asks fweek to wait a moment.');
        }
        if (reasons.contains('storageQuotaExceeded')) {
          throw const SyncException(
              SyncFailure.forbidden, 'Your Google storage is full, so fweek cannot save to it.');
        }
        throw SyncException(SyncFailure.forbidden,
            'Google refused fweek access to its files${message is String ? ': $message' : '.'}');
      }
      if (status >= 500) {
        throw SyncException(SyncFailure.server, 'Google Drive reported an error ($status).');
      }
      return (status, bytes);
    }
  }

  static String _quoted(String text) => "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// Every file in the app's folder, with its id.
  Future<List<({String id, String name, String modified})>> _all({String? named}) async {
    final files = <({String id, String name, String modified})>[];
    String? page;
    do {
      final uri = _endpoints.drive.replace(queryParameters: {
        'spaces': 'appDataFolder',
        'fields': 'nextPageToken,files(id,name,modifiedTime)',
        'pageSize': '1000',
        'q': named == null ? 'trashed = false' : 'name = ${_quoted(named)} and trashed = false',
        'pageToken': ?page,
      });
      final (status, bytes) = await _call('GET', uri);
      final json = _json(bytes);
      if (status != 200 || json is! Map) {
        throw SyncException(SyncFailure.server, 'Google Drive gave an unexpected answer ($status).');
      }
      for (final file in (json['files'] as List? ?? const [])) {
        if (file is Map && file['id'] is String && file['name'] is String) {
          files.add((
            id: file['id'] as String,
            name: file['name'] as String,
            modified: '${file['modifiedTime'] ?? ''}',
          ));
        }
      }
      final next = json['nextPageToken'];
      page = next is String && next.isNotEmpty ? next : null;
    } while (page != null);
    return files;
  }

  /// The ids of the files called [name], the newest first.
  Future<List<String>> _find(String name) async {
    final found = await _all(named: name);
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return [for (final f in found) f.id];
  }

  @override
  Future<List<String>> list(String dir) async {
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    final names = <String>{};
    final files = await _all();
    files.sort((a, b) => a.modified.compareTo(b.modified));
    _ids.clear();
    for (final file in files) {
      if (!file.name.startsWith(prefix)) continue;
      final rest = file.name.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      names.add(rest);
      _ids[file.name] = file.id; // the newest wins
    }
    return names.toList()..sort();
  }

  @override
  Future<Uint8List?> read(String path) async {
    final known = _ids[path];
    for (final id in [?known, if (known == null) ...await _find(path)]) {
      final (status, bytes) =
          await _call('GET', _endpoints.drive.replace(path: '${_endpoints.drive.path}/$id', queryParameters: {'alt': 'media'}));
      if (status == 200) return bytes;
      if (status == 404) {
        _ids.remove(path);
        // Listed, then removed by its device: look once more by name.
        if (known != null) return (await _find(path)).isEmpty ? null : read(path);
        continue;
      }
      throw SyncException(SyncFailure.server, 'Google Drive could not read $path ($status).');
    }
    return null;
  }

  @override
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false}) async {
    final existing = await _find(path);
    if (existing.isNotEmpty) {
      if (!overwrite) {
        throw SyncException(SyncFailure.exists, '$path is already in Google Drive.');
      }
      final (status, _) = await _call(
        'PATCH',
        _endpoints.upload.replace(
            path: '${_endpoints.upload.path}/${existing.first}', queryParameters: {'uploadType': 'media'}),
        headers: {'content-type': 'application/json'},
        body: bytes,
      );
      if (status != 200) {
        throw SyncException(SyncFailure.server, 'Google Drive did not take $path ($status).');
      }
      return;
    }
    const boundary = 'fweek-part-boundary-7d3f';
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\n'
          'content-type: application/json; charset=utf-8\r\n\r\n'
          '${jsonEncode({'name': path, 'parents': ['appDataFolder']})}\r\n'
          '--$boundary\r\n'
          'content-type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final (status, answer) = await _call(
      'POST',
      _endpoints.upload.replace(queryParameters: {'uploadType': 'multipart', 'fields': 'id'}),
      headers: {'content-type': 'multipart/related; boundary=$boundary'},
      body: body.takeBytes(),
    );
    final json = _json(answer);
    if (status != 200 || json is! Map || json['id'] is! String) {
      throw SyncException(SyncFailure.server, 'Google Drive did not take $path ($status).');
    }
    _ids[path] = json['id'] as String;
  }

  @override
  Future<void> delete(String path) async {
    _ids.remove(path);
    for (final id in await _find(path)) {
      final (status, _) =
          await _call('DELETE', _endpoints.drive.replace(path: '${_endpoints.drive.path}/$id'));
      if (status != 204 && status != 200 && status != 404) {
        throw SyncException(SyncFailure.server, 'Google Drive could not remove $path ($status).');
      }
    }
  }

  /// Nothing to create: the app's folder is flat (see the class).
  @override
  Future<void> createDir(String dir) async {}
}
