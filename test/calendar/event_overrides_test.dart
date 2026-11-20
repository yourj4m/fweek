import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/calendar/calendar_service.dart';
import 'package:weektodo/calendar/ics.dart';
import 'package:weektodo/calendar/identity.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/services/reminders.dart';
import 'package:weektodo/sync/secrets.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';

/// What the user changes about imported events: applied on top of the
/// calendar's version, kept through downloads, and synced between devices.

const address = 'https://calendar.example.org/ical/secret-0123456789abcdef/basic.ics';

String feed(List<List<String>> events, {String name = 'Work'}) => [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'X-WR-CALNAME:$name',
      for (final event in events) ...['BEGIN:VEVENT', ...event, 'END:VEVENT'],
      'END:VCALENDAR',
      '',
    ].join('\r\n');

List<String> meeting({String title = 'Team meeting', String day = '20261109', String uid = 'meeting@test'}) => [
      'UID:$uid',
      'SUMMARY:$title',
      'LOCATION:Room 204',
      'DESCRIPTION:Bring the <b>draft</b>.<br>See <a href="https://example.org/agenda">the agenda</a>',
      'DTSTART:${day}T090000Z',
      'DTEND:${day}T100000Z',
    ];

const conference = [
  'UID:conference@test',
  'SUMMARY:Conference',
  'DTSTART;VALUE=DATE:20261113',
  'DTEND;VALUE=DATE:20261116',
];

const seminar = [
  'UID:seminar@test',
  'SUMMARY:Group seminar',
  'DTSTART:20261104T080000Z',
  'DTEND:20261104T090000Z',
  'RRULE:FREQ=WEEKLY;BYDAY=WE',
];

/// One device: its planner, its keyring, its cache of downloads.
class Device {
  Device({String? text}) {
    store = PlannerStore(PlannerDatabase.inMemory(), today: () => Day(2026, 11, 13));
    if (text != null) subscribe(text);
    addTearDown(() => _service?.dispose());
  }

  late final PlannerStore store;
  final secrets = MemorySecretStore();
  final cache = MemoryCalendarCache();
  CalendarService? _service;

  /// As if this calendar had been added on an earlier run.
  void subscribe(String text, {String id = 'c1', String url = address, bool keyed = true}) {
    cache.feeds[id] = text;
    secrets.values['calendar-address-$id'] = url;
    final known = store.db.meta('local.calendars');
    final list = known == null ? <Object?>[] : jsonDecode(known) as List;
    store.db.setMeta(
      'local.calendars',
      jsonEncode([
        ...list,
        {
          'id': id,
          if (keyed) 'key': calendarKey(Uri.parse(url)),
          'name': 'Work',
          'color': 'blue',
        },
      ]),
    );
  }

  Future<CalendarService> start() async {
    final service = _service = CalendarService(
      store,
      secrets,
      cache,
      // One hour ahead of UTC whatever the machine's zone.
      parse: (text) async => IcsCalendar.parse(
        text,
        toLocal: (utc) => DateTime(utc.year, utc.month, utc.day, utc.hour + 1, utc.minute),
      ),
    );
    await service.load();
    return service;
  }

  CalendarService get calendars => _service!;

  /// As if the app had been closed and opened again.
  Future<CalendarService> restart() {
    _service?.dispose();
    return start();
  }

  /// Replaces what the calendar holds, as the next download would.
  Future<void> download(String text, {String id = 'c1'}) async {
    cache.feeds[id] = text;
    _service?.dispose();
    await start();
  }
}

