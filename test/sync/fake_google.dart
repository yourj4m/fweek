import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A stand-in for the parts of Google that fweek talks to: the sign-in page
/// (which "signs in" at once, as the account set in [nextAccount]), the
/// token service, revoking, and the Drive files of each account's hidden app
/// folder. Plain `dart:io`, so that it also runs by itself for test runs of
/// the real app (`dart run test/sync/fake_google.dart [port]`).
class FakeGoogle {
  FakeGoogle._(this._server);

  final HttpServer _server;

  static const clientId = 'test-client.apps.googleusercontent.com';
  static const clientSecret = 'test-secret';

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Who signs in next.
  String nextAccount = 'ada@example.org';

  /// The user declines on Google's page.
  bool decline = false;

  /// The user unticks the permission for the app's Drive folder.
  bool untickDrive = false;

  /// Files per page of a listing; small, so that paging is exercised.
  int pageSize = 3;

  /// Answers the next matching request with 503.
  bool Function(HttpRequest request)? failNext;

  /// Every request, as "METHOD path?query".
  final List<String> requests = [];

  /// The scopes the last sign-in asked for.
  List<String> askedScopes = [];

  final Map<String, _Code> _codes = {};
  final Map<String, String> _refresh = {}; // refresh token -> account
  final Map<String, (String, DateTime)> _access = {}; // access token -> account, expiry
  final Map<String, Map<String, _File>> _files = {}; // account -> id -> file
  int _next = 0;
  DateTime Function() clock = DateTime.now;

  static Future<FakeGoogle> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeGoogle._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// Makes every access token handed out so far expire.
  void expireAccess() => _access.updateAll((_, v) => (v.$1, DateTime(2000)));

  /// The user removed the app from their Google account.
  void revokeAll(String account) {
    _refresh.removeWhere((_, a) => a == account);
    _access.removeWhere((_, v) => v.$1 == account);
  }

  /// Names of the files in an account's app folder.
  List<String> filesOf(String account) =>
      [for (final f in (_files[account] ?? {}).values) f.name]..sort();

  bool hasRefreshToken(String token) => _refresh.containsKey(token);

  String _id(String prefix) => '$prefix${++_next}';

