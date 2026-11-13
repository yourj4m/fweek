import 'dart:async';
import 'dart:convert';

import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';

/// A reminder that has come due.
class DueReminder {
  const DueReminder(this.task, this.at);
  final Task task;
  final DateTime at;
}

/// Fires task reminders while the app is running, and the daily rollover.
///
/// Desktop Linux has no system service this app can hand a future
/// notification to, so reminders are delivered only while the app is open; a
/// reminder that came due while it was closed is delivered at the next start
/// if it is less than [catchUp] old.
class ReminderService {
  ReminderService(
    this.store, {
    required this.notify,
    DateTime Function()? clock,
    this.catchUp = const Duration(hours: 12),
  }) : _clock = clock ?? DateTime.now;

  final PlannerStore store;

  /// Shows one notification.
  final void Function(DueReminder reminder) notify;
  final DateTime Function() _clock;
  final Duration catchUp;

  static const _metaKey = 'reminders_fired';
  static const _keep = 300;

  Timer? _timer;
  int _seenRevision = -1;

  void start() {
    store.addListener(_onStoreChanged);
    check();
  }

  void dispose() {
    store.removeListener(_onStoreChanged);
    _timer?.cancel();
  }

  void _onStoreChanged() {
    if (store.revision == _seenRevision) return;
    check();
  }

  /// Every reminder moment between [from] and [to], including those of
  /// repeating tasks' occurrences.
  List<DueReminder> _between(DateTime from, DateTime to) {
    final out = <DueReminder>[];
    for (final task in store.tasksWithReminders) {
      final reminder = task.reminder!;
      final rule = task.recurrence;
      final date = task.date;
      if (rule == null || date == null) {
        if (!reminder.isBefore(from) && !reminder.isAfter(to)) {
          out.add(DueReminder(task, reminder));
        }
        continue;
      }
      // The reminder keeps its offset from each occurrence's day.
      final offset = Day.fromDateTime(reminder).difference(date);
      final first = Day.fromDateTime(from).addDays(-offset - 1);
      final last = Day.fromDateTime(to).addDays(-offset + 1);
      for (final day in rule.occurrences(date, first, last)) {
        if (task.exdates.contains(day)) continue;
        final at = reminder.add(Duration(days: day.difference(date)));
        if (!at.isBefore(from) && !at.isAfter(to)) {
          out.add(DueReminder(store.task('${task.id}@${day.iso}') ?? task, at));
        }
      }
    }
    return out..sort((a, b) => a.at.compareTo(b.at));
  }

  List<String> _fired() {
    final raw = store.db.meta(_metaKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<String>().toList() : [];
    } on FormatException {
      return [];
    }
  }

  /// Delivers everything due, runs the rollover if the day changed, and arms
  /// a timer for the next reminder.
  void check() {
    _timer?.cancel();
    final now = _clock();
    store.rollOver();
    _seenRevision = store.revision;

    final fired = _fired();
    final seen = fired.toSet();
    var changed = false;
    for (final due in _between(now.subtract(catchUp), now)) {
      final key = '${due.task.id}|${due.at.toIso8601String()}';
      if (!seen.add(key)) continue;
      fired.add(key);
      changed = true;
      notify(due);
    }
    if (changed) {
      final kept = fired.length > _keep
          ? fired.sublist(fired.length - _keep)
          : fired;
      store.db.setMeta(_metaKey, jsonEncode(kept));
    }

    // Wake for the next reminder, at midnight for the rollover, and at least
    // hourly in case the system clock jumped (suspend, time-zone change).
    final horizon = now.add(const Duration(hours: 1));
    final midnight = DateTime(now.year, now.month, now.day + 1);
    var wake = midnight.isBefore(horizon) ? midnight : horizon;
    final upcoming = _between(now.add(const Duration(milliseconds: 1)), wake);
    if (upcoming.isNotEmpty) wake = upcoming.first.at;
    final delay = wake.difference(now) + const Duration(milliseconds: 250);
    _timer = Timer(delay, check);
  }
}
