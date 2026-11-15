import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/planner_store.dart';
import 'secrets.dart';
import 'storage.dart';
import 'sync_engine.dart';
import 'webdav.dart';

/// Where the planner syncs to. The password is kept separately, in the
/// keyring.
class SyncConfig {
  const SyncConfig({
    required this.server,
    required this.user,
    required this.folder,
    this.userId,
  });

  /// The Nextcloud address as the user typed it.
  final String server;

  /// The login name the app password belongs to.
  final String user;

  /// Folder in the user's files, relative to their root.
  final String folder;

  /// The id Nextcloud files the account under, as the server reported it
  /// when connecting. It differs from [user] for accounts from a directory
  /// (LDAP), whose id is generated. Connections saved before the app asked
  /// for it have none; they only ever worked where the two are the same.
  final String? userId;

  /// The account's WebDAV root.
  Uri get root => nextcloudFilesRoot(server, userId ?? user);

  /// Identifies the folder, to notice when the app is pointed elsewhere.
  String get target => '$root$folder';

  Map<String, Object?> toJson() => {
        'server': server,
        'user': user,
        'folder': folder,
        if (userId != null) 'userId': userId,
      };

  static SyncConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final server = json['server'], user = json['user'], folder = json['folder'];
    if (server is! String || user is! String || folder is! String) return null;
    final userId = json['userId'];
    return SyncConfig(
      server: server,
      user: user,
      folder: folder,
      userId: userId is String && userId.isNotEmpty ? userId : null,
    );
  }
}

enum SyncState {
  /// Not set up.
  off,

  /// Set up and waiting for the next run.
  idle,
  syncing,

  /// The last run failed; [SyncService.message] says why.
  error,
}

/// Keeps the planner in sync with a Nextcloud folder: on start, every few
/// minutes, shortly after local edits, and on request.
class SyncService extends ChangeNotifier {
  SyncService(
    this.store,
    this.secrets, {
    SyncStorage Function(SyncConfig config, String password)? storageFor,
    Future<String?> Function(SyncConfig config, String password)? findUserId,
    DateTime Function()? clock,
    this.interval = const Duration(minutes: 5),
    this.afterEdit = const Duration(seconds: 8),
  })  : _storageFor = storageFor ?? _webDav,
        // Replacing the storage replaces the server, so asking the real one
        // for the account id would make no sense; such callers (tests) say
        // what the id is, or leave it to be the login name.
        _findUserId = findUserId ?? (storageFor == null ? _askNextcloud : _noUserId),
        _clock = clock ?? DateTime.now;

  final PlannerStore store;
  final SecretStore secrets;
  final SyncStorage Function(SyncConfig config, String password) _storageFor;
  final Future<String?> Function(SyncConfig config, String password) _findUserId;
  final DateTime Function() _clock;

  /// Time between automatic runs.
  final Duration interval;

  /// How long after a local edit to sync, so a burst of typing is one upload.
  final Duration afterEdit;

  static const _configKey = 'sync.config';
  static const _targetKey = 'sync.target';
  static const _passwordKey = 'nextcloud-app-password';

  static SyncStorage _webDav(SyncConfig config, String password) =>
      WebDavStorage(root: config.root, user: config.user, password: password);

  static Future<String?> _askNextcloud(SyncConfig config, String password) =>
      discoverNextcloudUserId(server: config.server, login: config.user, password: password);

  static Future<String?> _noUserId(SyncConfig config, String password) async => null;

  SyncConfig? get config => _config;
  SyncConfig? _config;

  SyncState get state => _state;
  SyncState _state = SyncState.off;

  /// Why the last run failed, when [state] is [SyncState.error].
  String? get message => _message;
  String? _message;

  /// When the planner last synced successfully.
  DateTime? get lastSync => _lastSync;
  DateTime? _lastSync;

  SyncEngine? _engine;
  SyncStorage? _storage;
  Timer? _periodic;
  Timer? _debounce;
  Future<void>? _running;
  int _seenRevision = -1;
  bool _paused = false;

  /// The app is in the background (phones only).
  bool _hidden = false;
  bool _disposed = false;
  DateTime? _lastAttempt;

  bool get configured => _config != null;

