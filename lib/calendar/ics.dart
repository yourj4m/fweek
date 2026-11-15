import 'dart:convert';

import '../data/day.dart';

/// A parsed calendar feed.
///
/// Reads the iCalendar format (RFC 5545) that calendar services publish for
/// read-only subscription. The text is parsed once; after that
/// [occurrencesBetween] answers from what was prepared then, so it can be
/// called for every week the planner draws.
class IcsCalendar {
  IcsCalendar._(
    this.name,
    this.eventCount,
    this.skipped,
    this._short,
    this._long,
    this._reach,
    this._series,
  );

  /// Parses a feed. Throws [FormatException] only when [text] is not an
  /// iCalendar file at all (no VCALENDAR). Events that cannot be understood
  /// are skipped and counted in [skipped]; they never throw.
  ///
  /// [toLocal] turns a UTC moment into the device's wall-clock time; the
  /// default is `(utc) => utc.toLocal()`. Tests pass a fixed zone.
  static IcsCalendar parse(
    String text, {
    DateTime Function(DateTime utc)? toLocal,
  }) =>
      _Reader(_Device(toLocal ?? (utc) => utc.toLocal())).read(text);

  /// The feed's own name (X-WR-CALNAME), if it has one.
  final String? name;

  /// How many events were read. A repeating series counts once, together
  /// with its changed instances; cancelled events are not counted.
  final int eventCount;

  /// How many events could not be understood and were left out.
  final int skipped;

  /// Events at fixed moments (everything but the repeating rules), sorted by
  /// first day, each lasting at most [_reach] days.
  final List<_Placed> _short;

  /// The few fixed events longer than [_longSpan] days. Kept apart so that
  /// one event with a mistyped end year does not widen the search for all.
  final List<_Placed> _long;

  final int _reach;

  final List<_Series> _series;

  /// One entry for every day in [first]..[last] (both included) that an
  /// event touches, in the device's time zone. Sorted by day, then all-day
  /// events first, then by start time, then by title.
  List<EventOccurrence> occurrencesBetween(Day first, Day last) {
    final from = _dayNumber(first);
    final to = _dayNumber(last);
    if (to < from) return [];
    final entries = <_Entry>[];
    for (var i = _firstStartingFrom(_short, from - _reach);
        i < _short.length && _short[i].firstDay <= to;
        i++) {
      _short[i].addTo(entries, from, to);
    }
    for (final placed in _long) {
      placed.addTo(entries, from, to);
    }
    for (final series in _series) {
      series.addTo(entries, from, to);
    }
    entries.sort(_inDisplayOrder);
    final days = <int, Day>{};
    return [for (final entry in entries) entry.placed.on(entry.day, days)];
  }

  /// The identifiers of every event in the feed.
  Set<String> get uids => {
        for (final placed in _short) placed.event.uid,
        for (final placed in _long) placed.event.uid,
        for (final series in _series) series.event.uid,
      };

  /// Every event that happens once, as shown on its first day, in no
  /// particular order. Together with [occurrencesBetween] for repeating
  /// events this finds an event wherever its calendar has moved it.
  Iterable<EventOccurrence> get standalone sync* {
    final days = <int, Day>{};
    for (final placed in _short.followedBy(_long)) {
      if (placed.instance.isEmpty) yield placed.on(placed.firstDay, days);
    }
  }
}

/// An event as shown on one day.
class EventOccurrence {
  const EventOccurrence({
    required this.uid,
    required this.title,
    required this.day,
    required this.allDay,
    required this.firstDay,
    required this.lastDay,
    this.start,
    this.end,
    this.location = '',
    this.description = '',
    this.instance = '',
  });

  final String uid;

  /// Which occurrence of a repeating event this is: a key made from the
  /// occurrence's original start, the same on every device whatever its
  /// time zone. An occurrence that the calendar changed on its own (moved,
  /// retitled) keeps the key of the one it replaces. Empty for an event
  /// that happens once.
  final String instance;

  bool get recurring => instance.isNotEmpty;

  /// SUMMARY, unescaped; empty if the event has none.
  final String title;

  /// The day this entry is shown on.
  final Day day;

  final bool allDay;

  /// Start and end in the device's wall-clock time (`isUtc == false`); both
  /// null for an all-day event. They belong to the whole occurrence, so on a
  /// later day of an occurrence spanning several days [start] lies before
  /// [day].
  final DateTime? start;
  final DateTime? end;

  /// First and last day of the whole occurrence.
  final Day firstDay;
  final Day lastDay;

  /// Unescaped; empty if missing.
  final String location;
  final String description;

  /// True on the second and later days of an occurrence spanning several days.
  bool get continues => day != firstDay;

  @override
  String toString() => allDay
      ? 'EventOccurrence($day, all day, "$title")'
      : 'EventOccurrence($day, $start–$end, "$title")';
}

const _msPerDay = Duration.millisecondsPerDay;

/// A timed event is looked for this many days either side of the requested
/// window in its own zone: zones lie up to 26 hours apart, so the date on the
/// device can differ from the date in the event's zone by two days.
const _zoneSlack = 2;

/// Fixed events longer than this many days are searched one by one.
const _longSpan = 60;

/// The most periods (days, weeks, months or years of a rule) walked for one
/// series in one query. A window of a few weeks needs a few dozen; the cap is
/// what keeps a year-long window or a senseless rule from stalling the app.
const _maxSteps = 20000;

/// The most periods walked to count out a rule with COUNT. That happens once
/// per series, from its beginning, and is remembered.
const _maxCountSteps = 50000;

/// Larger INTERVALs are treated as unsupported: stepping by them would leave
/// the range of dates [DateTime] can hold.
const _maxInterval = 100000;

/// Rules are not expanded past the year 9999.
final int _horizon = _epochDay(9999, 12, 31);

final Day _epoch = Day(1970, 1, 1);

/// TZIDs that mean UTC whether or not the feed defines them.
const _utcNames = {
  'UTC',
  'ETC/UTC',
  'UCT',
  'ETC/UCT',
  'GMT',
  'ETC/GMT',
  'Z',
  'ZULU',
  'ETC/ZULU',
};

const _weekdayCodes = {
  'MO': DateTime.monday,
  'TU': DateTime.tuesday,
  'WE': DateTime.wednesday,
  'TH': DateTime.thursday,
  'FR': DateTime.friday,
  'SA': DateTime.saturday,
  'SU': DateTime.sunday,
};

final _dateTimePattern = RegExp(
  r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$',
  caseSensitive: false,
);

// At most seven digits per part, so that the sum cannot overflow.
final _durationPattern = RegExp(
  r'^([+-])?P(?:(\d{1,7})W)?(?:(\d{1,7})D)?'
  r'(?:T(?:(\d{1,7})H)?(?:(\d{1,7})M)?(?:(\d{1,7})S)?)?$',
  caseSensitive: false,
);

final _offsetPattern = RegExp(r'^([+-])(\d{2})(\d{2})(\d{2})?$');

final _byDayPattern = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$');

// Dates are handled as whole days since 1970-01-01 and wall-clock times as
// UTC-flagged [DateTime]s holding the clock's fields, whatever zone the clock
// is in. Neither can cross a daylight-saving change during arithmetic, and
// neither involves the zone of the machine the code runs on.

