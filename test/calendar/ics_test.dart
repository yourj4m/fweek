import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/ics.dart';
import 'package:fweek/data/day.dart';

// Every test names the device's zone itself, so that the outcome does not
// depend on where the tests run. Asserted clock times stay clear of the small
// hours of a Sunday: the reader hands out local DateTimes, and a time that
// the machine's own zone skips cannot be held in one.

/// A device a fixed number of hours east of UTC.
DateTime Function(DateTime utc) fixed(int hours) =>
    (utc) => utc.add(Duration(hours: hours));

DateTime plusOne(DateTime utc) => utc.add(const Duration(hours: 1));

/// A device in Europe/Paris: UTC+2 from the last Sunday of March, 01:00 UTC,
/// to the last Sunday of October, 01:00 UTC, else UTC+1.
DateTime paris(DateTime utc) {
  DateTime change(int month) {
    final end = DateTime.utc(utc.year, month + 1, 0, 1);
    return end.subtract(Duration(days: end.weekday % 7));
  }

  final summer = !utc.isBefore(change(3)) && utc.isBefore(change(10));
  return utc.add(Duration(hours: summer ? 2 : 1));
}

/// Europe/Paris as Google Calendar writes it.
const parisZone = [
  'BEGIN:VTIMEZONE',
  'TZID:Europe/Paris',
  'X-LIC-LOCATION:Europe/Paris',
  'BEGIN:DAYLIGHT',
  'TZOFFSETFROM:+0100',
  'TZOFFSETTO:+0200',
  'TZNAME:CEST',
  'DTSTART:19700329T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU',
  'END:DAYLIGHT',
  'BEGIN:STANDARD',
  'TZOFFSETFROM:+0200',
  'TZOFFSETTO:+0100',
  'TZNAME:CET',
  'DTSTART:19701025T030000',
  'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU',
  'END:STANDARD',
  'END:VTIMEZONE',
];

List<String> event(List<String> props) =>
    ['BEGIN:VEVENT', ...props, 'END:VEVENT'];

String feedText(
  List<List<String>> components, {
  List<String> head = const [],
}) =>
    [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//fweek//tests//EN',
      ...head,
      for (final component in components) ...component,
      'END:VCALENDAR',
      '',
    ].join('\r\n');

IcsCalendar read(
  List<List<String>> components, {
  DateTime Function(DateTime utc) zone = plusOne,
  List<String> head = const [],
}) =>
    IcsCalendar.parse(feedText(components, head: head), toLocal: zone);

String two(int n) => n.toString().padLeft(2, '0');

String clock(DateTime time) => '${two(time.hour)}:${two(time.minute)}';

/// `2026-11-13 10:00` from the fields, whatever kind of DateTime it is.
String moment(DateTime time) => '${Day.fromDateTime(time).iso} ${clock(time)}';

/// One line per entry: `2026-11-13 10:00-11:00 Title`, or `… all-day Title`.
List<String> shown(IcsCalendar feed, Day first, Day last) => [
      for (final o in feed.occurrencesBetween(first, last))
        '${o.day.iso} '
            '${o.allDay ? 'all-day' : '${clock(o.start!)}-${clock(o.end!)}'} '
            '${o.title}',
    ];

List<String> days(IcsCalendar feed, Day first, Day last) =>
    [for (final o in feed.occurrencesBetween(first, last)) o.day.iso];

/// The first days of a rule for a timed series without a zone.
List<String> ruleDays(
  String start,
  String rule, {
  int take = 1000,
  List<String> more = const [],
}) {
  final feed = read([
    event(['UID:rule', 'DTSTART:$start', 'RRULE:$rule', ...more]),
  ]);
  final first = Day(int.parse(start.substring(0, 4)), 1, 1);
  return days(feed, first, Day(first.year + 12, 12, 31)).take(take).toList();
}

Future<IcsCalendar> parseElsewhere(String text) =>
    Isolate.run(() => IcsCalendar.parse(text, toLocal: plusOne));

Future<IcsCalendar> parseElsewhereInDeviceZone(String text) =>
    Isolate.run(() => IcsCalendar.parse(text));

