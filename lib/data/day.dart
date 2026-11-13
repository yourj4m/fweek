/// A calendar date without a time or time zone.
///
/// Backed by a UTC midnight so that arithmetic never crosses a daylight-saving
/// boundary. Serialised as `YYYY-MM-DD`.
class Day implements Comparable<Day> {
  Day(int year, int month, int day) : _utc = DateTime.utc(year, month, day);

  Day._(this._utc);

  factory Day.fromDateTime(DateTime local) =>
      Day(local.year, local.month, local.day);

  factory Day.today() => Day.fromDateTime(DateTime.now());

  /// Parses `YYYY-MM-DD`. Throws [FormatException] on anything else.
  factory Day.parse(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
    if (m == null) throw FormatException('Not a date: $iso');
    return Day(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static Day? tryParse(String? iso) {
    if (iso == null) return null;
    try {
      return Day.parse(iso);
    } on FormatException {
      return null;
    }
  }

  final DateTime _utc;

  int get year => _utc.year;
  int get month => _utc.month;
  int get day => _utc.day;

  /// Monday = 1 … Sunday = 7.
  int get weekday => _utc.weekday;

  String get iso =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  Day addDays(int n) => Day._(_utc.add(Duration(days: n)));

  /// Adds calendar months, clamping the day to the target month's length
  /// (31 Jan + 1 month = 28 or 29 Feb).
  Day addMonths(int n) {
    final total = year * 12 + (month - 1) + n;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final last = daysInMonth(y, m);
    return Day(y, m, day > last ? last : day);
  }

  int difference(Day other) => _utc.difference(other._utc).inDays;

  /// The first day of the week containing this day, for a week starting on
  /// [weekStart] (Monday = 1 … Sunday = 7).
  Day startOfWeek([int weekStart = DateTime.monday]) =>
      addDays(-((weekday - weekStart) % 7));

  Day get startOfMonth => Day(year, month, 1);

  /// ISO 8601 week number (weeks start on Monday; week 1 holds 4 January).
  int get isoWeek {
    final thursday = addDays(4 - weekday);
    final jan1 = Day(thursday.year, 1, 1);
    return thursday.difference(jan1) ~/ 7 + 1;
  }

  /// This date at local midnight.
  DateTime toLocal() => DateTime(year, month, day);

  static int daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  bool operator <(Day other) => _utc.isBefore(other._utc);
  bool operator >(Day other) => _utc.isAfter(other._utc);
  bool operator <=(Day other) => !(this > other);
  bool operator >=(Day other) => !(this < other);

  @override
  int compareTo(Day other) => _utc.compareTo(other._utc);

  @override
  bool operator ==(Object other) => other is Day && other._utc == _utc;

  @override
  int get hashCode => _utc.hashCode;

  @override
  String toString() => iso;
}