void main() {
  final monday = Day(2026, 11, 9);
  final sunday = monday.addDays(6);

  Task only(CalendarService calendars, Day day) =>
      calendars.eventsBetween(day, day).on(day).single;
  String only0(CalendarService calendars, Day day, String title) =>
      calendars.eventsBetween(day, day).on(day).firstWhere((t) => t.title == title).id;
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  group('an event as the planner shows it', () {
    test('is its calendar\'s version until something is changed', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final event = only(calendars, monday);
      expect(event.id, startsWith('ev:'));
      expect(event.fromCalendar, isTrue);
      expect(event.title, 'Team meeting');
      expect(event.time, 10 * 60);
      expect(event.location, 'Room 204');
      // What the calendar says about it is its note, and it is an event:
      // from 10 to 11, with nothing to tick.
      expect(event.note, 'Bring the draft.\nSee the agenda (https://example.org/agenda)');
      expect(event.kind, ItemKind.event);
      expect(event.checkable, isFalse);
      expect(event.end, 11 * 60);
      expect(event.event!.calendarName, 'Work');
      expect(event.event!.edited, isFalse);
      // What the calendar wrote in HTML reads as text, links kept.
      expect(event.event!.description,
          'Bring the draft.\nSee the agenda (https://example.org/agenda)');
      expect(device.store.task(event.id)!.title, 'Team meeting');
      expect(device.store.eventOverrides, isEmpty);
    });

    test('takes a note, a colour, another time and place and subtasks', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final id = only(calendars, monday).id;

      store.updateTask(id, note: 'Ask about the budget', color: () => 'green');
      store.updateTask(id, time: () => 14 * 60 + 15);
      store.updateTask(id, location: 'Room 12', geo: () => '45.1,5.7');
      store.updateTask(id, subtasks: const [Subtask(id: 's1', text: 'Print slides')]);
      // An event is not ticked off.
      store.setDone(id, true);

      final event = only(calendars, monday);
      expect(event.note, 'Ask about the budget');
      expect(event.color, 'green');
      expect(event.time, 14 * 60 + 15);
      expect(event.location, 'Room 12');
      expect(event.geo, '45.1,5.7');
      expect(event.subtasks.single.text, 'Print slides');
      expect(event.done, isFalse);
      expect(store.eventOverrides.single.done, isFalse);
      expect(event.event!.edited, isTrue);
      // The calendar's own values stay known beside the changed ones.
      expect(event.event!.title, 'Team meeting');
      expect(event.event!.location, 'Room 204');
      expect(event.event!.start, DateTime(2026, 11, 9, 10));
    });

    test('a value set back to the calendar\'s own is no change', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final id = only(calendars, monday).id;
      store.updateTask(id, title: 'Weekly sync', time: () => 9 * 60, location: 'Elsewhere');
      expect(only(calendars, monday).title, 'Weekly sync');
      store.updateTask(id, title: 'Team meeting', time: () => 10 * 60, location: 'Room 204');
      final change = store.eventOverrides.single;
      expect(change.title, isNull);
      expect(change.time, isNull);
      expect(change.location, isNull);
      expect(only(calendars, monday).event!.edited, isFalse);
    });

    test('a timed event can be shown without its time', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      device.store.updateTask(only(calendars, monday).id, time: () => null);
      expect(only(calendars, monday).time, isNull);
      expect(device.store.eventOverrides.single.time, EventOverride.noTime);
    });

    test('reset drops every change', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      device.store.updateTask(id, title: 'Mine', note: 'n', color: () => 'red');
      device.store.setEventHidden(id, true);
      device.store.resetEvent(id);
      final event = only(calendars, monday);
      expect(event.title, 'Team meeting');
      expect(event.note, startsWith('Bring the draft.'));
      expect(event.color, isNull);
      expect(event.event!.hidden, isFalse);
    });
  });

  group('an event\'s note', () {
    const theirs = 'Bring the draft.\nSee the agenda (https://example.org/agenda)';

    test('is the calendar\'s description until it is edited, and follows the calendar till then',
        () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      expect(only(calendars, monday).note, theirs);
      expect(device.store.eventOverrides, isEmpty);
      await device.download(feed([
        [...meeting().where((l) => !l.startsWith('DESCRIPTION')), 'DESCRIPTION:Room changed'],
      ]));
      expect(only(device.calendars, monday).note, 'Room changed');
    });

    test('an edit is the user\'s and stays through downloads', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      device.store.updateTask(id, note: '$theirs\nAnd the budget sheet');
      expect(device.store.eventOverrides.single.note, endsWith('And the budget sheet'));
      await device.download(feed([
        [...meeting().where((l) => !l.startsWith('DESCRIPTION')), 'DESCRIPTION:Room changed'],
      ]));
      expect(only(device.calendars, monday).note, endsWith('And the budget sheet'));
      // The calendar's own text stays known.
      expect(only(device.calendars, monday).event!.description, 'Room changed');
    });

    test('typed back to what the calendar says it is no change', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      device.store.updateTask(id, note: 'Mine');
      device.store.updateTask(id, note: theirs);
      expect(device.store.eventOverrides.single.note, isNull);
      expect(only(calendars, monday).event!.edited, isFalse);
    });

    test('emptied, it stays empty rather than bringing the description back', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      device.store.updateTask(id, note: '');
      expect(only(calendars, monday).note, '');
      expect(only(calendars, monday).hasNote, isFalse);
      device.store.resetEvent(id);
      expect(only(calendars, monday).note, theirs);
    });

    test('a note from the version that kept it beside the description gets the description under it, once',
        () async {
      final device = Device(text: feed([meeting(), meeting(title: 'Review', day: '20261110', uid: 'r@test')]));
      var calendars = await device.start();
      final first = only(calendars, monday).id, second = only(calendars, monday.addDays(1)).id;
      // As that version stored them: only the user's own words.
      device.store.updateTask(first, note: 'Ask about the budget');
      device.store.updateTask(second, color: () => 'red');
      // The planner is opened by this version for the first time.
      device.store.db.setMeta('events.notes.joined', 'pending');
      calendars = await device.restart();
      expect(only(calendars, monday).note, 'Ask about the budget\n\n$theirs');
      // Nothing is made up for an event that had no note of its own.
      expect(device.store.eventOverride(only(calendars, monday.addDays(1)).event!.key)!.note, isNull);
      // And not again.
      device.store.updateTask(first, note: 'Short');
      calendars = await device.restart();
      expect(only(calendars, monday).note, 'Short');
    });
  });

  group('events and tasks', () {
    test('what a calendar brings is an event; it can be made a task, and back', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final id = only(calendars, monday).id;

      store.setKind(id, ItemKind.task);
      expect(only(calendars, monday).checkable, isTrue);
      expect(store.eventOverrides.single.kind, ItemKind.task);
      store.setDone(id, true);
      expect(only(calendars, monday).done, isTrue);

      // As an event again it has no tick; the tick is not forgotten.
      store.setKind(id, ItemKind.event);
      expect(only(calendars, monday).done, isFalse);
      expect(only(calendars, monday).kind, ItemKind.event);
      store.setKind(id, ItemKind.task);
      expect(only(calendars, monday).done, isTrue);
    });

    test('an event ticked off before events lost their circle stays a ticked task', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final event = only(calendars, monday);
      // As the version before wrote it: done, and no word about the kind.
      device.store.refresh(device.store.db.apply(device.store.db.stamp('events', event.event!.key, {
        'cal': event.event!.calendar,
        'origin': '2026-11-09',
        'done': true,
      })));
      expect(only(calendars, monday).kind, ItemKind.task);
      expect(only(calendars, monday).done, isTrue);
    });

    test('the end follows the calendar, moves with the start, and can be the user\'s own', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final id = only(calendars, monday).id;
      expect((only(calendars, monday).time, only(calendars, monday).end), (600, 660));

      store.updateTask(id, time: () => 14 * 60);
      expect(only(calendars, monday).end, 15 * 60);
      expect(store.eventOverrides.single.end, isNull);

      store.updateTask(id, end: () => 16 * 60 + 30);
      expect(only(calendars, monday).end, 16 * 60 + 30);
      // The user's end keeps its distance when the start moves.
      store.updateTask(id, time: () => 15 * 60);
      expect(only(calendars, monday).end, 17 * 60 + 30);

      store.updateTask(id, time: () => null);
      expect(only(calendars, monday).time, isNull);
      expect(only(calendars, monday).end, isNull);
    });

    test('an event is over when its day or, today, its end has passed', () async {
      final device = Device(text: feed([meeting(), conference]));
      final calendars = await device.start();
      final event = only(calendars, monday);
      expect(event.overAt(DateTime(2026, 11, 9, 10, 59)), isFalse);
      expect(event.overAt(DateTime(2026, 11, 9, 11)), isTrue);
      expect(event.overAt(DateTime(2026, 11, 8, 23)), isFalse);
      expect(event.overAt(DateTime(2026, 11, 10)), isTrue);
      // Over several days: after the last one.
      final span = calendars.eventsBetween(monday, sunday).spans.single;
      expect(span.overAt(DateTime(2026, 11, 15, 23, 59)), isFalse);
      expect(span.overAt(DateTime(2026, 11, 16)), isTrue);
      // A task is never over, only done.
      device.store.setKind(event.id, ItemKind.task);
      expect(only(calendars, monday).overAt(DateTime(2026, 11, 20)), isFalse);
    });
  });

  group('placing an event among the tasks of its day', () {
    List<String> shown(Device device, Day day) => titles(device.store.itemsOn(day));
    List<String> review({String day = '20261109'}) => [
          'UID:review@test',
          'SUMMARY:Review',
          'DTSTART:${day}T130000Z',
          'DTEND:${day}T140000Z',
        ];

    test('an event nobody placed stands above the tasks; tasks keep their order', () async {
      final device = Device(text: feed([meeting(), review()]));
      await device.start();
      device.store.addTask(DaySlot(monday), 'A');
      device.store.addTask(DaySlot(monday), 'B');
      expect(shown(device, monday), ['Team meeting', 'Review', 'A', 'B']);
      expect(device.store.eventOverrides, isEmpty);
    });

    test('dropped between two tasks it stands there, and that is all that changes', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      store.addTask(DaySlot(monday), 'A');
      store.addTask(DaySlot(monday), 'B');
      final id = only(calendars, monday).id;
      // The place counts among the others: A, B.
      store.moveTask(id, DaySlot(monday), index: 1);
      expect(shown(device, monday), ['A', 'Team meeting', 'B']);
      final change = store.eventOverrides.single;
      expect(change.position, isNotNull);
      expect(change.date, isNull, reason: 'it did not change its day');
      expect(only(calendars, monday).event!.edited, isFalse,
          reason: 'where it stands is not an edit of the event');

      store.moveTask(id, DaySlot(monday), index: 2);
      expect(shown(device, monday), ['A', 'B', 'Team meeting']);
      store.moveTask(id, DaySlot(monday), index: 0);
      expect(shown(device, monday), ['Team meeting', 'A', 'B']);
    });

    test('a task typed afterwards goes to the end, below an event placed last', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      store.addTask(DaySlot(monday), 'A');
      store.moveTask(only(calendars, monday).id, DaySlot(monday), index: 1);
      store.addTask(DaySlot(monday), 'B');
      expect(shown(device, monday), ['A', 'Team meeting', 'B']);
    });

    test('a task dropped above or between events that were never placed: they keep their order',
        () async {
      final device = Device(text: feed([meeting(), review()]));
      await device.start();
      final store = device.store;
      final a = store.addTask(DaySlot(monday), 'A')!;
      store.addTask(DaySlot(monday), 'B');
      // Among the others (Team meeting, Review, B): between the two events.
      store.moveTask(a, DaySlot(monday), index: 1);
      expect(shown(device, monday), ['Team meeting', 'A', 'Review', 'B']);
      store.moveTask(a, DaySlot(monday), index: 0);
      expect(shown(device, monday), ['A', 'Team meeting', 'Review', 'B']);
      // A new event of the calendar, not placed by anyone, comes first.
      await device.download(feed([
        meeting(),
        review(),
        ['UID:new@test', 'SUMMARY:Lunch', 'DTSTART:20261109T110000Z', 'DTEND:20261109T120000Z'],
      ]));
      expect(shown(device, monday), ['Lunch', 'A', 'Team meeting', 'Review', 'B']);
    });

    test('dropped on another day at a place, it stands there; sent there by the menu, among that '
        'day\'s events', () async {
      final device = Device(text: feed([meeting(), review(day: '20261110')]));
      final calendars = await device.start();
      final store = device.store;
      final tuesday = monday.addDays(1);
      store.addTask(DaySlot(tuesday), 'A');
      store.addTask(DaySlot(tuesday), 'B');
      final id = only(calendars, monday).id;
      // Among Review, A, B: under A.
      store.moveTask(id, DaySlot(tuesday), index: 2);
      expect(shown(device, tuesday), ['Review', 'A', 'Team meeting', 'B']);
      expect(store.eventOverrides.single.date, tuesday);

      store.moveTask(id, DaySlot(monday));
      expect(shown(device, monday), ['Team meeting']);
      store.moveTask(id, DaySlot(tuesday));
      // 10:00 before 14:00, both above the tasks.
      expect(shown(device, tuesday), ['Team meeting', 'Review', 'A', 'B']);
    });

    test('completed tasks sorted down go below it too', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final a = store.addTask(DaySlot(monday), 'A')!;
      store.addTask(DaySlot(monday), 'B');
      store.moveTask(only(calendars, monday).id, DaySlot(monday), index: 2);
      store.setDone(a, true);
      store.setSetting(Settings.sortDoneDown, true);
      expect(shown(device, monday), ['B', 'Team meeting', 'A']);
    });

    test('"Reset" lets it go back above the tasks', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      device.store.addTask(DaySlot(monday), 'A');
      final id = only(calendars, monday).id;
      device.store.moveTask(id, DaySlot(monday), index: 1);
      device.store.resetEvent(id);
      expect(shown(device, monday), ['Team meeting', 'A']);
    });

    test('the other device shows the same order', () async {
      final folder = MemoryStorage();
      Future<void> sync(Device device) =>
          SyncEngine(device.store, folder, folder: 'WeekToDo').sync();
      final desk = Device(text: feed([meeting(), review()]));
      final phone = Device(text: feed([meeting(), review()]));
      final onDesk = await desk.start();
      await phone.start();
      final a = desk.store.addTask(DaySlot(monday), 'A')!;
      desk.store.addTask(DaySlot(monday), 'B');
      desk.store.moveTask(only0(onDesk, monday, 'Review'), DaySlot(monday), index: 3);
      desk.store.moveTask(a, DaySlot(monday), index: 0);
      expect(shown(desk, monday), ['A', 'Team meeting', 'B', 'Review']);
      await sync(desk);
      await sync(phone);
      expect(shown(phone, monday), ['A', 'Team meeting', 'B', 'Review']);
      // Nothing of the events themselves went along: fingerprints and keys.
      final sent = folder.files.values.map(utf8.decode).join();
      expect(sent, isNot(contains('Team meeting')));
      expect(sent, isNot(contains('Review')));
    });
  });

  group('moving', () {
    test('an event shows on the day it was moved to, at its own time', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      expect(device.store.moveTask(id, DaySlot(monday.addDays(2))), id);
      expect(calendars.eventsBetween(monday, monday).on(monday), isEmpty);
      final moved = only(calendars, monday.addDays(2));
      expect(moved.time, 10 * 60);
      expect(moved.event!.originalDay, monday);
      expect(moved.event!.edited, isTrue);
    });

    test('into another week: it leaves the one, arrives in the other', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final next = monday.addDays(9);
      device.store.moveTask(only(calendars, monday).id, DaySlot(next));
      expect(calendars.eventsBetween(monday, sunday).isEmpty, isTrue);
      expect(titles(calendars.eventsBetween(next.startOfWeek(), next.startOfWeek().addDays(6)).on(next)),
          ['Team meeting']);
      // And back to where its calendar has it: no change is left.
      device.store.moveTask(only(calendars, next).id, DaySlot(monday));
      expect(device.store.eventOverrides.single.date, isNull);
      expect(titles(calendars.eventsBetween(monday, sunday).on(monday)), ['Team meeting']);
    });

    test('one occurrence of a repeating event moves alone', () async {
      final device = Device(text: feed([seminar]));
      final calendars = await device.start();
      final wednesday = monday.addDays(2);
      device.store.moveTask(only(calendars, wednesday).id, DaySlot(wednesday.addDays(1)));
      expect(calendars.eventsBetween(wednesday, wednesday).on(wednesday), isEmpty);
      expect(titles(calendars.eventsBetween(monday, sunday).on(wednesday.addDays(1))), ['Group seminar']);
      // The week after is untouched.
      expect(titles(calendars.eventsBetween(wednesday.addDays(7), wednesday.addDays(7)).on(wednesday.addDays(7))),
          ['Group seminar']);
    });

    test('an event over several days keeps its length', () async {
      final device = Device(text: feed([conference]));
      final calendars = await device.start();
      final span = calendars.eventsBetween(monday, sunday).spans.single;
      expect(span.date, Day(2026, 11, 13));
      expect(span.event!.lastDay, Day(2026, 11, 15));
      expect(span.spansDays, isTrue);
      device.store.moveTask(span.id, DaySlot(Day(2026, 11, 10)));
      final moved = calendars.eventsBetween(monday, sunday).spans.single;
      expect(moved.date, Day(2026, 11, 10));
      expect(moved.event!.lastDay, Day(2026, 11, 12));
    });

    test('to a list it becomes a task, and the event is hidden', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final store = device.store;
      final list = store.lists.first.id;
      final task = store.moveTask(only(calendars, monday).id, ListSlot(list));
      expect(Task.isEventId(task), isFalse);
      expect(store.task(task)!.title, 'Team meeting');
      expect(store.task(task)!.location, 'Room 204');
      expect(store.task(task)!.note, contains('Bring the draft.'));
      expect(calendars.eventsBetween(monday, monday).on(monday), isEmpty);
    });
  });

  group('hiding', () {
    test('a hidden event is left out, counted, and shown on request', () async {
      final device = Device(text: feed([meeting(), conference]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      device.store.deleteTask(id); // deleting an event hides it
      final week = calendars.eventsBetween(monday, sunday);
      expect(week.on(monday), isEmpty);
      expect(week.hidden, 1);
      expect(week.spans, hasLength(1));

      calendars.showHidden = true;
      final shown = calendars.eventsBetween(monday, sunday).on(monday).single;
      expect(shown.event!.hidden, isTrue);
      device.store.restoreTask(id);
      expect(only(calendars, monday).event!.hidden, isFalse);
    });

    test('a hidden calendar shows nothing, its events stay findable by id', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final id = only(calendars, monday).id;
      calendars.setHidden(calendars.subscriptions.single.id, true);
      expect(calendars.eventsBetween(monday, sunday).isEmpty, isTrue);
      expect(device.store.calendarRows.single.hidden, isTrue);
      expect(device.store.task(id)!.title, 'Team meeting');
      calendars.setHidden(calendars.subscriptions.single.id, false);
      expect(titles(calendars.eventsBetween(monday, sunday).on(monday)), ['Team meeting']);
    });
  });

  group('a download', () {
    test('changes what the user left alone and nothing else', () async {
      final device = Device(text: feed([meeting()]));
      var calendars = await device.start();
      device.store.updateTask(only(calendars, monday).id, note: 'Mine', color: () => 'orange');
      // The calendar renames the event and moves it to Tuesday.
      await device.download(feed([meeting(title: 'Team retro', day: '20261110')]));
      calendars = device.calendars;
      expect(calendars.eventsBetween(monday, monday).on(monday), isEmpty);
      final event = only(calendars, monday.addDays(1));
      expect(event.title, 'Team retro');
      expect(event.note, 'Mine');
      expect(event.color, 'orange');
    });

    test('never touches the changes, and a change never the download', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      final before = device.cache.feeds['c1'];
      device.store.updateTask(only(calendars, monday).id, title: 'Mine');
      expect(device.cache.feeds['c1'], before);
      await device.download(feed([meeting(title: 'Theirs')]));
      expect(only(device.calendars, monday).title, 'Mine');
      expect(only(device.calendars, monday).event!.title, 'Theirs');
    });

    test('an event gone from the calendar keeps its changes, in case it returns', () async {
      final device = Device(text: feed([meeting()]));
      final calendars = await device.start();
      device.store.updateTask(only(calendars, monday).id, note: 'Mine');
      await device.download(feed([conference]));
      expect(device.calendars.eventsBetween(monday, monday).on(monday), isEmpty);
      expect(device.store.eventOverrides.single.note, 'Mine');
      await device.download(feed([meeting()]));
      expect(only(device.calendars, monday).note, 'Mine');
    });

    test('a series split "this and following" keeps the changes to its later occurrences', () async {
      final device = Device(text: feed([seminar]));
      final calendars = await device.start();
      final later = monday.addDays(9);
      device.store.updateTask(only(calendars, later).id, note: 'Bring cake');
      // Google ends the old series and continues under <id>_R<date>.
      await device.download(feed([
        [...seminar.take(4), 'RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20261111T235959Z'],
        [
          'UID:seminar_R20261118T080000@test',
          'SUMMARY:Group seminar (new room)',
          'DTSTART:20261118T080000Z',
          'DTEND:20261118T090000Z',
          'RRULE:FREQ=WEEKLY;BYDAY=WE',
        ],
      ]));
      final event = only(device.calendars, later);
      expect(event.title, 'Group seminar (new room)');
      expect(event.note, 'Bring cake');
    });

    test('a calendar that renames every event on each download is told apart by content', () async {
      List<List<String>> holidays(String run) => [
            for (var i = 0; i < 8; i++)
              [
                'UID:$run-$i@holidays',
                'SUMMARY:Holiday $i',
                'DTSTART;VALUE=DATE:202611${(9 + i).toString().padLeft(2, '0')}',
              ],
          ];
      final device = Device(text: feed(holidays('a')));
      final calendars = await device.start();
      // The first real download answers with new identifiers throughout.
      expect(CalendarService.renamedEverything(
              IcsCalendar.parse(feed(holidays('a'))), IcsCalendar.parse(feed(holidays('b')))),
          isTrue);
      expect(CalendarService.renamedEverything(
              IcsCalendar.parse(feed(holidays('a'))), IcsCalendar.parse(feed([...holidays('a'), meeting()]))),
          isFalse);
      // Once such a calendar is known, changes go by title and start.
      device.store.setCalendar(calendars.subscriptions.single.key, ids: () => 'content');
      device.store.updateTask(only(device.calendars, monday).id, note: 'Day off');
      await device.download(feed(holidays('b')));
      expect(only(device.calendars, monday).note, 'Day off');
    });
  });

  group('two devices', () {
    Future<void> sync(Device device, MemoryStorage folder) =>
        SyncEngine(device.store, folder, folder: 'WeekToDo').sync();

    test('a change made on one shows on the other', () async {
      final folder = MemoryStorage();
      final desk = Device(text: feed([meeting(), conference]));
      final phone = Device(text: feed([meeting(), conference]));
      final onDesk = await desk.start(), onPhone = await phone.start();

      final id = only(onDesk, monday).id;
      desk.store.updateTask(id, note: 'From the desk', color: () => 'purple');
      desk.store.moveTask(id, DaySlot(monday.addDays(1)));
      desk.store.setEventHidden(onDesk.eventsBetween(monday, sunday).spans.single.id, true);
      await sync(desk, folder);
      await sync(phone, folder);

      final event = only(onPhone, monday.addDays(1));
      expect(event.id, id, reason: 'both devices name the event alike');
      expect(event.note, 'From the desk');
      expect(event.color, 'purple');
      expect(onPhone.eventsBetween(monday, sunday).spans, isEmpty);
      expect(onPhone.eventsBetween(monday, sunday).hidden, 1);
    });

    test('changes to different things merge; for the same thing the later one wins', () async {
      final folder = MemoryStorage();
      final desk = Device(text: feed([meeting()]));
      final phone = Device(text: feed([meeting()]));
      final onDesk = await desk.start(), onPhone = await phone.start();
      final id = only(onDesk, monday).id;

      desk.store.updateTask(id, note: 'Note from the desk');
      phone.store.updateTask(id, color: () => 'red');
      desk.store.updateTask(id, title: 'Desk title');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      phone.store.updateTask(id, title: 'Phone title');
      await sync(desk, folder);
      await sync(phone, folder);
      await sync(desk, folder);

      for (final calendars in [onDesk, onPhone]) {
        final event = only(calendars, monday);
        expect(event.note, 'Note from the desk');
        expect(event.color, 'red');
        expect(event.title, 'Phone title');
      }
    });

    test('a calendar\'s name, colour and visibility are shared; its address is not', () async {
      final folder = MemoryStorage();
      final desk = Device(text: feed([meeting()]));
      final phone = Device(text: feed([meeting()]));
      final onDesk = await desk.start(), onPhone = await phone.start();
      final calendar = onDesk.subscriptions.single;

      onDesk.rename(calendar.id, 'Lab');
      onDesk.setColor(calendar.id, 'green');
      onDesk.setHidden(calendar.id, true);
      await sync(desk, folder);
      await sync(phone, folder);

      expect(onPhone.subscriptions.single.name, 'Lab');
      expect(onPhone.subscriptions.single.color, 'green');
      expect(onPhone.subscriptions.single.hidden, isTrue);
      expect(onPhone.eventsBetween(monday, sunday).isEmpty, isTrue);
      final sent = [for (final bytes in folder.files.values) utf8.decode(bytes)].join();
      expect(sent, isNot(contains('secret-0123456789abcdef')));
      expect(sent, isNot(contains('calendar.example.org')));
      expect(sent, isNot(contains('meeting@test')));
      expect(sent, isNot(contains('Team meeting')));
    });

    test('a device without the calendar lists it, and takes it over when its address is added', () async {
      final folder = MemoryStorage();
      final desk = Device(text: feed([meeting()]));
      final phone = Device();
      final onDesk = await desk.start(), onPhone = await phone.start();
      onDesk.rename(onDesk.subscriptions.single.id, 'Lab');
      desk.store.updateTask(only(onDesk, monday).id, note: 'From the desk');
      await sync(desk, folder);
      await sync(phone, folder);

      expect(onPhone.subscriptions, isEmpty);
      expect(onPhone.elsewhere.single.name, 'Lab');
      expect(onPhone.eventsBetween(monday, sunday).isEmpty, isTrue);

      // The address reaches the phone by the user's hand; as on a later run:
      phone.subscribe(feed([meeting()]));
      await phone.download(feed([meeting()]));
      expect(phone.calendars.subscriptions.single.name, 'Lab');
      expect(phone.calendars.elsewhere, isEmpty);
      expect(only(phone.calendars, monday).note, 'From the desk');
    });

    test('removed on one device, a calendar stays on the other', () async {
      final folder = MemoryStorage();
      final desk = Device(text: feed([meeting()]));
      final phone = Device(text: feed([meeting()]));
      final onDesk = await desk.start(), onPhone = await phone.start();
      await sync(desk, folder);
      await sync(phone, folder);
      await onDesk.remove(onDesk.subscriptions.single.id);
      await sync(desk, folder);
      await sync(phone, folder);
      expect(onPhone.subscriptions, hasLength(1));
      expect(titles(onPhone.eventsBetween(monday, sunday).on(monday)), ['Team meeting']);
      await sync(phone, folder);
      await sync(desk, folder);
      expect(onDesk.subscriptions, isEmpty);
      expect(onDesk.elsewhere.single.name, 'Work');
    });
  });

  group('calendars saved by an earlier version', () {
    test('are named by their address on the first start, keeping name and colour', () async {
      final device = Device()..subscribe(feed([meeting()]), keyed: false);
      final calendars = await device.start();
      final key = calendarKey(Uri.parse(address));
      expect(calendars.subscriptions.single.key, key);
      expect(device.store.calendarRow(key)!.name, 'Work');
      expect(device.store.calendarRow(key)!.color, 'blue');
      expect(jsonDecode(device.store.db.meta('local.calendars')!)[0]['key'], key);
      expect(titles(calendars.eventsBetween(monday, sunday).on(monday)), ['Team meeting']);
    });

    test('without an address in the keyring still show what was downloaded', () async {
      final device = Device()..subscribe(feed([meeting()]), keyed: false);
      device.secrets.values.clear();
      final calendars = await device.start();
      expect(calendars.subscriptions.single.key, localCalendarKey('c1'));
      expect(titles(calendars.eventsBetween(monday, sunday).on(monday)), ['Team meeting']);
    });
  });

  test('two calendars with events of one identifier keep their changes apart', () async {
    final device = Device(text: feed([meeting()]))
      ..subscribe(feed([meeting(title: 'Other meeting')], name: 'Other'),
          id: 'c2', url: 'https://calendar.example.org/ical/other/basic.ics');
    final calendars = await device.start();
    final both = calendars.eventsBetween(monday, monday).on(monday);
    expect(both, hasLength(2));
    expect(both[0].id, isNot(both[1].id));
    device.store.updateTask(both[0].id, note: 'Only here');
    final after = calendars.eventsBetween(monday, monday).on(monday);
    expect(after.where((e) => e.note == 'Only here'), hasLength(1));
  });

  test('search finds events by title, place, description and the user\'s note', () async {
    final device = Device(text: feed([meeting(), conference, seminar]));
    final calendars = await device.start();
    device.store.updateTask(only(calendars, monday).id, note: 'budget question');
    List<String> found(String query) => titles(
        calendars.search(query, from: monday.addDays(-30), to: monday.addDays(30)));
    expect(found('conference'), ['Conference']);
    expect(found('room 204'), ['Team meeting']);
    expect(found('agenda'), ['Team meeting']);
    expect(found('budget'), ['Team meeting']);
    expect(found('seminar').length, greaterThan(4));
    expect(found(''), isEmpty);
  });

  test('a reminder set on an event is delivered like a task\'s', () async {
    final device = Device(text: feed([meeting()]));
    final calendars = await device.start();
    final id = only(calendars, monday).id;
    device.store.updateTask(id, reminder: () => DateTime(2026, 11, 9, 9, 45));
    expect(titles(calendars.eventsWithReminders), ['Team meeting']);

    final delivered = <DueReminder>[];
    var now = DateTime(2026, 11, 9, 9, 40);
    final reminders = ReminderService(
      device.store,
      notify: delivered.add,
      events: () => calendars.eventsWithReminders,
      clock: () => now,
    )..check();
    addTearDown(reminders.dispose);
    expect(delivered, isEmpty);
    now = DateTime(2026, 11, 9, 9, 45, 1);
    reminders.check();
    expect(delivered.single.task.id, id);
    expect(delivered.single.task.title, 'Team meeting');
    // Not when the event is hidden or its calendar is.
    device.store.setEventHidden(id, true);
    expect(calendars.eventsWithReminders, isEmpty);
  });
}
