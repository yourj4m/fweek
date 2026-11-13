import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'database.dart';
import 'day.dart';
import 'models.dart';
import 'order_key.dart';
import 'recurrence.dart';

/// Setting keys and their defaults.
abstract final class Settings {
  /// `system`, `light` or `dark`, or the id of a colour theme.
  static const theme = 'theme';

  /// First day of the week: 1 (Monday) … 7 (Sunday).
  static const weekStart = 'week_start';

  /// Show times on a 24-hour clock.
  static const use24h = 'use_24h';

  /// Move unfinished tasks from past days to today.
  static const rollover = 'rollover';

  /// List completed tasks below unfinished ones.
  static const sortDoneDown = 'sort_done_down';

  /// Hide completed tasks.
  static const hideDone = 'hide_done';

  /// `week` or `month`.
  static const view = 'view';

  /// Colours the user added: a list of `#RRGGBB` strings.
  static const customColors = 'custom_colors';

  /// The day on which rollover last ran, as `YYYY-MM-DD`.
  static const lastRollover = 'last_rollover';

  /// Settings that belong to this device and are not synced: how a planner
  /// looks on a phone need not follow the desktop.
  static const local = {theme, view};

  static const defaults = <String, Object?>{
    theme: 'system',
    weekStart: 1,
    use24h: true,
    rollover: true,
    sortDoneDown: false,
    hideDone: false,
    view: 'week',
    customColors: <String>[],
    lastRollover: null,
  };
}

