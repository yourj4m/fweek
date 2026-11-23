import 'dart:convert';
import 'dart:typed_data';

import '../data/database.dart';
import '../data/planner_store.dart';
import 'storage.dart';

/// What one sync run did.
class SyncResult {
  const SyncResult({
    required this.received,
    required this.sent,
    required this.compacted,
  });

  /// Changes from other devices that altered this planner.
  final int received;

  /// Changes of this device that were uploaded.
  final int sent;

  /// Whether this device's files were merged into one.
  final bool compacted;

  @override
  String toString() =>
      'SyncResult(received: $received, sent: $sent, compacted: $compacted)';
}

/// Synchronises a planner with a shared folder, without a server of its own.
///
/// Each device only ever adds files named after itself:
///
///     <folder>/changes/<device id>-<sequence number>.json
///
/// A file holds a batch of that device's changes and is never modified, so two
/// devices can never overwrite each other. Syncing is: read the files of other
/// devices not seen yet and apply their changes, then upload this device's new
/// changes as its next file. Applying a change is idempotent and
/// order-independent (see [PlannerDatabase.apply]), so every device that has
/// read every file holds the same planner.
///
/// When a device has accumulated many files it merges them into one.
class SyncEngine {
  SyncEngine(
    this.store,
    this.storage, {
    required this.folder,
    this.compactAbove = 30,
  });

  final PlannerStore store;
  final SyncStorage storage;

  /// Path of the sync folder inside [storage].
  final String folder;

  /// Merge this device's files once there are more than this many.
  final int compactAbove;

  // Named after the app's earlier name; kept so that devices on different
  // versions, and the files already in the folder, stay readable.
  static const format = 'weektodo-changes';
  static const formatVersion = 1;

  PlannerDatabase get _db => store.db;
  String get _changes => '$folder/changes';

  // Local bookkeeping. It describes this device's view of one particular
  // folder, so it is kept under a key derived from that folder.
  String _key(String name) => 'sync.$name';

  static final _fileName = RegExp(r'^([0-9a-f]{8})-(\d{8})\.json$');

  static String _name(String device, int sequence) =>
      '$device-${sequence.toString().padLeft(8, '0')}.json';

  Map<String, int> _seen() {
    final raw = _db.meta(_key('seen'));
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is int) e.key as String: e.value as int,
      };
    } on FormatException {
      return {};
    }
  }

  /// Whether this device has changes that are not in the folder yet.
  bool get hasPending => _db.hasChangesSince(
        _db.meta(_key('uploaded_hlc')),
        fromDevice: _db.deviceId,
      );

  /// Forgets what has been exchanged with the folder. The next sync reads
  /// everything again (harmless) and uploads this device's full history.
  /// Call when pointing the app at a different folder.
  void reset() {
    _db.setMeta(_key('seen'), null);
    _db.setMeta(_key('uploaded_hlc'), null);
    _db.setMeta(_key('sequence'), null);
    _db.setMeta(_key('ready'), null);
  }

  Uint8List _encode(int sequence, List<Change> changes) => utf8.encode(
        jsonEncode({
          'format': format,
          'version': formatVersion,
          'device': _db.deviceId,
          'sequence': sequence,
          'changes': [for (final c in changes) c.toJson()],
        }),
      );

  List<Change> _decode(String name, Uint8List bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw SyncException(
        SyncFailure.incompatible,
        'The file $name in the sync folder is damaged.',
      );
    }
    if (json is! Map || json['format'] != format) {
      throw SyncException(
        SyncFailure.incompatible,
        'The file $name in the sync folder is not a fweek file.',
      );
    }
    final version = json['version'];
    if (version is! int || version > formatVersion) {
      throw const SyncException(
        SyncFailure.incompatible,
        'Another device uses a newer version of fweek. '
        'Update this one to keep syncing.',
      );
    }
    final list = json['changes'];
    return [
      if (list is List)
        for (final item in list) ?Change.fromJson(item),
    ];
  }

  /// Exchanges changes with the folder. Throws [SyncException] on failure;
  /// a failed run leaves nothing half-done that the next run does not repair.
  Future<SyncResult> sync() async {
    final me = _db.deviceId;
    if (_db.meta(_key('ready')) != folder) {
      await storage.createDir(_changes);
      _db.setMeta(_key('ready'), folder);
    }

    // What is in the folder, per device, in sequence order.
    final files = <String, List<int>>{};
    for (final name in await storage.list(_changes)) {
      final match = _fileName.firstMatch(name);
      if (match == null) continue;
      (files[match[1]!] ??= []).add(int.parse(match[2]!));
    }
    for (final sequences in files.values) {
      sequences.sort();
    }

    // 1. Receive.
    final seen = _seen();
    var mySequence = int.tryParse(_db.meta(_key('sequence')) ?? '') ?? 0;
    var received = 0;
    for (final entry in files.entries) {
      final device = entry.key;
      // Files under this device's own name that it does not remember writing
      // mean its bookkeeping was lost (a restored database). Read them like
      // anyone else's, and continue numbering after them.
      final known = device == me ? mySequence : (seen[device] ?? 0);
      var latest = known;
      for (final sequence in entry.value) {
        if (sequence <= known) continue;
        final name = _name(device, sequence);
        final bytes = await storage.read('$_changes/$name');
        // Gone between listing and reading: its owner merged it into a later
        // file, which is still to come in this loop or the next sync.
        if (bytes == null) continue;
        final applied = _db.apply(_decode(name, bytes));
        received += applied.length;
        // Shown at once: if a later file fails, what has been applied is
        // already in the database and must be on screen too.
        store.refresh(applied);
        latest = sequence;
        // Record progress file by file, so an interruption repeats little.
        if (device == me) {
          mySequence = latest;
          _db.setMeta(_key('sequence'), '$mySequence');
        } else {
          seen[device] = latest;
          _db.setMeta(_key('seen'), jsonEncode(seen));
        }
      }
    }

    // 2. Send.
    final uploaded = _db.meta(_key('uploaded_hlc'));
    final pending = _db.changesSince(uploaded, fromDevice: me);
    if (pending.isNotEmpty) {
      mySequence++;
      await storage.write(
        '$_changes/${_name(me, mySequence)}',
        _encode(mySequence, pending),
      );
      _db.setMeta(_key('sequence'), '$mySequence');
      _db.setMeta(_key('uploaded_hlc'), pending.last.hlc);
      (files[me] ??= []).add(mySequence);
    }

    // 3. Tidy up this device's own files.
    var compacted = false;
    final mine = files[me] ?? const <int>[];
    if (mine.length > compactAbove) {
      // The newest change per field is all another device can ever need from
      // this one: older ones lose to it wherever they arrive.
      final latest = <String, Change>{};
      for (final change in _db.changesSince(null, fromDevice: me)) {
        latest['${change.table}\u0000${change.row}\u0000${change.column}'] = change;
      }
      final merged = latest.values.toList()
        ..sort((a, b) => a.hlc.compareTo(b.hlc));
      mySequence++;
      // The merged file is written before the old ones are removed, so there
      // is no moment at which a change exists nowhere in the folder.
      await storage.write(
        '$_changes/${_name(me, mySequence)}',
        _encode(mySequence, merged),
      );
      _db.setMeta(_key('sequence'), '$mySequence');
      for (final sequence in mine) {
        await storage.delete('$_changes/${_name(me, sequence)}');
      }
      compacted = true;
    }

    return SyncResult(
      received: received,
      sent: pending.length,
      compacted: compacted,
    );
  }
}
