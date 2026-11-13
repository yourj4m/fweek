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
  });

  /// The Nextcloud address as the user typed it.
  final String server;
  final String user;

  /// Folder in the user's files, relative to their root.
  final String folder;

  /// The account's WebDAV root.
  Uri get root => nextcloudFilesRoot(server, user);

  /// Identifies the folder, to notice when the app is pointed elsewhere.
  String get target => '$root$folder';

  Map<String, Object?> toJson() =>
      {'server': server, 'user': user, 'folder': folder};

  static SyncConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final server = json['server'], user = json['user'], folder = json['folder'];
    if (server is! String || user is! String || folder is! String) return null;
    return SyncConfig(server: server, user: user, folder: folder);
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
    DateTime Function()? clock,
    this.interval = const Duration(minutes: 5),
    this.afterEdit = const Duration(seconds: 8),
  })  : _storageFor = storageFor ?? _webDav,
        _clock = clock ?? DateTime.now;

  final PlannerStore store;
  final SecretStore secrets;
  final SyncStorage Function(SyncConfig config, String password) _storageFor;
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
  bool _disposed = false;

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
      if (!_paused) unawaited(syncNow());
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
    final SyncConfig config;
    try {
      config = SyncConfig(
        server: server.trim(),
        user: user.trim(),
        folder: normalizeFolder(folder),
      );
      config.root; // validates the address
    } on FormatException catch (error) {
      return error.message;
    }
    if (password.isEmpty) return 'Enter the app password.';

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

  /// Syncs now. Calls made while a sync is running join that run.
  Future<void> syncNow() {
    final engine = _engine;
    if (engine == null) return Future.value();
    return _running ??= _run(engine).whenComplete(() => _running = null);
  }

  Future<void> _run(SyncEngine engine) async {
    _debounce?.cancel();
    _paused = false;
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
      // brute-force protection; wait for the user.
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
