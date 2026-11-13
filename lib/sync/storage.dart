import 'dart:io';
import 'dart:typed_data';

/// Why a sync operation failed, in terms the interface can explain.
enum SyncFailure {
  /// The server could not be reached.
  offline,

  /// The server rejected the user name or password.
  unauthorized,

  /// The server accepted the login but refuses this account the location.
  forbidden,

  /// The server refuses logins for a while after too many failed ones.
  throttled,

  /// The address does not lead to a usable folder.
  notFound,

  /// The file already exists and may not be replaced.
  exists,

  /// The server answered with an error of its own.
  server,

  /// What the server holds is not something this app can read.
  incompatible,
}

class SyncException implements Exception {
  const SyncException(this.failure, this.message);

  final SyncFailure failure;

  /// A sentence fit to show to the user.
  final String message;

  @override
  String toString() => 'SyncException(${failure.name}): $message';
}

/// A folder somewhere that devices share: a Nextcloud directory, a local
/// directory, or memory in tests. Deliberately minimal, so that any file
/// store can back it.
///
/// Paths are relative, use `/`, and never start with one.
abstract class SyncStorage {
  /// Names of the files directly inside [dir]. A missing directory is empty.
  Future<List<String>> list(String dir);

  /// The file's bytes, or null if it does not exist.
  Future<Uint8List?> read(String path);

  /// Creates the file. Throws [SyncException] with [SyncFailure.exists] if it
  /// is already there, unless [overwrite] is set.
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false});

  /// Removes the file; a missing file is not an error.
  Future<void> delete(String path);

  /// Makes sure [dir] and its parents exist.
  Future<void> createDir(String dir);
}

/// Storage held in memory, for tests. [failNext] makes the next matching
/// operation throw, to exercise interrupted syncs.
class MemoryStorage implements SyncStorage {
  final Map<String, Uint8List> files = {};
  final Set<String> dirs = {};

  /// When set, the next operation whose name it returns true for fails once.
  bool Function(String operation, String path)? failNext;

  /// Every operation performed, as `operation path`.
  final List<String> log = [];

  void _enter(String operation, String path) {
    log.add('$operation $path');
    final fail = failNext;
    if (fail != null && fail(operation, path)) {
      failNext = null;
      throw const SyncException(SyncFailure.offline, 'The connection was lost.');
    }
  }

  @override
  Future<List<String>> list(String dir) async {
    _enter('list', dir);
    final prefix = '$dir/';
    return [
      for (final path in files.keys)
        if (path.startsWith(prefix) && !path.substring(prefix.length).contains('/'))
          path.substring(prefix.length),
    ];
  }

  @override
  Future<Uint8List?> read(String path) async {
    _enter('read', path);
    return files[path];
  }

  @override
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false}) async {
    _enter('write', path);
    if (!overwrite && files.containsKey(path)) {
      throw SyncException(SyncFailure.exists, '$path already exists.');
    }
    files[path] = bytes;
  }

  @override
  Future<void> delete(String path) async {
    _enter('delete', path);
    files.remove(path);
  }

  @override
  Future<void> createDir(String dir) async {
    _enter('createDir', dir);
    dirs.add(dir);
  }
}

/// Storage in a local directory. Any tool that mirrors a directory between
/// machines can then carry the sync.
class LocalFolderStorage implements SyncStorage {
  LocalFolderStorage(this.root);

  final Directory root;

  File _file(String path) => File('${root.path}/$path');

  @override
  Future<List<String>> list(String dir) async {
    final directory = Directory('${root.path}/$dir');
    if (!await directory.exists()) return [];
    return [
      await for (final entry in directory.list())
        if (entry is File) entry.uri.pathSegments.last,
    ];
  }

  @override
  Future<Uint8List?> read(String path) async {
    final file = _file(path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> write(String path, Uint8List bytes, {bool overwrite = false}) async {
    final file = _file(path);
    if (!overwrite && await file.exists()) {
      throw SyncException(SyncFailure.exists, '$path already exists.');
    }
    // Write beside the target and rename, so a reader never sees half a file.
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete(String path) async {
    final file = _file(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> createDir(String dir) =>
      Directory('${root.path}/$dir').create(recursive: true);
}
