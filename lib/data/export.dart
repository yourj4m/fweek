import 'dart:convert';

import 'database.dart';
import 'day.dart';
import 'models.dart';
import 'planner_store.dart';
import 'recurrence.dart';

/// Export and backup formats.
abstract final class Export {
  static const backupFormat = 'weektodo-backup';
  static const backupVersion = 2;

  static List<Task> _ordered(PlannerStore store) => store.allTasks.toList()
    ..sort((a, b) {
      final ad = a.date, bd = b.date;
      if (ad != null && bd != null) {
        final byDate = ad.compareTo(bd);
        if (byDate != 0) return byDate;
      } else if (ad != null || bd != null) {
        return ad != null ? -1 : 1;
      } else {
        final byList = (a.listId ?? '').compareTo(b.listId ?? '');
        if (byList != 0) return byList;
      }
      return a.position.compareTo(b.position);
    });

  static String _listTitle(PlannerStore store, String? id) {
    final title = id == null ? null : store.list(id)?.title;
    return title == null || title.isEmpty ? 'Someday' : title;
  }

  /// A complete backup that [restore] can read back.
  static String backup(PlannerStore store) {
    final settings = {
      for (final key in Settings.defaults.keys)
        if (key != Settings.lastRollover) key: store.setting<Object?>(key),
    };
    return const JsonEncoder.withIndent('  ').convert({
      'format': backupFormat,
      'version': backupVersion,
      'lists': [
        for (final l in store.lists)
          {'id': l.id, 'title': l.title, 'position': l.position},
      ],
      'tasks': [
        for (final t in _ordered(store))
          {
            'id': t.id,
            'list_id': t.listId,
            'date': t.date?.iso,
            'position': t.position,
            'title': t.title,
            if (t.note.isNotEmpty) 'note': t.note,
            if (t.color != null) 'color': t.color,
            if (t.time != null) 'time': t.time,
            if (t.done) 'done': true,
            if (t.doneAt != null) 'done_at': t.doneAt,
            if (t.subtasks.isNotEmpty)
              'subtasks': [for (final s in t.subtasks) s.toJson()],
            if (t.recurrence != null) 'recurrence': t.recurrence!.toJson(),
            if (t.exdates.isNotEmpty)
              'exdates': (t.exdates.map((d) => d.iso).toList()..sort()),
            if (t.seriesId != null) 'series_id': t.seriesId,
            if (t.seriesDate != null) 'series_date': t.seriesDate!.iso,
            if (t.reminder != null) 'reminder': _localStamp(t.reminder!),
            if (t.location.isNotEmpty) 'location': t.location,
            if (t.geo != null) 'geo': t.geo,
            'created_at': t.createdAt,
          },
      ],
      // The calendars as arranged, and what was changed about their events.
      // Never a calendar's address, nor an event that was left as it is:
      // those are the calendar's, not the planner's.
      'calendars': [
        for (final c in store.calendarRows)
          {
            'id': c.id,
            'name': c.name,
            if (c.color != null) 'color': c.color,
            if (c.hidden) 'hidden': true,
            'position': c.position,
            if (c.ids != null) 'ids': c.ids,
          },
      ],
      'events': [
        for (final e in store.eventOverrides)
          {
            'id': e.id,
            if (e.calendar != null) 'cal': e.calendar,
            if (e.origin != null) 'origin': e.origin!.iso,
            if (e.hidden) 'hidden': true,
            if (e.color != null) 'color': e.color,
            if (e.title != null) 'title': e.title,
            if (e.note != null) 'note': e.note,
            if (e.location != null) 'location': e.location,
            if (e.geo != null) 'geo': e.geo,
            if (e.date != null) 'date': e.date!.iso,
            if (e.time != null) 'time': e.time,
            if (e.done) 'done': true,
            if (e.doneAt != null) 'done_at': e.doneAt,
            if (e.reminder != null) 'reminder': _localStamp(e.reminder!),
            if (e.subtasks.isNotEmpty)
              'subtasks': [for (final s in e.subtasks) s.toJson()],
          },
      ],
      'settings': settings,
    });
  }

