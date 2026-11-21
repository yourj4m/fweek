import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/day.dart';
import '../data/planner_store.dart';
import '../data/recurrence.dart';
import '../text/links.dart';
import 'ics.dart';

/// One item the planner made, or brought up to date, from a calendar file.
class ImportedItem {
  const ImportedItem({
    required this.id,
    required this.day,
    required this.title,
    required this.isNew,
    this.time,
    this.end,
    this.recurrence,
    this.lastDay,
  });

  /// The id of the item in the planner (for a repeating one, its series).
  final String id;

  /// The day it is on, or first on.
  final Day day;

  /// The last day of one that runs over several.
  final Day? lastDay;
  final String title;
  final int? time;
  final int? end;

  /// How it repeats, when it does.
  final Recurrence? recurrence;

  /// Made now, rather than known from an earlier import and brought up to
  /// date.
  final bool isNew;
}

/// What became of a calendar file.
class IcsImportResult {
  const IcsImportResult(this.items, {this.skipped = 0, this.calendarName});

  /// In the order of their days.
  final List<ImportedItem> items;

  /// Events of the file that could not be understood.
  final int skipped;

  /// The name the file gives itself, if it has one.
  final String? calendarName;

  int get added => items.where((i) => i.isNew).length;
  int get updated => items.length - added;
}

/// Takes the events of a calendar file (`.ics`) into the planner.
///
/// They become items of the planner's own, events by kind: on their day,
/// with start and end, place and description. So they sync like everything
/// else the planner holds, and can be changed and deleted like it. Each is
/// filed under an id made from the event's own identifier, so that taking
/// the same file in again brings its items up to date instead of doubling
/// them.
///
/// An event that repeats becomes one repeating item when the planner can
/// say its rule (every n days, weeks on given weekdays, months, years, with
/// days left out); what it cannot say is taken in date by date, for the
/// coming year. An event over several days is one item that runs over them.
abstract final class IcsImport {
  /// How far back and ahead repeating events are looked at.
  static const _back = 366, _ahead = 732;

  /// Dates taken in one by one for a rule the planner cannot say.
  static const _mostDates = 60;

  static String _id(String uid, [String instance = '']) =>
      'ics${sha256.convert(utf8.encode('$uid\n$instance')).toString().substring(0, 24)}';

  static int _minutes(DateTime t) => t.hour * 60 + t.minute;

