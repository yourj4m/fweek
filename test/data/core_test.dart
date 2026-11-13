import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/hlc.dart';
import 'package:weektodo/data/order_key.dart';
import 'package:weektodo/data/recurrence.dart';

void main() {
  group('Day', () {
    test('round-trips ISO strings and rejects junk', () {
      expect(Day.parse('2026-11-13').iso, '2026-11-13');
      expect(Day.tryParse('13.11.2026'), isNull);
      expect(Day.tryParse(null), isNull);
    });

    test('week arithmetic is unaffected by daylight saving', () {
      // Europe switches on 2026-03-29 and 2026-10-25.
      expect(Day(2026, 3, 28).addDays(2), Day(2026, 3, 30));
      expect(Day(2026, 10, 26).difference(Day(2026, 10, 24)), 2);
    });

    test('start of week honours the configured first day', () {
      final friday = Day(2026, 11, 13);
      expect(friday.weekday, DateTime.friday);
      expect(friday.startOfWeek(), Day(2026, 11, 9));
      expect(friday.startOfWeek(DateTime.sunday), Day(2026, 11, 8));
      expect(Day(2026, 11, 8).startOfWeek(DateTime.sunday), Day(2026, 11, 8));
    });

    test('ISO week numbers at year boundaries', () {
      expect(Day(2026, 11, 13).isoWeek, 46);
      expect(Day(2026, 1, 1).isoWeek, 1);
      expect(Day(2027, 1, 1).isoWeek, 53); // Friday, belongs to 2026-W53
      expect(Day(2024, 12, 30).isoWeek, 1); // Monday of 2025-W01
    });

    test('adding months clamps to the month length', () {
      expect(Day(2026, 1, 31).addMonths(1), Day(2026, 2, 28));
      expect(Day(2024, 2, 29).addMonths(12), Day(2025, 2, 28));
      expect(Day(2026, 11, 30).addMonths(3), Day(2027, 2, 28));
    });
  });

  group('Hlc', () {
    test('is strictly increasing even when the wall clock stalls or steps back', () {
      var wall = 1000;
      final clock = Hlc(deviceId: 'aaaa', now: () => wall);
      final a = clock.next();
      final b = clock.next();
      wall = 900;
      final c = clock.next();
      wall = 2000;
      final d = clock.next();
      expect([a, b, c, d], orderedEquals([a, b, c, d]..sort()));
      expect({a, b, c, d}.length, 4);
    });

    test('moves past timestamps observed from other devices', () {
      final ahead = Hlc(deviceId: 'bbbb', now: () => 50000).next();
      final clock = Hlc(deviceId: 'aaaa', now: () => 1000);
      clock.observe(ahead);
      expect(clock.next().compareTo(ahead), greaterThan(0));
    });

    test('resumes from a persisted timestamp', () {
      final first = Hlc(deviceId: 'aaaa', now: () => 5000);
      final last = first.next();
      final resumed = Hlc(deviceId: 'aaaa', now: () => 10, last: last);
      expect(resumed.next().compareTo(last), greaterThan(0));
    });

    test('ignores malformed input', () {
      final clock = Hlc(deviceId: 'aaaa', now: () => 1000);
      clock.observe('nonsense');
      expect(Hlc.timeOf('nonsense'), isNull);
      expect(Hlc.timeOf(clock.next())!.millisecondsSinceEpoch, 1000);
    });
  });

  group('order keys', () {
    test('a key between two neighbours sorts between them', () {
      final first = orderKeyBetween(null, null);
      final before = orderKeyBetween(null, first);
      final after = orderKeyBetween(first, null);
      final middle = orderKeyBetween(before, first);
      expect([before, middle, first, after],
          orderedEquals([before, middle, first, after]..sort()));
    });

    test('survives thousands of insertions at the same spot', () {
      // Always inserting right after the first key is the worst case.
      final keys = <String>[orderKeyBetween(null, null)];
      keys.add(orderKeyBetween(keys.first, null));
      for (var i = 0; i < 2000; i++) {
        keys.insert(1, orderKeyBetween(keys[0], keys[1]));
      }
      expect(keys, orderedEquals([...keys]..sort()));
      expect(keys.toSet().length, keys.length);
      // And at the very front and very end.
      var front = keys.first, back = keys.last;
      for (var i = 0; i < 500; i++) {
        final f = orderKeyBetween(null, front);
        final b = orderKeyBetween(back, null);
        expect(f.compareTo(front), lessThan(0));
        expect(b.compareTo(back), greaterThan(0));
        front = f;
        back = b;
      }
    });

    test('batch keys are ascending and inside the bounds', () {
      final keys = orderKeysBetween('A', 'B', 5);
      expect(keys, orderedEquals([...keys]..sort()));
      expect(keys.first.compareTo('A'), greaterThan(0));
      expect(keys.last.compareTo('B'), lessThan(0));
    });

    test('rejects bounds in the wrong order', () {
      expect(() => orderKeyBetween('B', 'A'), throwsArgumentError);
      expect(() => orderKeyBetween('A', 'A'), throwsArgumentError);
    });
  });

  group('Recurrence', () {
    final anchor = Day(2026, 11, 13); // a Friday
    List<String> iso(Iterable<Day> days) => [for (final d in days) d.iso];

    test('daily with an interval starts at the anchor', () {
      const rule = Recurrence(frequency: Frequency.daily, interval: 3);
      expect(
        iso(rule.occurrences(anchor, Day(2026, 11, 1), Day(2026, 11, 22))),
        ['2026-11-13', '2026-11-16', '2026-11-19', '2026-11-22'],
      );
      // A window that starts mid-cycle keeps the phase.
      expect(
        iso(rule.occurrences(anchor, Day(2026, 11, 17), Day(2026, 11, 23))),
        ['2026-11-19', '2026-11-22'],
      );
    });

    test('weekly presets', () {
      expect(
        iso(Recurrence.weekly
            .occurrences(anchor, Day(2026, 11, 9), Day(2026, 11, 29))),
        ['2026-11-13', '2026-11-20', '2026-11-27'],
      );
      expect(
        iso(Recurrence.biweekly
            .occurrences(anchor, Day(2026, 11, 9), Day(2026, 12, 13))),
        ['2026-11-13', '2026-11-27', '2026-12-11'],
      );
      // Weekdays: nothing before the anchor, nothing at weekends.
      expect(
        iso(Recurrence.weekdaysOnly
            .occurrences(anchor, Day(2026, 11, 9), Day(2026, 11, 18))),
        ['2026-11-13', '2026-11-16', '2026-11-17', '2026-11-18'],
      );
    });

    test('monthly on the 31st clamps to shorter months', () {
      final rule = Recurrence.monthly;
      expect(
        iso(rule.occurrences(Day(2026, 1, 31), Day(2026, 1, 1), Day(2026, 5, 1))),
        ['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30'],
      );
    });

    test('monthly on the n-th weekday', () {
      // 13 Nov 2026 is the second Friday.
      const second = Recurrence(frequency: Frequency.monthly, nthWeekday: 2);
      expect(
        iso(second.occurrences(anchor, anchor, Day(2027, 2, 28))),
        ['2026-11-13', '2026-12-11', '2027-01-08', '2027-02-12'],
      );
      const last = Recurrence(frequency: Frequency.monthly, nthWeekday: -1);
      expect(
        iso(last.occurrences(Day(2026, 11, 27), Day(2026, 11, 1), Day(2027, 1, 31))),
        ['2026-11-27', '2026-12-25', '2027-01-29'],
      );
    });

    test('yearly on 29 February uses the 28th outside leap years', () {
      expect(
        iso(Recurrence.yearly
            .occurrences(Day(2024, 2, 29), Day(2024, 1, 1), Day(2028, 12, 31))),
        ['2024-02-29', '2025-02-28', '2026-02-28', '2027-02-28', '2028-02-29'],
      );
    });

    test('until is inclusive and ends the series', () {
      final rule = Recurrence.daily.copyWith(until: () => Day(2026, 11, 15));
      expect(
        iso(rule.occurrences(anchor, Day(2026, 11, 1), Day(2026, 12, 1))),
        ['2026-11-13', '2026-11-14', '2026-11-15'],
      );
      expect(rule.nextAfter(anchor, Day(2026, 11, 15)), isNull);
      expect(rule.nextAfter(anchor, anchor), Day(2026, 11, 14));
    });

    test('JSON round trip preserves the rule; junk decodes to null', () {
      const rule = Recurrence(
        frequency: Frequency.weekly,
        interval: 2,
        weekdays: {1, 3},
      );
      expect(Recurrence.fromJson(rule.toJson()), rule);
      expect(Recurrence.fromJson({'freq': 'hourly'}), isNull);
      expect(Recurrence.fromJson('weekly'), isNull);
    });
  });
}