  /// Merges a backup into the store: tasks and lists are matched by id, so
  /// restoring twice does not duplicate anything. Returns the number of tasks
  /// read. Throws [FormatException] if [text] is not a backup.
  static int restore(PlannerStore store, String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('This file is not valid JSON.');
    }
    if (json is! Map || json['format'] != backupFormat) {
      throw const FormatException('This file is not a WeekToDo backup.');
    }
    final version = json['version'];
    if (version is! int || version > backupVersion) {
      throw FormatException(
        'This backup was made by a newer version of the app (format $version).',
      );
    }
    final db = store.db;
    final changes = <Change>[];
    final lists = json['lists'];
    if (lists is List) {
      for (final l in lists) {
        if (l is! Map || l['id'] is! String) continue;
        changes.addAll(db.stamp('lists', l['id'] as String, {
          'title': l['title'] is String ? l['title'] : '',
          'position': l['position'] is String ? l['position'] : '',
          'deleted': false,
        }));
      }
    }
    var count = 0;
    final tasks = json['tasks'];
    if (tasks is List) {
      for (final t in tasks) {
        if (t is! Map || t['id'] is! String) continue;
        count++;
        changes.addAll(db.stamp('tasks', t['id'] as String, {
          'list_id': t['list_id'],
          'date': t['date'],
          'position': t['position'] ?? '',
          'title': t['title'] ?? '',
          'note': t['note'] ?? '',
          'color': t['color'],
          'time': t['time'],
          'done': t['done'] == true,
          'done_at': t['done_at'],
          'subtasks': t['subtasks'] ?? const [],
          'recurrence': t['recurrence'],
          'exdates': t['exdates'] ?? const [],
          'series_id': t['series_id'],
          'series_date': t['series_date'],
          'reminder': t['reminder'],
          'location': t['location'],
          'geo': t['geo'],
          'created_at': t['created_at'] ?? 0,
          'deleted': false,
        }));
      }
    }
    final calendars = json['calendars'];
    if (calendars is List) {
      for (final c in calendars) {
        if (c is! Map || c['id'] is! String) continue;
        changes.addAll(db.stamp('calendars', c['id'] as String, {
          'name': c['name'],
          'color': c['color'],
          'hidden': c['hidden'] == true,
          'position': c['position'] ?? '',
          'ids': c['ids'],
          'deleted': false,
        }));
      }
    }
    final events = json['events'];
    if (events is List) {
      for (final e in events) {
        if (e is! Map || e['id'] is! String) continue;
        changes.addAll(db.stamp('events', e['id'] as String, {
          'cal': e['cal'],
          'origin': e['origin'],
          'hidden': e['hidden'] == true,
          'color': e['color'],
          'title': e['title'],
          'note': e['note'],
          'location': e['location'],
          'geo': e['geo'],
          'date': e['date'],
          'time': e['time'],
          'done': e['done'] == true,
          'done_at': e['done_at'],
          'reminder': e['reminder'],
          'subtasks': e['subtasks'],
        }));
      }
    }
    final settings = json['settings'];
    final local = <String, Object?>{};
    if (settings is Map) {
      for (final entry in settings.entries) {
        final key = entry.key;
        if (key is! String || !Settings.defaults.containsKey(key)) continue;
        if (Settings.local.contains(key)) {
          local[key] = entry.value;
        } else {
          changes.addAll(db.stamp('settings', key, {'value': entry.value}));
        }
      }
    }
    store.refresh(db.apply(changes));
    // Per-device settings are restored on this device only, not synced.
    local.forEach(store.setSetting);
    return count;
  }

  static String _localStamp(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}T'
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _clock(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// Comma-separated values, one task per line, with a header row.
  static String csv(PlannerStore store) {
    String cell(Object? value) {
      final text = value?.toString() ?? '';
      return RegExp('[",\n\r]').hasMatch(text)
          ? '"${text.replaceAll('"', '""')}"'
          : text;
    }

    final lines = [
      'date,list,time,title,done,color,repeats,note,subtasks,location',
      for (final t in _ordered(store))
        [
          t.date?.iso ?? '',
          t.date == null ? _listTitle(store, t.listId) : '',
          t.time == null ? '' : _clock(t.time!),
          t.title,
          t.done ? 'yes' : 'no',
          t.color ?? '',
          t.recurrence == null ? '' : t.recurrence!.frequency.name,
          t.note,
          t.subtasks.map((s) => '${s.done ? '[x]' : '[ ]'} ${s.text}').join('; '),
          t.location,
        ].map(cell).join(','),
    ];
    return '${lines.join('\r\n')}\r\n';
  }

  /// Plain text grouped by day, then by list.
  static String text(PlannerStore store) {
    final out = StringBuffer();
    String? heading;
    for (final t in _ordered(store)) {
      final group = t.date?.iso ?? _listTitle(store, t.listId);
      if (group != heading) {
        if (heading != null) out.writeln();
        out.writeln(group);
        heading = group;
      }
      final time = t.time == null ? '' : '${_clock(t.time!)} ';
      out.writeln('${t.done ? '[x]' : '[ ]'} $time${t.title}');
      for (final s in t.subtasks) {
        out.writeln(s.heading
            ? '      ${s.text}'
            : '    ${s.done ? '[x]' : '[ ]'} ${s.text}');
      }
      if (t.hasLocation) out.writeln('    @ ${t.location.trim().replaceAll('\n', ', ')}');
      if (t.note.trim().isNotEmpty) {
        for (final line in t.note.trim().split('\n')) {
          out.writeln('    > $line');
        }
      }
    }
    return out.toString();
  }

  /// iCalendar with one VTODO per dated task (Someday tasks have no due date).
  static String ics(PlannerStore store, {DateTime? now}) {
    String escape(String s) => s
        .replaceAll(r'\', r'\\')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .replaceAll('\r\n', r'\n')
        .replaceAll('\n', r'\n');
    String date(Day d) =>
        '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    String utc(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    }

    String rrule(Recurrence r, Day anchor) {
      const names = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
      final parts = <String>[
        'FREQ=${r.frequency.name.toUpperCase()}',
        if (r.interval != 1) 'INTERVAL=${r.interval}',
        if (r.frequency == Frequency.weekly && r.weekdays.isNotEmpty)
          'BYDAY=${(r.weekdays.toList()..sort()).map((d) => names[d - 1]).join(',')}',
        if (r.frequency == Frequency.monthly && r.nthWeekday != null)
          'BYDAY=${r.nthWeekday}${names[anchor.weekday - 1]}',
        if (r.until != null) 'UNTIL=${date(r.until!)}',
      ];
      return parts.join(';');
    }

    final stamp = utc(now ?? DateTime.now());
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//WeekToDo//Planner//EN',
    ];
    for (final t in _ordered(store)) {
      lines.addAll([
        'BEGIN:VTODO',
        'UID:${t.id}@weektodo',
        'DTSTAMP:$stamp',
        'SUMMARY:${escape(t.title)}',
        if (t.note.trim().isNotEmpty) 'DESCRIPTION:${escape(t.note.trim())}',
        if (t.hasLocation) 'LOCATION:${escape(t.location.trim())}',
        if (t.geo case final geo? when geo.contains(','))
          'GEO:${geo.replaceFirst(',', ';')}',
        if (t.date != null && t.time == null) 'DUE;VALUE=DATE:${date(t.date!)}',
        if (t.date != null && t.time != null)
          'DUE:${date(t.date!)}T${_clock(t.time!).replaceAll(':', '')}00',
        if (t.date != null && t.recurrence != null) ...[
          t.time == null
              ? 'DTSTART;VALUE=DATE:${date(t.date!)}'
              : 'DTSTART:${date(t.date!)}T${_clock(t.time!).replaceAll(':', '')}00',
          'RRULE:${rrule(t.recurrence!, t.date!)}',
          for (final d in t.exdates.toList()..sort())
            'EXDATE;VALUE=DATE:${date(d)}',
        ],
        'STATUS:${t.done ? 'COMPLETED' : 'NEEDS-ACTION'}',
        if (t.done && t.doneAt != null)
          'COMPLETED:${utc(DateTime.fromMillisecondsSinceEpoch(t.doneAt!))}',
        'END:VTODO',
      ]);
    }
    lines.add('END:VCALENDAR');
    // Content lines are folded at 75 octets (RFC 5545 §3.1).
    final folded = <String>[];
    for (final line in lines) {
      final bytes = utf8.encode(line);
      if (bytes.length <= 75) {
        folded.add(line);
        continue;
      }
      var start = 0;
      var first = true;
      while (start < bytes.length) {
        var end = start + (first ? 75 : 74);
        if (end > bytes.length) end = bytes.length;
        // Do not split inside a multi-byte character.
        while (end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
          end--;
        }
        folded.add((first ? '' : ' ') + utf8.decode(bytes.sublist(start, end)));
        start = end;
        first = false;
      }
    }
    return '${folded.join('\r\n')}\r\n';
  }
}
