import 'dart:io';

import 'package:path/path.dart' as p;

import 'day.dart';
import 'export.dart';
import 'planner_store.dart';

/// A copy of the planner kept on this device.
class LocalBackup {
  const LocalBackup(this.file, this.day, this.written);

  final File file;

  /// The day the copy is of.
  final Day day;

  /// When it was last written (a day's copy is replaced by a later one of
  /// the same day).
  final DateTime written;
}

/// Copies of the planner in a folder beside it, one for each day on which
/// one was made. They are the file that Settings → Backup saves, so they
/// are read back the same way.
///
/// They guard against a slip of one's own (a list deleted, a sync that
/// brought something unwanted), not against losing the device: for that
/// there is the sync folder, or a backup saved somewhere else.
class LocalBackups {
  LocalBackups(this.directory, {this.keep = 14, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Directory directory;

  /// How many days' copies are kept; older ones are removed.
  final int keep;
  final DateTime Function() _clock;

  static final _name = RegExp(r'^planner-(\d{4}-\d{2}-\d{2})\.json$');

  /// Writes today's copy, in the place of an earlier one of today, and
  /// removes the oldest ones beyond [keep].
  Future<LocalBackup> make(PlannerStore store) async {
    await directory.create(recursive: true);
    final now = _clock();
    final day = Day.fromDateTime(now);
    final file = File(p.join(directory.path, 'planner-${day.iso}.json'));
    // Complete before it takes the name, so that a copy is never half there.
    final part = File('${file.path}.part');
    await part.writeAsString(Export.backup(store), flush: true);
    await part.rename(file.path);
    for (final old in list().skip(keep)) {
      try {
        old.file.deleteSync();
      } on FileSystemException {
        // Still there next time.
      }
    }
    return LocalBackup(file, day, now);
  }

  /// The copies there are, the newest first.
  List<LocalBackup> list() {
    if (!directory.existsSync()) return const [];
    final found = <LocalBackup>[];
    for (final entry in directory.listSync()) {
      if (entry is! File) continue;
      final match = _name.firstMatch(p.basename(entry.path));
      if (match == null) continue;
      try {
        found.add(LocalBackup(entry, Day.parse(match[1]!), entry.lastModifiedSync()));
      } on FormatException {
        // Not a day: not one of ours.
      } on FileSystemException {
        // Gone meanwhile.
      }
    }
    return found..sort((a, b) => b.day.compareTo(a.day));
  }
}
