import '../data/day.dart';
import '../data/recurrence.dart';

/// Names and phrases. English only for now; kept in one place so that
/// translations can replace this file's contents later.
abstract final class Strings {
  static const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];
  static const monthsShort = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];

  /// Indexed by `weekday - 1` (Monday first).
  static const weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', //
  ];
  static const weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const weekdaysInitial = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const ordinals = ['first', 'second', 'third', 'fourth', 'fifth'];

  static String month(Day d) => months[d.month - 1];
  static String monthShort(Day d) => monthsShort[d.month - 1];
  static String weekday(Day d) => weekdays[d.weekday - 1];
  static String weekdayShort(Day d) => weekdaysShort[d.weekday - 1];

  /// `9 Nov`
  static String dayMonth(Day d) => '${d.day} ${monthShort(d)}';

  /// `Sat, 14 Nov 2026`
  static String fullDate(Day d) =>
      '${weekdayShort(d)}, ${d.day} ${monthShort(d)} ${d.year}';

  /// A day as a short mark beside a task, seen from [today]: `Today`,
  /// `Tomorrow`, `Yesterday`, `Wed 25` within the coming week, `25 Nov`
  /// otherwise (with the year when it is another one).
  static String near(Day d, Day today) {
    final ahead = d.difference(today);
    if (ahead == 0) return 'Today';
    if (ahead == 1) return 'Tomorrow';
    if (ahead == -1) return 'Yesterday';
    if (ahead > 1 && ahead < 7) return '${weekdayShort(d)} ${d.day}';
    return d.year == today.year ? dayMonth(d) : '${dayMonth(d)} ${d.year}';
  }

  /// `second` for a day that is the second of its weekday in its month.
  static String ordinalInMonth(Day d) => ordinals[(d.day - 1) ~/ 7];

  static String _every(int n, String unit) =>
      n == 1 ? 'every $unit' : 'every $n ${unit}s';

  /// A plain-language description of [rule] for a task first due on [anchor].
  static String describe(Recurrence rule, Day anchor) {
    final String text;
    switch (rule.frequency) {
      case Frequency.daily:
        text = _every(rule.interval, 'day');
      case Frequency.weekly:
        final days = rule.weekdays.isEmpty ? {anchor.weekday} : rule.weekdays;
        final sorted = days.toList()..sort();
        if (sorted.length == 5 && sorted.last == 5 && rule.interval == 1) {
          text = 'every weekday';
        } else if (sorted.length == 7 && rule.interval == 1) {
          text = 'every day';
        } else {
          final names = sorted.map((d) => weekdaysShort[d - 1]).join(', ');
          text = '${_every(rule.interval, 'week')} on $names';
        }
      case Frequency.monthly:
        final on = rule.nthWeekday == null
            ? 'on day ${anchor.day}'
            : rule.nthWeekday! < 0
                ? 'on the last ${weekday(anchor)}'
                : 'on the ${ordinals[rule.nthWeekday! - 1]} ${weekday(anchor)}';
        text = '${_every(rule.interval, 'month')} $on';
      case Frequency.yearly:
        text = '${_every(rule.interval, 'year')} on ${anchor.day} ${month(anchor)}';
    }
    final until = rule.until;
    return 'Repeats $text${until == null ? '' : ' until ${dayMonth(until)} ${until.year}'}';
  }
}
