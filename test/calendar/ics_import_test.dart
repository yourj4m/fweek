import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/ics_import.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/data/recurrence.dart';

/// A calendar file dropped on the planner: its events become items.
String file(List<List<String>> events, {String? name}) => [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      if (name != null) 'X-WR-CALNAME:$name',
      for (final event in events) ...['BEGIN:VEVENT', ...event, 'END:VEVENT'],
      'END:VCALENDAR',
      '',
    ].join('\r\n');

const seminar = [
  'UID:seminar-1@example.org',
  'SUMMARY:Eva Jägle\\, Tech. Univ. München - Séminaire',
  'LOCATION:Amphithéâtre Killian\\, Maison des Géosciences',
  'DESCRIPTION:Coda Wave Interferometry<br>See <a href="https://example.org/abs">the abstract</a>',
  'DTSTART:20261117T090000Z',
  'DTEND:20261117T100000Z',
];

void main() {
  final today = Day(2026, 11, 13);
  // One hour ahead of UTC whatever the machine's zone.
  DateTime local(DateTime utc) =>
      DateTime(utc.year, utc.month, utc.day, utc.hour + 1, utc.minute);
  late PlannerStore store;
  setUp(() => store = PlannerStore(PlannerDatabase.inMemory(), today: () => today));
  IcsImportResult take(String text) => IcsImport.run(store, text, toLocal: local);
  List<String> on(Day day) => [for (final t in store.tasksOn(day)) t.title];

  test('an event becomes an event of the planner: day, start and end, place, what it says', () {
    final result = take(file([seminar], name: 'Seminars'));
    expect((result.added, result.updated, result.skipped), (1, 0, 0));
    expect(result.calendarName, 'Seminars');
    final item = store.task(result.items.single.id)!;
    expect(item.date, Day(2026, 11, 17));
    expect(item.title, 'Eva Jägle, Tech. Univ. München - Séminaire');
    expect((item.time, item.end), (10 * 60, 11 * 60));
    expect(item.location, 'Amphithéâtre Killian, Maison des Géosciences');
    expect(item.note, 'Coda Wave Interferometry\nSee the abstract (https://example.org/abs)');
    expect(item.kind, ItemKind.event);
    expect(item.fromCalendar, isFalse, reason: 'it is the planner\'s own now, and syncs');
    expect(result.items.single.isNew, isTrue);
  });

  test('the same file again brings its items up to date; nothing is there twice', () {
    final first = take(file([seminar])).items.single;
    // The user placed it, and made it a task.
    store.addTask(DaySlot(Day(2026, 11, 17)), 'Prepare questions');
    store.moveTask(first.id, DaySlot(Day(2026, 11, 17)), index: 1);
    store.setKind(first.id, ItemKind.task);

    final again = take(file([
      [...seminar.where((l) => !l.startsWith('DTSTART') && !l.startsWith('DTEND')),
        'DTSTART:20261117T130000Z', 'DTEND:20261117T143000Z'],
    ]));
    expect((again.added, again.updated), (0, 1));
    expect(again.items.single.id, first.id);
    expect(store.allTasks.where((t) => t.title.startsWith('Eva')), hasLength(1));
    final item = store.task(first.id)!;
    expect((item.time, item.end), (14 * 60, 15 * 60 + 30));
    // What the user did with it stays.
    expect(item.kind, ItemKind.task);
    expect(on(Day(2026, 11, 17)), ['Prepare questions', item.title]);
  });

  test('one that was deleted comes back', () {
    final id = take(file([seminar])).items.single.id;
    store.deleteTask(id, wholeSeries: true);
    expect(store.task(id), isNull);
    final again = take(file([seminar]));
    expect(again.added, 1);
    expect(store.task(id)!.title, startsWith('Eva'));
  });

  test('a whole day has no time; several whole days are one event that runs over them', () {
    final result = take(file([
      ['UID:d1', 'SUMMARY:Open day', 'DTSTART;VALUE=DATE:20261120', 'DTEND;VALUE=DATE:20261121'],
      ['UID:d3', 'SUMMARY:Conference', 'DTSTART;VALUE=DATE:20261123', 'DTEND;VALUE=DATE:20261126'],
    ]));
    expect(result.added, 2);
    expect(store.tasksOn(Day(2026, 11, 20)).single.time, isNull);
    // One item from the 23rd to the 25th: a bar over the days, not a row
    // on each, and not something that repeats.
    final conference = store.allTasks.singleWhere((t) => t.title == 'Conference');
    expect((conference.date, conference.endDay, conference.recurrence),
        (Day(2026, 11, 23), Day(2026, 11, 25), null));
    expect(on(Day(2026, 11, 24)), isEmpty);
    expect([for (final t in store.spansBetween(Day(2026, 11, 25), Day(2026, 11, 29))) t.title],
        ['Conference']);
    expect(store.spansBetween(Day(2026, 11, 26), Day(2026, 11, 29)), isEmpty);
    expect(result.items.last.lastDay, Day(2026, 11, 25));

    // Taken in again after the calendar shortened it: brought up to date.
    take(file([
      ['UID:d3', 'SUMMARY:Conference', 'DTSTART;VALUE=DATE:20261123', 'DTEND;VALUE=DATE:20261124'],
    ]));
    expect(store.task(conference.id)!.endDay, isNull);
    expect(on(Day(2026, 11, 23)), ['Conference']);
  });

  group('an event that repeats', () {
    Task only() => store.allTasks.single;

    test('every week: one repeating item', () {
      final result = take(file([
        ['UID:w', 'SUMMARY:Group seminar', 'DTSTART:20261104T080000Z', 'DTEND:20261104T090000Z',
          'RRULE:FREQ=WEEKLY;BYDAY=WE'],
      ]));
      expect(result.items, hasLength(1));
      final rule = only().recurrence!;
      expect((rule.frequency, rule.interval, rule.until), (Frequency.weekly, 1, null));
      expect(on(Day(2026, 11, 18)), ['Group seminar']);
      expect(on(Day(2027, 3, 10)), ['Group seminar']);
      expect(on(Day(2026, 11, 19)), isEmpty);
    });

    test('on several weekdays, every second week, until a day', () {
      take(file([
        ['UID:m', 'SUMMARY:Lab', 'DTSTART:20261102T080000Z', 'DTEND:20261102T090000Z',
          'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;UNTIL=20261231T000000Z'],
      ]));
      final rule = only().recurrence!;
      expect((rule.frequency, rule.interval), (Frequency.weekly, 2));
      expect(rule.weekdays, {1, 4});
      expect(rule.until, isNotNull);
      expect(on(Day(2026, 11, 16)), ['Lab']); // a Monday of an "on" week
      expect(on(Day(2026, 11, 19)), ['Lab']);
      expect(on(Day(2026, 11, 9)), isEmpty); // the week between
      expect(on(Day(2027, 1, 11)), isEmpty); // after the end
    });

    test('a count of times ends where the calendar ends it', () {
      take(file([
        ['UID:c', 'SUMMARY:Course', 'DTSTART:20261110T170000Z', 'DTEND:20261110T180000Z',
          'RRULE:FREQ=WEEKLY;COUNT=4'],
      ]));
      expect(on(Day(2026, 12, 1)), ['Course']);
      expect(on(Day(2026, 12, 8)), isEmpty);
    });

    test('days the calendar leaves out are left out', () {
      take(file([
        ['UID:x', 'SUMMARY:Stand-up', 'DTSTART:20261109T080000Z', 'DTEND:20261109T081500Z',
          'RRULE:FREQ=DAILY;UNTIL=20261130T000000Z', 'EXDATE:20261111T080000Z'],
      ]));
      expect(on(Day(2026, 11, 10)), ['Stand-up']);
      expect(on(Day(2026, 11, 11)), isEmpty);
      expect(on(Day(2026, 11, 12)), ['Stand-up']);
      expect(store.allTasks, hasLength(1));
    });

    test('every month on the second Tuesday; every year', () {
      take(file([
        ['UID:mo', 'SUMMARY:Board', 'DTSTART:20261110T130000Z', 'DTEND:20261110T140000Z',
          'RRULE:FREQ=MONTHLY;BYDAY=2TU'],
        ['UID:y', 'SUMMARY:Anniversary', 'DTSTART;VALUE=DATE:20260305', 'RRULE:FREQ=YEARLY'],
      ]));
      expect(on(Day(2026, 12, 8)), ['Board']);
      expect(on(Day(2027, 1, 12)), ['Board']);
      expect(on(Day(2027, 3, 5)), ['Anniversary']);
      expect(store.allTasks, hasLength(2));
    });

    test('a rule the planner cannot say is taken in date by date', () {
      // The last weekday of every month.
      final result = take(file([
        ['UID:odd', 'SUMMARY:Report', 'DTSTART:20261030T080000Z', 'DTEND:20261030T090000Z',
          'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1'],
      ]));
      expect(result.items.length, greaterThan(6));
      expect(store.allTasks.every((t) => t.recurrence == null), isTrue);
      expect(on(Day(2026, 11, 30)), ['Report']);
      expect(on(Day(2026, 12, 31)), ['Report']);
      // And again: the same dates, not twice.
      final again = take(file([
        ['UID:odd', 'SUMMARY:Report', 'DTSTART:20261030T080000Z', 'DTEND:20261030T090000Z',
          'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1'],
      ]));
      expect(again.added, 0);
      expect(on(Day(2026, 11, 30)), ['Report']);
    });
  });

  test('the items are told in the order of their days', () {
    final result = take(file([
      ['UID:b', 'SUMMARY:Later', 'DTSTART:20261201T090000Z'],
      seminar,
      ['UID:a', 'SUMMARY:Sooner', 'DTSTART;VALUE=DATE:20261114'],
    ]));
    expect([for (final i in result.items) i.title.split(',').first], ['Sooner', 'Eva Jägle', 'Later']);
  });

  test('what is not a calendar file is refused, and nothing is taken in', () {
    expect(() => take('Dear all,\nplease find attached…'), throwsFormatException);
    expect(store.allTasks, isEmpty);
  });
}