/// The planner's data and every operation on it.
///
/// Holds all tasks and lists in memory (a personal planner is small) and
/// writes each edit through [PlannerDatabase] as field-level changes, which is
/// what later makes sync a matter of exchanging change logs.
class PlannerStore extends ChangeNotifier {
  PlannerStore(this.db, {Day Function()? today, int Function()? now})
      : _today = today ?? Day.today,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _load();
  }

  final PlannerDatabase db;
  final Day Function() _today;
  final int Function() _now;
  final _rng = Random.secure();

  final Map<String, Task> _tasks = {};
  final Map<String, TaskList> _lists = {};
  final Map<String, Object?> _settings = {};

  /// Bumped on every change; lets views cache derived data cheaply.
  int get revision => _revision;
  int _revision = 0;

  Day get today => _today();

  // ---------------------------------------------------------------- loading

  void _load() {
    _tasks.clear();
    _lists.clear();
    _settings.clear();
    for (final row in db.rows('tasks')) {
      final task = _taskFromRow(row);
      if (!task.deleted) _tasks[task.id] = task;
    }
    for (final row in db.rows('lists')) {
      final list = _listFromRow(row);
      if (!list.deleted) _lists[list.id] = list;
    }
    for (final row in db.rows('settings')) {
      final key = row['id'] as String;
      if (Settings.local.contains(key)) continue;
      final raw = row['value'] as String?;
      _settings[key] = raw == null ? null : jsonDecode(raw);
    }
    for (final key in Settings.local) {
      final raw = db.meta('local.$key');
      if (raw != null) _settings[key] = jsonDecode(raw);
    }
    _ensureDefaultList();
  }

  /// Re-reads rows changed underneath the store, for example by sync.
  void refresh(Set<(String, String)> touched) {
    if (touched.isEmpty) return;
    for (final (table, id) in touched) {
      final row = db.row(table, id);
      switch (table) {
        case 'tasks':
          final task = row == null ? null : _taskFromRow(row);
          if (task == null || task.deleted) {
            _tasks.remove(id);
          } else {
            _tasks[id] = task;
          }
        case 'lists':
          final list = row == null ? null : _listFromRow(row);
          if (list == null || list.deleted) {
            _lists.remove(id);
          } else {
            _lists[id] = list;
          }
        case 'settings':
          if (Settings.local.contains(id)) break;
          final raw = row?['value'] as String?;
          _settings[id] = raw == null ? null : jsonDecode(raw);
      }
    }
    _revision++;
    notifyListeners();
  }

  void _ensureDefaultList() {
    if (_lists.isNotEmpty) return;
    final columns = {
      'title': '',
      'position': orderKeyBetween(null, null),
      'deleted': false,
    };
    final List<Change> changes;
    if (db.rows('lists').isEmpty) {
      // A new planner. The first list has a fixed id, so two fresh devices
      // that sync end up with one list rather than two, and its creation is
      // stamped with the oldest possible time: when this device later meets
      // one where that list was renamed or reordered, the real edits win.
      var n = 0;
      changes = [
        for (final entry in columns.entries)
          Change(
            hlc: '000000000000-${(n++).toRadixString(16).padLeft(4, '0')}-${db.deviceId}',
            table: 'lists',
            row: 'someday',
            column: entry.key,
            value: entry.value,
          ),
      ];
    } else {
      // Every list was deleted: bring the first one back as a real edit.
      changes = db.stamp('lists', 'someday', columns);
    }
    for (final (table, id) in db.apply(changes)) {
      final row = db.row(table, id);
      if (row == null) continue;
      final list = _listFromRow(row);
      if (!list.deleted) _lists[id] = list;
    }
  }

  static Task _taskFromRow(Map<String, Object?> row) {
    List<Object?> list(String key) {
      final raw = row[key] as String?;
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    }

    final recurrence = row['recurrence'] as String?;
    final reminder = row['reminder'] as String?;
    return Task(
      id: row['id'] as String,
      listId: row['list_id'] as String?,
      date: Day.tryParse(row['date'] as String?),
      position: row['position'] as String? ?? '',
      title: row['title'] as String? ?? '',
      note: row['note'] as String? ?? '',
      color: row['color'] as String?,
      time: row['time'] as int?,
      done: row['done'] == 1,
      doneAt: row['done_at'] as int?,
      subtasks: [
        for (final item in list('subtasks')) ?Subtask.fromJson(item),
      ],
      recurrence:
          recurrence == null ? null : Recurrence.fromJson(jsonDecode(recurrence)),
      exdates: {
        for (final item in list('exdates'))
          if (item is String) ?Day.tryParse(item),
      },
      seriesId: row['series_id'] as String?,
      seriesDate: Day.tryParse(row['series_date'] as String?),
      reminder: reminder == null ? null : DateTime.tryParse(reminder),
      createdAt: row['created_at'] as int? ?? 0,
      deleted: row['deleted'] == 1,
    );
  }

  static TaskList _listFromRow(Map<String, Object?> row) => TaskList(
        id: row['id'] as String,
        title: row['title'] as String? ?? '',
        position: row['position'] as String? ?? '',
        deleted: row['deleted'] == 1,
      );

  // ---------------------------------------------------------------- writing

  void _write(
    String table,
    String id,
    Map<String, Object?> columns, {
    bool notify = true,
  }) {
    if (columns.isEmpty) return;
    final touched = db.apply(db.stamp(table, id, columns));
    if (notify) {
      refresh(touched);
    } else {
      for (final (t, rowId) in touched) {
        final row = db.row(t, rowId);
        if (row == null) continue;
        if (t == 'tasks') _tasks[rowId] = _taskFromRow(row);
        if (t == 'lists') _lists[rowId] = _listFromRow(row);
      }
    }
  }

  String _newId() => List.generate(
        20,
        (_) => _rng.nextInt(36).toRadixString(36),
      ).join();

  static String _stamp(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}T'
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // --------------------------------------------------------------- settings

  T setting<T>(String key) =>
      (_settings.containsKey(key) ? _settings[key] : Settings.defaults[key]) as T;

  void setSetting(String key, Object? value) {
    if (_settings.containsKey(key) && _settings[key] == value) return;
    if (Settings.local.contains(key)) {
      db.setMeta('local.$key', jsonEncode(value));
      _settings[key] = value;
      _revision++;
      notifyListeners();
      return;
    }
    _write('settings', key, {'value': value});
  }

  int get weekStart {
    final value = setting<Object?>(Settings.weekStart);
    return value is int && value >= 1 && value <= 7 ? value : 1;
  }

  // ------------------------------------------------------------------ lists

  /// Someday lists in display order.
  List<TaskList> get lists => _lists.values.toList()
    ..sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });

  TaskList? list(String id) => _lists[id];

  /// Adds a list after the existing ones and returns its id.
  String addList([String title = '']) {
    final ordered = lists;
    final id = _newId();
    _write('lists', id, {
      'title': title,
      'position':
          orderKeyBetween(ordered.isEmpty ? null : ordered.last.position, null),
    });
    return id;
  }

  void renameList(String id, String title) =>
      _write('lists', id, {'title': title});

  /// Deletes a list together with the tasks in it.
  void deleteList(String id) {
    final changes = <Change>[
      for (final task in _tasks.values.where((t) => t.listId == id))
        ...db.stamp('tasks', task.id, {'deleted': true}),
      ...db.stamp('lists', id, {'deleted': true}),
    ];
    db.apply(changes);
    _load();
    _revision++;
    notifyListeners();
  }

  // ------------------------------------------------------------------ reads

  Task? task(String id) {
    final at = id.indexOf('@');
    if (at < 0) return _tasks[id];
    final series = _tasks[id.substring(0, at)];
    final day = Day.tryParse(id.substring(at + 1));
    if (series == null || day == null) return null;
    return _occurrence(series, day);
  }

  Task _occurrence(Task series, Day day) {
    final shift = day.difference(series.date!);
    return series.copyWith(
      id: '${series.id}@${day.iso}',
      date: () => day,
      reminder: () => series.reminder?.add(Duration(days: shift)),
      occurrenceOf: () => series.id,
      done: false,
      doneAt: () => null,
    );
  }

  int _compare(Task a, Task b) {
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
  }

  List<Task> _arrange(List<Task> tasks) {
    tasks.sort(_compare);
    if (setting<bool>(Settings.hideDone)) {
      tasks.removeWhere((t) => t.done);
    } else if (setting<bool>(Settings.sortDoneDown)) {
      final open = tasks.where((t) => !t.done).toList();
      return open..addAll(tasks.where((t) => t.done));
    }
    return tasks;
  }

  /// Tasks on [day] in display order, including occurrences of repeating tasks.
  List<Task> tasksOn(Day day) => tasksBetween(day, day)[day] ?? [];

  /// Tasks for each day in [from]..[to] that has any.
  Map<Day, List<Task>> tasksBetween(Day from, Day to) {
    final byDay = <Day, List<Task>>{};
    for (final task in _tasks.values) {
      final date = task.date;
      if (date == null) continue;
      final rule = task.recurrence;
      if (rule == null) {
        if (date >= from && date <= to) (byDay[date] ??= []).add(task);
      } else {
        for (final day in rule.occurrences(date, from, to)) {
          if (task.exdates.contains(day)) continue;
          (byDay[day] ??= []).add(_occurrence(task, day));
        }
      }
    }
    return {for (final e in byDay.entries) e.key: _arrange(e.value)};
  }

  /// Tasks in a Someday list in display order.
  List<Task> tasksIn(String listId) =>
      _arrange(_tasks.values.where((t) => t.listId == listId).toList());

  List<Task> _tasksAt(Slot slot) => switch (slot) {
        DaySlot(:final day) => tasksOn(day),
        ListSlot(:final listId) => tasksIn(listId),
      };

  /// Tasks whose title, note or subtasks contain [query], newest date first.
  /// With [color], only tasks highlighted in that colour.
  List<Task> search(String query, {String? color}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty && color == null) return const [];
    bool matches(Task t) {
      if (color != null && t.color != color) return false;
      if (needle.isEmpty) return true;
      return t.title.toLowerCase().contains(needle) ||
          t.note.toLowerCase().contains(needle) ||
          t.subtasks.any((s) => s.text.toLowerCase().contains(needle));
    }

    return _tasks.values.where(matches).toList()
      ..sort((a, b) {
        final ad = a.date, bd = b.date;
        if (ad == null && bd == null) return _compare(a, b);
        if (ad == null) return 1;
        if (bd == null) return -1;
        final byDate = bd.compareTo(ad);
        return byDate != 0 ? byDate : _compare(a, b);
      });
  }

  /// Every stored task that has a reminder and is not done.
  Iterable<Task> get tasksWithReminders =>
      _tasks.values.where((t) => t.reminder != null && !t.done);

  /// Every stored task (no computed occurrences), for export.
  Iterable<Task> get allTasks => _tasks.values;

  // -------------------------------------------------------------- positions

  /// An ordering key that places a task at [index] among the tasks at [slot],
  /// ignoring the task [except] (the one being moved).
  String _keyAt(Slot slot, int? index, {String? except}) {
    final shown = _tasksAt(slot).where((t) => t.id != except).toList();
    final i = index == null ? shown.length : index.clamp(0, shown.length);
    final before = i > 0 ? shown[i - 1].position : null;
    var after = i < shown.length ? shown[i].position : null;
    if (before != null && after != null && before.compareTo(after) >= 0) {
      // The list is not shown in stored order (done tasks sorted down), or
      // two devices issued the same key: go directly after the upper
      // neighbour in stored order instead.
      final later = shown
          .map((t) => t.position)
          .where((p) => p.compareTo(before) > 0)
          .toList()
        ..sort();
      after = later.isEmpty ? null : later.first;
    }
    return orderKeyBetween(before, after);
  }

  static Map<String, Object?> _slotColumns(Slot slot) => switch (slot) {
        DaySlot(:final day) => {'date': day.iso, 'list_id': null},
        ListSlot(:final listId) => {'date': null, 'list_id': listId},
      };

  // ------------------------------------------------------------------ edits

  /// Adds a task at [slot] (at the end, or at [index]) and returns its id.
  /// Returns null without adding anything when [title] is blank.
  String? addTask(Slot slot, String title, {int? index}) {
    final text = title.trim();
    if (text.isEmpty) return null;
    final id = _newId();
    _write('tasks', id, {
      ..._slotColumns(slot),
      'position': _keyAt(slot, index),
      'title': text,
      'created_at': _now(),
    });
    return id;
  }

  /// Returns the id of a stored task for [id]. A computed occurrence of a
  /// repeating task is first split off into a task of its own, and that day
  /// is excluded from the series.
  String detach(String id) {
    final task = this.task(id);
    if (task == null) throw ArgumentError('No task $id');
    if (!task.isOccurrence) return id;
    final series = _tasks[task.occurrenceOf]!;
    final newId = _newId();
    final changes = [
      ...db.stamp('tasks', newId, {
        'date': task.date!.iso,
        'list_id': null,
        'position': task.position,
        'title': task.title,
        'note': task.note,
        'color': task.color,
        'time': task.time,
        'subtasks': [for (final s in task.subtasks) s.toJson()],
        'reminder': task.reminder == null ? null : _stamp(task.reminder!),
        'series_id': series.id,
        'series_date': task.date!.iso,
        'created_at': _now(),
      }),
      ...db.stamp('tasks', series.id, {
        'exdates': [...series.exdates.map((d) => d.iso), task.date!.iso]..sort(),
      }),
    ];
    refresh(db.apply(changes));
    return newId;
  }

  /// The id to write to for an edit that applies to the whole series when
  /// [id] is an occurrence of a repeating task.
  String _seriesId(String id) {
    final at = id.indexOf('@');
    return at < 0 ? id : id.substring(0, at);
  }

  /// Edits text, colour, time, notes, subtasks or reminder. For a repeating
  /// task the edit applies to the whole series.
  void updateTask(
    String id, {
    String? title,
    String? note,
    String? Function()? color,
    int? Function()? time,
    List<Subtask>? subtasks,
    DateTime? Function()? reminder,
  }) {
    final occurrence = task(id);
    if (occurrence == null) return;
    final target = _seriesId(id);
    DateTime? seriesReminder(DateTime? value) {
      // A reminder set on a later occurrence is stored relative to the first.
      if (value == null || !occurrence.isOccurrence) return value;
      final series = _tasks[target]!;
      return value
          .subtract(Duration(days: occurrence.date!.difference(series.date!)));
    }

    _write('tasks', target, {
      'title': ?title,
      'note': ?note,
      if (color != null) 'color': color(),
      if (time != null) 'time': time(),
      if (subtasks != null) 'subtasks': [for (final s in subtasks) s.toJson()],
      if (reminder != null)
        'reminder': switch (seriesReminder(reminder())) {
          final value? => _stamp(value),
          null => null,
        },
    });
  }

  /// Marks a task done or not done. Completing one occurrence of a repeating
  /// task splits it off, so the rest of the series stays open.
  ///
  /// Returns the id under which the task is addressed afterwards.
  String setDone(String id, bool done) {
    final target = detach(id);
    _write('tasks', target, {'done': done, 'done_at': done ? _now() : null});
    return target;
  }

  /// Sets or clears how a task repeats. Returns the id under which the task
  /// is addressed afterwards.
  String setRecurrence(String id, Recurrence? rule) {
    final current = task(id);
    if (current == null) return id;
    if (current.isOccurrence) {
      final series = _tasks[current.occurrenceOf]!;
      if (rule == null) {
        // "Never" on a later occurrence ends the series the day before and
        // keeps this occurrence as an ordinary task.
        final kept = detach(id);
        _write('tasks', series.id, {
          'recurrence': series.recurrence!
              .copyWith(until: () => current.date!.addDays(-1))
              .toJson(),
        });
        return kept;
      }
      _write('tasks', series.id, {'recurrence': rule.toJson()});
      return id;
    }
    if (current.date == null && rule != null) return id; // Someday tasks cannot repeat.
    _write('tasks', id, {
      'recurrence': rule?.toJson(),
      if (rule == null) 'exdates': <String>[],
    });
    return id;
  }

  /// Moves a task to [slot] at [index] (the end when null). Moving one
  /// occurrence of a repeating task moves only that occurrence. Returns the
  /// id under which the task is addressed afterwards.
  String moveTask(String id, Slot slot, {int? index}) {
    final target = detach(id);
    _write('tasks', target, {
      ..._slotColumns(slot),
      'position': _keyAt(slot, index, except: target),
      if (slot is ListSlot) 'recurrence': null,
    });
    return target;
  }

  /// Duplicates a task to [slot] and returns the copy's id. A copy does not
  /// repeat and is not done.
  String copyTask(String id, Slot slot) {
    final source = task(id);
    if (source == null) throw ArgumentError('No task $id');
    final newId = _newId();
    _write('tasks', newId, {
      ..._slotColumns(slot),
      'position': _keyAt(slot, null),
      'title': source.title,
      'note': source.note,
      'color': source.color,
      'time': source.time,
      'subtasks': [
        for (final s in source.subtasks) s.copyWith(done: false).toJson(),
      ],
      'created_at': _now(),
    });
    return newId;
  }

  /// Deletes a task. For an occurrence of a repeating task, [wholeSeries]
  /// chooses between removing just that day and removing the series.
  void deleteTask(String id, {bool wholeSeries = false}) {
    final current = task(id);
    if (current == null) return;
    if (current.isOccurrence && !wholeSeries) {
      final series = _tasks[current.occurrenceOf]!;
      _write('tasks', series.id, {
        'exdates': [...series.exdates.map((d) => d.iso), current.date!.iso]
          ..sort(),
      });
      return;
    }
    _write('tasks', _seriesId(id), {'deleted': true});
  }

  /// Restores a task removed by [deleteTask] (undo).
  void restoreTask(String id) => _write('tasks', id, {'deleted': false});

  // --------------------------------------------------------------- rollover

  /// Moves unfinished tasks from past days to the top of today, once per day,
  /// when the setting is on. Repeating tasks are left where they are: their
  /// next occurrence comes round on its own. Returns how many tasks moved.
  int rollOver() {
    final now = today;
    if (!setting<bool>(Settings.rollover)) return 0;
    if (setting<String?>(Settings.lastRollover) == now.iso) return 0;
    final overdue = _tasks.values
        .where((t) =>
            t.date != null && t.date! < now && !t.done && t.recurrence == null)
        .toList()
      ..sort((a, b) {
        final byDate = a.date!.compareTo(b.date!);
        return byDate != 0 ? byDate : _compare(a, b);
      });
    final existing = [...tasksOn(now)]..sort(_compare);
    final keys = orderKeysBetween(
      null,
      existing.isEmpty ? null : existing.first.position,
      overdue.length,
    );
    final changes = <Change>[
      for (var i = 0; i < overdue.length; i++)
        ...db.stamp('tasks', overdue[i].id, {
          'date': now.iso,
          'position': keys[i],
        }),
      ...db.stamp('settings', Settings.lastRollover, {'value': now.iso}),
    ];
    refresh(db.apply(changes));
    return overdue.length;
  }
}