  /// Throws a [FormatException] when [text] is not a calendar file.
  static IcsImportResult run(
    PlannerStore store,
    String text, {
    DateTime Function(DateTime utc)? toLocal,
  }) {
    final calendar = IcsCalendar.parse(text, toLocal: toLocal);
    final today = store.today;
    final items = <ImportedItem>[];

    void take(
      String id,
      EventOccurrence event, {
      Recurrence? recurrence,
      Set<Day> exdates = const {},
    }) {
      final start = event.start, end = event.end;
      final time = event.allDay || start == null ? null : _minutes(start);
      // Over several days it runs to its last day; an end time is then a
      // time of that day. Within one day an end is kept when it lies after
      // the start.
      final lastDay = event.lastDay > event.firstDay ? event.lastDay : null;
      final ends = time == null || end == null ? null : _minutes(end);
      final until = ends == null
          ? null
          : lastDay != null
              ? (Day.fromDateTime(end!) == lastDay ? ends : null)
              : (Day.fromDateTime(end!) == event.firstDay && ends > time! ? ends : null);
      final title = event.title.trim().isEmpty ? '(No title)' : event.title.trim();
      final isNew = store.putItem(
        id,
        day: event.firstDay,
        lastDay: lastDay,
        title: title,
        note: plainFromHtml(event.description).trim(),
        location: event.location.trim(),
        time: time,
        end: until,
        recurrence: recurrence,
        exdates: exdates,
      );
      items.add(ImportedItem(
        id: id,
        day: event.firstDay,
        lastDay: lastDay,
        title: title,
        time: time,
        end: until,
        recurrence: recurrence,
        isNew: isNew,
      ));
    }

    // Events that happen once.
    for (final event in calendar.standalone) {
      take(_id(event.uid), event);
    }

    // Events that repeat, by their occurrences around today.
    final first = today.addDays(-_back), last = today.addDays(_ahead);
    final series = <String, List<EventOccurrence>>{};
    for (final occurrence in calendar.occurrencesBetween(first, last)) {
      if (occurrence.instance.isEmpty || occurrence.day != occurrence.firstDay) continue;
      (series[occurrence.uid] ??= []).add(occurrence);
    }
    for (final entry in series.entries) {
      final occurrences = entry.value..sort((a, b) => a.firstDay.compareTo(b.firstDay));
      final rule = occurrences.length < 2 ? null : _ruleFor(occurrences, last);
      if (rule != null) {
        take(_id(entry.key), occurrences.first, recurrence: rule.$1, exdates: rule.$2);
      } else if (occurrences.length == 1) {
        take(_id(entry.key), occurrences.single);
      } else {
        // A rule the planner cannot say: its dates, from a month ago on.
        final from = today.addDays(-31);
        for (final occurrence
            in occurrences.where((o) => o.firstDay >= from).take(_mostDates)) {
          take(_id(entry.key, occurrence.instance), occurrence);
        }
      }
    }

    items.sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      return byDay != 0 ? byDay : (a.time ?? -1).compareTo(b.time ?? -1);
    });
    return IcsImportResult(items, skipped: calendar.skipped, calendarName: calendar.name);
  }

  /// A rule of the planner's that gives exactly the days of [occurrences]
  /// (all of one repeating event, in order), with the days it gives too
  /// many; or null when there is none, or the occurrences differ in more
  /// than their day.
  static (Recurrence, Set<Day>)? _ruleFor(List<EventOccurrence> occurrences, Day horizon) {
    final first = occurrences.first;
    for (final o in occurrences) {
      final sameTime = o.allDay == first.allDay &&
          (o.start == null) == (first.start == null) &&
          (o.start == null || _minutes(o.start!) == _minutes(first.start!)) &&
          o.lastDay.difference(o.firstDay) == first.lastDay.difference(first.firstDay);
      if (!sameTime || o.title != first.title) return null;
    }
    final days = [for (final o in occurrences) o.firstDay];
    final anchor = days.first;
    final wanted = days.toSet();
    if (wanted.length != days.length) return null;

    final candidates = <Recurrence>[];
    final gaps = [for (var i = 1; i < days.length; i++) days[i].difference(days[i - 1])];
    final smallest = gaps.reduce((a, b) => a < b ? a : b);
    // Every n days, or every n weeks on one weekday.
    if (smallest % 7 == 0) {
      candidates.add(Recurrence(frequency: Frequency.weekly, interval: smallest ~/ 7));
    }
    candidates.add(Recurrence(frequency: Frequency.daily, interval: smallest));
    // Every n weeks on several weekdays.
    final weekdays = {for (final d in days) d.weekday};
    if (weekdays.length > 1) {
      final weeks = {for (final d in days) d.startOfWeek().difference(anchor.startOfWeek()) ~/ 7}
          .toList()
        ..sort();
      var every = 1;
      if (weeks.length > 1) {
        every = weeks[1] - weeks[0];
        for (var i = 2; i < weeks.length; i++) {
          if (weeks[i] - weeks[i - 1] < every) every = weeks[i] - weeks[i - 1];
        }
      }
      candidates.add(Recurrence(frequency: Frequency.weekly, interval: every, weekdays: weekdays));
    }
    // Every n months: on the same day, or on the same n-th weekday.
    final months = [
      for (var i = 1; i < days.length; i++)
        (days[i].year - days[i - 1].year) * 12 + days[i].month - days[i - 1].month,
    ];
    final fewestMonths = months.reduce((a, b) => a < b ? a : b);
    if (fewestMonths >= 1) {
      if (days.every((d) => d.day == anchor.day)) {
        candidates.add(fewestMonths % 12 == 0
            ? Recurrence(frequency: Frequency.yearly, interval: fewestMonths ~/ 12)
            : Recurrence(frequency: Frequency.monthly, interval: fewestMonths));
      }
      if (days.every((d) => d.weekday == anchor.weekday)) {
        final nth = (anchor.day - 1) ~/ 7 + 1;
        final isLast = anchor.addDays(7).month != anchor.month;
        candidates.addAll([
          Recurrence(frequency: Frequency.monthly, interval: fewestMonths, nthWeekday: nth),
          if (isLast)
            Recurrence(frequency: Frequency.monthly, interval: fewestMonths, nthWeekday: -1),
        ]);
      }
    }

    for (final candidate in candidates) {
      var rule = candidate;
      var given = rule.occurrences(anchor, anchor, horizon);
      // The event ends before the days looked at do: so does the rule.
      if (given.isNotEmpty && given.last > days.last) {
        final after = given.where((d) => d > days.last).toList();
        // More than a couple of days it should have had: it has ended.
        if (after.length >= 2 || days.last < horizon.addDays(-400)) {
          rule = rule.copyWith(until: () => days.last);
          given = rule.occurrences(anchor, anchor, horizon);
        }
      }
      final extra = given.toSet().difference(wanted);
      final missing = wanted.difference(given.toSet());
      // Every day of the event, and few that are not: those are left out.
      if (missing.isEmpty && extra.length <= 2 + wanted.length ~/ 4) {
        return (rule, extra);
      }
    }
    return null;
  }
}
