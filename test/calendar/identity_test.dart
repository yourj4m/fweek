import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/identity.dart';
import 'package:fweek/data/day.dart';

import 'ics_test.dart' show event, fixed, paris, parisZone, read;

void main() {
  final monday = Day(2026, 11, 9);

  List<String> weekly({String extra = ''}) => [
        'UID:standup@test',
        'SUMMARY:Stand-up',
        'DTSTART;TZID=Europe/Paris:20261102T100000',
        'DTEND;TZID=Europe/Paris:20261102T101500',
        'RRULE:FREQ=WEEKLY',
        if (extra.isNotEmpty) extra,
      ];

  group('occurrence keys', () {
    test('an event that happens once has none', () {
      final feed = read([
        event(['UID:once@test', 'SUMMARY:Once', 'DTSTART:20261110T090000Z', 'DTEND:20261110T100000Z']),
      ]);
      final found = feed.occurrencesBetween(monday, monday.addDays(6)).single;
      expect(found.instance, '');
      expect(found.recurring, isFalse);
      expect(feed.standalone.single.uid, 'once@test');
    });

    test('each occurrence of a series has its own, the same in every time zone', () {
      List<String> keys(DateTime Function(DateTime) zone) => [
            for (final o in read([parisZone, event(weekly())], zone: zone)
                .occurrencesBetween(monday, monday.addDays(13)))
              o.instance,
          ];
      final inParis = keys(paris);
      expect(inParis, hasLength(2));
      expect(inParis.toSet(), hasLength(2));
      // 10:00 in Paris on 9 November is 09:00 UTC.
      expect(inParis.first, 'U${DateTime.utc(2026, 11, 9, 9).millisecondsSinceEpoch}');
      expect(keys(fixed(-8)), inParis);
      expect(keys(fixed(9)), inParis);
      expect(read([parisZone, event(weekly())]).standalone, isEmpty);
    });

    test('an all-day series is keyed by the day', () {
      final feed = read([
        event(['UID:day@test', 'SUMMARY:Day', 'DTSTART;VALUE=DATE:20261102', 'RRULE:FREQ=WEEKLY']),
      ]);
      final found = feed.occurrencesBetween(monday, monday.addDays(6)).single;
      expect(found.instance, 'D${monday.difference(Day(1970, 1, 1))}');
    });

    test('an occurrence the calendar moved keeps the key of the one it replaces', () {
      final plain = read([parisZone, event(weekly())], zone: paris)
          .occurrencesBetween(monday, monday)
          .single;
      final feed = read([
        parisZone,
        event(weekly()),
        event([
          'UID:standup@test',
          'SUMMARY:Stand-up (moved)',
          'RECURRENCE-ID;TZID=Europe/Paris:20261109T100000',
          'DTSTART;TZID=Europe/Paris:20261111T140000',
          'DTEND;TZID=Europe/Paris:20261111T141500',
        ]),
      ], zone: paris);
      final week = feed.occurrencesBetween(monday, monday.addDays(6));
      expect(week.single.title, 'Stand-up (moved)');
      expect(week.single.day, Day(2026, 11, 11));
      expect(week.single.instance, plain.instance);
    });

    test('however the calendar writes the replaced start', () {
      String keyWith(String recurrenceId) => read([
            parisZone,
            event(weekly()),
            event([
              'UID:standup@test',
              'SUMMARY:Changed',
              recurrenceId,
              'DTSTART;TZID=Europe/Paris:20261109T110000',
              'DTEND;TZID=Europe/Paris:20261109T111500',
            ]),
          ], zone: paris)
              .occurrencesBetween(monday, monday)
              .single
              .instance;
      final zoned = keyWith('RECURRENCE-ID;TZID=Europe/Paris:20261109T100000');
      expect(keyWith('RECURRENCE-ID:20261109T090000Z'), zoned);
      expect(keyWith('RECURRENCE-ID;VALUE=DATE:20261109'), zoned);
    });

    test('dates added to an event give several occurrences, each keyed', () {
      final feed = read([
        event([
          'UID:twice@test',
          'SUMMARY:Twice',
          'DTSTART:20261110T090000Z',
          'DTEND:20261110T100000Z',
          'RDATE:20261112T090000Z',
        ]),
      ]);
      final found = feed.occurrencesBetween(monday, monday.addDays(6));
      expect(found, hasLength(2));
      expect(found.map((o) => o.instance).toSet(), hasLength(2));
      expect(found.every((o) => o.recurring), isTrue);
    });
  });

  group('fingerprints', () {
    final address = Uri.parse('https://calendar.example.com/ical/secret-0123456789abcdef/basic.ics');

    test('a calendar is named by its address without giving it away', () {
      final key = calendarKey(address);
      expect(key, hasLength(20));
      expect(key, matches(RegExp(r'^[0-9a-f]+$')));
      expect(key, isNot(contains('secret')));
      expect(calendarKey(Uri.parse('HTTPS://Calendar.Example.com/ical/secret-0123456789abcdef/basic.ics')), key);
      expect(calendarKey(Uri.parse('https://calendar.example.com/ical/other/basic.ics')), isNot(key));
    });

    test('an event is named within its calendar, per occurrence', () {
      final key = eventKey('cal-a', 'standup@test', 'U1');
      expect(key, hasLength(24));
      expect(key, isNot(contains('standup')));
      expect(eventKey('cal-a', 'standup@test', 'U1'), key);
      expect(eventKey('cal-a', 'standup@test', 'U2'), isNot(key));
      expect(eventKey('cal-b', 'standup@test', 'U1'), isNot(key));
      expect(eventKey('cal-a', 'standup@test', ''), isNot(key));
    });

    test('the later part of a split series is still the same series', () {
      expect(seriesUid('7kq2m9x4c1v8b5n3z6l0p2r4s8_R20260727@google.com'),
          '7kq2m9x4c1v8b5n3z6l0p2r4s8@google.com');
      expect(seriesUid('7kq2m9x4c1v8b5n3z6l0p2r4s8_R20260727T090000@google.com'),
          '7kq2m9x4c1v8b5n3z6l0p2r4s8@google.com');
      expect(seriesUid('abc_R20260727T090000Z'), 'abc');
      expect(seriesUid('plain_Report@example.org'), 'plain_Report@example.org');
      expect(
        eventKey('c', '7kq2m9x4c1v8b5n3z6l0p2r4s8_R20260727@google.com', 'U5'),
        eventKey('c', '7kq2m9x4c1v8b5n3z6l0p2r4s8@google.com', 'U5'),
      );
    });

    test('a calendar with unstable identifiers names events by what they say', () {
      final key = contentEventKey('c', 'Bank holiday ', 'D20000');
      expect(contentEventKey('c', 'bank holiday', 'D20000'), key);
      expect(contentEventKey('c', 'Bank holiday', 'D20001'), isNot(key));
    });
  });

  test('IcsCalendar keeps reading the reference feeds', () {
    // A guard for the parser change itself: nothing about days or times
    // moved when occurrences gained keys.
    final feed = read([parisZone, event(weekly(extra: 'EXDATE;TZID=Europe/Paris:20261116T100000'))], zone: paris);
    expect(
      [for (final o in feed.occurrencesBetween(monday, monday.addDays(20))) o.day.iso],
      ['2026-11-09', '2026-11-23'],
    );
  });
}