int _epochDay(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ _msPerDay;

int _floorDiv(int a, int b) => (a - a % b) ~/ b;

int _dayOfWall(DateTime wall) =>
    _floorDiv(wall.millisecondsSinceEpoch, _msPerDay);

/// Monday = 1 … Sunday = 7; day 0 was a Thursday.
int _weekday(int day) => (day + 3) % 7 + 1;

DateTime _dateOf(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * _msPerDay, isUtc: true);

Day _toDay(int day) => _epoch.addDays(day);

int _dayNumber(Day day) => day.difference(_epoch);

/// The clock fields of [time], kept in a UTC-flagged value.
DateTime _wallOf(DateTime time) => DateTime.utc(
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second,
      time.millisecond,
    );

int _firstStartingFrom(List<_Placed> sorted, int day) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (sorted[middle].firstDay < day) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

int _firstAtLeast(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (sorted[middle] < value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

int _inDisplayOrder(_Entry a, _Entry b) {
  if (a.day != b.day) return a.day < b.day ? -1 : 1;
  final x = a.placed;
  final y = b.placed;
  if (x.event.allDay != y.event.allDay) return x.event.allDay ? -1 : 1;
  if (x.order != y.order) return x.order < y.order ? -1 : 1;
  var order = x.event.titleKey.compareTo(y.event.titleKey);
  if (order != 0) return order;
  order = x.event.title.compareTo(y.event.title);
  return order != 0 ? order : x.event.uid.compareTo(y.event.uid);
}

String _unescape(String text) {
  if (!text.contains(r'\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == r'\' && i + 1 < text.length) {
      final next = text[i + 1];
      if (next == 'n' || next == 'N') {
        out.write('\n');
        i++;
        continue;
      }
      if (next == ',' || next == ';' || next == r'\') {
        out.write(next);
        i++;
        continue;
      }
    }
    // Anything else, a stray backslash included, is kept as written.
    out.write(char);
  }
  return out.toString();
}

/// What the device's clock shows, relative to UTC.
class _Reading {
  const _Reading(this.offset, {required this.local}) : steady = true;

  /// Marks a day during which the device's offset changes.
  const _Reading.changing()
      : offset = 0,
        local = false,
        steady = false;

  /// Clock fields minus UTC, in milliseconds.
  final int offset;

  /// Whether the answer was a local [DateTime] rather than a UTC-flagged one.
  final bool local;

  /// Whether this holds for a whole day.
  final bool steady;

  bool sameAs(_Reading other) =>
      offset == other.offset && local == other.local;
}

/// The device's zone, known only through the function given to
/// [IcsCalendar.parse].
///
/// Asking is cheap, but reading the answer is not: a real device looks its
/// offset up in the system's zone data whenever the clock fields of a local
/// [DateTime] are first read, and building one from clock fields takes
/// several such lookups. A feed is asked about thousands of moments, most of
/// them on the same few days, so the offset is kept per UTC day: one that is
/// the same at both ends of a day is taken to hold throughout it. Days on
/// which the clocks change are read moment by moment.
class _Device {
  _Device(this._toLocal);

  final DateTime Function(DateTime utc) _toLocal;

  final Map<int, _Reading> _days = {};
  final Map<int, DateTime> _built = {};

  static const _remembered = 4096;

  static DateTime _utc(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  _Reading _read(int utcMs) {
    final answer = _toLocal(_utc(utcMs));
    return _Reading(
      _wallOf(answer).millisecondsSinceEpoch - utcMs,
      local: !answer.isUtc,
    );
  }

  /// The reading that holds all through a UTC day, if one does.
  _Reading? _steady(int day) {
    var reading = _days[day];
    if (reading == null) {
      final morning = _read(day * _msPerDay);
      final night = _read((day + 1) * _msPerDay - 1);
      reading = morning.sameAs(night) ? morning : const _Reading.changing();
      if (_days.length >= _remembered) _days.clear();
      _days[day] = reading;
    }
    return reading.steady ? reading : null;
  }

  /// The local [DateTime] with the clock fields of [wall], built the slow
  /// way and remembered.
  DateTime _build(DateTime wall) {
    final key = wall.millisecondsSinceEpoch;
    var built = _built[key];
    if (built == null) {
      built = DateTime(
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
        wall.second,
        wall.millisecond,
      );
      if (_built.length >= _remembered) _built.clear();
      _built[key] = built;
    }
    return built;
  }

  /// The device's clock fields at [utc].
  DateTime wall(DateTime utc) => at(utc).$1;

  /// The device's clock fields at [utc], and the value to hand to the app.
  ///
  /// A real device answers with a local [DateTime], which is handed on as
  /// it is: it knows which of two equal clock times it is when the clocks
  /// go back. A fixed test zone answers with a shifted UTC value, whose
  /// fields are rebuilt as a local one.
  (DateTime, DateTime) at(DateTime utc) {
    final utcMs = utc.millisecondsSinceEpoch;
    final answer = _toLocal(utc);
    final steady = _steady(_floorDiv(utcMs, _msPerDay));
    final wall =
        steady == null ? _wallOf(answer) : _utc(utcMs + steady.offset);
    return (wall, answer.isUtc ? _build(wall) : answer);
  }

  /// The local [DateTime] for a time that is already the device's clock.
  DateTime shown(DateTime wall) {
    // The moment is found by taking the day's offset off again. When the
    // device has that very offset at the moment found, its clock shows
    // [wall] then and its own answer for that moment is the value wanted.
    // Next to a clock change the platform is left to sort it out.
    final wallMs = wall.millisecondsSinceEpoch;
    final here = _steady(_floorDiv(wallMs, _msPerDay));
    if (here != null && here.local) {
      final utcMs = wallMs - here.offset;
      final there = _steady(_floorDiv(utcMs, _msPerDay));
      if (there != null && there.sameAs(here)) {
        final answer = _toLocal(_utc(utcMs));
        if (!answer.isUtc) return answer;
      }
    }
    return _build(wall);
  }
}

/// One content line: `NAME;PARAM=value;PARAM="quoted:value":value`.
class _Prop {
  _Prop(this.name, this.params, this.value);

  /// Upper case.
  final String name;

  /// Keys in upper case; values without their quotes.
  final Map<String, String> params;

  final String value;

  static const _semicolon = 0x3B;
  static const _colon = 0x3A;
  static const _equals = 0x3D;
  static const _quote = 0x22;

  static _Prop? parse(String line) {
    final length = line.length;
    var i = 0;
    while (i < length) {
      final c = line.codeUnitAt(i);
      if (c == _semicolon || c == _colon) break;
      i++;
    }
    if (i == 0 || i == length) return null;
    final name = line.substring(0, i).trim().toUpperCase();
    var params = const <String, String>{};
    while (i < length && line.codeUnitAt(i) == _semicolon) {
      final keyStart = i + 1;
      var j = keyStart;
      while (j < length) {
        final c = line.codeUnitAt(j);
        if (c == _equals || c == _semicolon || c == _colon) break;
        j++;
      }
      final key = line.substring(keyStart, j).trim().toUpperCase();
      var value = '';
      if (j < length && line.codeUnitAt(j) == _equals) {
        // A quoted parameter value may hold the separators themselves, as
        // in `ATTENDEE;CN="Doe; Jane":mailto:jane@example.org`.
        final valueStart = ++j;
        var quoted = false;
        while (j < length) {
          final c = line.codeUnitAt(j);
          if (c == _quote) {
            quoted = !quoted;
          } else if (!quoted && (c == _semicolon || c == _colon)) {
            break;
          }
          j++;
        }
        value = line.substring(valueStart, j).replaceAll('"', '');
      }
      if (params.isEmpty) params = {};
      params[key] = value;
      i = j;
    }
    if (i >= length) return null;
    return _Prop(name, params, line.substring(i + 1));
  }
}

/// Splits [text] into content lines, joining the ones that were folded (a
/// line break followed by a space or tab continues the line before it).
List<String> _unfold(String text) {
  final lines = <String>[];
  // Collected and joined once: an inline attachment can be folded into tens
  // of thousands of pieces, and appending them one by one would be quadratic.
  final parts = <String>[];
  void flush() {
    if (parts.isEmpty) return;
    lines.add(parts.length == 1 ? parts.first : parts.join());
    parts.clear();
  }

  for (final raw in const LineSplitter().convert(text)) {
    if (raw.isEmpty) continue;
    final first = raw.codeUnitAt(0);
    if ((first == 0x20 || first == 0x09) && parts.isNotEmpty) {
      parts.add(raw.substring(1));
    } else {
      flush();
      parts.add(raw);
    }
  }
  flush();
  return lines;
}

/// A DATE or DATE-TIME as written, before any zone is applied.
class _Value {
  _Value(this.wall, {required this.isDate, required this.isUtc});

  final DateTime wall;
  final bool isDate;
  final bool isUtc;

  static _Value? parse(String text) {
    final m = _dateTimePattern.firstMatch(text.trim());
    if (m == null) return null;
    final year = int.parse(m[1]!);
    final month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > Day.daysInMonth(year, month)) return null;
    if (m[4] == null) {
      return _Value(
        DateTime.utc(year, month, day),
        isDate: true,
        isUtc: false,
      );
    }
    final hour = int.parse(m[4]!);
    final minute = int.parse(m[5]!);
    final second = int.parse(m[6]!);
    // 24:00:00 is written by some producers for the end of a day, and :60
    // is a leap second; everything else out of range is a broken value.
    if (hour > 24 || minute > 59 || second > 60) return null;
    if (hour == 24 && (minute != 0 || second != 0)) return null;
    return _Value(
      DateTime.utc(year, month, day, hour, minute, second > 59 ? 59 : second),
      isDate: false,
      isUtc: m[7] != null,
    );
  }
}

/// A date or date-time together with the zone its clock is in.
class _Stamp {
  _Stamp(this.wall, this.zone, {required this.isDate});

  final DateTime wall;
  final _Zone zone;
  final bool isDate;
}

/// A DURATION value.
class _Length {
  _Length(this.value, {required this.nominal});

  final Duration value;

  /// Whether it counts days or weeks, which are calendar days rather than
  /// exactly 24 hours.
  final bool nominal;

  static _Length? parse(String text) {
    final m = _durationPattern.firstMatch(text.trim());
    if (m == null) return null;
    final parts = [for (var i = 2; i <= 6; i++) m[i]];
    if (parts.every((part) => part == null)) return null;
    int number(int i) => parts[i] == null ? 0 : int.parse(parts[i]!);
    final value = Duration(
      days: number(0) * 7 + number(1),
      hours: number(2),
      minutes: number(3),
      seconds: number(4),
    );
    return _Length(
      m[1] == '-' ? -value : value,
      nominal: parts[0] != null || parts[1] != null,
    );
  }
}

int? _parseOffset(String text) {
  final m = _offsetPattern.firstMatch(text.trim());
  if (m == null) return null;
  final seconds = int.parse(m[2]!) * 3600 +
      int.parse(m[3]!) * 60 +
      (m[4] == null ? 0 : int.parse(m[4]!));
  return m[1] == '-' ? -seconds : seconds;
}

/// The moment a zone's offset changes, by the clock that was in force until
/// then.
class _Onset {
  _Onset(this.at, this.offset);

  /// Wall-clock milliseconds.
  final int at;

  /// Seconds east of UTC from this moment on.
  final int offset;
}

/// A time zone: UTC, the device's own, or one defined by a VTIMEZONE.
class _Zone {
  _Zone._(this.isDevice, this._initial, this._fixed, this._open, this._to);

  _Zone.defined(
    int initial,
    List<_Onset> fixed,
    List<_Recurrence> open,
    List<int> openOffsets,
  ) : this._(false, initial, fixed, open, openOffsets);

  static final utc = _Zone._(false, 0, const [], const [], const []);

  /// The zone of floating times, and of times whose TZID the feed does not
  /// define. Its offset is unknown here: such times already are what the
  /// device's clock shows.
  static final device = _Zone._(true, 0, const [], const [], const []);

  final bool isDevice;

  /// The offset before the first change.
  final int _initial;

  /// Changes listed one by one, sorted by time.
  final List<_Onset> _fixed;

  /// Changes that recur every year without end, with the offset each one
  /// brings.
  final List<_Recurrence> _open;
  final List<int> _to;

  final Map<int, List<_Onset>> _openByYear = {};

  /// Seconds east of UTC at a wall-clock time in this zone: the offset
  /// brought by the latest change at or before it.
  ///
  /// Both sides of the comparison are wall-clock times, as VTIMEZONE states
  /// its changes that way. A time skipped when the clocks go forward thus
  /// counts as summer time, and a time repeated when they go back as its
  /// first pass.
  int offsetAt(DateTime wall) {
    final at = wall.millisecondsSinceEpoch;
    _Onset? best;
    var low = 0;
    var high = _fixed.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_fixed[middle].at <= at) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0) best = _fixed[low - 1];
    if (_open.isNotEmpty) {
      // These rules bring a change every year, so the latest one is in
      // this year or the one before.
      for (var year = wall.year; year >= wall.year - 1; year--) {
        final onsets = _openByYear[year] ??= _openOnsets(year);
        _Onset? found;
        for (var i = onsets.length - 1; i >= 0; i--) {
          if (onsets[i].at <= at) {
            found = onsets[i];
            break;
          }
        }
        if (found == null) continue;
        if (best == null || found.at >= best.at) best = found;
        break;
      }
    }
    return best?.offset ?? _initial;
  }

  List<_Onset> _openOnsets(int year) {
    final onsets = <_Onset>[];
    final first = _epochDay(year, 1, 1);
    final last = _epochDay(year, 12, 31);
    for (var i = 0; i < _open.length; i++) {
      for (final day in _open[i].between(first, last)) {
        onsets.add(_Onset(_open[i].wallMsOn(day), _to[i]));
      }
    }
    onsets.sort((a, b) => a.at.compareTo(b.at));
    return onsets;
  }

  /// The moment at which this zone's clock shows [wall]. Not for [device].
  DateTime toUtc(DateTime wall) {
    assert(!isDevice);
    return wall.subtract(Duration(seconds: offsetAt(wall)));
  }
}

enum _Freq { daily, weekly, monthly, yearly }

/// One BYDAY entry: a weekday, with an ordinal for "the n-th".
class _ByDay {
  _ByDay(this.weekday, this.ordinal);

  final int weekday;

  /// 0 for every such weekday, 2 for the second, -1 for the last.
  final int ordinal;

  /// The n-th such weekday among the [length] days from [first], if there
  /// are that many.
  int? nth(int first, int length) {
    final last = first + length - 1;
    final day = ordinal > 0
        ? first + (weekday - _weekday(first)) % 7 + 7 * (ordinal - 1)
        : last - (_weekday(last) - weekday) % 7 + 7 * (ordinal + 1);
    return day >= first && day <= last ? day : null;
  }

  void addMatches(List<int> out, int first, int length) {
    if (ordinal != 0) {
      final day = nth(first, length);
      if (day != null) out.add(day);
      return;
    }
    final end = first + length;
    for (var day = first + (weekday - _weekday(first)) % 7;
        day < end;
        day += 7) {
      out.add(day);
    }
  }

  bool matches(int day, int first, int length) =>
      _weekday(day) == weekday && (ordinal == 0 || nth(first, length) == day);
}

/// A repeat rule anchored at its first occurrence.
///
/// The rule is walked in periods (the n-th day, week, month or year after
/// the start, times INTERVAL), each of which yields the days it selects.
/// A period is found by arithmetic, so a window years after the start costs
/// no more than one next to it. Every occurrence has the start's time of day,
/// in the series' own wall-clock time.
class _Recurrence {
  _Recurrence._(
    DateTime start, {
    required this.freq,
    required this.interval,
    required this.count,
    required this.weekStart,
    required this.byDay,
    required this.byMonthDay,
    required this.byMonth,
    required this.bySetPos,
    required this._untilWall,
    required this._untilUtc,
    required this._utcOf,
  })  : _day0 = _dayOfWall(start),
        _year0 = start.year,
        _monthOfYear0 = start.month,
        _dayOfMonth0 = start.day {
    _timeOfDay = start.millisecondsSinceEpoch - _day0 * _msPerDay;
    _week0 = _day0 - (_weekday(_day0) - weekStart) % 7;
    _month0 = _year0 * 12 + _monthOfYear0 - 1;
    _lastDay = _untilWall != null
        ? _floorDiv(_untilWall, _msPerDay)
        : _untilUtc != null
            ? _floorDiv(_untilUtc, _msPerDay) + 1
            : _horizon;
  }

  /// Reads an RRULE value for a series whose first occurrence is at the
  /// wall-clock time [start]. Returns null for a rule this reader does not
  /// expand; the caller then shows the first occurrence alone.
  ///
  /// An UNTIL in UTC is compared with occurrences through [utcOf]. A series
  /// whose zone has no known offset (all-day, floating) passes null and
  /// gets such an UNTIL turned into its own wall-clock time by [wallOfUtc].
  static _Recurrence? parse(
    String text, {
    required DateTime start,
    required DateTime Function(DateTime wall)? utcOf,
    required DateTime Function(DateTime utc) wallOfUtc,
  }) {
    _Freq? freq;
    var interval = 1;
    int? count;
    _Value? until;
    var weekStart = DateTime.monday;
    var byDay = <_ByDay>[];
    var byMonthDay = <int>[];
    var byMonth = <int>[];
    var bySetPos = <int>[];
    for (final part in text.split(';')) {
      if (part.trim().isEmpty) continue;
      final equals = part.indexOf('=');
      if (equals < 0) return null;
      final key = part.substring(0, equals).trim().toUpperCase();
      final value = part.substring(equals + 1).trim().toUpperCase();
      switch (key) {
        case 'FREQ':
          freq = const {
            'DAILY': _Freq.daily,
            'WEEKLY': _Freq.weekly,
            'MONTHLY': _Freq.monthly,
            'YEARLY': _Freq.yearly,
          }[value];
          // SECONDLY, MINUTELY and HOURLY are not for a day planner.
          if (freq == null) return null;
        case 'INTERVAL':
          final n = int.tryParse(value);
          if (n == null || n < 1 || n > _maxInterval) return null;
          interval = n;
        case 'COUNT':
          final n = int.tryParse(value);
          if (n == null || n < 1) return null;
          count = n;
        case 'UNTIL':
          until = _Value.parse(value);
          if (until == null) return null;
        case 'WKST':
          final weekday = _weekdayCodes[value];
          if (weekday == null) return null;
          weekStart = weekday;
        case 'BYDAY':
          byDay = [];
          for (final item in value.split(',')) {
            final m = _byDayPattern.firstMatch(item.trim());
            if (m == null) return null;
            final ordinal = m[1] == null ? 0 : int.parse(m[1]!);
            if (m[1] != null && ordinal == 0) return null;
            byDay.add(_ByDay(_weekdayCodes[m[2]]!, ordinal));
          }
        case 'BYMONTHDAY':
          final days = _numbers(value, 31, signed: true);
          if (days == null) return null;
          byMonthDay = days;
        case 'BYMONTH':
          final months = _numbers(value, 12, signed: false);
          if (months == null) return null;
          byMonth = months;
        case 'BYSETPOS':
          final positions = _numbers(value, 366, signed: true);
          if (positions == null) return null;
          bySetPos = positions;
        default:
          // BYHOUR, BYMINUTE, BYSECOND, BYWEEKNO, BYYEARDAY, RSCALE and
          // whatever comes later change which days a rule means. Guessing
          // would show events on wrong days, so the rule is given up.
          if (!key.startsWith('X-')) return null;
      }
    }
    if (freq == null) return null;
    int? untilWall;
    int? untilUtc;
    if (until != null) {
      if (until.isDate) {
        // Inclusive: through the end of that day.
        untilWall = until.wall.millisecondsSinceEpoch + _msPerDay - 1;
      } else if (!until.isUtc) {
        untilWall = until.wall.millisecondsSinceEpoch;
      } else if (utcOf != null) {
        untilUtc = until.wall.millisecondsSinceEpoch;
      } else {
        untilWall = wallOfUtc(until.wall).millisecondsSinceEpoch;
      }
    }
    return _Recurrence._(
      start,
      freq: freq,
      interval: interval,
      count: count,
      weekStart: weekStart,
      byDay: byDay,
      byMonthDay: byMonthDay,
      byMonth: byMonth,
      bySetPos: bySetPos,
      untilWall: untilWall,
      untilUtc: untilUtc,
      utcOf: utcOf,
    );
  }

  static List<int>? _numbers(String text, int max, {required bool signed}) {
    final out = <int>[];
    for (final item in text.split(',')) {
      final n = int.tryParse(item.trim());
      if (n == null || n == 0 || n > max || n < (signed ? -max : 1)) {
        return null;
      }
      out.add(n);
    }
    return out;
  }

  final _Freq freq;
  final int interval;
  final int? count;
  final int weekStart;
  final List<_ByDay> byDay;
  final List<int> byMonthDay;
  final List<int> byMonth;
  final List<int> bySetPos;

  /// The last moment an occurrence may start at, inclusive, either as a
  /// wall-clock time or as a UTC moment (milliseconds); at most one is set.
  final int? _untilWall;
  final int? _untilUtc;
  final DateTime Function(DateTime wall)? _utcOf;

  /// The first occurrence: its day, and the parts the periods count from.
  final int _day0;
  final int _year0;
  final int _monthOfYear0;
  final int _dayOfMonth0;
  late final int _timeOfDay;
  late final int _week0;
  late final int _month0;

  /// No occurrence starts after this day.
  late final int _lastDay;

  /// Every occurrence of a rule with COUNT, worked out on first use.
  List<int>? _counted;

  /// Whether the rule selects days of every year, for ever.
  bool get isYearlyForEver =>
      freq == _Freq.yearly &&
      interval == 1 &&
      count == null &&
      _untilWall == null &&
      _untilUtc == null;

  int get firstDay => _day0;

  int wallMsOn(int day) => day * _msPerDay + _timeOfDay;

  DateTime wallOn(int day) =>
      DateTime.fromMillisecondsSinceEpoch(wallMsOn(day), isUtc: true);

  /// The days in [from]..[to] on which an occurrence starts, ascending.
  ///
  /// The first occurrence is always one of them, whether or not it fits the
  /// rule: that is what calendar applications show.
  List<int> between(int from, int to) {
    if (to > _horizon) to = _horizon;
    if (to < _day0 || to < from) return const [];
    if (count != null) {
      // COUNT can only be honoured by counting from the start. That is done
      // once, after which a query is a search in the list.
      final all = _counted ??= _countOut();
      final out = <int>[];
      for (var i = _firstAtLeast(all, from);
          i < all.length && all[i] <= to;
          i++) {
        out.add(all[i]);
      }
      return out;
    }
    final out = <int>[];
    if (_day0 >= from) out.add(_day0);
    if (from > _lastDay) return out;
    var period = _periodHolding(from);
    for (var steps = 0; steps < _maxSteps; steps++, period++) {
      if (_periodStart(period) > to) break;
      for (final day in _candidates(period)) {
        if (day <= _day0 || day < from) continue;
        if (day > to || !_withinUntil(day)) return out;
        out.add(day);
      }
    }
    return out;
  }

  List<int> _countOut() {
    final out = <int>[_day0];
    for (var period = 0;
        period < _maxCountSteps && out.length < count!;
        period++) {
      if (_periodStart(period) > _horizon) break;
      for (final day in _candidates(period)) {
        if (day <= _day0) continue;
        if (!_withinUntil(day)) return out;
        out.add(day);
        if (out.length >= count!) break;
      }
    }
    return out;
  }

  bool _withinUntil(int day) {
    final wall = wallMsOn(day);
    if (_untilWall != null) return wall <= _untilWall;
    if (_untilUtc == null) return true;
    // No zone is further than a day from UTC, so only occurrences next to
    // the limit need their offset looked up.
    if (wall + _msPerDay <= _untilUtc) return true;
    if (wall - _msPerDay > _untilUtc) return false;
    return _utcOf!(wallOn(day)).millisecondsSinceEpoch <= _untilUtc;
  }

  /// The period [day] lies in, or the first one if it is before the start.
  int _periodHolding(int day) {
    if (day <= _day0) return 0;
    switch (freq) {
      case _Freq.daily:
        return (day - _day0) ~/ interval;
      case _Freq.weekly:
        return (day - _week0) ~/ (7 * interval);
      case _Freq.monthly:
        final date = _dateOf(day);
        return (date.year * 12 + date.month - 1 - _month0) ~/ interval;
      case _Freq.yearly:
        return (_dateOf(day).year - _year0) ~/ interval;
    }
  }

  int _periodStart(int period) {
    switch (freq) {
      case _Freq.daily:
        return _day0 + period * interval;
      case _Freq.weekly:
        return _week0 + 7 * period * interval;
      case _Freq.monthly:
        final month = _month0 + period * interval;
        return _epochDay(month ~/ 12, month % 12 + 1, 1);
      case _Freq.yearly:
        return _epochDay(_year0 + period * interval, 1, 1);
    }
  }

  /// The days one period selects, ascending. Days before the start are
  /// included; BYSETPOS counts them.
  List<int> _candidates(int period) {
    final days = <int>[];
    switch (freq) {
      case _Freq.daily:
        final day = _day0 + period * interval;
        if (_allows(day, checkWeekday: true)) days.add(day);
      case _Freq.weekly:
        final week = _week0 + 7 * period * interval;
        if (byDay.isEmpty) {
          final day = week + (_weekday(_day0) - weekStart) % 7;
          if (_allows(day, checkWeekday: false)) days.add(day);
        } else {
          for (final entry in byDay) {
            final day = week + (entry.weekday - weekStart) % 7;
            if (_allows(day, checkWeekday: false)) days.add(day);
          }
        }
      case _Freq.monthly:
        final index = _month0 + period * interval;
        final month = index % 12 + 1;
        if (byMonth.isEmpty || byMonth.contains(month)) {
          _addMonth(days, index ~/ 12, month);
        }
      case _Freq.yearly:
        final year = _year0 + period * interval;
        if (byMonth.isNotEmpty) {
          for (final month in byMonth) {
            _addMonth(days, year, month);
          }
        } else if (byMonthDay.isNotEmpty) {
          // Day numbers without a month mean those days of every month.
          for (var month = 1; month <= 12; month++) {
            _addMonth(days, year, month);
          }
        } else if (byDay.isNotEmpty) {
          // Without a month, "20MO" counts Mondays of the year.
          final first = _epochDay(year, 1, 1);
          final length = _epochDay(year + 1, 1, 1) - first;
          for (final entry in byDay) {
            entry.addMatches(days, first, length);
          }
        } else if (_dayOfMonth0 <= Day.daysInMonth(year, _monthOfYear0)) {
          // 29 February exists in leap years only; other years are skipped.
          days.add(_epochDay(year, _monthOfYear0, _dayOfMonth0));
        }
    }
    if (days.length > 1) {
      days.sort();
      var kept = 1;
      for (var i = 1; i < days.length; i++) {
        if (days[i] != days[kept - 1]) days[kept++] = days[i];
      }
      days.length = kept;
    }
    if (bySetPos.isEmpty) return days;
    final picked = <int>{};
    for (final position in bySetPos) {
      final i = position > 0 ? position - 1 : days.length + position;
      if (i >= 0 && i < days.length) picked.add(days[i]);
    }
    return picked.toList()..sort();
  }

  /// The days of one month that BYMONTHDAY and BYDAY select; without
  /// either, the start's day of the month, if this month has it.
  void _addMonth(List<int> out, int year, int month) {
    final first = _epochDay(year, month, 1);
    final length = Day.daysInMonth(year, month);
    if (byMonthDay.isNotEmpty) {
      for (final number in byMonthDay) {
        final dayOfMonth = number > 0 ? number : length + number + 1;
        if (dayOfMonth < 1 || dayOfMonth > length) continue;
        final day = first + dayOfMonth - 1;
        // Given both, BYDAY narrows the numbered days down.
        if (byDay.isEmpty ||
            byDay.any((entry) => entry.matches(day, first, length))) {
          out.add(day);
        }
      }
    } else if (byDay.isNotEmpty) {
      for (final entry in byDay) {
        entry.addMatches(out, first, length);
      }
    } else if (_dayOfMonth0 <= length) {
      out.add(first + _dayOfMonth0 - 1);
    }
  }

  /// Whether the BY parts that only narrow a daily or weekly rule let
  /// [day] through.
  bool _allows(int day, {required bool checkWeekday}) {
    if (checkWeekday && byDay.isNotEmpty) {
      final weekday = _weekday(day);
      if (!byDay.any((entry) => entry.weekday == weekday)) return false;
    }
    if (byMonth.isEmpty && byMonthDay.isEmpty) return true;
    final date = _dateOf(day);
    if (byMonth.isNotEmpty && !byMonth.contains(date.month)) return false;
    if (byMonthDay.isEmpty) return true;
    final length = Day.daysInMonth(date.year, date.month);
    return byMonthDay.any(
      (number) => (number > 0 ? number : length + number + 1) == date.day,
    );
  }
}

/// What all occurrences of one VEVENT share.
class _Event {
  _Event({
    required this.uid,
    required this.title,
    required this.location,
    required this.description,
    required this.allDay,
    required this.zone,
    required this.days,
    required this.span,
    required this.exactSpan,
  });

  final String uid;
  final String title;
  final String location;
  final String description;
  final bool allDay;

  /// The zone DTSTART is written in; [_Zone.device] for an all-day event,
  /// whose dates are the same everywhere.
  final _Zone zone;

  /// All-day: how many days an occurrence covers.
  final int days;

  /// Timed: how long an occurrence lasts.
  ///
  /// Normally the difference between the clock times of start and end in
  /// the event's zone. That keeps the end of a repeating event at the same
  /// clock time when a daylight-saving change falls inside an occurrence,
  /// and for a single event it is DTEND itself. With [exactSpan] it is
  /// elapsed time instead: when the end is given in another zone than the
  /// start, or as a DURATION in hours, minutes and seconds.
  final Duration span;
  final bool exactSpan;

  /// What titles are sorted by first, so that case does not decide.
  late final String titleKey = title.toLowerCase();

  /// How many days before a window an occurrence can start and still reach
  /// into it.
  int get reach => allDay ? days : span.inDays + 1;

  /// A number that is the same for two ways of writing one occurrence's
  /// start: the day for an all-day event, else the UTC moment, or the
  /// device's clock time for a floating event (which has no UTC moment).
  /// This is what EXDATE, RDATE and RECURRENCE-ID are matched by, since
  /// feeds freely mix `…Z` and `TZID=` forms.
  int keyOf(DateTime wall, _Zone zone, _Device device) {
    if (allDay) return _dayOfWall(wall);
    if (this.zone.isDevice) {
      final local = zone.isDevice ? wall : device.wall(zone.toUtc(wall));
      return local.millisecondsSinceEpoch;
    }
    // A floating value in a series with a zone is read in that zone.
    final known = zone.isDevice ? this.zone : zone;
    return known.toUtc(wall).millisecondsSinceEpoch;
  }

  /// [keyOf] as text, marked with what kind of number it is.
  String instanceOf(DateTime wall, _Zone zone, _Device device) =>
      '${allDay ? 'D' : this.zone.isDevice ? 'L' : 'U'}${keyOf(wall, zone, device)}';

  /// The occurrence starting at [wall] in [zone], in the device's time.
  /// With [keyed] it is one of several occurrences and carries its key.
  _Placed at(DateTime wall, _Zone zone, _Device device, {bool keyed = false}) {
    final instance = keyed ? instanceOf(wall, zone, device) : '';
    if (allDay) {
      final first = _dayOfWall(wall);
      return _Placed(this, first, first + days - 1, null, null, first, instance);
    }
    DateTime startWall;
    DateTime endWall;
    DateTime start;
    DateTime end;
    if (zone.isDevice) {
      startWall = wall;
      endWall = wall.add(span);
      start = device.shown(startWall);
      end = device.shown(endWall);
    } else {
      final startUtc = zone.toUtc(wall);
      var endUtc = exactSpan ? startUtc.add(span) : zone.toUtc(wall.add(span));
      // Possible only around a clock change; an end before its start would
      // be nonsense further on.
      if (endUtc.isBefore(startUtc)) endUtc = startUtc;
      (startWall, start) = device.at(startUtc);
      (endWall, end) = device.at(endUtc);
    }
    final first = _dayOfWall(startWall);
    var last = _dayOfWall(endWall);
    // An event ending at midnight does not touch the day that begins then.
    if (endWall.isAfter(startWall) &&
        endWall.millisecondsSinceEpoch % _msPerDay == 0) {
      last--;
    }
    if (last < first) last = first;
    return _Placed(
      this,
      first,
      last,
      start,
      end,
      startWall.millisecondsSinceEpoch,
      instance,
    );
  }
}

/// One occurrence, placed on the device's days.
class _Placed {
  _Placed(
    this.event,
    this.firstDay,
    this.lastDay,
    this.start,
    this.end,
    this.order, [
    this.instance = '',
  ]);

  /// See [EventOccurrence.instance].
  final String instance;

  /// This occurrence under another key.
  _Placed keyed(String instance) =>
      _Placed(event, firstDay, lastDay, start, end, order, instance);

  final _Event event;
  final int firstDay;
  final int lastDay;
  final DateTime? start;
  final DateTime? end;

  /// What a day's entries are sorted by: the start as clock fields in
  /// milliseconds, or the first day of an all-day occurrence. Clock fields
  /// rather than the moment, so that the repeated hour at the end of
  /// summer time cannot reorder a day.
  final int order;

  /// Adds an entry for each of this occurrence's days within [from]..[to].
  void addTo(List<_Entry> out, int from, int to) {
    final a = firstDay > from ? firstDay : from;
    final b = lastDay < to ? lastDay : to;
    for (var day = a; day <= b; day++) {
      out.add(_Entry(day, this));
    }
  }

  /// This occurrence as shown on [day]. [days] saves building the same
  /// [Day] for every entry of a query.
  EventOccurrence on(int day, Map<int, Day> days) => EventOccurrence(
        uid: event.uid,
        title: event.title,
        day: days[day] ??= _toDay(day),
        allDay: event.allDay,
        start: start,
        end: end,
        firstDay: days[firstDay] ??= _toDay(firstDay),
        lastDay: days[lastDay] ??= _toDay(lastDay),
        location: event.location,
        description: event.description,
        instance: instance,
      );
}

/// One day of one occurrence, before it is sorted and handed out.
class _Entry {
  _Entry(this.day, this.placed);

  final int day;
  final _Placed placed;
}

/// A repeating event: its rule, and the occurrences taken out of it.
class _Series {
  _Series(
    this.event,
    this.rule,
    this.device,
    this.removedKeys,
    this.removedDays,
    this.addedKeys,
  );

  final _Event event;
  final _Recurrence rule;
  final _Device device;

  /// Occurrences removed by EXDATE or replaced by a changed instance, by
  /// [_Event.keyOf], and whole days removed by an EXDATE written as a date.
  final Set<int> removedKeys;
  final Set<int> removedDays;

  /// Occurrences that RDATE names as well; those are placed already.
  final Set<int> addedKeys;

  void addTo(List<_Entry> out, int from, int to) {
    final slack = event.allDay ? 0 : _zoneSlack;
    // Most series have nothing taken out, and need no keys worked out.
    final plain = removedKeys.isEmpty && addedKeys.isEmpty;
    try {
      final days = rule.between(from - slack - event.reach, to + slack);
      for (final day in days) {
        if (removedDays.contains(day)) continue;
        final wall = rule.wallOn(day);
        if (!plain) {
          final key = event.keyOf(wall, event.zone, device);
          if (removedKeys.contains(key) || addedKeys.contains(key)) continue;
        }
        event.at(wall, event.zone, device, keyed: true).addTo(out, from, to);
      }
    } catch (_) {
      // A feed is outside input. Dates beyond what DateTime can hold fail
      // deep inside the arithmetic; such a series shows what it could.
    }
  }
}

/// A VEVENT as read, before series and their changed instances are joined.
class _Draft {
  _Draft({
    required this.event,
    required this.start,
    required this.first,
    required this.cancelled,
    required this.rule,
    required this.exdates,
    required this.rdates,
    required this.recurrenceId,
    required this.sequence,
  });

  final _Event event;
  final _Stamp start;

  /// The occurrence at DTSTART.
  final _Placed first;

  final bool cancelled;
  final String? rule;
  final List<_Stamp> exdates;
  final List<_Stamp> rdates;
  final _Stamp? recurrenceId;
  final int sequence;

  /// The RECURRENCE-IDs of this series' changed instances.
  final List<_Stamp> replaced = [];
}

class _RawZone {
  String? id;
  final List<List<_Prop>> observances = [];
}

class _Reader {
  _Reader(this.device);

  final _Device device;
  final Map<String, _Zone> zones = {};
  final List<_Placed> fixed = [];
  final List<_Series> series = [];
  int eventCount = 0;
  int skipped = 0;

  IcsCalendar read(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    // Pass one: sort the lines into components. Zones are built before any
    // event, since a feed may define a zone after the events that use it.
    final stack = <String>[];
    final events = <List<_Prop>>[];
    final rawZones = <_RawZone>[];
    String? name;
    var isCalendar = false;
    List<_Prop>? event;
    _RawZone? zone;
    List<_Prop>? observance;
    for (final line in _unfold(text)) {
      final prop = _Prop.parse(line);
      if (prop == null) continue;
      if (prop.name == 'BEGIN') {
        final kind = prop.value.trim().toUpperCase();
        final parent = stack.isEmpty ? '' : stack.last;
        stack.add(kind);
        switch (kind) {
          case 'VCALENDAR':
            isCalendar = true;
          case 'VEVENT':
            // The event before never ended; it cannot be trusted.
            if (event != null) skipped++;
            event = [];
          case 'VTIMEZONE':
            zone = _RawZone();
          case 'STANDARD' || 'DAYLIGHT':
            if (parent == 'VTIMEZONE' && zone != null) observance = [];
        }
        continue;
      }
      if (prop.name == 'END') {
        final kind = prop.value.trim().toUpperCase();
        final depth = stack.lastIndexOf(kind);
        if (depth < 0) continue;
        stack.length = depth;
        switch (kind) {
          case 'VEVENT':
            if (event != null) events.add(event);
            event = null;
          case 'VTIMEZONE':
            if (zone != null) rawZones.add(zone);
            zone = null;
            observance = null;
          case 'STANDARD' || 'DAYLIGHT':
            if (zone != null && observance != null) {
              zone.observances.add(observance);
            }
            observance = null;
        }
        continue;
      }
      if (stack.isEmpty) continue;
      // Only the properties directly inside a component are its own; those
      // of a VALARM inside a VEVENT (which has a DESCRIPTION and often a
      // DURATION too) fall through here.
      switch (stack.last) {
        case 'VEVENT':
          event?.add(prop);
        case 'VTIMEZONE':
          if (prop.name == 'TZID') zone?.id = prop.value.trim();
        case 'STANDARD' || 'DAYLIGHT':
          observance?.add(prop);
        case 'VCALENDAR':
          if (prop.name == 'X-WR-CALNAME' && name == null) {
            final value = _unescape(prop.value).trim();
            if (value.isNotEmpty) name = value;
          }
      }
    }
    if (!isCalendar) throw const FormatException('Not an iCalendar file');
    // A download cut off inside an event.
    if (event != null) skipped++;

    for (final raw in rawZones) {
      final id = raw.id;
      if (id == null || id.isEmpty || zones.containsKey(id)) continue;
      final built = _buildZone(raw);
      if (built != null) zones[id] = built;
    }

    // Pass two: read the events, then join each series with the instances
    // that were changed, which are VEVENTs of their own with the same UID.
    final masters = <_Draft>[];
    final changed = <String, _Draft>{};
    for (final props in events) {
      final _Draft draft;
      try {
        draft = _draft(props);
      } catch (_) {
        // Deliberately everything: a feed is outside input, and one event
        // that cannot be read must not cost the user all the others.
        skipped++;
        continue;
      }
      final id = draft.recurrenceId;
      if (id == null || draft.event.uid.isEmpty) {
        masters.add(draft);
        continue;
      }
      // A feed may carry several versions of one changed instance; the
      // latest wins.
      final key = '${draft.event.uid}\n${_instanceName(id)}';
      final known = changed[key];
      if (known == null || draft.sequence >= known.sequence) {
        changed[key] = draft;
      }
    }
    final byUid = <String, List<_Draft>>{};
    for (final master in masters) {
      if (master.event.uid.isEmpty) continue;
      (byUid[master.event.uid] ??= []).add(master);
    }
    for (final change in changed.values) {
      final owners = byUid[change.event.uid];
      if (owners != null) {
        for (final owner in owners) {
          owner.replaced.add(change.recurrenceId!);
        }
      }
      // A cancelled instance only takes its original out of the series.
      if (change.cancelled) continue;
      // It answers to the key of the occurrence it replaces, worked out
      // the way its series would, so that the two always agree.
      final id = change.recurrenceId!;
      final owner = owners == null ? change : owners.first;
      var wall = id.wall;
      var zone = id.zone;
      if (id.isDate && !owner.event.allDay) {
        // A bare date naming an occurrence of a timed series: that day, at
        // the series' usual time.
        final start = owner.start;
        wall = wall.add(start.wall.difference(_dateOf(_dayOfWall(start.wall))));
        zone = start.zone;
      }
      fixed.add(change.first.keyed(owner.event.instanceOf(wall, zone, device)));
      // Without its series in the feed it stands as an event of its own.
      if (owners == null) eventCount++;
    }
    for (final master in masters) {
      if (master.cancelled) continue;
      try {
        _addMaster(master);
        eventCount++;
      } catch (_) {
        skipped++;
      }
    }

    fixed.sort((a, b) => a.firstDay.compareTo(b.firstDay));
    final short = <_Placed>[];
    final long = <_Placed>[];
    var reach = 0;
    for (final placed in fixed) {
      final span = placed.lastDay - placed.firstDay;
      if (span > _longSpan) {
        long.add(placed);
      } else {
        short.add(placed);
        if (span > reach) reach = span;
      }
    }
    return IcsCalendar._(
      name,
      eventCount,
      skipped,
      short,
      long,
      reach,
      series,
    );
  }

  String _instanceName(_Stamp id) {
    if (id.isDate) return 'D${_dayOfWall(id.wall)}';
    if (id.zone.isDevice) return 'L${id.wall.millisecondsSinceEpoch}';
    return 'U${id.zone.toUtc(id.wall).millisecondsSinceEpoch}';
  }

  _Zone _zoneOf(Map<String, String> params) {
    final id = params['TZID'];
    if (id == null) return _Zone.device;
    final defined = zones[id];
    if (defined != null) return defined;
    return _utcNames.contains(id.toUpperCase()) ? _Zone.utc : _Zone.device;
  }

  _Stamp? _stamp(String text, Map<String, String> params) {
    final value = _Value.parse(text);
    if (value == null) return null;
    if (value.isDate || params['VALUE']?.toUpperCase() == 'DATE') {
      final wall = value.wall;
      return _Stamp(
        DateTime.utc(wall.year, wall.month, wall.day),
        _Zone.device,
        isDate: true,
      );
    }
    return _Stamp(
      value.wall,
      value.isUtc ? _Zone.utc : _zoneOf(params),
      isDate: false,
    );
  }

  /// The values of a property that lists several, such as EXDATE.
  void _stamps(_Prop prop, List<_Stamp> out) {
    for (final item in prop.value.split(',')) {
      // RDATE may give periods (`start/end`); those are not read.
      if (item.contains('/')) continue;
      final stamp = _stamp(item, prop.params);
      if (stamp != null) out.add(stamp);
    }
  }

  _Zone? _buildZone(_RawZone raw) {
    final fixed = <_Onset>[];
    final open = <_Recurrence>[];
    final openOffsets = <int>[];
    DateTime? earliest;
    var initial = 0;
    for (final props in raw.observances) {
      _Value? start;
      int? from;
      int? to;
      String? ruleText;
      final extra = <_Value>[];
      for (final prop in props) {
        switch (prop.name) {
          case 'DTSTART':
            start = _Value.parse(prop.value);
          case 'TZOFFSETFROM':
            from = _parseOffset(prop.value);
          case 'TZOFFSETTO':
            to = _parseOffset(prop.value);
          case 'RRULE':
            ruleText ??= prop.value;
          case 'RDATE':
            for (final item in prop.value.split(',')) {
              final value = _Value.parse(item);
              if (value != null) extra.add(value);
            }
        }
      }
      if (start == null || from == null || to == null) continue;
      final offsetFrom = from;
      final offsetTo = to;
      if (earliest == null || start.wall.isBefore(earliest)) {
        earliest = start.wall;
        initial = offsetFrom;
      }
      for (final value in extra) {
        fixed.add(_Onset(value.wall.millisecondsSinceEpoch, offsetTo));
      }
      final rule = ruleText == null
          ? null
          : _Recurrence.parse(
              ruleText,
              start: start.wall,
              // A change is stated by the clock in force until it happens.
              utcOf: (wall) => wall.subtract(Duration(seconds: offsetFrom)),
              wallOfUtc: (utc) => utc,
            );
      if (rule == null) {
        fixed.add(_Onset(start.wall.millisecondsSinceEpoch, offsetTo));
      } else if (rule.isYearlyForEver) {
        open.add(rule);
        openOffsets.add(offsetTo);
      } else {
        // A rule that ended (the zone's law changed) is written out, and
        // so is any that is not simply yearly.
        for (final day in rule.between(rule.firstDay, _horizon)) {
          fixed.add(_Onset(rule.wallMsOn(day), offsetTo));
        }
      }
    }
    if (earliest == null) return null;
    fixed.sort((a, b) => a.at.compareTo(b.at));
    return _Zone.defined(initial, fixed, open, openOffsets);
  }

  /// Reads one VEVENT. Throws when it has no usable start.
  _Draft _draft(List<_Prop> props) {
    var uid = '';
    var title = '';
    var location = '';
    var description = '';
    var cancelled = false;
    var sequence = 0;
    _Prop? startProp;
    _Prop? endProp;
    _Prop? lengthProp;
    _Prop? idProp;
    String? rule;
    final exdates = <_Stamp>[];
    final rdates = <_Stamp>[];
    for (final prop in props) {
      switch (prop.name) {
        case 'UID':
          uid = prop.value.trim();
        case 'SUMMARY':
          title = _unescape(prop.value);
        case 'LOCATION':
          location = _unescape(prop.value);
        case 'DESCRIPTION':
          description = _unescape(prop.value);
        case 'STATUS':
          cancelled = prop.value.trim().toUpperCase() == 'CANCELLED';
        case 'SEQUENCE':
          sequence = int.tryParse(prop.value.trim()) ?? 0;
        case 'DTSTART':
          startProp ??= prop;
        case 'DTEND':
          endProp ??= prop;
        case 'DURATION':
          lengthProp ??= prop;
        case 'RECURRENCE-ID':
          idProp ??= prop;
        case 'RRULE':
          rule ??= prop.value;
        case 'EXDATE':
          _stamps(prop, exdates);
        case 'RDATE':
          _stamps(prop, rdates);
      }
    }
    if (startProp == null) throw const FormatException('No DTSTART');
    final start = _stamp(startProp.value, startProp.params);
    if (start == null) throw const FormatException('Unreadable DTSTART');
    // A broken end is no reason to hide an event whose start is known.
    final end = endProp == null ? null : _stamp(endProp.value, endProp.params);
    final length = lengthProp == null ? null : _Length.parse(lengthProp.value);

    var days = 1;
    var span = Duration.zero;
    var exactSpan = false;
    if (start.isDate) {
      // DTEND of an all-day event is the day after its last day.
      if (end != null) {
        days = _dayOfWall(end.wall) - _dayOfWall(start.wall);
      } else if (length != null) {
        days = (length.value.inSeconds / Duration.secondsPerDay).ceil();
      }
      if (days < 1) days = 1;
    } else if (end != null) {
      final from = start.zone;
      final to = end.isDate ? from : end.zone;
      if (identical(from, to) || to.isDevice) {
        span = end.wall.difference(start.wall);
      } else if (from.isDevice) {
        span = device.wall(to.toUtc(end.wall)).difference(start.wall);
      } else {
        span = to.toUtc(end.wall).difference(from.toUtc(start.wall));
        exactSpan = true;
      }
    } else if (length != null) {
      span = length.value;
      exactSpan = !length.nominal && !start.zone.isDevice;
    }
    if (span.isNegative) span = Duration.zero;

    final event = _Event(
      uid: uid,
      title: title,
      location: location,
      description: description,
      allDay: start.isDate,
      zone: start.zone,
      days: days,
      span: span,
      exactSpan: exactSpan,
    );
    return _Draft(
      event: event,
      start: start,
      // Placing it here also proves that the event's times can be worked
      // with; one that cannot is dropped while reading, not while drawing.
      first: event.at(start.wall, start.zone, device),
      cancelled: cancelled,
      rule: rule,
      exdates: exdates,
      rdates: rdates,
      recurrenceId:
          idProp == null ? null : _stamp(idProp.value, idProp.params),
      sequence: sequence,
    );
  }

  void _addMaster(_Draft master) {
    final event = master.event;
    final start = master.start;
    final removedKeys = <int>{};
    final removedDays = <int>{};
    for (final stamp in [...master.exdates, ...master.replaced]) {
      if (stamp.isDate && !event.allDay) {
        removedDays.add(_dayOfWall(stamp.wall));
      } else {
        removedKeys.add(event.keyOf(stamp.wall, stamp.zone, device));
      }
    }
    bool removed(DateTime wall, _Zone zone) =>
        removedDays.contains(_dayOfWall(wall)) ||
        removedKeys.contains(event.keyOf(wall, zone, device));

    final placed = <_Placed>[];
    final addedKeys = <int>{};
    final startKey = event.keyOf(start.wall, start.zone, device);
    for (final stamp in master.rdates) {
      var wall = stamp.wall;
      var zone = stamp.zone;
      if (stamp.isDate && !event.allDay) {
        // A bare date added to a timed series: that day, at the usual time.
        final time = start.wall.difference(_dateOf(_dayOfWall(start.wall)));
        wall = wall.add(time);
        zone = start.zone;
      }
      final key = event.keyOf(wall, zone, device);
      if (key == startKey || !addedKeys.add(key)) continue;
      if (!removed(wall, zone)) {
        placed.add(event.at(wall, zone, device, keyed: true));
      }
    }

    final rule = master.rule == null
        ? null
        : _Recurrence.parse(
            master.rule!,
            start: start.wall,
            utcOf: event.allDay || event.zone.isDevice
                ? null
                : event.zone.toUtc,
            wallOfUtc: event.allDay ? (utc) => utc : device.wall,
          );
    if (rule != null) {
      series.add(_Series(
        event,
        rule,
        device,
        removedKeys,
        removedDays,
        addedKeys,
      ));
    } else if (!removed(start.wall, start.zone)) {
      // No rule, or one that is not understood: the first occurrence. With
      // added dates beside it, it is one of several and needs its key.
      placed.add(addedKeys.isEmpty
          ? master.first
          : event.at(start.wall, start.zone, device, keyed: true));
    }
    fixed.addAll(placed);
  }
}