  /// Restores a saved connection and starts syncing. Safe to call when
  /// nothing is set up.
  Future<void> load() async {
    final raw = store.db.meta(_configKey);
    final config = raw == null ? null : SyncConfig.fromJson(_tryDecode(raw));
    if (config == null) return;
    final last = store.db.meta('sync.last_ok');
    _lastSync = last == null ? null : DateTime.tryParse(last);
    String? password;
    try {
      password = await secrets.read(_passwordKey);
    } on Object catch (error) {
      _config = config;
      _fail('Could not read the password from the keyring: $error');
      return;
    }
    if (password == null) {
      _config = config;
      _fail('The saved password is missing from the keyring. Connect again.');
      return;
    }
    _start(config, password);
    unawaited(syncNow());
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  void _start(SyncConfig config, String password) {
    _stop();
    _config = config;
    _storage = _storageFor(config, password);
    _engine = SyncEngine(store, _storage!, folder: config.folder);
    // A different folder has seen none of this device's changes.
    if (store.db.meta(_targetKey) != config.target) {
      _engine!.reset();
      store.db.setMeta(_targetKey, config.target);
    }
    _state = SyncState.idle;
    _message = null;
    _paused = false;
    _seenRevision = store.revision;
    store.addListener(_onStoreChanged);
    _periodic = Timer.periodic(interval, (_) {
      // Not while the app is out of sight: a phone that has not yet put the
      // app to sleep would otherwise go online every few minutes for
      // nothing. It catches up the moment it is looked at again.
      if (!_paused && !_hidden) unawaited(syncNow());
    });
  }

  void _stop() {
    store.removeListener(_onStoreChanged);
    _periodic?.cancel();
    _debounce?.cancel();
    _periodic = null;
    _debounce = null;
    final storage = _storage;
    if (storage is WebDavStorage) storage.close();
    _storage = null;
    _engine = null;
  }

  void _onStoreChanged() {
    // While a run is in progress its end decides whether another is needed.
    if (_paused || _running != null) return;
    if (store.revision == _seenRevision) return;
    _seenRevision = store.revision;
    _scheduleIfPending();
  }

  /// Arranges a sync shortly, if this device has something to upload.
  /// Changes that only arrived from the folder, or settings that stay on the
  /// device, need none.
  void _scheduleIfPending() {
    final engine = _engine;
    if (engine == null || !engine.hasPending) return;
    _debounce?.cancel();
    _debounce = Timer(afterEdit, () => unawaited(syncNow()));
  }

  void _fail(String message) {
    _state = SyncState.error;
    _message = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Sets up syncing with a Nextcloud account and runs a first sync to prove
  /// it works. Returns null on success, otherwise a message for the user;
  /// nothing is saved unless it succeeds.
  Future<String?> connect({
    required String server,
    required String user,
    required String password,
    required String folder,
  }) async {
    final SyncConfig typed;
    try {
      typed = SyncConfig(
        server: server.trim(),
        user: user.trim(),
        folder: normalizeFolder(folder),
      );
      typed.root; // validates the address
    } on FormatException catch (error) {
      return error.message;
    }
    // App passwords never contain white space; a space or line break copied
    // along with one would otherwise read as a wrong password.
    password = password.trim();
    if (password.isEmpty) return 'Enter the app password.';

    // Log in first, and learn where the account's files are: the login name
    // is not always the id in the files' address.
    String? userId;
    try {
      userId = await _findUserId(typed, password);
    } on SyncException catch (error) {
      return error.message;
    }
    // A server that does not say: an id in a pasted WebDAV address is the
    // next best guess, then the login name, as before.
    userId ??= nextcloudUserIdInAddress(typed.server);
    final config = SyncConfig(
      server: typed.server,
      user: typed.user,
      folder: typed.folder,
      userId: userId,
    );

    final storage = _storageFor(config, password);
    final engine = SyncEngine(store, storage, folder: config.folder);
    // Bookkeeping describes one folder; forgetting it is always safe (the
    // next sync re-reads and re-uploads), so do that when the folder changes.
    if (store.db.meta(_targetKey) != config.target) engine.reset();
    try {
      await engine.sync();
    } on SyncException catch (error) {
      if (storage is WebDavStorage) storage.close();
      return error.message;
    }
    if (storage is WebDavStorage) storage.close();

    try {
      await secrets.write(_passwordKey, password);
    } on Object catch (error) {
      return 'Connected, but the password could not be saved in the keyring: $error';
    }
    store.db.setMeta(_configKey, jsonEncode(config.toJson()));
    store.db.setMeta(_targetKey, config.target);
    _lastSync = _clock();
    store.db.setMeta('sync.last_ok', _lastSync!.toIso8601String());
    _start(config, password);
    _notify();
    return null;
  }

  /// Stops syncing and forgets the connection. Nothing is removed from the
  /// server or from this device's planner.
  Future<void> disconnect() async {
    _stop();
    _config = null;
    _state = SyncState.off;
    _message = null;
    _lastSync = null;
    store.db.setMeta(_configKey, null);
    store.db.setMeta('sync.last_ok', null);
    try {
      await secrets.delete(_passwordKey);
    } on Object {
      // The keyring is unavailable; the saved entry is harmless without the
      // connection details, which are gone.
    }
    _notify();
  }

  /// The app is back in the foreground. A phone suspends the app (and its
  /// timers) in the background, so catch up now unless a sync just ran.
  void resumed({Duration staleAfter = const Duration(minutes: 1)}) {
    _hidden = false;
    if (_engine == null || _paused) return;
    final last = _lastAttempt;
    if (last != null && _clock().difference(last) < staleAfter) return;
    unawaited(syncNow());
  }

  /// The app is leaving the foreground. Upload pending edits right away
  /// rather than after the usual pause, which the system may never let run.
  void leaving() {
    _hidden = true;
    final engine = _engine;
    if (engine == null || _paused || !engine.hasPending) return;
    unawaited(syncNow());
  }

  /// Syncs now. Calls made while a sync is running join that run.
  Future<void> syncNow() {
    final engine = _engine;
    if (engine == null) return Future.value();
    return _running ??= _run(engine).whenComplete(() => _running = null);
  }

  Future<void> _run(SyncEngine engine) async {
    _debounce?.cancel();
    _paused = false;
    _lastAttempt = _clock();
    _state = SyncState.syncing;
    _notify();
    try {
      await engine.sync();
      if (_engine != engine) return; // disconnected meanwhile
      _state = SyncState.idle;
      _message = null;
      _lastSync = _clock();
      store.db.setMeta('sync.last_ok', _lastSync!.toIso8601String());
    } on SyncException catch (error) {
      if (_engine != engine) return;
      _state = SyncState.error;
      _message = error.message;
      // Retrying a rejected password would only trip the server's
      // brute-force protection; wait for the user. A throttled login is
      // retried as usual: refused attempts do not count as failed ones, and
      // the saved password goes through once the server lifts the block.
      if (error.failure == SyncFailure.unauthorized) _paused = true;
    } on Object catch (error) {
      if (_engine != engine) return;
      _state = SyncState.error;
      _message = 'Sync failed unexpectedly: $error';
    }
    // Edits made while this run was in progress still need to go up.
    _seenRevision = store.revision;
    if (_state == SyncState.idle) _scheduleIfPending();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}
