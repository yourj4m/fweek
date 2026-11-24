import 'package:flutter/foundation.dart';

import '../calendar/calendar_service.dart';
import '../data/local_backups.dart';
import '../data/planner_store.dart';
import '../sync/sync_service.dart';

/// How a run of [SyncAll] went: what was done, and what could not be.
class SyncAllResult {
  const SyncAllResult({required this.done, required this.failed});

  final List<String> done;
  final List<String> failed;

  bool get ok => failed.isEmpty;

  /// One line for the user.
  String get message {
    if (failed.isNotEmpty) return failed.join(' ');
    if (done.isEmpty) return 'Nothing to sync yet';
    // Alone, the copy is said in full.
    if (done.length == 1 && done.single == 'copy kept') {
      return 'A copy of the planner was kept on this device';
    }
    final line = done.join(' · ');
    return line[0].toUpperCase() + line.substring(1);
  }
}

/// Everything that brings this device up to date and keeps the planner
/// safe, in one go: the header's sync button.
///
///  - the Nextcloud folder is synced, if one is connected;
///  - every subscribed calendar is read again (and a contacts file that
///    birthdays come from);
///  - a copy of the planner is kept on this device ([LocalBackups]), made
///    last so that it holds what just arrived.
///
/// Each part also runs by itself at its own times; this is for wanting it
/// now. Listeners are told when a run starts and when it ends.
class SyncAll extends ChangeNotifier {
  SyncAll({
    required this.store,
    required this.sync,
    required this.calendars,
    this.backups,
  });

  final PlannerStore store;
  final SyncService sync;
  final CalendarService calendars;

  /// Where copies are kept; without it (widget tests) none is made.
  final LocalBackups? backups;

  Future<SyncAllResult>? _running;
  bool _disposed = false;

  bool get running => _running != null;

  /// How the last run went; null before the first.
  SyncAllResult? last;

  /// Runs everything. Calls made while a run is under way join it.
  Future<SyncAllResult> run() {
    final running = _running;
    if (running != null) return running;
    final run = _run().whenComplete(() {
      _running = null;
      _notify();
    });
    _running = run;
    _notify();
    return run;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<SyncAllResult> _run() async {
    // Each part says what it did and what it could not do.
    Future<(String?, String?)> cloud() async {
      if (!sync.configured) return (null, null);
      await sync.syncNow();
      final place = (sync.config?.isGoogle ?? false) ? 'Google Drive' : 'Nextcloud';
      return sync.state == SyncState.error
          ? (null, '$place: ${sync.message ?? 'the sync failed.'}')
          : ('$place in sync', null);
    }

    Future<(String?, String?)> feeds() async {
      if (calendars.subscriptions.isEmpty) return (null, null);
      await calendars.refresh();
      final all = calendars.subscriptions;
      final broken = [for (final c in all) if (c.error != null) c];
      final read = all.length - broken.length;
      return (
        read == 0 ? null : read == 1 ? 'calendar read' : '$read calendars read',
        broken.isEmpty
            ? null
            : broken.length == 1
                ? '${broken.single.name}: ${broken.single.error}'
                : '${broken.length} of ${all.length} calendars could not be read.',
      );
    }

    Future<(String?, String?)> copy() async {
      final copies = backups;
      if (copies == null) return (null, null);
      try {
        await copies.make(store);
        return ('copy kept', null);
      } on Object catch (error) {
        return (null, 'The copy on this device could not be written: $error');
      }
    }

    // The two that go online run side by side; neither holds the other up.
    final online = await Future.wait([cloud(), feeds()]);
    final parts = [...online, await copy()];
    return last = SyncAllResult(
      done: [for (final (did, _) in parts) ?did],
      failed: [for (final (_, missed) in parts) ?missed],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