  Future<void> _handle(HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}${request.uri.hasQuery ? '?${request.uri.query}' : ''}');
    final body = await request.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d)).then((b) => b.takeBytes());
    final response = request.response;
    try {
      if (failNext?.call(request) ?? false) {
        failNext = null;
        return _reply(response, 503, {'error': {'code': 503, 'message': 'Backend Error'}});
      }
      final path = request.uri.path;
      // For test runs of the real app: what an account's folder holds, and
      // whether a sign-in's token is still valid.
      if (path == '/_test/files') {
        return _reply(response, 200, filesOf(request.uri.queryParameters['account'] ?? ''));
      }
      if (path == '/_test/tokens') return _reply(response, 200, _refresh.length);
      if (path == '/o/oauth2/v2/auth') return _authorize(request, response);
      if (path == '/token') return _token(response, utf8.decode(body));
      if (path == '/revoke') {
        final token = Uri.splitQueryString(utf8.decode(body))['token'];
        final account = _refresh.remove(token);
        if (account != null) _access.removeWhere((_, v) => v.$1 == account);
        return _reply(response, 200, {});
      }
      if (path.startsWith('/drive/v3/files') || path.startsWith('/upload/drive/v3/files')) {
        final auth = request.headers.value('authorization') ?? '';
        final held = _access[auth.replaceFirst('Bearer ', '')];
        if (held == null || !held.$2.isAfter(clock())) {
          return _reply(response, 401, {'error': {'code': 401, 'message': 'Invalid Credentials'}});
        }
        return _drive(request, response, held.$1, body);
      }
      return _reply(response, 404, {'error': 'not found'});
    } finally {
      await response.close();
    }
  }

  void _reply(HttpResponse response, int status, Object json) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(json));
  }

  void _authorize(HttpRequest request, HttpResponse response) {
    final q = request.uri.queryParameters;
    final redirect = Uri.parse(q['redirect_uri'] ?? '');
    askedScopes = (q['scope'] ?? '').split(' ');
    if (q['client_id'] != clientId) {
      response
        ..statusCode = 400
        ..write('invalid_client');
      return;
    }
    if (decline) {
      response.redirect(redirect.replace(queryParameters: {'error': 'access_denied', 'state': q['state']}),
          status: 302);
      return;
    }
    final code = _id('code-');
    _codes[code] = _Code(
      account: nextAccount,
      challenge: q['code_challenge'] ?? '',
      redirect: q['redirect_uri'] ?? '',
      scopes: [for (final s in askedScopes) if (!(untickDrive && s.contains('drive'))) s],
    );
    response.redirect(redirect.replace(queryParameters: {'code': code, 'state': q['state']}), status: 302);
  }

  void _token(HttpResponse response, String body) {
    final form = Uri.splitQueryString(body);
    if (form['client_id'] != clientId || form['client_secret'] != clientSecret) {
      return _reply(response, 401, {'error': 'invalid_client'});
    }
    String access(String account) {
      final token = _id('access-');
      _access[token] = (account, clock().add(const Duration(hours: 1)));
      return token;
    }

    switch (form['grant_type']) {
      case 'authorization_code':
        final code = _codes.remove(form['code']);
        final verifier = form['code_verifier'] ?? '';
        final expected =
            base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
        if (code == null || code.challenge != expected || code.redirect != form['redirect_uri']) {
          return _reply(response, 400, {'error': 'invalid_grant'});
        }
        final refresh = _id('refresh-');
        _refresh[refresh] = code.account;
        String part(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
        return _reply(response, 200, {
          'access_token': access(code.account),
          'expires_in': 3599,
          'refresh_token': refresh,
          'scope': code.scopes.join(' '),
          'token_type': 'Bearer',
          'id_token': '${part({'alg': 'none'})}.${part({'email': code.account})}.sig',
        });
      case 'refresh_token':
        final account = _refresh[form['refresh_token']];
        if (account == null) return _reply(response, 400, {'error': 'invalid_grant'});
        return _reply(response, 200, {'access_token': access(account), 'expires_in': 3599});
      default:
        return _reply(response, 400, {'error': 'unsupported_grant_type'});
    }
  }

  void _drive(HttpRequest request, HttpResponse response, String account, Uint8List body) {
    final files = _files.putIfAbsent(account, () => {});
    final segments = request.uri.pathSegments;
    final upload = segments.first == 'upload';
    final id = segments.length > (upload ? 4 : 3) ? segments.last : null;
    final q = request.uri.queryParameters;
    Map<String, Object> describe(_File f) =>
        {'id': f.id, 'name': f.name, 'modifiedTime': f.modified.toUtc().toIso8601String()};

    switch ((request.method, upload, id)) {
      case ('GET', false, null):
        if (q['spaces'] != 'appDataFolder') return _reply(response, 403, {'error': 'only appData'});
        final query = q['q'] ?? '';
        final named = RegExp(r"name = '((?:[^'\\]|\\.)*)'").firstMatch(query)?[1]
            ?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
        final all = [for (final f in files.values) if (named == null || f.name == named) f];
        final start = int.tryParse(q['pageToken'] ?? '') ?? 0;
        final page = all.skip(start).take(pageSize).toList();
        return _reply(response, 200, {
          'files': [for (final f in page) describe(f)],
          if (start + pageSize < all.length) 'nextPageToken': '${start + pageSize}',
        });
      case ('GET', false, final id?):
        final file = files[id];
        if (file == null) return _reply(response, 404, {'error': {'code': 404, 'message': 'File not found'}});
        response.add(file.bytes);
        return;
      case ('DELETE', false, final id?):
        if (files.remove(id) == null) return _reply(response, 404, {'error': {'code': 404}});
        response.statusCode = 204;
        return;
      case ('POST', true, null):
        final boundary = request.headers.contentType?.parameters['boundary'];
        if (q['uploadType'] != 'multipart' || boundary == null) return _reply(response, 400, {});
        final parts = _multipart(body, boundary);
        final meta = jsonDecode(utf8.decode(parts[0])) as Map;
        if ((meta['parents'] as List?)?.single != 'appDataFolder') return _reply(response, 403, {});
        final file = _File(_id('file-'), meta['name'] as String, parts[1], clock());
        files[file.id] = file;
        return _reply(response, 200, {'id': file.id});
      case ('PATCH', true, final id?):
        final file = files[id];
        if (file == null) return _reply(response, 404, {});
        files[id] = _File(id, file.name, body, clock());
        return _reply(response, 200, describe(files[id]!));
      default:
        return _reply(response, 400, {'error': 'unexpected ${request.method} ${request.uri}'});
    }
  }

  static List<Uint8List> _multipart(Uint8List body, String boundary) {
    final text = latin1.decode(body);
    final parts = <Uint8List>[];
    for (final chunk in text.split('--$boundary')) {
      final split = chunk.indexOf('\r\n\r\n');
      if (split < 0) continue;
      var content = chunk.substring(split + 4);
      if (content.endsWith('\r\n')) content = content.substring(0, content.length - 2);
      parts.add(Uint8List.fromList(latin1.encode(content)));
    }
    return parts;
  }
}

class _Code {
  _Code({required this.account, required this.challenge, required this.redirect, required this.scopes});
  final String account, challenge, redirect;
  final List<String> scopes;
}

class _File {
  _File(this.id, this.name, this.bytes, this.modified);
  final String id, name;
  final Uint8List bytes;
  final DateTime modified;
}

/// A browser for tests: opens the sign-in address and follows Google's
/// redirect back to the app.
Future<bool> fakeBrowser(String address) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(address));
    request.followRedirects = true;
    final response = await request.close();
    await response.drain<void>();
    return true;
  } finally {
    client.close();
  }
}

/// Runs the stand-in by itself, for test runs of the real app:
/// `FWEEK_GOOGLE_SERVER=http://127.0.0.1:<port>` and the client id and
/// secret above in the build.
Future<void> main(List<String> arguments) async {
  final fake = await FakeGoogle.start(port: arguments.isEmpty ? 0 : int.parse(arguments.first));
  if (arguments.length > 1) fake.nextAccount = arguments[1];
  stdout.writeln('fake google on ${fake.base}');
}
