import 'day.dart';

enum Frequency { daily, weekly, monthly, yearly }

/// How a task repeats.
///
/// The rule is anchored at the task's own date (the first occurrence), which
/// is passed to [occurrences] rather than stored here.
class Recurrence {
  const Recurrence({
    required this.frequency,
    this.interval = 1,
    this.weekdays = const {},
    this.nthWeekday,
    this.until,
  }) : assert(interval >= 1);

  /// Every day.
  static const daily = Recurrence(frequency: Frequency.daily);

  /// Every week on the anchor's weekday.
  static const weekly = Recurrence(frequency: Frequency.weekly);

  /// Monday to Friday.
  static const weekdaysOnly = Recurrence(
    frequency: Frequency.weekly,
    weekdays: {1, 2, 3, 4, 5},
  );

  /// Every second week on the anchor's weekday.
  static const biweekly = Recurrence(frequency: Frequency.weekly, interval: 2);

  /// Every month on the anchor's day of the month.
  static const monthly = Recurrence(frequency: Frequency.monthly);

  /// Every year on the anchor's date.
  static const yearly = Recurrence(frequency: Frequency.yearly);

  final Frequency frequency;

  /// Repeat every [interval] days, weeks, months or years.
  final int interval;

  /// Weekly only: the weekdays (Monday = 1 … Sunday = 7) it falls on.
  /// Empty means the anchor's weekday.
  final Set<int> weekdays;

  /// Monthly only: when set, repeat on the n-th weekday of the month matching
  /// the anchor (for example "second Friday") instead of the same day number.
  /// 1–4 count from the start of the month; −1 means the last one.
  final int? nthWeekday;

  /// Last day on which the task may occur, inclusive. Null repeats forever.
  final Day? until;

  Recurrence copyWith({
    Frequency? frequency,
    int? interval,
    Set<int>? weekdays,
    int? Function()? nthWeekday,
    Day? Function()? until,
  }) =>
      Recurrence(
        frequency: frequency ?? this.frequency,
        interval: interval ?? this.interval,
        weekdays: weekdays ?? this.weekdays,
        nthWeekday: nthWeekday != null ? nthWeekday() : this.nthWeekday,
        until: until != null ? until() : this.until,
      );

  /// The occurrences of a task anchored at [anchor] that fall within
  /// [from]..[to], both inclusive, in ascending order.
  List<Day> occurrences(Day anchor, Day from, Day to) {
    final last = (until != null && until! < to) ? until! : to;
    final first = from < anchor ? anchor : from;
    if (last < first) return const [];
    final out = <Day>[];
    switch (frequency) {
      case Frequency.daily:
        final offset = first.difference(anchor);
        var d = anchor.addDays(offset + (-offset) % interval);
        while (d <= last) {
          out.add(d);
          d = d.addDays(interval);
        }
      case Frequency.weekly:
        final days = weekdays.isEmpty ? {anchor.weekday} : weekdays;
        final anchorWeek = anchor.startOfWeek();
        for (var d = first; d <= last; d = d.addDays(1)) {
          if (!days.contains(d.weekday)) continue;
          final weeks = d.startOfWeek().difference(anchorWeek) ~/ 7;
          if (weeks % interval == 0) out.add(d);
        }
      case Frequency.monthly:
        var months = (first.year - anchor.year) * 12 + first.month - anchor.month;
        if (months < 0) months = 0;
        months += (-months) % interval;
        while (true) {
          final d = _monthlyOccurrence(anchor, months);
          if (d > last) break;
          if (d >= first) out.add(d);
          months += interval;
        }
      case Frequency.yearly:
        var years = first.year - anchor.year;
        if (years < 0) years = 0;
        years += (-years) % interval;
        while (true) {
          final d = anchor.addMonths(years * 12);
          if (d > last) break;
          if (d >= first) out.add(d);
          years += interval;
        }
    }
    return out;
  }

  /// The first occurrence strictly after [day], or null if the rule has ended.
  Day? nextAfter(Day anchor, Day day) {
    // Look ahead far enough to cover the sparsest rule this type can express.
    final span = switch (frequency) {
      Frequency.daily => interval + 1,
      Frequency.weekly => 7 * interval + 7,
      Frequency.monthly => 31 * interval + 31,
      Frequency.yearly => 366 * interval + 366,
    };
    final start = day.addDays(1);
    final found = occurrences(anchor, start, start.addDays(span));
    return found.isEmpty ? null : found.first;
  }

  Day _monthlyOccurrence(Day anchor, int monthsAhead) {
    final nth = nthWeekday;
    if (nth == null) return anchor.addMonths(monthsAhead);
    final month = Day(anchor.year, anchor.month, 1).addMonths(monthsAhead);
    final length = Day.daysInMonth(month.year, month.month);
    if (nth < 0) {
      final lastDay = Day(month.year, month.month, length);
      return lastDay.addDays(-((lastDay.weekday - anchor.weekday) % 7));
    }
    final firstMatch = month.addDays((anchor.weekday - month.weekday) % 7);
    final candidate = firstMatch.addDays(7 * (nth - 1));
    // A fifth weekday that this month does not have falls back to the last one.
    return candidate.month == month.month ? candidate : candidate.addDays(-7);
  }

  Map<String, Object?> toJson() => {
        'freq': frequency.name,
        if (interval != 1) 'interval': interval,
        if (weekdays.isNotEmpty) 'weekdays': weekdays.toList()..sort(),
        if (nthWeekday != null) 'nth': nthWeekday,
        if (until != null) 'until': until!.iso,
      };

  static Recurrence? fromJson(Object? json) {
    if (json is! Map) return null;
    final freq = Frequency.values.where((f) => f.name == json['freq']);
    if (freq.isEmpty) return null;
    final interval = json['interval'];
    final weekdays = json['weekdays'];
    final nth = json['nth'];
    return Recurrence(
      frequency: freq.first,
      interval: interval is int && interval >= 1 ? interval : 1,
      weekdays: weekdays is List
          ? weekdays.whereType<int>().where((d) => d >= 1 && d <= 7).toSet()
          : const {},
      nthWeekday: nth is int ? nth : null,
      until: Day.tryParse(json['until'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.nthWeekday == nthWeekday &&
      other.until == until &&
      other.weekdays.length == weekdays.length &&
      other.weekdays.containsAll(weekdays);

  @override
  int get hashCode => Object.hash(
        frequency,
        interval,
        nthWeekday,
        until,
        Object.hashAllUnordered(weekdays),
      );
}
