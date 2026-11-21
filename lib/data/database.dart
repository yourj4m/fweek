import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'hlc.dart';

/// One change to one field of one row, stamped with when and where it was made.
///
/// Changes are the unit of both storage and sync: the tables hold the result
/// of applying every change, newest stamp winning per field, so two devices
/// that have seen the same changes hold the same data regardless of the order
/// in which the changes arrived.
class Change {
  const Change({
    required this.hlc,
    required this.table,
    required this.row,
    required this.column,
    required this.value,
  });

  /// Hybrid-logical-clock stamp; see [Hlc].
  final String hlc;
  final String table;
  final String row;
  final String column;

  /// JSON-compatible value: null, bool, num, String, List or Map.
  final Object? value;

  Map<String, Object?> toJson() =>
      {'h': hlc, 't': table, 'r': row, 'c': column, 'v': value};

  static Change? fromJson(Object? json) {
    if (json is! Map) return null;
    final h = json['h'], t = json['t'], r = json['r'], c = json['c'];
    if (h is! String || t is! String || r is! String || c is! String) {
      return null;
    }
    return Change(hlc: h, table: t, row: r, column: c, value: json['v']);
  }
}

/// How a column's change value is stored in its table.
enum _Kind { text, integer, boolean, json }

const _schema = <String, Map<String, _Kind>>{
  'tasks': {
    'list_id': _Kind.text,
    'date': _Kind.text,
    'position': _Kind.text,
    'title': _Kind.text,
    'note': _Kind.text,
    'color': _Kind.text,
    'time': _Kind.integer,
    'done': _Kind.boolean,
    'done_at': _Kind.integer,
    'subtasks': _Kind.json,
    'recurrence': _Kind.json,
    'exdates': _Kind.json,
    'series_id': _Kind.text,
    'series_date': _Kind.text,
    'reminder': _Kind.text,
    'created_at': _Kind.integer,
    'deleted': _Kind.boolean,
    'location': _Kind.text,
    'geo': _Kind.text,
    'kind': _Kind.text,
    'end_time': _Kind.integer,
    'rolled_from': _Kind.text,
    'rolled_pos': _Kind.text,
    'list_pos': _Kind.text,
    'due': _Kind.text,
    'end_date': _Kind.text,
  },
  // What the user changed about an event of a subscribed calendar. The row
  // id is a fingerprint of the calendar and the event (see
  // calendar/identity.dart); a column left null follows the calendar.
  'events': {
    'cal': _Kind.text,
    'origin': _Kind.text,
    'hidden': _Kind.boolean,
    'color': _Kind.text,
    'title': _Kind.text,
    'note': _Kind.text,
    'location': _Kind.text,
    'geo': _Kind.text,
    'date': _Kind.text,
    'time': _Kind.integer,
    'done': _Kind.boolean,
    'done_at': _Kind.integer,
    'reminder': _Kind.text,
    'subtasks': _Kind.json,
    'kind': _Kind.text,
    'end_time': _Kind.integer,
    'position': _Kind.text,
  },
  // Subscribed calendars as the user arranged them: the row id is a
  // fingerprint of the calendar's address, which itself is never stored here.
  'calendars': {
    'name': _Kind.text,
    'color': _Kind.text,
    'hidden': _Kind.boolean,
    'position': _Kind.text,
    'ids': _Kind.text,
    'deleted': _Kind.boolean,
  },
  'lists': {
    'title': _Kind.text,
    'position': _Kind.text,
    'deleted': _Kind.boolean,
  },
  'settings': {
    'value': _Kind.json,
  },
};

/// The planner's SQLite database: current rows plus the log of changes that
/// produced them.
class PlannerDatabase {
  PlannerDatabase._(this._db) {
    final before = _migrate();
    foundVersion = before;
    deviceId = _meta('device_id') ?? _newDeviceId();
    clock = Hlc(deviceId: deviceId, last: _meta('last_hlc'));
    if (before >= 1 && before < _schemaVersion) _replay(before);
  }

  factory PlannerDatabase.open(String path) {
    final db = sqlite3.open(path);
    _keepCopy(db, path);
    return PlannerDatabase._(db);
  }