void main() {
  final friday = Day(2026, 11, 13);
  final monday = Day(2026, 11, 9);
  final sunday = Day(2026, 11, 15);

  test('the stand-in for Europe/Paris changes when Paris does', () {
    expect(paris(DateTime.utc(2026, 3, 29, 0, 59)).hour, 1);
    expect(paris(DateTime.utc(2026, 3, 29, 1)).hour, 3);
    expect(paris(DateTime.utc(2026, 10, 25, 0, 59)).hour, 2);
    expect(paris(DateTime.utc(2026, 10, 25, 1)).hour, 2);
    expect(paris(DateTime.utc(2026, 10, 25, 2)).hour, 3);
  });

  group('lines', () {
    test('folded lines are joined and escapes undone', () {
      final feed = IcsCalendar.parse(
        [
          'BEGIN:VCALENDAR',
          'BEGIN:VEVENT',
          'UID:fold',
          'DTSTART;VALUE=DATE:20261113',
          'SUMMARY:Lunch with A',
          ' lice\\, Bob\\; and',
          '\t Carol',
          'DESCRIPTION:Line one\\nLine two\\NLine three\\\\n is not a break\\',
          '  and a stray \\x stays',
          'LOCATION:Café de la Gare\\, Grenoble',
          'END:VEVENT',
          'END:VCALENDAR',
        ].join('\r\n'),
        toLocal: plusOne,
      );
      final o = feed.occurrencesBetween(friday, friday).single;
      expect(o.title, 'Lunch with Alice, Bob; and Carol');
      expect(
        o.description,
        'Line one\nLine two\nLine three\\n is not a break\\'
        ' and a stray \\x stays',
      );
      expect(o.location, 'Café de la Gare, Grenoble');
    });

    test('bare line feeds, a byte-order mark and blank lines are accepted', () {
      final feed = IcsCalendar.parse(
        '\uFEFFBEGIN:VCALENDAR\n'
        'BEGIN:VEVENT\n'
        'UID:lf\n'
        '\n'
        'DTSTART:20261113T090000Z\n'
        'SUMMARY:Folded with\n'
        '  line feeds only\n'
        'END:VEVENT\n'
        'END:VCALENDAR',
        toLocal: plusOne,
      );
      expect(shown(feed, friday, friday), [
        '2026-11-13 10:00-10:00 Folded with line feeds only',
      ]);
    });

    test('names are case-insensitive and parameters may be quoted', () {
      final feed = IcsCalendar.parse(
        [
          'begin:vcalendar',
          ...parisZone,
          'begin:vevent',
          'uid:case',
          'dtstart;tzid="Europe/Paris":20261113T100000',
          'DtEnd;TzId=Europe/Paris:20261113T110000',
          'summary;language=en;x-note="a:b;c,d":Quoted: yes; fine',
          'location;altrep="http://example.org/rooms:12":Room 12',
          'end:vevent',
          'begin:vevent',
          'uid:date',
          'dtstart;value=date:20261113',
          'summary:All day',
          'end:vevent',
          'end:vcalendar',
        ].join('\r\n'),
        toLocal: fixed(0),
      );
      expect(shown(feed, friday, friday), [
        '2026-11-13 all-day All day',
        '2026-11-13 09:00-10:00 Quoted: yes; fine',
      ]);
      expect(feed.occurrencesBetween(friday, friday).last.location, 'Room 12');
    });

    test('the calendar name is read, unescaped', () {
      expect(
        read(const [], head: ['X-WR-CALNAME:Work\\, shared']).name,
        'Work, shared',
      );
      expect(read(const []).name, isNull);
      expect(read(const [], head: ['X-WR-CALNAME:  ']).name, isNull);
    });

    test('text that is not a calendar is refused', () {
      expect(() => IcsCalendar.parse(''), throwsFormatException);
      expect(
        () => IcsCalendar.parse('<!DOCTYPE html><html><body>404</body></html>'),
        throwsFormatException,
      );
      expect(
        () => IcsCalendar.parse('BEGIN:VCARD\r\nFN:Someone\r\nEND:VCARD\r\n'),
        throwsFormatException,
      );
    });

    test('an empty calendar is a calendar', () {
      final feed = IcsCalendar.parse('BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n');
      expect(feed.eventCount, 0);
      expect(feed.skipped, 0);
      expect(feed.occurrencesBetween(Day(1900, 1, 1), Day(2200, 1, 1)), isEmpty);
    });
  });

  group('components', () {
    test('only events are shown, and an alarm does not speak for its event', () {
      final feed = read([
        [
          'BEGIN:VTODO',
          'UID:todo',
          'DTSTART:20261113T090000Z',
          'SUMMARY:A task, not an event',
          'END:VTODO',
        ],
        [
          'BEGIN:VJOURNAL',
          'UID:journal',
          'DTSTART;VALUE=DATE:20261113',
          'SUMMARY:A note',
          'END:VJOURNAL',
        ],
        event([
          'UID:with-alarm',
          'DTSTART:20261113T090000Z',
          'DTEND:20261113T100000Z',
          'SUMMARY:Review',
          'BEGIN:VALARM',
          'ACTION:DISPLAY',
          'SUMMARY:Alarm',
          'DESCRIPTION:This is an event reminder',
          'TRIGGER:-PT15M',
          'DURATION:PT5M',
          'REPEAT:2',
          'END:VALARM',
          'DESCRIPTION:Bring the figures',
          'LOCATION:Room 2',
        ]),
      ]);
      final o = feed.occurrencesBetween(friday, friday).single;
      expect(o.title, 'Review');
      expect(o.description, 'Bring the figures');
      expect(o.location, 'Room 2');
      expect(moment(o.end!), '2026-11-13 11:00');
      expect(feed.eventCount, 1);
      expect(feed.skipped, 0);
    });

    test('missing texts are empty', () {
      final o = read([
        event(['UID:bare', 'DTSTART:20261113T090000Z']),
      ]).occurrencesBetween(friday, friday).single;
      expect(o.uid, 'bare');
      expect(o.title, '');
      expect(o.location, '');
      expect(o.description, '');
    });

    test('events that cannot be read are skipped, the rest still loads', () {
      final feed = read([
        event(['UID:no-start', 'SUMMARY:No start']),
        event(['UID:junk', 'DTSTART:next tuesday', 'SUMMARY:Junk']),
        event(['UID:month13', 'DTSTART:20261340T100000Z', 'SUMMARY:Month 13']),
        event(['UID:hour25', 'DTSTART:20261113T250000Z', 'SUMMARY:Hour 25']),
        ['THIS LINE MEANS NOTHING', ':', ';;;', 'X-ORPHAN;A=1'],
        event(['UID:good', 'DTSTART:20261113T090000Z', 'SUMMARY:Good']),
        event([
          'UID:bad-end',
          'DTSTART:20261113T120000Z',
          'DTEND:whenever',
          'RRULE:FREQ=WEEKLY;COUNT=x',
          'EXDATE:nonsense,20261120T120000Z',
          'SUMMARY:Bad end',
        ]),
      ]);
      expect(feed.skipped, 4);
      expect(feed.eventCount, 2);
      expect(shown(feed, monday, sunday.addDays(21)), [
        '2026-11-13 10:00-10:00 Good',
        '2026-11-13 13:00-13:00 Bad end',
      ]);
    });

    test('a length beyond all reason is shown, not thrown', () {
      final feed = read([
        event([
          'UID:endless',
          'DTSTART:20261113T090000Z',
          'DURATION:P9999999W',
          'SUMMARY:Typo',
        ]),
        event([
          'UID:endless-days',
          'DTSTART;VALUE=DATE:20261113',
          'DTEND;VALUE=DATE:99991231',
          'RRULE:FREQ=DAILY;COUNT=2',
          'SUMMARY:Typo too',
        ]),
      ]);
      expect(feed.skipped, 0);
      expect(shown(feed, Day(2026, 11, 12), Day(2026, 11, 14)), [
        '2026-11-13 all-day Typo too',
        '2026-11-13 10:00-10:00 Typo',
        '2026-11-14 all-day Typo too',
        '2026-11-14 all-day Typo too',
        '2026-11-14 10:00-10:00 Typo',
      ]);
      expect(days(feed, Day(2300, 1, 1), Day(2300, 1, 1)), hasLength(3));
    });

    test('a download cut off inside an event keeps what came before', () {
      final feed = IcsCalendar.parse(
        'BEGIN:VCALENDAR\r\n'
        'BEGIN:VEVENT\r\nUID:a\r\nDTSTART:20261113T090000Z\r\n'
        'SUMMARY:Whole\r\nEND:VEVENT\r\n'
        'BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20261113T1',
        toLocal: plusOne,
      );
      expect(feed.eventCount, 1);
      expect(feed.skipped, 1);
      expect(shown(feed, friday, friday), ['2026-11-13 10:00-10:00 Whole']);
    });
  });

  group('all-day events', () {
    test('a single day, with VALUE=DATE or just eight digits', () {
      final feed = read([
        event(['UID:a', 'DTSTART;VALUE=DATE:20261113', 'SUMMARY:Marked']),
        event(['UID:b', 'DTSTART:20261113', 'SUMMARY:Unmarked']),
        event([
          'UID:c',
          'DTSTART;VALUE=DATE:20261113',
          'DTEND;VALUE=DATE:20261114',
          'SUMMARY:With end',
        ]),
      ]);
      final found = feed.occurrencesBetween(monday, sunday);
      expect([for (final o in found) o.title], [
        'Marked',
        'Unmarked',
        'With end',
      ]);
      for (final o in found) {
        expect(o.day, friday);
        expect(o.allDay, isTrue);
        expect(o.start, isNull);
        expect(o.end, isNull);
        expect(o.firstDay, friday);
        expect(o.lastDay, friday);
        expect(o.continues, isFalse);
      }
    });

    test('several days: the end is the day after the last', () {
      final feed = read([
        event([
          'UID:trip',
          'DTSTART;VALUE=DATE:20261113',
          'DTEND;VALUE=DATE:20261115',
          'SUMMARY:Trip',
        ]),
      ]);
      final found = feed.occurrencesBetween(monday, sunday);
      expect([for (final o in found) o.day.iso], ['2026-11-13', '2026-11-14']);
      expect([for (final o in found) o.continues], [false, true]);
      for (final o in found) {
        expect(o.firstDay, friday);
        expect(o.lastDay, Day(2026, 11, 14));
      }
      // A window that only catches its tail.
      expect(days(feed, Day(2026, 11, 14), Day(2026, 11, 20)), ['2026-11-14']);
      expect(days(feed, Day(2026, 11, 15), Day(2026, 11, 20)), isEmpty);
      expect(days(feed, Day(2026, 11, 1), Day(2026, 11, 12)), isEmpty);
    });

    test('dates do not move with the device zone', () {
      for (final hours in [-11, 0, 13]) {
        final feed = read(
          [
            event(['UID:a', 'DTSTART;VALUE=DATE:20261113', 'SUMMARY:Day']),
          ],
          zone: fixed(hours),
        );
        expect(days(feed, monday, sunday), ['2026-11-13']);
      }
    });

    test('a length given as DURATION', () {
      final feed = read([
        event(['UID:d', 'DTSTART;VALUE=DATE:20261102', 'DURATION:P1D']),
        event(['UID:w', 'DTSTART;VALUE=DATE:20261109', 'DURATION:P1W']),
        event(['UID:h', 'DTSTART;VALUE=DATE:20261123', 'DURATION:PT36H']),
      ]);
      expect(days(feed, Day(2026, 11, 1), Day(2026, 11, 30)), [
        '2026-11-02',
        for (var d = 9; d <= 15; d++) '2026-11-${two(d)}',
        '2026-11-23',
        '2026-11-24',
      ]);
    });
  });

  group('timed events', () {
    test('UTC times are shown in device time', () {
      final feed = read([
        event([
          'UID:utc',
          'DTSTART:20261113T090000Z',
          'DTEND:20261113T103000Z',
          'SUMMARY:Call',
        ]),
      ]);
      final o = feed.occurrencesBetween(friday, friday).single;
      expect(o.allDay, isFalse);
      expect(o.start, DateTime(2026, 11, 13, 10));
      expect(o.end, DateTime(2026, 11, 13, 11, 30));
      expect(o.start!.isUtc, isFalse);
      expect(o.end!.isUtc, isFalse);
      expect(o.firstDay, friday);
      expect(o.lastDay, friday);
    });

    test('an evening in UTC can be the next day on the device', () {
      final feed = read([
        event([
          'UID:late',
          'DTSTART:20261113T233000Z',
          'DTEND:20261114T003000Z',
          'SUMMARY:Late',
        ]),
      ]);
      expect(shown(feed, monday, sunday), ['2026-11-14 00:30-01:30 Late']);
      expect(days(feed, friday, friday), isEmpty);
    });

    test('a morning in UTC can be the day before on the device', () {
      final feed = read(
        [
          event([
            'UID:early',
            'DTSTART:20261114T030000Z',
            'DTEND:20261114T040000Z',
            'SUMMARY:Early',
          ]),
        ],
        zone: fixed(-8),
      );
      expect(shown(feed, monday, sunday), ['2026-11-13 19:00-20:00 Early']);
    });

    test('a time without a zone is the device clock, wherever that is', () {
      for (final hours in [-8, 0, 9]) {
        final feed = read(
          [
            event([
              'UID:floating',
              'DTSTART:20261113T100000',
              'DTEND:20261113T113000',
              'SUMMARY:Floating',
            ]),
          ],
          zone: fixed(hours),
        );
        final o = feed.occurrencesBetween(friday, friday).single;
        expect(o.start, DateTime(2026, 11, 13, 10));
        expect(o.end, DateTime(2026, 11, 13, 11, 30));
        expect(o.start!.isUtc, isFalse);
      }
    });

    test('the end may be given as DURATION, or not at all', () {
      final feed = read([
        event(['UID:a', 'DTSTART:20261113T090000Z', 'DURATION:PT1H30M']),
        event(['UID:b', 'DTSTART:20261113T110000Z', 'DURATION:P2DT1H']),
        event(['UID:c', 'DTSTART:20261113T130000Z', 'DURATION:PT45M30S']),
        event(['UID:d', 'DTSTART:20261113T150000Z', 'DURATION:-PT1H']),
        event(['UID:e', 'DTSTART:20261113T170000Z', 'DURATION:+PT20M']),
        event(['UID:f', 'DTSTART:20261113T190000Z']),
      ]);
      final found = feed.occurrencesBetween(friday, friday);
      expect(
        [for (final o in found) '${moment(o.start!)} to ${moment(o.end!)}'],
        [
          '2026-11-13 10:00 to 2026-11-13 11:30',
          '2026-11-13 12:00 to 2026-11-15 13:00',
          '2026-11-13 14:00 to 2026-11-13 14:45',
          '2026-11-13 16:00 to 2026-11-13 16:00',
          '2026-11-13 18:00 to 2026-11-13 18:20',
          '2026-11-13 20:00 to 2026-11-13 20:00',
        ],
      );
      expect(found[2].end!.second, 30);
    });

    test('an event crossing midnight is on both days', () {
      final feed = read([
        event([
          'UID:night',
          'DTSTART:20261113T220000',
          'DTEND:20261114T013000',
          'SUMMARY:Night train',
        ]),
      ]);
      final found = feed.occurrencesBetween(monday, sunday);
      expect([for (final o in found) o.day.iso], ['2026-11-13', '2026-11-14']);
      expect([for (final o in found) o.continues], [false, true]);
      for (final o in found) {
        expect(o.start, DateTime(2026, 11, 13, 22));
        expect(o.end, DateTime(2026, 11, 14, 1, 30));
        expect(o.firstDay, friday);
        expect(o.lastDay, Day(2026, 11, 14));
      }
      expect(days(feed, Day(2026, 11, 14), sunday), ['2026-11-14']);
    });

    test('midnight is crossed in device time, not in the time as written', () {
      final feed = read([
        event([
          'UID:utc-evening',
          'DTSTART:20261113T220000Z',
          'DTEND:20261113T233000Z',
          'SUMMARY:Evening in UTC',
        ]),
      ]);
      expect(shown(feed, monday, sunday), [
        '2026-11-13 23:00-00:30 Evening in UTC',
        '2026-11-14 23:00-00:30 Evening in UTC',
      ]);
    });

    test('an event ending exactly at midnight stays on its day', () {
      final feed = read([
        event([
          'UID:till-midnight',
          'DTSTART:20261113T220000',
          'DTEND:20261114T000000',
          'SUMMARY:Until midnight',
        ]),
        event([
          'UID:whole-day-timed',
          'DTSTART:20261110T000000',
          'DTEND:20261111T000000',
          'SUMMARY:Midnight to midnight',
        ]),
        event([
          'UID:at-midnight',
          'DTSTART:20261112T000000',
          'SUMMARY:At midnight',
        ]),
        event([
          'UID:utc-till-local-midnight',
          'DTSTART:20261109T200000Z',
          'DTEND:20261109T230000Z',
          'SUMMARY:Ends at the device midnight',
        ]),
      ]);
      expect(shown(feed, monday, sunday), [
        '2026-11-09 21:00-00:00 Ends at the device midnight',
        '2026-11-10 00:00-00:00 Midnight to midnight',
        '2026-11-12 00:00-00:00 At midnight',
        '2026-11-13 22:00-00:00 Until midnight',
      ]);
      final last = feed.occurrencesBetween(friday, friday).single;
      expect(last.end, DateTime(2026, 11, 14));
      expect(last.lastDay, friday);
    });

    test('an end before the start is taken as no length', () {
      final feed = read([
        event([
          'UID:backwards',
          'DTSTART:20261113T100000Z',
          'DTEND:20261113T090000Z',
        ]),
      ]);
      final o = feed.occurrencesBetween(monday, sunday).single;
      expect(o.end, o.start);
    });
  });

  group('repeats', () {
    test('daily with INTERVAL and COUNT', () {
      final feed = read([
        event([
          'UID:daily',
          'DTSTART;VALUE=DATE:20261101',
          'RRULE:FREQ=DAILY;INTERVAL=3;COUNT=4',
          'SUMMARY:Water the plants',
        ]),
      ]);
      expect(days(feed, Day(2026, 10, 1), Day(2026, 12, 31)), [
        '2026-11-01',
        '2026-11-04',
        '2026-11-07',
        '2026-11-10',
      ]);
      // Counted from the start even when the window begins later.
      expect(days(feed, Day(2026, 11, 5), Day(2026, 12, 31)), [
        '2026-11-07',
        '2026-11-10',
      ]);
      expect(feed.eventCount, 1);
    });

    test('weekly on several weekdays until a moment, inclusive', () {
      List<String> until(String limit) => days(
            read([
              event([
                'UID:weekly',
                'DTSTART:20261109T100000Z',
                'DTEND:20261109T110000Z',
                'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=$limit',
              ]),
            ]),
            Day(2026, 11, 1),
            Day(2026, 12, 31),
          );
      const all = [
        '2026-11-09',
        '2026-11-11',
        '2026-11-13',
        '2026-11-16',
        '2026-11-18',
        '2026-11-20',
      ];
      expect(until('20261120T100000Z'), all);
      expect(until('20261120T095959Z'), all.sublist(0, 5));
      expect(until('20261120'), all);
      expect(until('20261119'), all.sublist(0, 5));
    });

    test('an all-day series until a date, or until a moment of that date', () {
      for (final limit in ['20261111', '20261111T235959Z', '20261111T000000']) {
        final feed = read([
          event([
            'UID:all-day',
            'DTSTART;VALUE=DATE:20261109',
            'RRULE:FREQ=DAILY;UNTIL=$limit',
          ]),
        ]);
        expect(days(feed, Day(2026, 11, 1), Day(2026, 11, 30)), [
          '2026-11-09',
          '2026-11-10',
          '2026-11-11',
        ]);
      }
    });

    test('an UNTIL in UTC limits a series without a zone in device time', () {
      List<String> on(int hours) => days(
            read(
              [
                event([
                  'UID:floating',
                  'DTSTART:20261109T100000',
                  'RRULE:FREQ=DAILY;UNTIL=20261111T090000Z',
                ]),
              ],
              zone: fixed(hours),
            ),
            Day(2026, 11, 1),
            Day(2026, 11, 30),
          );
      expect(on(1), ['2026-11-09', '2026-11-10', '2026-11-11']);
      expect(on(0), ['2026-11-09', '2026-11-10']);
      // And one written as a local time, again inclusive.
      expect(
        ruleDays('20261109T100000', 'FREQ=DAILY;UNTIL=20261111T100000'),
        ['2026-11-09', '2026-11-10', '2026-11-11'],
      );
      expect(
        ruleDays('20261109T100000', 'FREQ=DAILY;UNTIL=20261111T095959'),
        ['2026-11-09', '2026-11-10'],
      );
    });

    test('the week start decides which weeks an every-other-week rule means',
        () {
      const rule = 'FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU';
      expect(ruleDays('19970805T090000', '$rule;WKST=MO'), [
        '1997-08-05',
        '1997-08-10',
        '1997-08-19',
        '1997-08-24',
      ]);
      expect(ruleDays('19970805T090000', '$rule;WKST=SU'), [
        '1997-08-05',
        '1997-08-17',
        '1997-08-19',
        '1997-08-31',
      ]);
    });

    test('monthly on the 31st skips the shorter months', () {
      final feed = read([
        event([
          'UID:31st',
          'DTSTART;VALUE=DATE:20260131',
          'RRULE:FREQ=MONTHLY',
        ]),
      ]);
      expect(days(feed, Day(2026, 1, 1), Day(2026, 12, 31)), [
        '2026-01-31',
        '2026-03-31',
        '2026-05-31',
        '2026-07-31',
        '2026-08-31',
        '2026-10-31',
        '2026-12-31',
      ]);
    });

    test('monthly by day number, counted from either end', () {
      expect(
        ruleDays('20260115T090000', 'FREQ=MONTHLY;BYMONTHDAY=15,-1', take: 6),
        [
          '2026-01-15',
          '2026-01-31',
          '2026-02-15',
          '2026-02-28',
          '2026-03-15',
          '2026-03-31',
        ],
      );
      expect(
        ruleDays('19970928T090000', 'FREQ=MONTHLY;BYMONTHDAY=-3', take: 6),
        [
          '1997-09-28',
          '1997-10-29',
          '1997-11-28',
          '1997-12-29',
          '1998-01-29',
          '1998-02-26',
        ],
      );
      expect(
        ruleDays('19970930T090000', 'FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1'),
        [
          '1997-09-30',
          '1997-10-01',
          '1997-10-31',
          '1997-11-01',
          '1997-11-30',
          '1997-12-01',
          '1997-12-31',
          '1998-01-01',
          '1998-01-31',
          '1998-02-01',
        ],
      );
    });

    test('monthly on the second Tuesday', () {
      expect(ruleDays('20260113T090000', 'FREQ=MONTHLY;BYDAY=2TU', take: 4), [
        '2026-01-13',
        '2026-02-10',
        '2026-03-10',
        '2026-04-14',
      ]);
    });

    test('monthly on the last Friday, and other ordinals', () {
      expect(ruleDays('20260130T090000', 'FREQ=MONTHLY;BYDAY=-1FR', take: 4), [
        '2026-01-30',
        '2026-02-27',
        '2026-03-27',
        '2026-04-24',
      ]);
      expect(ruleDays('19970905T090000', 'FREQ=MONTHLY;COUNT=10;BYDAY=1FR'), [
        '1997-09-05',
        '1997-10-03',
        '1997-11-07',
        '1997-12-05',
        '1998-01-02',
        '1998-02-06',
        '1998-03-06',
        '1998-04-03',
        '1998-05-01',
        '1998-06-05',
      ]);
      expect(ruleDays('19970922T090000', 'FREQ=MONTHLY;COUNT=6;BYDAY=-2MO'), [
        '1997-09-22',
        '1997-10-20',
        '1997-11-17',
        '1997-12-22',
        '1998-01-19',
        '1998-02-16',
      ]);
      expect(
        ruleDays(
          '19970907T090000',
          'FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU',
        ),
        [
          '1997-09-07',
          '1997-09-28',
          '1997-11-02',
          '1997-11-30',
          '1998-01-04',
          '1998-01-25',
          '1998-03-01',
          '1998-03-29',
          '1998-05-03',
          '1998-05-31',
        ],
      );
    });

    test('monthly on the last weekday (a weekday list with BYSETPOS)', () {
      expect(
        ruleDays(
          '20260130T090000',
          'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
          take: 5,
        ),
        ['2026-01-30', '2026-02-27', '2026-03-31', '2026-04-30', '2026-05-29'],
      );
      expect(
        ruleDays(
          '19970929T090000',
          'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2',
          take: 7,
        ),
        [
          '1997-09-29',
          '1997-10-30',
          '1997-11-27',
          '1997-12-30',
          '1998-01-29',
          '1998-02-26',
          '1998-03-30',
        ],
      );
      expect(
        ruleDays(
          '19970904T090000',
          'FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3',
        ),
        ['1997-09-04', '1997-10-07', '1997-11-06'],
      );
    });

    test('a plain weekday list with MONTHLY is every such weekday', () {
      expect(
        ruleDays('20261102T090000', 'FREQ=MONTHLY;INTERVAL=2;BYDAY=MO', take: 9),
        [
          '2026-11-02',
          '2026-11-09',
          '2026-11-16',
          '2026-11-23',
          '2026-11-30',
          '2027-01-04',
          '2027-01-11',
          '2027-01-18',
          '2027-01-25',
        ],
      );
    });

    test('day numbers and weekdays together narrow each other', () {
      // Friday the 13th. The start itself is no Friday the 13th and is taken
      // out, as in the standard's own example.
      expect(
        ruleDays(
          '19970902T090000',
          'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13',
          more: ['EXDATE:19970902T090000'],
          take: 5,
        ),
        ['1998-02-13', '1998-03-13', '1998-11-13', '1999-08-13', '2000-10-13'],
      );
      // The first Saturday after the first Sunday of the month.
      expect(
        ruleDays(
          '19970913T090000',
          'FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13',
          take: 6,
        ),
        [
          '1997-09-13',
          '1997-10-11',
          '1997-11-08',
          '1997-12-13',
          '1998-01-10',
          '1998-02-07',
        ],
      );
      // U.S. election day: every fourth year.
      expect(
        ruleDays(
          '19961105T090000',
          'FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;'
              'BYMONTHDAY=2,3,4,5,6,7,8',
          take: 3,
        ),
        ['1996-11-05', '2000-11-07', '2004-11-02'],
      );
    });

    test('yearly on 29 February happens in leap years only', () {
      final feed = read([
        event([
          'UID:leap',
          'DTSTART;VALUE=DATE:20240229',
          'RRULE:FREQ=YEARLY',
          'SUMMARY:Leap day',
        ]),
      ]);
      expect(days(feed, Day(2024, 1, 1), Day(2033, 12, 31)), [
        '2024-02-29',
        '2028-02-29',
        '2032-02-29',
      ]);
      expect(days(feed, Day(2025, 1, 1), Day(2027, 12, 31)), isEmpty);
      // 2100 is no leap year.
      expect(days(feed, Day(2097, 1, 1), Day(2105, 1, 1)), ['2104-02-29']);
    });

    test('yearly: a birthday, months, weekdays in a month or in the year', () {
      final birthday = read([
        event([
          'UID:birthday',
          'DTSTART;VALUE=DATE:19900704',
          'RRULE:FREQ=YEARLY',
        ]),
      ]);
      expect(days(birthday, Day(2026, 1, 1), Day(2027, 12, 31)), [
        '2026-07-04',
        '2027-07-04',
      ]);
      expect(
        ruleDays('20251127T090000', 'FREQ=YEARLY;BYMONTH=11;BYDAY=4TH', take: 3),
        ['2025-11-27', '2026-11-26', '2027-11-25'],
      );
      expect(
        ruleDays('20260115T090000', 'FREQ=YEARLY;INTERVAL=2;BYMONTH=1,7', take: 4),
        ['2026-01-15', '2026-07-15', '2028-01-15', '2028-07-15'],
      );
      expect(
        ruleDays('19970313T090000', 'FREQ=YEARLY;BYMONTH=3;BYDAY=TH', take: 7),
        [
          '1997-03-13',
          '1997-03-20',
          '1997-03-27',
          '1998-03-05',
          '1998-03-12',
          '1998-03-19',
          '1998-03-26',
        ],
      );
      expect(ruleDays('19970519T090000', 'FREQ=YEARLY;BYDAY=20MO', take: 3), [
        '1997-05-19',
        '1998-05-18',
        '1999-05-17',
      ]);
      expect(
        ruleDays('19970101T090000', 'FREQ=YEARLY;BYMONTHDAY=1,15;COUNT=6'),
        [
          '1997-01-01',
          '1997-01-15',
          '1997-02-01',
          '1997-02-15',
          '1997-03-01',
          '1997-03-15',
        ],
      );
      expect(
        ruleDays('19970310T090000', 'FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3'),
        [
          '1997-03-10',
          '1999-01-10',
          '1999-02-10',
          '1999-03-10',
          '2001-01-10',
          '2001-02-10',
          '2001-03-10',
          '2003-01-10',
          '2003-02-10',
          '2003-03-10',
        ],
      );
    });

    test('BY parts narrow a daily or weekly rule', () {
      expect(
        ruleDays('20261109T090000', 'FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR', take: 7),
        [
          '2026-11-09',
          '2026-11-10',
          '2026-11-11',
          '2026-11-12',
          '2026-11-13',
          '2026-11-16',
          '2026-11-17',
        ],
      );
      // Every day in January, written two ways.
      final yearly = ruleDays(
        '19980101T090000',
        'FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;'
            'BYDAY=SU,MO,TU,WE,TH,FR,SA',
      );
      final daily = ruleDays(
        '19980101T090000',
        'FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1',
      );
      expect(yearly.length, 93);
      expect(yearly.first, '1998-01-01');
      expect(yearly[31], '1999-01-01');
      expect(yearly.last, '2000-01-31');
      expect(daily, yearly);
    });

    test('long intervals and several days per month', () {
      expect(
        ruleDays(
          '19970910T090000',
          'FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15',
        ),
        [
          '1997-09-10',
          '1997-09-11',
          '1997-09-12',
          '1997-09-13',
          '1997-09-14',
          '1997-09-15',
          '1999-03-10',
          '1999-03-11',
          '1999-03-12',
          '1999-03-13',
        ],
      );
      expect(
        ruleDays(
          '19970901T090000',
          'FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;'
              'BYDAY=MO,WE,FR',
        ),
        [
          '1997-09-01',
          '1997-09-03',
          '1997-09-05',
          '1997-09-15',
          '1997-09-17',
          '1997-09-19',
          '1997-09-29',
          '1997-10-01',
          '1997-10-03',
          '1997-10-13',
          '1997-10-15',
          '1997-10-17',
          '1997-10-27',
          '1997-10-29',
          '1997-10-31',
          '1997-11-10',
          '1997-11-12',
          '1997-11-14',
          '1997-11-24',
          '1997-11-26',
          '1997-11-28',
          '1997-12-08',
          '1997-12-10',
          '1997-12-12',
          '1997-12-22',
        ],
      );
    });

    test('the first occurrence is shown even when the rule does not name it',
        () {
      // A Friday, repeating on Mondays.
      expect(ruleDays('20261113T090000', 'FREQ=WEEKLY;BYDAY=MO;COUNT=3'), [
        '2026-11-13',
        '2026-11-16',
        '2026-11-23',
      ]);
    });

    test('a repeating event of several days', () {
      final feed = read([
        event([
          'UID:weekend',
          'DTSTART;VALUE=DATE:20261107',
          'DTEND;VALUE=DATE:20261109',
          'RRULE:FREQ=WEEKLY',
          'SUMMARY:Weekend',
        ]),
      ]);
      expect(shown(feed, Day(2026, 11, 8), Day(2026, 11, 14)), [
        '2026-11-08 all-day Weekend',
        '2026-11-14 all-day Weekend',
      ]);
      final found = feed.occurrencesBetween(Day(2026, 11, 8), Day(2026, 11, 14));
      expect(found.first.continues, isTrue);
      expect(found.first.firstDay, Day(2026, 11, 7));
      expect(found.last.continues, isFalse);
      expect(found.last.lastDay, Day(2026, 11, 15));
    });

    test('a repeating night reaches into a window that starts the day after',
        () {
      final feed = read([
        event([
          'UID:shift',
          'DTSTART:20261101T220000',
          'DTEND:20261102T060000',
          'RRULE:FREQ=DAILY',
          'SUMMARY:Night shift',
        ]),
      ]);
      final found = feed.occurrencesBetween(Day(2026, 11, 10), Day(2026, 11, 10));
      expect([for (final o in found) moment(o.start!)], [
        '2026-11-09 22:00',
        '2026-11-10 22:00',
      ]);
      expect([for (final o in found) o.continues], [true, false]);
    });

    test('nothing before the start, nothing after the end', () {
      final feed = read([
        event([
          'UID:bounded',
          'DTSTART:20261109T100000Z',
          'RRULE:FREQ=DAILY;UNTIL=20261113T100000Z',
        ]),
      ]);
      expect(days(feed, Day(2020, 1, 1), Day(2026, 11, 8)), isEmpty);
      expect(days(feed, Day(2026, 11, 14), Day(2040, 1, 1)), isEmpty);
      expect(days(feed, Day(2026, 11, 12), Day(2040, 1, 1)), [
        '2026-11-12',
        '2026-11-13',
      ]);
      expect(feed.occurrencesBetween(sunday, monday), isEmpty);
    });

    test('a rule with parts that are not supported shows the first occurrence',
        () {
      const rules = [
        'FREQ=DAILY;BYHOUR=9,15',
        'FREQ=DAILY;BYMINUTE=30',
        'FREQ=DAILY;BYSECOND=10',
        'FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO',
        'FREQ=YEARLY;BYYEARDAY=1,100,200',
        'FREQ=HOURLY;INTERVAL=3',
        'FREQ=MINUTELY;INTERVAL=90',
        'FREQ=SECONDLY',
        'FREQ=FORTNIGHTLY',
        'INTERVAL=2',
        'FREQ=DAILY;INTERVAL=0',
        'FREQ=DAILY;INTERVAL=two',
        'FREQ=DAILY;COUNT=0',
        'FREQ=WEEKLY;BYDAY=XX',
        'FREQ=MONTHLY;BYMONTHDAY=32',
        'FREQ=YEARLY;BYMONTH=13',
        'FREQ=DAILY;UNTIL=tomorrow',
        'FREQ=YEARLY;RSCALE=CHINESE',
        'FREQ=DAILY;INTERVAL=99999999999',
        'garbage',
      ];
      final feed = read([
        for (var i = 0; i < rules.length; i++)
          event([
            'UID:unsupported-$i',
            'DTSTART:20261113T090000Z',
            'DTEND:20261113T093000Z',
            'RRULE:${rules[i]}',
            'SUMMARY:${two(i)}',
          ]),
      ]);
      expect(feed.skipped, 0);
      expect(feed.eventCount, rules.length);
      expect(shown(feed, Day(2026, 1, 1), Day(2028, 12, 31)), [
        for (var i = 0; i < rules.length; i++)
          '2026-11-13 10:00-10:30 ${two(i)}',
      ]);
    });
  });

  group('removed and added occurrences', () {
    test('EXDATE in the series zone, in UTC, and several per line', () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:weekly',
            'DTSTART;TZID=Europe/Paris:20261102T100000',
            'DTEND;TZID=Europe/Paris:20261102T110000',
            'RRULE:FREQ=WEEKLY',
            'EXDATE;TZID=Europe/Paris:20261109T100000',
            'EXDATE:20261116T090000Z,20261123T090000Z',
            'SUMMARY:Seminar',
          ]),
        ],
        zone: fixed(0),
      );
      expect(shown(feed, Day(2026, 11, 1), Day(2026, 12, 7)), [
        '2026-11-02 09:00-10:00 Seminar',
        '2026-11-30 09:00-10:00 Seminar',
        '2026-12-07 09:00-10:00 Seminar',
      ]);
    });

    test('an EXDATE only removes the occurrence at that very time', () {
      final feed = read([
        event([
          'UID:daily',
          'DTSTART:20261109T100000Z',
          'RRULE:FREQ=DAILY;COUNT=4',
          // An hour off, and so not an occurrence of this series.
          'EXDATE:20261110T110000Z',
          'EXDATE:20261111T100000Z',
        ]),
      ]);
      expect(days(feed, monday, sunday), [
        '2026-11-09',
        '2026-11-10',
        '2026-11-12',
      ]);
    });

    test('EXDATE written as dates', () {
      final allDay = read([
        event([
          'UID:all-day',
          'DTSTART;VALUE=DATE:20261109',
          'RRULE:FREQ=DAILY;COUNT=5',
          'EXDATE;VALUE=DATE:20261110,20261112',
        ]),
      ]);
      expect(days(allDay, monday, sunday), [
        '2026-11-09',
        '2026-11-11',
        '2026-11-13',
      ]);
      final timed = read([
        event([
          'UID:timed',
          'DTSTART:20261109T100000Z',
          'RRULE:FREQ=DAILY;COUNT=5',
          'EXDATE;VALUE=DATE:20261110',
        ]),
      ]);
      expect(days(timed, monday, sunday), [
        '2026-11-09',
        '2026-11-11',
        '2026-11-12',
        '2026-11-13',
      ]);
    });

    test('COUNT counts occurrences before any are removed', () {
      final feed = read([
        event([
          'UID:counted',
          'DTSTART;VALUE=DATE:20261101',
          'RRULE:FREQ=DAILY;COUNT=3',
          'EXDATE;VALUE=DATE:20261102',
        ]),
      ]);
      expect(days(feed, Day(2026, 11, 1), Day(2026, 11, 30)), [
        '2026-11-01',
        '2026-11-03',
      ]);
    });

    test('removing the first occurrence', () {
      final feed = read([
        event([
          'UID:first-out',
          'DTSTART:20261109T100000Z',
          'RRULE:FREQ=DAILY;COUNT=3',
          'EXDATE:20261109T100000Z',
        ]),
        event([
          'UID:single-out',
          'DTSTART:20261109T120000Z',
          'EXDATE:20261109T120000Z',
        ]),
      ]);
      expect(days(feed, monday, sunday), ['2026-11-10', '2026-11-11']);
    });

    test('RDATE adds occurrences, as times or dates, without doubling', () {
      final feed = read([
        event([
          'UID:extra',
          'DTSTART:20261102T100000Z',
          'DTEND:20261102T110000Z',
          'RRULE:FREQ=WEEKLY;COUNT=2',
          // The 9th is the rule's own second occurrence.
          'RDATE:20261105T100000Z,20261109T100000Z',
          'RDATE;VALUE=DATE:20261112',
          'RDATE;VALUE=PERIOD:20261120T100000Z/PT1H',
          'EXDATE:20261105T100000Z',
          'RDATE:20261106T150000Z',
          'SUMMARY:Extra',
        ]),
      ]);
      expect(shown(feed, Day(2026, 11, 1), Day(2026, 11, 30)), [
        '2026-11-02 11:00-12:00 Extra',
        '2026-11-06 16:00-17:00 Extra',
        '2026-11-09 11:00-12:00 Extra',
        '2026-11-12 11:00-12:00 Extra',
      ]);
      expect(feed.eventCount, 1);
    });

    test('RDATE without a rule', () {
      final feed = read([
        event([
          'UID:dates',
          'DTSTART;VALUE=DATE:20261102',
          'RDATE;VALUE=DATE:20261110,20261125',
          'RDATE;VALUE=DATE:20261102',
          'SUMMARY:Bin collection',
        ]),
      ]);
      expect(days(feed, Day(2026, 11, 1), Day(2026, 11, 30)), [
        '2026-11-02',
        '2026-11-10',
        '2026-11-25',
      ]);
    });
  });

  group('changed instances', () {
    List<String> series({String zone = 'TZID=Europe/Paris'}) => event([
          'UID:meeting@example.org',
          'DTSTART;$zone:20261102T100000',
          'DTEND;$zone:20261102T110000',
          'RRULE:FREQ=WEEKLY',
          'SUMMARY:Team meeting',
        ]);

    test('an override moves one instance to another day and renames it', () {
      final feed = read(
        [
          parisZone,
          // Before its series in the file, as feeds may have it.
          event([
            'UID:meeting@example.org',
            'RECURRENCE-ID;TZID=Europe/Paris:20261109T100000',
            'DTSTART;TZID=Europe/Paris:20261110T140000',
            'DTEND;TZID=Europe/Paris:20261110T153000',
            'SUMMARY:Team meeting (moved)',
            'LOCATION:Room 4',
          ]),
          series(),
        ],
        zone: paris,
      );
      expect(shown(feed, Day(2026, 11, 2), Day(2026, 11, 22)), [
        '2026-11-02 10:00-11:00 Team meeting',
        '2026-11-10 14:00-15:30 Team meeting (moved)',
        '2026-11-16 10:00-11:00 Team meeting',
      ]);
      final moved = feed.occurrencesBetween(Day(2026, 11, 10), Day(2026, 11, 10));
      expect(moved.single.location, 'Room 4');
      expect(moved.single.uid, 'meeting@example.org');
      expect(feed.eventCount, 1);
      expect(feed.skipped, 0);
    });

    test('the instance may be named in UTC while the series has a zone', () {
      final feed = read(
        [
          parisZone,
          series(),
          event([
            'UID:meeting@example.org',
            'RECURRENCE-ID:20261116T090000Z',
            'DTSTART:20261116T100000Z',
            'DTEND:20261116T110000Z',
            'SUMMARY:An hour later',
          ]),
        ],
        zone: paris,
      );
      expect(shown(feed, Day(2026, 11, 9), Day(2026, 11, 22)), [
        '2026-11-09 10:00-11:00 Team meeting',
        '2026-11-16 11:00-12:00 An hour later',
      ]);
    });

    test('a cancelled override makes the instance disappear', () {
      final feed = read(
        [
          parisZone,
          series(),
          event([
            'UID:meeting@example.org',
            'RECURRENCE-ID;TZID=Europe/Paris:20261109T100000',
            'DTSTART;TZID=Europe/Paris:20261109T100000',
            'DTEND;TZID=Europe/Paris:20261109T110000',
            'STATUS:CANCELLED',
            'SUMMARY:Team meeting',
          ]),
        ],
        zone: paris,
      );
      expect(days(feed, Day(2026, 11, 2), Day(2026, 11, 22)), [
        '2026-11-02',
        '2026-11-16',
      ]);
      expect(feed.eventCount, 1);
    });

    test('of several versions of one override the latest counts', () {
      List<String> version(int sequence, String hour) => event([
            'UID:meeting@example.org',
            'RECURRENCE-ID;TZID=Europe/Paris:20261109T100000',
            'DTSTART;TZID=Europe/Paris:20261109T${hour}0000',
            'SEQUENCE:$sequence',
            'SUMMARY:Version $sequence',
          ]);
      final feed = read(
        [parisZone, version(1, '12'), version(3, '16'), version(2, '14'), series()],
        zone: paris,
      );
      expect(shown(feed, Day(2026, 11, 9), Day(2026, 11, 15)), [
        '2026-11-09 16:00-16:00 Version 3',
      ]);
    });

    test('an override whose series is missing stands as a single event', () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:gone@example.org',
            'RECURRENCE-ID;TZID=Europe/Paris:20261109T100000',
            'DTSTART;TZID=Europe/Paris:20261110T140000',
            'DTEND;TZID=Europe/Paris:20261110T150000',
            'SUMMARY:Left over',
          ]),
        ],
        zone: paris,
      );
      expect(shown(feed, Day(2026, 1, 1), Day(2027, 12, 31)), [
        '2026-11-10 14:00-15:00 Left over',
      ]);
      expect(feed.eventCount, 1);
    });

    test('an all-day series with a changed day', () {
      final feed = read([
        event([
          'UID:market',
          'DTSTART;VALUE=DATE:20261107',
          'RRULE:FREQ=WEEKLY',
          'SUMMARY:Market',
        ]),
        event([
          'UID:market',
          'RECURRENCE-ID;VALUE=DATE:20261114',
          'DTSTART;VALUE=DATE:20261115',
          'SUMMARY:Market (Sunday)',
        ]),
      ]);
      expect(shown(feed, Day(2026, 11, 7), Day(2026, 11, 21)), [
        '2026-11-07 all-day Market',
        '2026-11-15 all-day Market (Sunday)',
        '2026-11-21 all-day Market',
      ]);
    });

    test('cancelled events are not shown and not counted', () {
      final feed = read([
        event([
          'UID:off',
          'DTSTART:20261113T090000Z',
          'STATUS:CANCELLED',
          'SUMMARY:Called off',
        ]),
        event([
          'UID:off-series',
          'DTSTART:20261109T090000Z',
          'RRULE:FREQ=DAILY',
          'STATUS:cancelled',
          'SUMMARY:Called off for good',
        ]),
        event([
          'UID:on',
          'DTSTART:20261113T110000Z',
          'STATUS:CONFIRMED',
          'SUMMARY:Still on',
        ]),
        event([
          'UID:maybe',
          'DTSTART:20261113T130000Z',
          'STATUS:TENTATIVE',
          'SUMMARY:Perhaps',
        ]),
      ]);
      expect(shown(feed, monday, sunday), [
        '2026-11-13 12:00-12:00 Still on',
        '2026-11-13 14:00-14:00 Perhaps',
      ]);
      expect(feed.eventCount, 2);
      expect(feed.skipped, 0);
    });
  });

  group('time zones', () {
    final standup = event([
      'UID:standup',
      'DTSTART;TZID=Europe/Paris:20260316T100000',
      'DTEND;TZID=Europe/Paris:20260316T104500',
      'RRULE:FREQ=WEEKLY',
      'SUMMARY:Standup',
    ]);

    test('a series keeps its wall time across the March and October changes',
        () {
      // Seen from a device that has no summer time: the meeting stays at ten
      // in Paris, and so moves by an hour here.
      final feed = read([parisZone, standup], zone: fixed(0));
      expect(shown(feed, Day(2026, 3, 16), Day(2026, 4, 5)), [
        '2026-03-16 09:00-09:45 Standup',
        '2026-03-23 09:00-09:45 Standup',
        '2026-03-30 08:00-08:45 Standup',
      ]);
      expect(shown(feed, Day(2026, 10, 19), Day(2026, 11, 1)), [
        '2026-10-19 08:00-08:45 Standup',
        '2026-10-26 09:00-09:45 Standup',
      ]);
      // Years on, the rule still holds: 2031 changes on 30 March.
      expect(shown(feed, Day(2031, 3, 24), Day(2031, 4, 6)), [
        '2031-03-24 09:00-09:45 Standup',
        '2031-03-31 08:00-08:45 Standup',
      ]);
    });

    test('seen from Paris itself it is always at ten', () {
      // The zone is defined after the event that uses it.
      final feed = read([standup, parisZone], zone: paris);
      final found = feed.occurrencesBetween(Day(2026, 3, 16), Day(2027, 3, 14));
      expect(found.length, 52);
      for (final o in found) {
        expect(clock(o.start!), '10:00');
        expect(clock(o.end!), '10:45');
        expect(o.day.weekday, DateTime.monday);
      }
    });

    test('an EXDATE in summer time meets its occurrence', () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:standup',
            'DTSTART;TZID=Europe/Paris:20260316T100000',
            'RRULE:FREQ=WEEKLY',
            'EXDATE:20260706T080000Z',
            'EXDATE;TZID=Europe/Paris:20260713T100000',
          ]),
        ],
        zone: fixed(0),
      );
      expect(days(feed, Day(2026, 6, 29), Day(2026, 7, 26)), [
        '2026-06-29',
        '2026-07-20',
      ]);
    });

    test('the offset on the days the clocks change', () {
      List<String> at(String wall) => event([
            'UID:$wall',
            'DTSTART;TZID=Europe/Paris:$wall',
            'SUMMARY:$wall',
          ]);
      final feed = read(
        [
          parisZone,
          at('20260329T013000'),
          at('20260329T033000'),
          at('20261025T013000'),
          at('20261025T023000'),
          at('20261025T033000'),
          at('19690601T120000'),
        ],
        zone: fixed(10),
      );
      String startOf(String wall) => moment(feed
          .occurrencesBetween(Day(1969, 1, 1), Day(2027, 1, 1))
          .firstWhere((o) => o.title == wall)
          .start!);
      // 01:30 is still winter time (00:30 UTC), 03:30 already summer time.
      expect(startOf('20260329T013000'), '2026-03-29 10:30');
      expect(startOf('20260329T033000'), '2026-03-29 11:30');
      // 01:30 is still summer time; 02:30 happens twice and is taken as its
      // first pass; 03:30 is winter time.
      expect(startOf('20261025T013000'), '2026-10-25 09:30');
      expect(startOf('20261025T023000'), '2026-10-25 10:30');
      expect(startOf('20261025T033000'), '2026-10-25 12:30');
      // Before the first change the zone names: the offset it changed from.
      expect(startOf('19690601T120000'), '1969-06-01 21:00');
    });

    test('a time in the skipped hour does not throw', () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:gap',
            'DTSTART;TZID=Europe/Paris:20260329T023000',
            'DTEND;TZID=Europe/Paris:20260329T024500',
            'RRULE:FREQ=YEARLY',
            'SUMMARY:In the gap',
          ]),
        ],
        zone: fixed(10),
      );
      final o = feed.occurrencesBetween(Day(2026, 3, 29), Day(2026, 3, 29)).single;
      expect(clock(o.start!), anyOf('10:30', '11:30'));
      expect(feed.skipped, 0);
    });

    test('a zone listing its changes one by one, and the time before them', () {
      final feed = read(
        [
          [
            'BEGIN:VTIMEZONE',
            'TZID:Test/Listed',
            'BEGIN:DAYLIGHT',
            'TZOFFSETFROM:-0800',
            'TZOFFSETTO:-0700',
            'DTSTART:20260308T020000',
            'RDATE:20260308T020000,20270314T020000',
            'END:DAYLIGHT',
            'BEGIN:STANDARD',
            'TZOFFSETFROM:-0700',
            'TZOFFSETTO:-0800',
            'DTSTART:20261101T020000',
            'RDATE:20261101T020000',
            'RDATE:20271107T020000',
            'END:STANDARD',
            'END:VTIMEZONE',
          ],
          for (final day in ['20260201', '20260701', '20261201', '20270701'])
            event([
              'UID:$day',
              'DTSTART;TZID=Test/Listed:${day}T120000',
              'SUMMARY:$day',
            ]),
        ],
        zone: fixed(0),
      );
      expect(shown(feed, Day(2026, 1, 1), Day(2027, 12, 31)), [
        '2026-02-01 20:00-20:00 20260201',
        '2026-07-01 19:00-19:00 20260701',
        '2026-12-01 20:00-20:00 20261201',
        '2027-07-01 19:00-19:00 20270701',
      ]);
    });

    test('a zone with a single change, and offsets with minutes', () {
      final feed = read(
        [
          [
            'BEGIN:VTIMEZONE',
            'TZID:Asia/Kolkata',
            'BEGIN:STANDARD',
            'TZOFFSETFROM:+0553',
            'TZOFFSETTO:+0530',
            'DTSTART:19451015T000000',
            'END:STANDARD',
            'END:VTIMEZONE',
          ],
          event([
            'UID:delhi',
            'DTSTART;TZID=Asia/Kolkata:20261113T173000',
            'DTEND;TZID=Asia/Kolkata:20261113T190000',
            'SUMMARY:Call Delhi',
          ]),
        ],
        zone: fixed(0),
      );
      expect(shown(feed, monday, sunday), ['2026-11-13 12:00-13:30 Call Delhi']);
    });

    test('rules that ended give way to the ones that followed', () {
      // Los Angeles: summer time began on the first Sunday of April until
      // 2006 and on the second Sunday of March from 2007.
      final feed = read(
        [
          [
            'BEGIN:VTIMEZONE',
            'TZID:America/Los_Angeles',
            'BEGIN:DAYLIGHT',
            'TZOFFSETFROM:-0800',
            'TZOFFSETTO:-0700',
            'DTSTART:19870405T020000',
            'RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU;UNTIL=20060402T100000Z',
            'END:DAYLIGHT',
            'BEGIN:DAYLIGHT',
            'TZOFFSETFROM:-0800',
            'TZOFFSETTO:-0700',
            'DTSTART:20070311T020000',
            'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU',
            'END:DAYLIGHT',
            'BEGIN:STANDARD',
            'TZOFFSETFROM:-0700',
            'TZOFFSETTO:-0800',
            'DTSTART:19671029T020000',
            'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=20061029T090000Z',
            'END:STANDARD',
            'BEGIN:STANDARD',
            'TZOFFSETFROM:-0700',
            'TZOFFSETTO:-0800',
            'DTSTART:20071104T020000',
            'RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU',
            'END:STANDARD',
            'END:VTIMEZONE',
          ],
          for (final day in [
            '20050320', // winter time under the old rule, summer under the new
            '20050410',
            '20060402', // the old rule's last change, at its UNTIL
            '20061030',
            '20070312',
            '20071101', // still summer time under the new rule
            '20071105',
            '20260320',
            '20261110',
          ])
            event([
              'UID:$day',
              'DTSTART;TZID=America/Los_Angeles:${day}T120000',
              'SUMMARY:$day',
            ]),
        ],
        zone: fixed(0),
      );
      expect(
        [
          for (final o in feed.occurrencesBetween(Day(2005, 1, 1), Day(2027, 1, 1)))
            '${o.title} ${clock(o.start!)}',
        ],
        [
          '20050320 20:00',
          '20050410 19:00',
          '20060402 19:00',
          '20061030 20:00',
          '20070312 19:00',
          '20071101 19:00',
          '20071105 20:00',
          '20260320 19:00',
          '20261110 20:00',
        ],
      );
    });

    test('a TZID the feed does not define is the device clock', () {
      for (final hours in [-8, 0, 9]) {
        final feed = read(
          [
            event([
              'UID:unknown',
              'DTSTART;TZID=Mars/Olympus_Mons:20261113T100000',
              'DTEND;TZID=Mars/Olympus_Mons:20261113T110000',
              'RRULE:FREQ=DAILY;COUNT=2',
              'SUMMARY:Unknown zone',
            ]),
          ],
          zone: fixed(hours),
        );
        expect(shown(feed, monday, sunday), [
          '2026-11-13 10:00-11:00 Unknown zone',
          '2026-11-14 10:00-11:00 Unknown zone',
        ]);
      }
    });

    test('a TZID that names UTC needs no definition', () {
      final feed = read(
        [
          event([
            'UID:utc',
            'DTSTART;TZID=UTC:20261113T100000',
            'DTEND;TZID=Etc/UTC:20261113T110000',
          ]),
        ],
        zone: fixed(5),
      );
      final o = feed.occurrencesBetween(friday, friday).single;
      expect(clock(o.start!), '15:00');
      expect(clock(o.end!), '16:00');
    });

    test('start and end in different zones', () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:flight',
            'DTSTART;TZID=Europe/Paris:20261113T100000',
            'DTEND:20261113T180000Z',
            'RRULE:FREQ=DAILY;COUNT=2',
            'SUMMARY:Flight',
          ]),
        ],
        zone: fixed(0),
      );
      expect(shown(feed, monday, sunday), [
        '2026-11-13 09:00-18:00 Flight',
        '2026-11-14 09:00-18:00 Flight',
      ]);
    });

    test('a daily event after midnight in Paris is the evening before in UTC',
        () {
      final feed = read(
        [
          parisZone,
          event([
            'UID:early',
            'DTSTART;TZID=Europe/Paris:20261110T003000',
            'DTEND;TZID=Europe/Paris:20261110T010000',
            'RRULE:FREQ=DAILY;COUNT=3',
            'SUMMARY:Backup',
          ]),
        ],
        zone: fixed(0),
      );
      expect(shown(feed, monday, sunday), [
        '2026-11-09 23:30-00:00 Backup',
        '2026-11-10 23:30-00:00 Backup',
        '2026-11-11 23:30-00:00 Backup',
      ]);
      // The window is in device days: the 9th is in it although the series
      // starts on the 10th by its own clock.
      expect(days(feed, monday, monday), ['2026-11-09']);
      expect(days(feed, Day(2026, 11, 12), sunday), isEmpty);
    });

    test('the real device zone agrees with the platform on every day of a year',
        () {
      // Whatever zone the tests run in, its clock changes included: each
      // time must be the very one the platform gives, on the platform's day.
      final feed = IcsCalendar.parse(feedText([
        for (final time in ['0030', '0130', '0230', '1200', '2330'])
          event([
            'UID:utc-$time',
            'DTSTART:20260101T${time}00Z',
            'DTEND:20260101T${time}30Z',
            'RRULE:FREQ=DAILY;COUNT=365',
            'SUMMARY:$time',
          ]),
      ]));
      final found = feed.occurrencesBetween(Day(2025, 12, 30), Day(2027, 1, 2));
      final starts = {
        for (final o in found.where((o) => !o.continues))
          '${o.title} ${o.start!.toUtc().toIso8601String()}': o,
      };
      expect(starts.length, 5 * 365);
      for (var day = 0; day < 365; day++) {
        for (final time in ['0030', '0130', '0230', '1200', '2330']) {
          final utc = DateTime.utc(
            2026,
            1,
            1 + day,
            int.parse(time.substring(0, 2)),
            int.parse(time.substring(2)),
          );
          final o = starts['$time ${utc.toIso8601String()}']!;
          expect(o.start, utc.toLocal());
          expect(o.start!.isUtc, isFalse);
          expect(o.end, utc.add(const Duration(seconds: 30)).toLocal());
          expect(o.day, Day.fromDateTime(utc.toLocal()));
          expect(o.firstDay, o.day);
        }
      }
    });

    test('times without a zone are the real device clock on every day', () {
      final feed = IcsCalendar.parse(feedText([
        for (final time in ['0030', '0230', '1200', '2330'])
          event([
            'UID:floating-$time',
            'DTSTART:20260101T${time}00',
            'DURATION:PT20M',
            'RRULE:FREQ=DAILY;COUNT=365',
            'SUMMARY:$time',
          ]),
      ]));
      final found = feed.occurrencesBetween(Day(2026, 1, 1), Day(2026, 12, 31));
      expect(found.length, 4 * 365);
      for (final o in found) {
        expect(o.start!.isUtc, isFalse);
        final wanted = DateTime(
          o.day.year,
          o.day.month,
          o.day.day,
          int.parse(o.title.substring(0, 2)),
          int.parse(o.title.substring(2)),
        );
        // Compared as clock fields: where the machine's zone repeats an
        // hour, either pass is a right answer; where it skips one, the
        // platform's own answer is passed on.
        expect(moment(o.start!), moment(wanted));
        expect(moment(o.end!), moment(wanted.add(const Duration(minutes: 20))));
      }
    });

    test('without a function the device zone of the machine is used', () {
      final feed = IcsCalendar.parse(feedText([
        event([
          'UID:default',
          'DTSTART:20261113T110000Z',
          'DTEND:20261113T120000Z',
        ]),
      ]));
      final first = Day(2026, 11, 12);
      final o = feed.occurrencesBetween(first, first.addDays(2)).single;
      expect(o.start, DateTime.utc(2026, 11, 13, 11).toLocal());
      expect(o.end, DateTime.utc(2026, 11, 13, 12).toLocal());
      expect(o.start!.isUtc, isFalse);
      expect(o.day, Day.fromDateTime(o.start!));
    });
  });

  group('order', () {
    test('by day, all-day first, then start time, then title', () {
      final feed = read([
        event(['UID:1', 'DTSTART:20261113T090000', 'SUMMARY:b at nine']),
        event(['UID:2', 'DTSTART;VALUE=DATE:20261113', 'SUMMARY:Zeta']),
        event(['UID:3', 'DTSTART:20261113T090000', 'SUMMARY:A at nine']),
        event(['UID:4', 'DTSTART:20261114T070000', 'SUMMARY:Tomorrow']),
        event(['UID:5', 'DTSTART:20261113T080000', 'SUMMARY:Listed late']),
        event(['UID:6', 'DTSTART;VALUE=DATE:20261113', 'SUMMARY:alpha']),
        event([
          'UID:7',
          'DTSTART:20261112T230000',
          'DTEND:20261113T100000',
          'SUMMARY:Overnight',
        ]),
        event([
          'UID:8',
          'DTSTART;VALUE=DATE:20261111',
          'DTEND;VALUE=DATE:20261114',
          'SUMMARY:Trip',
        ]),
        event(['UID:9', 'DTSTART:20261112T120000', 'SUMMARY:Yesterday']),
      ]);
      expect(shown(feed, Day(2026, 11, 12), Day(2026, 11, 14)), [
        '2026-11-12 all-day Trip',
        '2026-11-12 12:00-12:00 Yesterday',
        '2026-11-12 23:00-10:00 Overnight',
        '2026-11-13 all-day Trip',
        '2026-11-13 all-day alpha',
        '2026-11-13 all-day Zeta',
        '2026-11-13 23:00-10:00 Overnight',
        '2026-11-13 08:00-08:00 Listed late',
        '2026-11-13 09:00-09:00 A at nine',
        '2026-11-13 09:00-09:00 b at nine',
        '2026-11-14 07:00-07:00 Tomorrow',
      ]);
    });
  });

  group('speed and safety', () {
    test('a far-future window on an endless daily series from years ago', () {
      final feed = read([
        event([
          'UID:endless',
          'DTSTART:20100101T080000Z',
          'DTEND:20100101T083000Z',
          'RRULE:FREQ=DAILY;INTERVAL=3',
          'SUMMARY:Every third day',
        ]),
      ]);
      final start = Day(2010, 1, 1);
      final first = Day(2090, 6, 1);
      final watch = Stopwatch()..start();
      final found = feed.occurrencesBetween(first, first.addDays(41));
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(250));
      expect(found.length, 14);
      expect([for (final o in found.take(4)) o.day.iso], [
        '2090-06-03',
        '2090-06-06',
        '2090-06-09',
        '2090-06-12',
      ]);
      for (final o in found) {
        expect(o.day.difference(start) % 3, 0);
        expect(clock(o.start!), '09:00');
      }
    });

    test('far-future windows on weekly, monthly and yearly series', () {
      List<String> far(String start, String rule, Day first, Day last) => days(
            read([
              event(['UID:far', 'DTSTART;VALUE=DATE:$start', 'RRULE:$rule']),
            ]),
            first,
            last,
          );
      expect(
        far(
          '20010105',
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR',
          Day(2090, 6, 1),
          Day(2090, 7, 12),
        ),
        [
          '2090-06-05',
          '2090-06-09',
          '2090-06-19',
          '2090-06-23',
          '2090-07-03',
          '2090-07-07',
        ],
      );
      expect(
        far('20010105', 'FREQ=MONTHLY;BYDAY=-1FR', Day(2090, 6, 1), Day(2090, 6, 30)),
        ['2090-06-30'],
      );
      expect(
        far('20010131', 'FREQ=MONTHLY;INTERVAL=5', Day(2090, 1, 1), Day(2091, 12, 31)),
        ['2090-03-31', '2090-08-31', '2091-01-31'],
      );
      expect(
        far('20000229', 'FREQ=YEARLY', Day(2088, 1, 1), Day(2109, 12, 31)),
        ['2088-02-29', '2092-02-29', '2096-02-29', '2104-02-29', '2108-02-29'],
      );
    });

    test('ten thousand events and hundreds of series stay quick to query', () {
      final origin = Day(2015, 1, 1);
      String stamp(Day day) =>
          '${day.year}${two(day.month)}${two(day.day)}';
      final text = feedText([
        parisZone,
        for (var i = 0; i < 10000; i++)
          event([
            'UID:single-$i',
            'DTSTART:${stamp(origin.addDays(i % 5800))}T120000Z',
            'DTEND:${stamp(origin.addDays(i % 5800))}T130000Z',
            'SUMMARY:Single $i',
          ]),
        for (var i = 0; i < 300; i++)
          event([
            'UID:series-$i',
            // 5 January 2015 was a Monday.
            'DTSTART;TZID=Europe/Paris:20150105T100000',
            'DTEND;TZID=Europe/Paris:20150105T110000',
            'RRULE:FREQ=WEEKLY',
            'SUMMARY:Series $i',
          ]),
      ]);
      final parsing = Stopwatch()..start();
      final feed = IcsCalendar.parse(text, toLocal: plusOne);
      parsing.stop();
      expect(feed.eventCount, 10300);
      expect(feed.skipped, 0);
      expect(parsing.elapsedMilliseconds, lessThan(10000));

      // Days 0..4199 hold two single events each, later ones one; every week
      // holds each series once.
      final week = feed.occurrencesBetween(
        origin.addDays(100),
        origin.addDays(106),
      );
      expect(week.length, 14 + 300);
      final late = feed.occurrencesBetween(
        origin.addDays(5000),
        origin.addDays(5006),
      );
      expect(late.length, 7 + 300);

      final querying = Stopwatch()..start();
      var total = 0;
      for (var i = 0; i < 100; i++) {
        final first = origin.addDays(i * 37);
        total += feed.occurrencesBetween(first, first.addDays(41)).length;
      }
      querying.stop();
      expect(total, greaterThan(100 * 6 * 300));
      expect(querying.elapsedMilliseconds, lessThan(5000));
    });

    test('rules that never match, or match for ever, do not hang', () {
      final feed = read([
        event([
          'UID:never',
          'DTSTART;VALUE=DATE:20200101',
          // There is no 30 February to count.
          'RRULE:FREQ=DAILY;COUNT=10;BYMONTH=2;BYMONTHDAY=30',
          'SUMMARY:Never again',
        ]),
        event([
          'UID:never-open',
          'DTSTART;VALUE=DATE:20200102',
          'RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30',
          'SUMMARY:Never again, for ever',
        ]),
        event([
          'UID:sparse',
          'DTSTART;VALUE=DATE:20200103',
          'RRULE:FREQ=YEARLY;INTERVAL=100000',
          'SUMMARY:Once in a hundred thousand years',
        ]),
        event([
          'UID:counted',
          'DTSTART;VALUE=DATE:20200104',
          'RRULE:FREQ=DAILY;COUNT=999999999',
          'SUMMARY:Counted',
        ]),
        event([
          'UID:open',
          'DTSTART;VALUE=DATE:20200104',
          'RRULE:FREQ=DAILY',
          'SUMMARY:Open',
        ]),
      ]);
      final watch = Stopwatch()..start();
      expect(shown(feed, Day(2020, 1, 1), Day(2020, 1, 5)), [
        '2020-01-01 all-day Never again',
        '2020-01-02 all-day Never again, for ever',
        '2020-01-03 all-day Once in a hundred thousand years',
        '2020-01-04 all-day Counted',
        '2020-01-04 all-day Open',
        '2020-01-05 all-day Counted',
        '2020-01-05 all-day Open',
      ]);
      expect(shown(feed, Day(2090, 6, 1), Day(2090, 6, 2)), [
        '2090-06-01 all-day Counted',
        '2090-06-01 all-day Open',
        '2090-06-02 all-day Counted',
        '2090-06-02 all-day Open',
      ]);
      // Neither an absurd COUNT nor a window of five centuries is walked to
      // its end: both are cut short.
      final wide = feed.occurrencesBetween(Day(1990, 1, 1), Day(2490, 1, 1));
      watch.stop();
      int count(String title) => wide.where((o) => o.title == title).length;
      expect(count('Counted'), inInclusiveRange(10000, 100000));
      expect(count('Open'), inInclusiveRange(10000, 100000));
      expect(count('Never again'), 1);
      expect(watch.elapsedMilliseconds, lessThan(10000));
    });

    test('a parsed feed can be handed over from another isolate', () async {
      final text = feedText([
        parisZone,
        event([
          'UID:weekly',
          'DTSTART;TZID=Europe/Paris:20261102T100000',
          'DTEND;TZID=Europe/Paris:20261102T110000',
          'RRULE:FREQ=WEEKLY;UNTIL=20261221T225959Z',
          'EXDATE;TZID=Europe/Paris:20261116T100000',
          'SUMMARY:Weekly',
        ]),
        event([
          'UID:counted',
          'DTSTART:20261110T180000',
          'RRULE:FREQ=DAILY;COUNT=3',
          'SUMMARY:Counted',
        ]),
        event(['UID:day', 'DTSTART;VALUE=DATE:20261113', 'SUMMARY:Day']),
        event(['UID:utc', 'DTSTART:20261113T233000Z', 'SUMMARY:Late']),
      ]);
      final here = IcsCalendar.parse(text, toLocal: plusOne);
      final there = await parseElsewhere(text);
      final first = Day(2026, 11, 1);
      final last = Day(2026, 12, 31);
      expect(shown(there, first, last), shown(here, first, last));
      expect(shown(there, first, last), hasLength(7 + 3 + 1 + 1));
      expect(there.eventCount, 4);

      final deviceZone = await parseElsewhereInDeviceZone(text);
      expect(
        [
          for (final o in deviceZone.occurrencesBetween(first, last))
            if (o.allDay) o.day.iso,
        ],
        ['2026-11-13'],
      );
      expect(
        deviceZone
            .occurrencesBetween(first, last)
            .firstWhere((o) => o.title == 'Late')
            .start,
        DateTime.utc(2026, 11, 13, 23, 30).toLocal(),
      );
    });
  });

  group('a feed as Google Calendar exports it', () {
    final text = [
      'BEGIN:VCALENDAR',
      'PRODID:-//Google Inc//Google Calendar 70.9054//EN',
      'VERSION:2.0',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      'X-WR-CALNAME:Jonas – private',
      'X-WR-TIMEZONE:Europe/Paris',
      'X-WR-CALDESC:Everything that is not work',
      ...parisZone,
      'BEGIN:VEVENT',
      'DTSTART;TZID=Europe/Paris:20260907T183000',
      'DTEND;TZID=Europe/Paris:20260907T200000',
      'RRULE:FREQ=WEEKLY;WKST=MO;UNTIL=20261221T225959Z;BYDAY=MO',
      'EXDATE;TZID=Europe/Paris:20261116T183000',
      'DTSTAMP:20261113T101500Z',
      'UID:4k2j0c9t5h7m1q8r3s6v0a2b4d@google.com',
      'CREATED:20260901T070000Z',
      'DESCRIPTION:Bring shoes and chalk.\\nHall B this term\\, not A; the entr',
      ' ance is on the side of the building.',
      'LAST-MODIFIED:20261101T120000Z',
      'LOCATION:Gymnase Berthe de Boissieux\\, Grenoble',
      'SEQUENCE:1',
      'STATUS:CONFIRMED',
      'SUMMARY:Climbing',
      'TRANSP:OPAQUE',
      'BEGIN:VALARM',
      'ACTION:DISPLAY',
      'DESCRIPTION:This is an event reminder',
      'TRIGGER:-P0DT0H30M0S',
      'END:VALARM',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'DTSTART;TZID=Europe/Paris:20261111T170000',
      'DTEND;TZID=Europe/Paris:20261111T183000',
      'DTSTAMP:20261113T101500Z',
      'UID:4k2j0c9t5h7m1q8r3s6v0a2b4d@google.com',
      'RECURRENCE-ID;TZID=Europe/Paris:20261109T183000',
      'CREATED:20260901T070000Z',
      'DESCRIPTION:',
      'LAST-MODIFIED:20261108T190000Z',
      'LOCATION:Espace Vertical',
      'SEQUENCE:2',
      'STATUS:CONFIRMED',
      'SUMMARY:Climbing (Wednesday this week)',
      'TRANSP:OPAQUE',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'DTSTART:20261113T140000Z',
      'DTEND:20261113T150000Z',
      'DTSTAMP:20261113T101500Z',
      'UID:7pq1r5n9c3b8d2f6g0h4j7k1m3@google.com',
      'CREATED:20261020T083000Z',
      'DESCRIPTION:',
      'LAST-MODIFIED:20261020T083000Z',
      'LOCATION:',
      'SEQUENCE:0',
      'STATUS:CONFIRMED',
      'SUMMARY:Dentist',
      'TRANSP:OPAQUE',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'DTSTART:20261114T193000Z',
      'DTEND:20261114T230000Z',
      'DTSTAMP:20261113T101500Z',
      'UID:2a4c6e8g0i2k4m6o8q0s2u4w6y@google.com',
      'SEQUENCE:0',
      'STATUS:CONFIRMED',
      'SUMMARY:Dinner at Léa\'s',
      'TRANSP:OPAQUE',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'DTSTART;VALUE=DATE:20261112',
      'DTEND;VALUE=DATE:20261114',
      'DTSTAMP:20261113T101500Z',
      'UID:9z8y7x6w5v4u3t2s1r0q9p8o7n@google.com',
      'SEQUENCE:0',
      'STATUS:CONFIRMED',
      'SUMMARY:Conference',
      'TRANSP:TRANSPARENT',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'DTSTART:20261112T080000Z',
      'DTEND:20261112T090000Z',
      'DTSTAMP:20261113T101500Z',
      'UID:1b3d5f7h9j1l3n5p7r9t1v3x5z@google.com',
      'SEQUENCE:3',
      'STATUS:CANCELLED',
      'SUMMARY:Breakfast meeting',
      'TRANSP:OPAQUE',
      'END:VEVENT',
      'END:VCALENDAR',
      '',
    ].join('\r\n');

    final feed = IcsCalendar.parse(text, toLocal: paris);

    test('its name and its events are read', () {
      expect(feed.name, 'Jonas – private');
      expect(feed.eventCount, 4);
      expect(feed.skipped, 0);
    });

    test('a week with a moved instance, UTC events and an all-day event', () {
      expect(shown(feed, monday, sunday), [
        '2026-11-11 17:00-18:30 Climbing (Wednesday this week)',
        '2026-11-12 all-day Conference',
        '2026-11-13 all-day Conference',
        '2026-11-13 15:00-16:00 Dentist',
        '2026-11-14 20:30-00:00 Dinner at Léa\'s',
      ]);
      final moved = feed.occurrencesBetween(monday, sunday).first;
      expect(moved.location, 'Espace Vertical');
      expect(moved.description, '');
    });

    test('the series through summer, its removed week and its end', () {
      expect(shown(feed, Day(2026, 8, 31), Day(2026, 9, 20)), [
        '2026-09-07 18:30-20:00 Climbing',
        '2026-09-14 18:30-20:00 Climbing',
      ]);
      expect(shown(feed, Day(2026, 11, 16), Day(2026, 11, 29)), [
        '2026-11-23 18:30-20:00 Climbing',
      ]);
      expect(shown(feed, Day(2026, 12, 14), Day(2027, 1, 31)), [
        '2026-12-14 18:30-20:00 Climbing',
        '2026-12-21 18:30-20:00 Climbing',
      ]);
      final o = feed.occurrencesBetween(Day(2026, 9, 7), Day(2026, 9, 7)).single;
      expect(o.uid, '4k2j0c9t5h7m1q8r3s6v0a2b4d@google.com');
      expect(o.location, 'Gymnase Berthe de Boissieux, Grenoble');
      expect(
        o.description,
        'Bring shoes and chalk.\nHall B this term, not A; the entrance is on '
        'the side of the building.',
      );
      expect(o.start, DateTime(2026, 9, 7, 18, 30));
      expect(o.end, DateTime(2026, 9, 7, 20));
    });
  });
}
