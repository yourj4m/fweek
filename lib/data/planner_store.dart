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

  /// Whether a list's task that is given a day stays in its list as well
  /// (and shows in both places), or leaves the list for the week.
  static const keepInList = 'keep_in_list';

  /// Whether the lists are shown in a panel beside the week (wide windows).
  static const listPanel = 'list_panel';

  /// Ids of the lists folded shut in that panel.
  static const foldedLists = 'folded_lists';

  /// The list that is open where the Tasks page shows one list at a time.
  static const openList = 'open_list';

  /// How wide that panel is, in logical pixels, once its edge was dragged;
  /// null for the width it comes with.
  static const panelWidth = 'panel_width';

  /// Settings that belong to this device and are not synced: how a planner
  /// looks on a phone need not follow the desktop.
  static const local = {
    theme, view, frameTiming, listPanel, foldedLists, openList, panelWidth,
  };

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
    keepInList: true,
    listPanel: false,
    foldedLists: <String>[],
    openList: null,
    panelWidth: null,
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

  /// Hands out what the calendars bring within one day (set by the calendar
  /// service), so that the planner's own tasks can be placed among it.
  List<Task> Function(Day day)? dayEventsResolver;

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
    final date = Day.tryParse(row['date'] as String?);
    // A last day counts when it lies after the first.
    final last = Day.tryParse(row['end_date'] as String?);
    final endDay = date != null && last != null && last > date ? last : null;
    return Task(
      id: row['id'] as String,
      listId: row['list_id'] as String?,
      date: date,
      endDay: endDay,
      position: row['position'] as String? ?? '',
      title: row['title'] as String? ?? '',
      note: row['note'] as String? ?? '',
      color: row['color'] as String?,
      time: time,
      kind: kind,
      // Within one day an end comes after the start.
      end: time != null && end != null && (end > time || endDay != null) ? end : null,
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
      rolledFrom: Day.tryParse(row['rolled_from'] as String?),
      rolledPosition: row['rolled_pos'] as String?,
      listPos: row['list_pos'] as String? ?? '',
      due: Day.tryParse(row['due'] as String?),
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
      position: switch (row['position']) {
        final String key when key.isNotEmpty => key,
        _ => null,
      },
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

  /// The lists of the Tasks page in display order.
  List<TaskList> get lists => _lists.values.toList()
    ..sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });

  TaskList? list(String id) => _lists[id];

  /// What a list is called: its title, or a stand-in while it has none.
  String listName(String id) {
    final list = _lists[id];
    if (list == null) return '';
    if (list.title.isNotEmpty) return list.title;
    return lists.first.id == id ? 'To do' : 'Untitled list';
  }

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

  /// Deletes a list. Its tasks that have no day go with it; those on a day
  /// stay on that day and only lose the list. Returns what was done, for
  /// [restoreList].
  ListRemoval deleteList(String id) =>
      _take(id, _tasks.values.where((t) => t.listId == id), list: true);

  /// Clears the done tasks out of a list: those without a day are deleted,
  /// those on a day stay there and leave the list. Returns what was done,
  /// for [restoreList].
  ListRemoval clearDone(String id) =>
      _take(id, _tasks.values.where((t) => t.listId == id && t.done), list: false);

  ListRemoval _take(String id, Iterable<Task> tasks, {required bool list}) {
    final deleted = <String>[], detached = <String>[];
    for (final task in tasks) {
      (task.date == null ? deleted : detached).add(task.id);
    }
    final changes = <Change>[
      for (final task in deleted) ...db.stamp('tasks', task, {'deleted': true}),
      for (final task in detached) ...db.stamp('tasks', task, {'list_id': null}),
      if (list) ...db.stamp('lists', id, {'deleted': true}),
    ];
    if (changes.isNotEmpty) {
      db.apply(changes);
      _load();
      _revision++;
      notifyListeners();
    }
    return ListRemoval(listId: id, list: list, deleted: deleted, detached: detached);
  }

  /// Takes back [deleteList] or [clearDone] (undo).
  void restoreList(ListRemoval removal) {
    final changes = <Change>[
      if (removal.list) ...db.stamp('lists', removal.listId, {'deleted': false}),
      for (final task in removal.deleted)
        ...db.stamp('tasks', task, {'deleted': false}),
      for (final task in removal.detached)
        ...db.stamp('tasks', task, {'list_id': removal.listId}),
    ];
    if (changes.isEmpty) return;
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
      endDay: () => series.endDay?.addDays(shift),
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
      // What runs over several days is not a row of one day: see
      // [spansBetween].
      if (date == null || task.endDay != null) continue;
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

  final Map<(Day, Day), List<Task>> _spanRanges = {};
  int _spansRevision = -1;

  /// The planner's own items that run over several days and touch
  /// [from]..[to], each once (a repeating one once per occurrence): by
  /// first day, longer ones first. Shared between callers until the next
  /// change; do not alter it.
  List<Task> spansBetween(Day from, Day to) {
    if (_spansRevision != _revision) {
      _spanRanges.clear();
      _spansRevision = _revision;
    }
    return _spanRanges[(from, to)] ??= _spansBetween(from, to);
  }

  List<Task> _spansBetween(Day from, Day to) {
    final spans = <Task>[];
    final hideDone = setting<bool>(Settings.hideDone);
    for (final task in _tasks.values) {
      final date = task.date, last = task.endDay;
      if (date == null || last == null) continue;
      final rule = task.recurrence;
      if (rule == null) {
        if (date <= to && last >= from && !(hideDone && task.done)) spans.add(task);
      } else {
        // An occurrence that began before the range may reach into it.
        final length = last.difference(date);
        for (final day in rule.occurrences(date, from.addDays(-length), to)) {
          if (!task.exdates.contains(day)) spans.add(_occurrence(task, day));
        }
      }
    }
    return spans..sort(compareSpans);
  }

  /// The order of items over several days: by first day, longer ones
  /// first, then by time and title.
  static int compareSpans(Task a, Task b) {
    final byStart = a.date!.compareTo(b.date!);
    if (byStart != 0) return byStart;
    final byLength = b.lastDay!.compareTo(a.lastDay!);
    if (byLength != 0) return byLength;
    final timedA = a.time == null ? 0 : 1, timedB = b.time == null ? 0 : 1;
    if (timedA != timedB) return timedA - timedB;
    if (a.time != null && a.time != b.time) return a.time! - b.time!;
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
  }

  int _compareInList(Task a, Task b) {
    final byPosition = a.listPosition.compareTo(b.listPosition);
    return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
  }

  final Map<String, _Listed> _listed = {};
  int _listedRevision = -1;
  Day? _listedDay;

  _Listed _inList(String listId) {
    // Every list of the page asks; the tasks are gone through once (and
    // once more when the day has turned: what was ticked today is told
    // from what was ticked before).
    final day = today;
    if (_listedRevision != _revision || _listedDay != day) {
      _listed.clear();
      _listedRevision = _revision;
      _listedDay = day;
      bool tickedToday(Task task) {
        final at = task.doneAt;
        return at != null &&
            Day.fromDateTime(DateTime.fromMillisecondsSinceEpoch(at)) == day;
      }

      for (final task in _tasks.values) {
        final id = task.listId;
        if (id == null) continue;
        final list = _listed[id] ??= (open: [], done: [], shown: [], folded: []);
        (task.done ? list.done : list.open).add(task);
        (!task.done || tickedToday(task) ? list.shown : list.folded).add(task);
      }
      int lastTickedFirst(Task a, Task b) {
        final byTime = (b.doneAt ?? 0).compareTo(a.doneAt ?? 0);
        // Ticked in the same moment: as they stood in the list.
        return byTime != 0 ? byTime : _compareInList(a, b);
      }

      for (final list in _listed.values) {
        list.open.sort(_compareInList);
        list.shown.sort(_compareInList);
        list.done.sort(lastTickedFirst);
        list.folded.sort(lastTickedFirst);
      }
    }
    return _listed[listId] ?? const (open: [], done: [], shown: [], folded: []);
  }

  /// What is still to do in a list, in the list's order: tasks without a
  /// day and tasks that have one alike. Shared until the next change; do
  /// not alter it.
  List<Task> openIn(String listId) => _inList(listId).open;

  /// The done tasks of a list, the one ticked last first.
  List<Task> doneIn(String listId) => _inList(listId).done;

  /// The rows a list shows: what is still to do and, in their places among
  /// it, the tasks ticked today. Those stay in sight until the day ends, a
  /// running record of what was done; from the next day on they are with
  /// the older done tasks ([foldedIn]). Shared until the next change; do
  /// not alter it.
  List<Task> shownIn(String listId) => _inList(listId).shown;

  /// The done tasks a list has put away: those ticked before today, the
  /// one ticked last first.
  List<Task> foldedIn(String listId) => _inList(listId).folded;

  /// Every task of a list: [openIn], then [doneIn].
  List<Task> tasksIn(String listId) => [...openIn(listId), ...doneIn(listId)];

  final Map<Day, List<Task>> _due = {};
  int _dueRevision = -1;

  /// The tasks still to do whose deadline is [day]. Shared until the next
  /// change; do not alter it.
  List<Task> dueOn(Day day) {
    if (_dueRevision != _revision) {
      _due.clear();
      _dueRevision = _revision;
      for (final task in _tasks.values) {
        final due = task.due;
        if (due != null && !task.done) (_due[due] ??= []).add(task);
      }
      for (final tasks in _due.values) {
        tasks.sort((a, b) => a.title.compareTo(b.title));
      }
    }
    return _due[day] ?? const [];
  }

  /// How many tasks are still to do in all lists together.
  int get openInLists {
    var count = 0;
    for (final list in _lists.keys) {
      count += openIn(list).length;
    }
    return count;
  }

  /// The items of one day as they are shown: [tasks] (as [tasksOn] gives
  /// them) and the [events] calendars bring within that day, as one list.
  ///
  /// An event the user has placed stands where its key puts it, among the
  /// tasks. One never placed has no key: those come first, in the order
  /// given (by time). Completed tasks go last when that is the setting.
  /// Then the items with a time are put in time order among the places
  /// such items hold: see [inTimeOrder].
  List<Task> arrangeDay(List<Task> tasks, List<Task> events) =>
      inTimeOrder(_byKey(tasks, events));

  /// [arrangeDay] before the items with a time are put in time order: the
  /// order of the keys, which a new key is made between.
  List<Task> _byKey(List<Task> tasks, List<Task> events) {
    if (events.isEmpty) return tasks;
    final loose = <Task>[], keyed = <Task>[...tasks];
    for (final event in events) {
      (event.position.isEmpty ? loose : keyed).add(event);
    }
    if (keyed.length > tasks.length) {
      keyed.sort(_compare);
      if (setting<bool>(Settings.sortDoneDown)) {
        final open = keyed.where((t) => !t.done).toList();
        keyed
          ..retainWhere((t) => t.done)
          ..insertAll(0, open);
      }
    }
    return [...loose, ...keyed];
  }

  /// [items] with those that have a time in time order. Items without a
  /// time stay where they were put, and so do those with a time that are
  /// already in time order among themselves (the largest such set, where
  /// an item placed by hand counts for more than any number of a
  /// calendar's events nobody placed). The others move next to them, by
  /// time: before the first later one, or right after the last one. So an
  /// event a calendar brings in later stands by its time, and a task given
  /// a time keeps its place while events move around it. Done tasks sorted
  /// down are ordered among themselves. Returns [items] itself when
  /// nothing moves.
  List<Task> inTimeOrder(List<Task> items) => _timeOrder(items).shown;

  /// [inTimeOrder], and the ids of the items it moved.
  ({List<Task> shown, Set<String> moved}) _timeOrder(List<Task> items) {
    final doneDown = setting<bool>(Settings.sortDoneDown);
    final moved = <String>{};
    final parts = doneDown
        ? [items.where((t) => !t.done).toList(), items.where((t) => t.done).toList()]
        : [items];
    var changed = false;
    final shown = <Task>[];
    for (final part in parts) {
      final ordered = _timeOrderOf(part, moved);
      changed |= !identical(ordered, part);
      shown.addAll(ordered);
    }
    return (shown: changed ? shown : items, moved: moved);
  }

  List<Task> _timeOrderOf(List<Task> items, Set<String> moved) {
    final timed = [for (final t in items) if (t.time != null) t];
    if (timed.length < 2) return items;
    // Events nobody placed have no place of their own to keep.
    int weight(Task t) => t.position.isNotEmpty || !Task.isEventId(t.id) ? 1 << 20 : 1;
    final score = [for (final t in timed) weight(t)], before = List.filled(timed.length, -1);
    var best = 0;
    for (var i = 0; i < timed.length; i++) {
      for (var j = 0; j < i; j++) {
        if (timed[j].time! <= timed[i].time! && score[j] + weight(timed[i]) > score[i]) {
          score[i] = score[j] + weight(timed[i]);
          before[i] = j;
        }
      }
      if (score[i] > score[best]) best = i;
    }
    final stay = <Task>{};
    for (var i = best; i >= 0; i = before[i]) {
      stay.add(timed[i]);
    }
    final movers = [for (final t in timed) if (!stay.contains(t)) t];
    if (movers.isEmpty) return items;
    // By time; of one time, in the order they stood in.
    final order = {for (var i = 0; i < movers.length; i++) movers[i]: i};
    movers.sort((a, b) {
      final byTime = a.time!.compareTo(b.time!);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    final result = <Task>[];
    var next = 0, left = stay.length;
    for (final t in items) {
      if (t.time != null && !stay.contains(t)) continue;
      if (stay.contains(t)) {
        while (next < movers.length && movers[next].time! < t.time!) {
          result.add(movers[next++]);
        }
        result.add(t);
        if (--left == 0) result.addAll(movers.skip(next));
      } else {
        result.add(t);
      }
    }
    for (final t in movers) {
      moved.add(t.id);
    }
    return result;
  }

  /// Gives the items [moved] of a day's rows [shown] keys that put them
  /// where they are shown, so that the keys follow the rows before a place
  /// among them is counted. What lies between two rows that stay gets keys
  /// between theirs.
  void _keepShownOrder(List<Task> shown, Set<String> moved) {
    final doneDown = setting<bool>(Settings.sortDoneDown);
    var i = 0;
    while (i < shown.length) {
      if (!moved.contains(shown[i].id)) {
        i++;
        continue;
      }
      var end = i;
      while (end < shown.length && moved.contains(shown[end].id)) {
        end++;
      }
      // The rows that stay on either side, if of the same part (open or,
      // sorted down, done).
      final part = shown[i].done;
      String? keyOf(int at) {
        if (at < 0 || at >= shown.length) return null;
        if (doneDown && shown[at].done != part) return null;
        final key = shown[at].position;
        return key.isEmpty ? null : key;
      }

      final low = keyOf(i - 1);
      var high = keyOf(end);
      if (low != null && high != null && low.compareTo(high) >= 0) high = null;
      final keys = orderKeysBetween(low, high, end - i);
      for (var k = i; k < end; k++) {
        final item = shown[k];
        if (item.event case final source?) {
          _writeEvent(source, {'position': keys[k - i]});
        } else if (_tasks.containsKey(item.id)) {
          _write('tasks', item.id, {'position': keys[k - i]});
        }
      }
      i = end;
    }
  }

  /// Everything shown on [day], in order: see [arrangeDay].
  List<Task> itemsOn(Day day) =>
      arrangeDay(tasksOn(day), dayEventsResolver?.call(day) ?? const []);

  /// The items of [slot] in the order of their keys. On a day that is the
  /// order shown except among items with a time ([inTimeOrder]); a place
  /// counted in the rows shown is the same place here, since the rows
  /// without a time stand in both alike and those with one fill the places
  /// such rows hold.
  List<Task> _itemsAt(Slot slot) => switch (slot) {
        DaySlot(:final day) =>
          _byKey(tasksOn(day), dayEventsResolver?.call(day) ?? const []),
        // As the list shows them, so that a place counted in its rows is
        // the place meant.
        ListSlot(:final listId) => shownIn(listId),
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
    // A list orders its tasks by keys of its own.
    final inList = slot is ListSlot;
    String place(Task t) => inList ? t.listPosition : t.position;
    List<Task> others() => _itemsAt(slot).where((t) => t.id != except).toList();
    var shown = others();
    // On a day some items with a time may be shown elsewhere than their
    // keys put them (see [inTimeOrder]): those get keys for where they are
    // shown first, so that a place counted in the rows is the place meant.
    if (!inList) {
      final order = _timeOrder(shown);
      if (order.moved.isNotEmpty) {
        _keepShownOrder(order.shown, order.moved);
        shown = others();
      }
    }
    final i = index == null ? shown.length : index.clamp(0, shown.length);
    // What a calendar brought and was never placed has no key and stands
    // above all that has one. To put something among such events, or above
    // them, they are given keys first, in the order they stand in.
    final loose =
        inList ? const <Task>[] : shown.takeWhile((t) => t.position.isEmpty).toList();
    if (i < loose.length) {
      final first = loose.length < shown.length ? shown[loose.length].position : null;
      final keys = orderKeysBetween(null, first, loose.length);
      for (var k = 0; k < loose.length; k++) {
        final source = loose[k].event;
        if (source != null) _writeEvent(source, {'position': keys[k]});
      }
      shown = others();
    }
    String? key(Task t) => place(t).isEmpty ? null : place(t);
    final before = i > 0 ? key(shown[i - 1]) : null;
    var after = i < shown.length ? key(shown[i]) : null;
    if (before != null && after != null && before.compareTo(after) >= 0) {
      // The list is not shown in stored order (done tasks sorted down), or
      // two devices issued the same key: go directly after the upper
      // neighbour in stored order instead.
      final later = shown
          .map(place)
          .where((p) => p.compareTo(before) > 0)
          .toList()
        ..sort();
      after = later.isEmpty ? null : later.first;
    }
    return orderKeyBetween(before, after);
  }

  /// The columns that put a new task at [index] of [slot].
  Map<String, Object?> _placeColumns(Slot slot, int? index) => switch (slot) {
        DaySlot(:final day) => {'date': day.iso, 'position': _keyAt(slot, index)},
        ListSlot(:final listId) => {
            'list_id': listId,
            'list_pos': _keyAt(slot, index),
          },
      };

  // ------------------------------------------------------------------ edits

  /// What a new item is when nothing else is said: the setting.
  ItemKind get newItemKind =>
      ItemKind.tryParse(setting<String>(Settings.newItems)) ?? ItemKind.task;

  /// Adds an item at [slot] (at the end, or at [index]) and returns its id:
  /// on a day a task or an event as [kind] says, or as the setting has it;
  /// in a list always a task. Returns null without adding anything when
  /// [title] is blank.
  String? addTask(Slot slot, String title, {int? index, ItemKind? kind}) {
    final text = title.trim();
    if (text.isEmpty) return null;
    final id = _newId();
    _write('tasks', id, {
      ..._placeColumns(slot, index),
      'title': text,
      'created_at': _now(),
      if (slot is DaySlot && (kind ?? newItemKind) == ItemKind.event)
        'kind': ItemKind.event.name,
    });
    return id;
  }

  /// Adds an item on [day] with everything the form for a new event sets,
  /// as one change, and returns its id. With [endDay] after [day] it runs
  /// over those days; [end] is then a time of the last day.
  String addItem({
    required Day day,
    required String title,
    ItemKind kind = ItemKind.event,
    Day? endDay,
    int? time,
    int? end,
    String note = '',
    String location = '',
    String? geo,
    String? color,
    Recurrence? recurrence,
    DateTime? reminder,
  }) {
    final id = _newId();
    final spans = endDay != null && endDay > day;
    _write('tasks', id, {
      ..._placeColumns(DaySlot(day), null),
      'title': title.trim(),
      'created_at': _now(),
      if (kind == ItemKind.event) 'kind': ItemKind.event.name,
      if (spans) 'end_date': endDay.iso,
      'time': ?time,
      if (time != null && end != null && (spans || end > time)) 'end_time': end,
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (location.trim().isNotEmpty) 'location': location.trim(),
      if (location.trim().isNotEmpty && geo != null) 'geo': geo,
      'color': ?color,
      if (recurrence != null) 'recurrence': recurrence.toJson(),
      if (reminder != null) 'reminder': _stamp(reminder),
    });
    return id;
  }

  /// Takes in an item from outside (an event of a calendar file) under an
  /// id of the caller's choosing: made when the planner has none under that
  /// id, brought up to date otherwise. What the user did with it since
  /// stays: its place in its day, whether it is a task or an event, a tick.
  /// One that had been deleted comes back. Returns whether it was made now.
  bool putItem(
    String id, {
    required Day day,
    required String title,
    String note = '',
    String location = '',
    int? time,
    int? end,
    Day? lastDay,
    ItemKind kind = ItemKind.event,
    Recurrence? recurrence,
    Set<Day> exdates = const {},
  }) {
    final known = _tasks[id];
    final isNew = known == null;
    final spans = lastDay != null && lastDay > day;
    _write('tasks', id, {
      'date': day.iso,
      'end_date': spans ? lastDay.iso : null,
      'list_id': null,
      if (isNew || known.date != day)
        'position': _keyAt(DaySlot(day), null, except: id),
      'title': title,
      'note': note,
      'location': location,
      'time': time,
      'end_time': time != null && end != null && (spans || end > time) ? end : null,
      'recurrence': recurrence?.toJson(),
      'exdates': [for (final d in exdates.toList()..sort()) d.iso],
      'deleted': false,
      if (isNew) ...{
        'kind': kind == ItemKind.event ? ItemKind.event.name : null,
        'created_at': _now(),
      },
    });
    return isNew;
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
        'end_time': task.end,
        'end_date': task.endDay?.iso,
        if (task.happens) 'kind': ItemKind.event.name,
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
    Day? Function()? due,
    Day? Function()? endDay,
  }) {
    final occurrence = task(id);
    if (occurrence == null) return;
    final source = occurrence.event;

    // The last day as it is to be: one after the first, or none. How long
    // an event of a calendar runs is its calendar's business.
    final first = occurrence.date;
    final Day? lastDay = switch (endDay) {
      null => occurrence.endDay,
      final set => switch (set()) {
          final day? when first != null && day > first => day,
          _ => null,
        },
    };
    final spans = source == null && lastDay != null;

    // The end as it is to be stored. One given outright is taken as it is.
    // With only the start changing, an end the user had set moves along
    // with it, and goes when it would pass midnight or the time is taken
    // away. [explicit] is that end, if any.
    ({int? value})? endFor(int? explicit) {
      if (end != null) {
        final start = time != null ? time() : occurrence.time;
        final value = end();
        // Over several days the end is a time of the last day.
        return (
          value: start != null && value != null && (spans || value > start) ? value : null
        );
      }
      if (explicit == null) return null;
      if (time == null) {
        // Only the last day can have changed. Back within one day, an end
        // at or before the start goes.
        if (endDay == null || spans) return null;
        final start = occurrence.time;
        return start == null || explicit <= start ? (value: null) : null;
      }
      final from = occurrence.time, to = time();
      if (from == null || to == null) return (value: null);
      // A time of the last day stays as it is.
      if (spans) return null;
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
      if (due != null) 'due': due()?.iso,
      if (endDay != null)
        // For one occurrence of a repeating item the length is what is
        // meant: the whole series runs that long.
        'end_date': lastDay == null
            ? null
            : _tasks[target]!.date!.addDays(lastDay.difference(first!)).iso,
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
      'position': null,
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
    _write('tasks', target, {
      'done': done,
      'done_at': done ? _now() : null,
      // Ticked where the daily move put it: no question left to answer.
      if (done && _tasks[target]?.rolledFrom != null) ...{
        'rolled_from': null,
        'rolled_pos': null,
      },
    });
    return target;
  }

  /// For a task the daily move of unfinished tasks brought to today: it had
  /// been done on the day it comes from, only not ticked. Puts it back
  /// exactly where it stood, ticked.
  void doneWhereItWas(String id) {
    final task = _tasks[id];
    final from = task?.rolledFrom;
    if (task == null || from == null) return;
    _write('tasks', id, {
      'date': from.iso,
      'position': task.rolledPosition ?? task.position,
      'done': true,
      'done_at': _now(),
      'rolled_from': null,
      'rolled_pos': null,
    });
  }

  /// For such a task: it is still to be done. It stays where the move put
  /// it, a task like any other from now on.
  void stillToDo(String id) {
    if (_tasks[id]?.rolledFrom == null) return;
    _write('tasks', id, {'rolled_from': null, 'rolled_pos': null});
  }

  /// Takes [doneWhereItWas] back: the task is as [before] again.
  void restoreMoved(Task before) {
    if (!_tasks.containsKey(before.id)) return;
    _write('tasks', before.id, {
      'date': before.date?.iso,
      'list_id': before.listId,
      'position': before.position,
      'done': before.done,
      'done_at': before.doneAt,
      'rolled_from': before.rolledFrom?.iso,
      'rolled_pos': before.rolledPosition,
    });
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
    if (current.date == null && rule != null) return id; // Only a day's task can repeat.
    _write('tasks', id, {
      'recurrence': rule?.toJson(),
      if (rule == null) 'exdates': <String>[],
      // What repeats is the week's business: it is in no list.
      if (rule != null && current.listId != null) 'list_id': null,
    });
    return id;
  }

  /// Moves a task to [slot] at [index] (the end when null). Moving one
  /// occurrence of a repeating task moves only that occurrence. Returns the
  /// id under which the task is addressed afterwards.
  ///
  /// To a day: the task is on that day from now on. One that came from a
  /// list stays in its list too, or leaves it, as [Settings.keepInList] has
  /// it. To a list: the task is in that list and has no day any more,
  /// unless [keepDay] (a task moved from one list to another, or within its
  /// list, keeps the day it is planned for).
  ///
  /// An imported event moved to a day is shown on that day from then on; one
  /// moved to a list becomes a task there, and the event itself is hidden.
  String moveTask(String id, Slot slot, {int? index, bool keepDay = false}) {
    if (Task.isEventId(id)) {
      final source = task(id)?.event;
      if (source == null) return id;
      switch (slot) {
        case DaySlot(:final day):
          _writeEvent(source, {
            'date': day == source.originalDay ? null : day.iso,
            // Dropped at a place among the day's items: it stands there.
            // Sent to a day without one: among that day's events, by time.
            'position': index == null ? null : _keyAt(slot, index, except: id),
          });
          return id;
        case ListSlot():
          final copy = copyTask(id, slot);
          _writeEvent(source, {'hidden': true});
          return copy;
      }
    }
    final target = detach(id);
    final current = _tasks[target];
    if (current == null) return target;
    // Moved by hand after the daily move: the user has dealt with it.
    final dealtWith = <String, Object?>{
      if (current.rolledFrom != null) ...{'rolled_from': null, 'rolled_pos': null},
    };
    switch (slot) {
      case DaySlot(:final day):
        final fromList = current.listId != null && current.date == null;
        _write('tasks', target, {
          'date': day.iso,
          // Over several days: as many from the new first day on.
          if (current.endDay != null)
            'end_date': day.addDays(current.endDay!.difference(current.date!)).iso,
          'position': _keyAt(slot, index, except: target),
          if (fromList && !setting<bool>(Settings.keepInList))
            'list_id': null
          else if (current.listId != null && current.listPos.isEmpty)
            // Its place in the list was kept in `position` until now.
            'list_pos': current.position,
          ...dealtWith,
        });
      case ListSlot(:final listId):
        _write('tasks', target, {
          'list_id': listId,
          'list_pos': _keyAt(slot, index, except: target),
          if (!keepDay) ...{
            'date': null,
            'end_date': null,
            'recurrence': null,
            ...dealtWith,
          },
        });
    }
    return target;
  }

  /// Takes a list's task off its day: it is in its list only again. Does
  /// nothing for a task that is in no list (it would be nowhere).
  void unplan(String id) {
    final item = task(id);
    if (item == null ||
        item.fromCalendar ||
        item.isOccurrence ||
        item.listId == null ||
        item.date == null) {
      return;
    }
    _write('tasks', id, {
      'date': null,
      'end_date': null,
      'recurrence': null,
      if (item.rolledFrom != null) ...{'rolled_from': null, 'rolled_pos': null},
    });
  }

  /// Puts a task into a list, at its end, or takes it out of its list
  /// ([listId] null); it keeps its day either way. A task without a day
  /// stays in some list. Repeating tasks and what a calendar brings are in
  /// no list.
  void setList(String id, String? listId) {
    final item = task(id);
    if (item == null || item.fromCalendar || item.repeats || item.listId == listId) {
      return;
    }
    if (listId == null) {
      if (item.date != null) _write('tasks', id, {'list_id': null});
    } else if (_lists.containsKey(listId)) {
      _write('tasks', id, {
        'list_id': listId,
        'list_pos': _keyAt(ListSlot(listId), null, except: id),
      });
    }
  }

  /// Duplicates a task to [slot] and returns the copy's id. A copy does not
  /// repeat and is not done.
  String copyTask(String id, Slot slot) {
    final source = task(id);
    if (source == null) throw ArgumentError('No task $id');
    final newId = _newId();
    final first = source.date, last = source.lastDay;
    _write('tasks', newId, {
      ..._placeColumns(slot, null),
      // On a day, a copy of what runs over several days runs as long.
      if (slot is DaySlot && source.spansDays)
        'end_date': slot.day.addDays(last!.difference(first!)).iso,
      'title': source.title,
      // For what a calendar brought this is its description, or what the
      // user made of it.
      'note': source.note,
      'color': source.color,
      'time': source.time,
      'end_time': source.end,
      // A list holds tasks: what is copied there is one.
      if (source.happens && slot is DaySlot) 'kind': ItemKind.event.name,
      'due': source.due?.iso,
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
  /// took place. Each task remembers where it came from ([Task.rolledFrom]),
  /// see [doneWhereItWas]. Returns how many tasks moved.
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
            t.endDay == null &&
            t.recurrence == null)
        .toList()
      ..sort((a, b) {
        final byDate = a.date!.compareTo(b.date!);
        return byDate != 0 ? byDate : _compare(a, b);
      });
    // Above everything that has a place on today, placed events included.
    final placed = [
      for (final item in itemsOn(now))
        if (item.position.isNotEmpty) item.position,
    ]..sort();
    final keys = orderKeysBetween(
      null,
      placed.isEmpty ? null : placed.first,
      overdue.length,
    );
    final changes = <Change>[
      for (var i = 0; i < overdue.length; i++)
        ...db.stamp('tasks', overdue[i].id, {
          'date': now.iso,
          'position': keys[i],
          // Where it comes from, so that it can go back there: it may have
          // been done and only left unticked. A task moved along day after
          // day keeps the place it first stood in.
          if (overdue[i].rolledFrom == null) ...{
            'rolled_from': overdue[i].date!.iso,
            'rolled_pos': overdue[i].position,
          },
        }),
      ...db.stamp('settings', Settings.lastRollover, {'value': now.iso}),
    ];
    refresh(db.apply(changes));
    return overdue.length;
  }
}

/// The tasks of one list, sorted for its different uses.
typedef _Listed = ({List<Task> open, List<Task> done, List<Task> shown, List<Task> folded});
