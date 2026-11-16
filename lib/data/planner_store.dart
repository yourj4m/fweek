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

  /// Suggest places from the online search while a location is typed.
  static const placeSearch = 'place_search';

  /// The place search server; empty for the default one.
  static const placeServer = 'place_server';

  /// Draw the frame timing graphs over the app (for checking smoothness).
  static const frameTiming = 'frame_timing';

  /// What a new item is unless said otherwise while making it: `task` or
  /// `event`.
  static const newItems = 'new_items';

  /// Settings that belong to this device and are not synced: how a planner
  /// looks on a phone need not follow the desktop.
  static const local = {theme, view, frameTiming};

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
    placeSearch: true,
    placeServer: '',
    frameTiming: false,
    newItems: 'task',
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
  final Map<String, EventOverride> _overrides = {};
  final Map<String, CalendarRow> _calendars = {};

  /// Bumped on every change; lets views cache derived data cheaply.
  int get revision => _revision;
  int _revision = 0;

  /// Bumped when what the user changed about imported events, or the list
  /// of calendars, changes.
  int get overlayRevision => _overlayRevision;
  int _overlayRevision = 0;

  /// Finds the event of a subscribed calendar behind an id starting
  /// [Task.eventPrefix]. Set by the calendar service, which holds the
  /// calendars' events; the store holds only what was changed about them.
  Task? Function(String id)? eventResolver;

  Day get today => _today();

  /// The time now, by the clock the store was given.
  DateTime get clock => DateTime.fromMillisecondsSinceEpoch(_now());

  /// Midnight has passed: everything that marks today is drawn again.
  void dayTurned() {
    _revision++;
    notifyListeners();
  }

  // ---------------------------------------------------------------- loading

  void _load() {
    _tasks.clear();
    _lists.clear();
    _settings.clear();
    _overrides.clear();
    _calendars.clear();
    for (final row in db.rows('events')) {
      final override = _eventFromRow(row);
      _overrides[override.id] = override;
    }
    for (final row in db.rows('calendars')) {
      final calendar = _calendarFromRow(row);
      _calendars[calendar.id] = calendar;
    }
    _overlayRevision++;
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
        case 'events':
          if (row == null) {
            _overrides.remove(id);
          } else {
            _overrides[id] = _eventFromRow(row);
          }
          _overlayRevision++;
        case 'calendars':
          if (row == null) {
            _calendars.remove(id);
          } else {
            _calendars[id] = _calendarFromRow(row);
          }
          _overlayRevision++;
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
    final kind = ItemKind.tryParse(row['kind']) ?? ItemKind.task;
    final time = row['time'] as int?;
    final end = row['end_time'] as int?;
    return Task(
      id: row['id'] as String,
      listId: row['list_id'] as String?,
      date: Day.tryParse(row['date'] as String?),
      position: row['position'] as String? ?? '',
      title: row['title'] as String? ?? '',
      note: row['note'] as String? ?? '',
      color: row['color'] as String?,
      time: time,
      kind: kind,
      end: time != null && end != null && end > time ? end : null,
      // An event is not ticked off; a tick it had as a task comes back
      // with it should it become one again.
      done: row['done'] == 1 && kind == ItemKind.task,
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
      location: row['location'] as String? ?? '',
      geo: row['geo'] as String?,
    );
  }

  static EventOverride _eventFromRow(Map<String, Object?> row) {
    final reminder = row['reminder'] as String?;
    final raw = row['subtasks'] as String?;
    final decoded = raw == null ? null : jsonDecode(raw);
    return EventOverride(
      id: row['id'] as String,
      calendar: row['cal'] as String?,
      origin: Day.tryParse(row['origin'] as String?),
      hidden: row['hidden'] == 1,
      color: row['color'] as String?,
      title: row['title'] as String?,
      note: row['note'] as String?,
      location: row['location'] as String?,
      geo: row['geo'] as String?,
      date: Day.tryParse(row['date'] as String?),
      time: row['time'] as int?,
      done: row['done'] == 1,
      doneAt: row['done_at'] as int?,
      reminder: reminder == null ? null : DateTime.tryParse(reminder),
      subtasks: [
        if (decoded is List)
          for (final item in decoded) ?Subtask.fromJson(item),
      ],
      kind: ItemKind.tryParse(row['kind']),
      end: row['end_time'] as int?,
    );
  }

  static CalendarRow _calendarFromRow(Map<String, Object?> row) => CalendarRow(
        id: row['id'] as String,
        name: row['name'] as String? ?? '',
        color: row['color'] as String?,
        hidden: row['hidden'] == 1,
        position: row['position'] as String? ?? '',
        ids: row['ids'] as String?,
        deleted: row['deleted'] == 1,
      );

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

  /// Deletes a list together with the tasks in it. Returns the ids of those
  /// tasks, for [restoreList].
  List<String> deleteList(String id) {
    final tasks = [
      for (final task in _tasks.values.where((t) => t.listId == id)) task.id,
    ];
    final changes = <Change>[
      for (final task in tasks) ...db.stamp('tasks', task, {'deleted': true}),
      ...db.stamp('lists', id, {'deleted': true}),
    ];
    db.apply(changes);
    _load();
    _revision++;
    notifyListeners();
    return tasks;
  }

  /// Brings back a list removed by [deleteList], with its tasks (undo).
  void restoreList(String id, List<String> tasks) {
    final changes = <Change>[
      ...db.stamp('lists', id, {'deleted': false}),
      for (final task in tasks) ...db.stamp('tasks', task, {'deleted': false}),
    ];
    db.apply(changes);
    _load();
    _revision++;
    notifyListeners();
  }

  /// Moves a list one place earlier ([by] = −1) or later (+1) among the
  /// lists. Does nothing at either end.
  void moveList(String id, int by) {
    final ordered = lists;
    final from = ordered.indexWhere((l) => l.id == id);
    final to = from + by;
    if (from < 0 || to < 0 || to >= ordered.length || by == 0) return;
    ordered.removeAt(from);
    final before = to > 0 ? ordered[to - 1].position : null;
    final after = to < ordered.length ? ordered[to].position : null;
    // Two devices may have issued the same key; then no key fits between.
    if (before != null && after != null && before.compareTo(after) >= 0) return;
    _write('lists', id, {'position': orderKeyBetween(before, after)});
  }

  // ------------------------------------------------------------------ reads

  Task? task(String id) {
    if (Task.isEventId(id)) return eventResolver?.call(id);
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

  final Map<(Day, Day), Map<Day, List<Task>>> _ranges = {};
  int _rangesRevision = -1;

  /// Tasks for each day in [from]..[to] that has any. The result is shared
  /// between callers until the next change; do not alter it.
  Map<Day, List<Task>> tasksBetween(Day from, Day to) {
    // Every rebuild of a week asks for the same range again.
    if (_rangesRevision != _revision) {
      _ranges.clear();
      _rangesRevision = _revision;
    }
    return _ranges[(from, to)] ??= _tasksBetween(from, to);
  }

  Map<Day, List<Task>> _tasksBetween(Day from, Day to) {
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
          t.location.toLowerCase().contains(needle) ||
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

  /// What a new item is when nothing else is said: the setting.
  ItemKind get newItemKind =>
      ItemKind.tryParse(setting<String>(Settings.newItems)) ?? ItemKind.task;

  /// Adds an item at [slot] (at the end, or at [index]) and returns its id:
  /// a task or an event as [kind] says, or as the setting has it. Returns
  /// null without adding anything when [title] is blank.
  String? addTask(Slot slot, String title, {int? index, ItemKind? kind}) {
    final text = title.trim();
    if (text.isEmpty) return null;
    final id = _newId();
    _write('tasks', id, {
      ..._slotColumns(slot),
      'position': _keyAt(slot, index),
      'title': text,
      'created_at': _now(),
      if ((kind ?? newItemKind) == ItemKind.event) 'kind': ItemKind.event.name,
    });
    return id;
  }

  /// Makes an item a task or an event. For a repeating task this applies to
  /// the whole series; for what a calendar brought it is kept as the user's
  /// change to that event.
  void setKind(String id, ItemKind kind) {
    final item = task(id);
    if (item == null || item.kind == kind) return;
    final source = item.event;
    if (source != null) {
      _writeEvent(source, {'kind': kind.name});
    } else {
      _write('tasks', _seriesId(id), {'kind': kind.name});
    }
  }

  /// Returns the id of a stored task for [id]. A computed occurrence of a
  /// repeating task is first split off into a task of its own, and that day
  /// is excluded from the series.
  String detach(String id) {
    if (Task.isEventId(id)) return id;
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
        'location': task.location,
        'geo': task.geo,
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

  /// Edits text, colour, time, notes, place, subtasks or reminder. For a
  /// repeating task the edit applies to the whole series; for an imported
  /// event it is kept as the user's change to that event.
  void updateTask(
    String id, {
    String? title,
    String? note,
    String? Function()? color,
    int? Function()? time,
    int? Function()? end,
    List<Subtask>? subtasks,
    DateTime? Function()? reminder,
    String? location,
    String? Function()? geo,
  }) {
    final occurrence = task(id);
    if (occurrence == null) return;
    final source = occurrence.event;

    // The end as it is to be stored. One given outright is taken as it is.
    // With only the start changing, an end the user had set moves along
    // with it, and goes when it would pass midnight or the time is taken
    // away. [explicit] is that end, if any.
    ({int? value})? endFor(int? explicit) {
      if (end != null) {
        final start = time != null ? time() : occurrence.time;
        final value = end();
        return (value: start != null && value != null && value > start ? value : null);
      }
      if (time == null || explicit == null) return null;
      final from = occurrence.time, to = time();
      if (from == null || to == null) return (value: null);
      final moved = explicit + (to - from);
      return (value: moved > to && moved < 24 * 60 ? moved : null);
    }

    if (source != null) {
      final ownTime = source.allDay || source.start == null
          ? null
          : source.start!.hour * 60 + source.start!.minute;
      final newEnd = endFor(_overrides[source.key]?.end);
      _writeEvent(source, {
        if (title != null)
          'title': title.trim().isEmpty || title.trim() == source.title.trim()
              ? null
              : title.trim(),
        // The calendar's description is the note until it is edited. An
        // emptied note is kept as empty: null would bring the description
        // back.
        if (note != null) 'note': note.trim() == source.description.trim() ? null : note,
        if (color != null) 'color': color(),
        if (time != null)
          'time': switch (time()) {
            final minutes when minutes == ownTime => null,
            final minutes => minutes ?? EventOverride.noTime,
          },
        if (newEnd != null) 'end_time': newEnd.value,
        if (subtasks != null)
          'subtasks':
              subtasks.isEmpty ? null : [for (final s in subtasks) s.toJson()],
        if (reminder != null)
          'reminder': switch (reminder()) {
            final value? => _stamp(value),
            null => null,
          },
        if (location != null)
          'location':
              location.trim() == source.location.trim() ? null : location.trim(),
        if (geo != null) 'geo': geo(),
      });
      return;
    }
    final target = _seriesId(id);
    DateTime? seriesReminder(DateTime? value) {
      // A reminder set on a later occurrence is stored relative to the first.
      if (value == null || !occurrence.isOccurrence) return value;
      final series = _tasks[target]!;
      return value
          .subtract(Duration(days: occurrence.date!.difference(series.date!)));
    }

    final newEnd = endFor(occurrence.end);
    _write('tasks', target, {
      'title': ?title,
      'note': ?note,
      if (color != null) 'color': color(),
      if (time != null) 'time': time(),
      if (newEnd != null) 'end_time': newEnd.value,
      if (subtasks != null) 'subtasks': [for (final s in subtasks) s.toJson()],
      if (reminder != null)
        'reminder': switch (seriesReminder(reminder())) {
          final value? => _stamp(value),
          null => null,
        },
      'location': ?location?.trim(),
      if (geo != null) 'geo': geo(),
    });
  }

  // ---------------------------------------------------------------- events

  /// What was changed about the imported event named [key], if anything.
  EventOverride? eventOverride(String key) => _overrides[key];

  /// Every change made to imported events.
  Iterable<EventOverride> get eventOverrides => _overrides.values;

  static String _eventKey(String id) => id.substring(Task.eventPrefix.length);

  void _writeEvent(EventSource source, Map<String, Object?> columns) {
    if (columns.isEmpty) return;
    final known = _overrides[source.key];
    _write('events', source.key, {
      // Where to find the event again, on this and on other devices.
      if (known?.calendar == null) 'cal': source.calendar,
      if (known?.origin == null) 'origin': source.originalDay.iso,
      ...columns,
    });
  }

  /// Hides an imported event, or shows it again.
  void setEventHidden(String id, bool hidden) {
    final source = task(id)?.event;
    if (source != null) {
      _writeEvent(source, {'hidden': hidden});
    } else if (_overrides.containsKey(_eventKey(id))) {
      _write('events', _eventKey(id), {'hidden': hidden});
    }
  }

  /// Drops everything changed about an imported event: it reads as its
  /// calendar has it again.
  void resetEvent(String id) {
    final key = _eventKey(id);
    if (!_overrides.containsKey(key)) return;
    _write('events', key, {
      'hidden': false,
      'color': null,
      'title': null,
      'note': null,
      'location': null,
      'geo': null,
      'date': null,
      'time': null,
      'done': false,
      'done_at': null,
      'reminder': null,
      'subtasks': null,
      'kind': null,
      'end_time': null,
    });
  }

  /// Changes to imported events that carry a reminder and are neither
  /// ticked off (as tasks) nor hidden.
  Iterable<EventOverride> get eventsWithReminders => _overrides.values.where((o) =>
      o.reminder != null && !o.hidden && !(o.done && o.shownAs == ItemKind.task));

  // ------------------------------------------------------------- calendars

  /// A calendar's shared name, colour and visibility; null if none is known.
  CalendarRow? calendarRow(String key) => _calendars[key];

  /// Every calendar known, on this device or another, in display order.
  List<CalendarRow> get calendarRows => _calendars.values.where((c) => !c.deleted).toList()
    ..sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });

  /// Sets what is given of a calendar's name, colour, visibility and place
  /// in the list, creating its entry if needed.
  void setCalendar(
    String key, {
    String? name,
    String? color,
    bool? hidden,
    String? position,
    String? Function()? ids,
    bool? deleted,
  }) {
    final known = _calendars[key];
    final columns = <String, Object?>{
      if (name != null && name != known?.name) 'name': name,
      if (color != null && color != known?.color) 'color': color,
      if (hidden != null && hidden != (known?.hidden ?? false)) 'hidden': hidden,
      if (position != null && position != known?.position) 'position': position,
      if (ids != null && ids() != known?.ids) 'ids': ids(),
      if (deleted != null && deleted != (known?.deleted ?? false)) 'deleted': deleted,
    };
    // A new entry goes after the others unless it says where.
    if (known == null && !columns.containsKey('position')) {
      final ordered = calendarRows;
      columns['position'] =
          orderKeyBetween(ordered.isEmpty ? null : ordered.last.position, null);
    }
    _write('calendars', key, columns);
  }

  /// Moves a calendar one place earlier ([by] = −1) or later (+1).
  void moveCalendar(String key, int by) {
    final ordered = calendarRows;
    final from = ordered.indexWhere((c) => c.id == key);
    final to = from + by;
    if (from < 0 || to < 0 || to >= ordered.length || by == 0) return;
    ordered.removeAt(from);
    final before = to > 0 ? ordered[to - 1].position : null;
    final after = to < ordered.length ? ordered[to].position : null;
    if (before != null && after != null && before.compareTo(after) >= 0) return;
    _write('calendars', key, {'position': orderKeyBetween(before, after)});
  }

  // ---------------------------------------------------------------- status

  /// Marks a task done or not done. Completing one occurrence of a repeating
  /// task splits it off, so the rest of the series stays open.
  ///
  /// Returns the id under which the task is addressed afterwards.
  String setDone(String id, bool done) {
    // Only a task is ticked off.
    if (task(id)?.checkable == false) return id;
    if (Task.isEventId(id)) {
      final source = task(id)?.event;
      if (source != null) {
        _writeEvent(source, {'done': done, 'done_at': done ? _now() : null});
      }
      return id;
    }
    final target = detach(id);
    _write('tasks', target, {'done': done, 'done_at': done ? _now() : null});
    return target;
  }

  /// Sets or clears how a task repeats. Returns the id under which the task
  /// is addressed afterwards.
  String setRecurrence(String id, Recurrence? rule) {
    // How an imported event repeats is its calendar's business.
    if (Task.isEventId(id)) return id;
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
  ///
  /// An imported event moved to a day is shown on that day from then on; one
  /// moved to a list becomes a task there, and the event itself is hidden.
  String moveTask(String id, Slot slot, {int? index}) {
    if (Task.isEventId(id)) {
      final source = task(id)?.event;
      if (source == null) return id;
      switch (slot) {
        case DaySlot(:final day):
          _writeEvent(source, {'date': day == source.originalDay ? null : day.iso});
          return id;
        case ListSlot():
          final copy = copyTask(id, slot);
          _writeEvent(source, {'hidden': true});
          return copy;
      }
    }
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
      // For what a calendar brought this is its description, or what the
      // user made of it.
      'note': source.note,
      'color': source.color,
      'time': source.time,
      'end_time': source.end,
      if (source.happens) 'kind': ItemKind.event.name,
      'location': source.location,
      'geo': source.geo,
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
    // An imported event cannot be deleted from here, only hidden.
    if (Task.isEventId(id)) return setEventHidden(id, true);
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
  void restoreTask(String id) {
    if (Task.isEventId(id)) return setEventHidden(id, false);
    _write('tasks', _seriesId(id), {'deleted': false});
  }

  /// Puts back one day of a repeating task that [deleteTask] took out.
  void restoreOccurrence(String seriesId, Day day) {
    final series = _tasks[seriesId];
    if (series == null || !series.exdates.contains(day)) return;
    _write('tasks', seriesId, {
      'exdates': [
        for (final d in series.exdates)
          if (d != day) d.iso,
      ]..sort(),
    });
  }

  // --------------------------------------------------------------- rollover

  /// Moves unfinished tasks from past days to the top of today, once per day,
  /// when the setting is on. Repeating tasks are left where they are: their
  /// next occurrence comes round on its own. Events stay on their day: they
  /// took place. Returns how many tasks moved.
  int rollOver() {
    final now = today;
    if (!setting<bool>(Settings.rollover)) return 0;
    if (setting<String?>(Settings.lastRollover) == now.iso) return 0;
    final overdue = _tasks.values
        .where((t) =>
            t.date != null &&
            t.date! < now &&
            t.checkable &&
            !t.done &&
            t.recurrence == null)
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