  /// Before a file written by an earlier version is brought up to date, a
  /// copy of it as it was is put beside it (`planner.db.v3`): the earlier
  /// version cannot open the file afterwards, and with the copy it can.
  static void _keepCopy(Database db, String path) {
    try {
      final version = db.select('pragma user_version').first.columnAt(0) as int;
      if (version < 1 || version >= _schemaVersion) return;
      final copy = File('$path.v$version');
      if (copy.existsSync()) copy.deleteSync();
      db.execute("vacuum into '${copy.path.replaceAll("'", "''")}'");
    } catch (_) {
      // A precaution only: a full disk must not keep the planner shut.
    }
  }

  factory PlannerDatabase.inMemory() =>
      PlannerDatabase._(sqlite3.openInMemory());

  final Database _db;

  /// The schema version the file had when it was opened just now; 0 for a
  /// new file, the current version unless an update came in between.
  late final int foundVersion;

  /// Identifies this installation in change stamps.
  late final String deviceId;
  late final Hlc clock;

  static const _schemaVersion = 6;

  /// Tables and columns each schema version added, for [_replay]. A null
  /// column set means the whole table is new.
  static const _added = <int, Map<String, Set<String>?>>{
    2: {
      'tasks': {'location', 'geo'},
      'events': null,
      'calendars': null,
    },
    3: {
      'tasks': {'kind', 'end_time'},
      'events': {'kind', 'end_time'},
    },
    4: {
      'tasks': {'rolled_from', 'rolled_pos'},
      'events': {'position'},
    },
    5: {
      'tasks': {'list_pos', 'due'},
    },
    6: {
      'tasks': {'end_date'},
    },
  };

  /// Brings the tables up to this build's schema and returns the version
  /// found (0 for a new file).
  int _migrate() {
    _db.execute('pragma journal_mode = wal');
    _db.execute('pragma foreign_keys = off');
    final version = _db.select('pragma user_version').first.columnAt(0) as int;
    if (version > _schemaVersion) {
      throw StateError(
        'This database was written by a newer version of the app '
        '(schema $version, this build understands $_schemaVersion).',
      );
    }
    if (version < 1) {
      _db.execute('''
        create table tasks(
          id text primary key,
          list_id text,
          date text,
          position text not null default '',
          title text not null default '',
          note text not null default '',
          color text,
          time integer,
          done integer not null default 0,
          done_at integer,
          subtasks text not null default '[]',
          recurrence text,
          exdates text not null default '[]',
          series_id text,
          series_date text,
          reminder text,
          created_at integer not null default 0,
          deleted integer not null default 0
        );
        create index tasks_date on tasks(date);
        create table lists(
          id text primary key,
          title text not null default '',
          position text not null default '',
          deleted integer not null default 0
        );
        create table settings(
          id text primary key,
          value text
        );
        create table changes(
          hlc text primary key,
          tbl text not null,
          row text not null,
          col text not null,
          value text
        );
        create table cell_clock(
          tbl text not null,
          row text not null,
          col text not null,
          hlc text not null,
          primary key (tbl, row, col)
        );
        create table meta(
          key text primary key,
          value text
        );
        pragma user_version = 1;
      ''');
    }
    if (version < 2) {
      _db.execute('''
        alter table tasks add column location text;
        alter table tasks add column geo text;
        create table events(
          id text primary key,
          cal text,
          origin text,
          hidden integer not null default 0,
          color text,
          title text,
          note text,
          location text,
          geo text,
          date text,
          time integer,
          done integer not null default 0,
          done_at integer,
          reminder text,
          subtasks text
        );
        create table calendars(
          id text primary key,
          name text,
          color text,
          hidden integer not null default 0,
          position text,
          ids text,
          deleted integer not null default 0
        );
        pragma user_version = 2;
      ''');
    }
    if (version < 3) {
      // Whether an item is a task or an event, and when it ends.
      _db.execute('''
        alter table tasks add column kind text;
        alter table tasks add column end_time integer;
        alter table events add column kind text;
        alter table events add column end_time integer;
        pragma user_version = 3;
      ''');
    }
    if (version < 4) {
      // Where a task moved to today came from; where an event was put
      // among the items of its day.
      _db.execute('''
        alter table tasks add column rolled_from text;
        alter table tasks add column rolled_pos text;
        alter table events add column position text;
        pragma user_version = 4;
      ''');
    }
    if (version < 5) {
      // A task's place in its list, now that it can be on a day as well;
      // the day by which it is to be done.
      _db.execute('''
        alter table tasks add column list_pos text;
        alter table tasks add column due text;
        pragma user_version = 5;
      ''');
    }
    if (version < 6) {
      // The last day of an item that runs over several days.
      _db.execute('''
        alter table tasks add column end_date text;
        pragma user_version = 6;
      ''');
    }
    return version;
  }

  /// Applies changes that an older build of the app received from a newer
  /// one and kept in the log without understanding them (see [apply]): now
  /// that their tables and columns exist, they take effect.
  void _replay(int from) {
    final clauses = <String>[];
    final values = <Object?>[];
    for (var v = from + 1; v <= _schemaVersion; v++) {
      for (final entry in (_added[v] ?? const {}).entries) {
        final columns = entry.value;
        if (columns == null) {
          clauses.add('tbl = ?');
          values.add(entry.key);
        } else {
          clauses.add('(tbl = ? and col in (${List.filled(columns.length, '?').join(', ')}))');
          values..add(entry.key)..addAll(columns);
        }
      }
    }
    if (clauses.isEmpty) return;
    final rows = _db.select(
      'select hlc, tbl, row, col, value from changes '
      'where ${clauses.join(' or ')} order by hlc',
      values,
    );
    if (rows.isEmpty) return;
    apply([
      for (final r in rows)
        Change(
          hlc: r['hlc'] as String,
          table: r['tbl'] as String,
          row: r['row'] as String,
          column: r['col'] as String,
          value: jsonDecode(r['value'] as String),
        ),
    ]);
  }

  String _newDeviceId() {
    final rng = Random.secure();
    final id = List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();
    setMeta('device_id', id);
    return id;
  }

  String? _meta(String key) {
    final rows = _db.select('select value from meta where key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  String? meta(String key) => _meta(key);

  void setMeta(String key, String? value) {
    _db.execute(
      'insert into meta(key, value) values(?, ?) '
      'on conflict(key) do update set value = excluded.value',
      [key, value],
    );
  }

  /// Stamps new local changes for the given columns of one row. The changes
  /// are not stored until passed to [apply].
  List<Change> stamp(String table, String row, Map<String, Object?> columns) {
    final known = _schema[table];
    if (known == null) throw ArgumentError('Unknown table $table');
    return [
      for (final entry in columns.entries)
        if (!known.containsKey(entry.key))
          throw ArgumentError('Unknown column $table.${entry.key}')
        else
          Change(
            hlc: clock.next(),
            table: table,
            row: row,
            column: entry.key,
            value: entry.value,
          ),
    ];
  }

  /// Records [changes] and updates the affected rows, in one transaction.
  ///
  /// A change only takes effect if it is newer than the last change applied
  /// to the same field, so applying the same changes twice, or in a different
  /// order, gives the same result. Changes to unknown tables or columns are
  /// kept in the log (a newer app version may understand them) but not
  /// applied. Returns the `(table, row)` pairs whose stored values changed.
  Set<(String, String)> apply(Iterable<Change> changes) {
    final touched = <(String, String)>{};
    _db.execute('begin immediate');
    try {
      final insertChange = _db.prepare(
        'insert or ignore into changes(hlc, tbl, row, col, value) values(?, ?, ?, ?, ?)',
      );
      final readClock = _db.prepare(
        'select hlc from cell_clock where tbl = ? and row = ? and col = ?',
      );
      final writeClock = _db.prepare(
        'insert into cell_clock(tbl, row, col, hlc) values(?, ?, ?, ?) '
        'on conflict(tbl, row, col) do update set hlc = excluded.hlc',
      );
      try {
        for (final change in changes) {
          clock.observe(change.hlc);
          insertChange.execute([
            change.hlc,
            change.table,
            change.row,
            change.column,
            jsonEncode(change.value),
          ]);
          final kind = _schema[change.table]?[change.column];
          if (kind == null) continue;
          final current = readClock
              .select([change.table, change.row, change.column]);
          if (current.isNotEmpty &&
              (current.first['hlc'] as String).compareTo(change.hlc) >= 0) {
            continue;
          }
          _db.execute(
            'insert or ignore into ${change.table}(id) values(?)',
            [change.row],
          );
          _db.execute(
            'update ${change.table} set ${change.column} = ? where id = ?',
            [_toSql(kind, change.value), change.row],
          );
          writeClock.execute(
            [change.table, change.row, change.column, change.hlc],
          );
          touched.add((change.table, change.row));
        }
      } finally {
        insertChange.close();
        readClock.close();
        writeClock.close();
      }
      setMeta('last_hlc', clock.current);
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
    }
    return touched;
  }

  static Object? _toSql(_Kind kind, Object? value) => switch (kind) {
        _Kind.text => value is String ? value : null,
        _Kind.integer => value is num ? value.toInt() : null,
        _Kind.boolean => value == true ? 1 : 0,
        _Kind.json => value == null ? null : jsonEncode(value),
      };

  /// All rows of [table] as column maps.
  List<Map<String, Object?>> rows(String table) {
    if (!_schema.containsKey(table)) throw ArgumentError('Unknown table $table');
    return [for (final row in _db.select('select * from $table')) {...row}];
  }

  /// One row of [table], or null if it does not exist.
  Map<String, Object?>? row(String table, String id) {
    if (!_schema.containsKey(table)) throw ArgumentError('Unknown table $table');
    final rows = _db.select('select * from $table where id = ?', [id]);
    return rows.isEmpty ? null : {...rows.first};
  }

  /// Changes with a stamp greater than [after] (all changes when null), in
  /// stamp order. With [fromDevice], only those made on that device.
  List<Change> changesSince(String? after, {String? fromDevice}) {
    final rows = _db.select(
      'select hlc, tbl, row, col, value from changes '
      'where hlc > ? ${fromDevice == null ? '' : "and hlc like '%-' || ?"} '
      'order by hlc',
      [after ?? '', ?fromDevice],
    );
    return [
      for (final r in rows)
        Change(
          hlc: r['hlc'] as String,
          table: r['tbl'] as String,
          row: r['row'] as String,
          column: r['col'] as String,
          value: jsonDecode(r['value'] as String),
        ),
    ];
  }

  /// Whether [changesSince] would return anything, without reading it.
  bool hasChangesSince(String? after, {String? fromDevice}) => _db.select(
        'select 1 from changes '
        'where hlc > ? ${fromDevice == null ? '' : "and hlc like '%-' || ?"} limit 1',
        [after ?? '', ?fromDevice],
      ).isNotEmpty;

  int get changeCount =>
      _db.select('select count(*) from changes').first.columnAt(0) as int;

  void close() => _db.close();
}
