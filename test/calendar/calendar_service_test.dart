import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/calendar/calendar_service.dart';
import 'package:weektodo/data/database.dart';
import 'package:weektodo/data/day.dart';
import 'package:weektodo/data/export.dart';
import 'package:weektodo/data/models.dart';
import 'package:weektodo/data/planner_store.dart';
import 'package:weektodo/sync/secrets.dart';
import 'package:weektodo/sync/storage.dart';
import 'package:weektodo/sync/sync_engine.dart';

/// A calendar server on this machine. All-day events only, so the tests do
/// not depend on the machine's time zone.
class FakeCalendarServer {
  late HttpServer _server;
  String body = feed(['Dentist appointment']);
  int status = 200;
  int version = 1;
  final List<String> requests = [];

  static const secret = 'private-0123456789abcdef';

  static String feed(List<String> titles, {String name = 'Private diary'}) => [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//Test//Calendar//EN',
        'X-WR-CALNAME:$name',
        for (var i = 0; i < titles.length; i++) ...[
          'BEGIN:VEVENT',
          'UID:event-$i@test',
          'SUMMARY:${titles[i]}',
          'DTSTART;VALUE=DATE:202611${13 + i}',
          'DTEND;VALUE=DATE:202611${14 + i}',
          'END:VEVENT',
        ],
        'END:VCALENDAR',
        '',
      ].join('\r\n');

  String get address => 'http://127.0.0.1:${_server.port}/calendar/ical/$secret/basic.ics';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests.add('${request.method} ${request.uri.path} '
          'if-none-match=${request.headers.value(HttpHeaders.ifNoneMatchHeader)}');
      final response = request.response;
      final tag = '"v$version"';
      if (status != 200) {
        response.statusCode = status;
      } else if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == tag) {
        response.statusCode = HttpStatus.notModified;
      } else {
        response.headers.set(HttpHeaders.etagHeader, tag);
        response.headers.contentType = ContentType('text', 'calendar', charset: 'utf-8');
        response.add(utf8.encode(body));
      }
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  final friday = Day(2026, 11, 13);
  late FakeCalendarServer server;
  late PlannerDatabase db;
  late PlannerStore store;
  late MemorySecretStore secrets;
  late MemoryCalendarCache cache;

  CalendarService service() {
    final s = CalendarService(store, secrets, cache);
    addTearDown(s.dispose);
    return s;
  }

  List<String> titles(CalendarService s, Day day) =>
      [for (final e in s.eventsBetween(day, day).on(day)) e.title];

  setUp(() async {
    server = FakeCalendarServer();
    await server.start();
    db = PlannerDatabase.inMemory();
    store = PlannerStore(db, today: () => friday);
    secrets = MemorySecretStore();
    cache = MemoryCalendarCache();
  });

  tearDown(() => server.stop());

  group('addresses', () {
    test('calendar link schemes and bare hosts become https', () {
      expect(calendarAddress(' webcal://example.org/a.ics ').toString(), 'https://example.org/a.ics');
      expect(calendarAddress('example.org/a.ics').toString(), 'https://example.org/a.ics');
      expect(calendarAddress('HTTPS://example.org/a.ics').scheme, 'https');
    });

    test('plain http is refused, except for this machine', () {
      expect(() => calendarAddress('http://example.org/a.ics'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('https'))));
      expect(calendarAddress('http://127.0.0.1:8080/a.ics').scheme, 'http');
      expect(() => calendarAddress(''), throwsFormatException);
      expect(() => calendarAddress('ftp://example.org/a.ics'), throwsFormatException);
    });
  });

  test('subscribing reads the calendar and shows its events on their days', () async {
    final s = service();
    expect(await s.add(address: server.address), isNull);
    expect(s.subscriptions.single.name, 'Private diary');
    expect(s.subscriptions.single.events, 1);
    expect(titles(s, friday), ['Dentist appointment']);
    expect(titles(s, friday.addDays(1)), isEmpty);
  });

  test('a name typed by the user wins over the calendar\'s own', () async {
    final s = service();
    await s.add(address: server.address, name: ' Work ');
    expect(s.subscriptions.single.name, 'Work');
  });

  test('an address that is not a calendar is not kept', () async {
    server.body = '<html>Sign in</html>';
    final s = service();
    expect(await s.add(address: server.address), contains('did not answer with a calendar'));
    expect(s.subscriptions, isEmpty);
    expect(secrets.values, isEmpty);
    expect(cache.feeds, isEmpty);

    server.status = 404;
    expect(await s.add(address: server.address), contains('was not accepted (404)'));
    expect(await s.add(address: 'http://example.org/x.ics'), contains('https'));
    expect(s.subscriptions, isEmpty);
  });

  test('the address is kept with the passwords, not in the planner database', () async {
    final s = service();
    await s.add(address: server.address);
    expect(secrets.values.values.single, server.address);
    final stored = db.meta('local.calendars')!;
    expect(stored, isNot(contains(FakeCalendarServer.secret)));
    expect(stored, isNot(contains('basic.ics')));
  });

  test('the address and the events never leave the device; what the user arranges does', () async {
    store.addTask(DaySlot(friday), 'Buy oat milk');
    final s = service();
    await s.add(address: server.address);
    s.setColor(s.subscriptions.single.id, 'green');
    s.rename(s.subscriptions.single.id, 'Renamed diary');
    // The user annotates and hides the one event there is.
    final event = s.eventsBetween(friday, friday).on(friday).single;
    store.updateTask(event.id, note: 'Ask about the crown');
    store.setEventHidden(event.id, true);

    final folder = MemoryStorage();
    await SyncEngine(store, folder, folder: 'WeekToDo').sync();
    expect(folder.files, isNotEmpty);
    final uploaded = [for (final bytes in folder.files.values) utf8.decode(bytes)].join('\n');
    expect(uploaded, contains('Buy oat milk')); // the task does sync
    final outgoing = [
      uploaded,
      folder.files.keys.join('\n'),
      Export.backup(store),
      Export.csv(store),
      Export.ics(store),
      Export.text(store),
      jsonEncode([for (final c in db.changesSince(null)) c.toJson()]),
      db.meta('local.calendars')!,
    ].join('\n');
    // The calendar's own: its address, its events, their identifiers.
    for (final private in [
      FakeCalendarServer.secret,
      'basic.ics',
      'Dentist appointment',
      'event-0@test',
    ]) {
      expect(outgoing, isNot(contains(private)), reason: '"$private" must stay on the device');
    }
    // The user's own: how the calendar is named and shown (it starts out
    // under the name its feed gives), and the note.
    expect(uploaded, contains('Private diary'));
    expect(uploaded, contains('Renamed diary'));
    expect(uploaded, contains('green'));
    expect(uploaded, contains('Ask about the crown'));
    expect(Export.backup(store), contains('Ask about the crown'));
  });

  test('a refresh asks only for changes, and picks them up', () async {
    final s = service();
    await s.add(address: server.address);
    await s.refresh();
    expect(server.requests.last, contains('if-none-match="v1"'));
    expect(titles(s, friday), ['Dentist appointment']);

    server
      ..version = 2
      ..body = FakeCalendarServer.feed(['Dentist moved', 'Team lunch']);
    await s.refresh();
    expect(titles(s, friday), ['Dentist moved']);
    expect(titles(s, friday.addDays(1)), ['Team lunch']);
    expect(s.subscriptions.single.events, 2);
    expect(s.subscriptions.single.error, isNull);
  });

  test('a failed refresh keeps the last events and says why', () async {
    final s = service();
    await s.add(address: server.address);
    server.status = 404;
    await s.refresh();
    expect(s.subscriptions.single.error, contains('was not accepted (404)'));
    expect(titles(s, friday), ['Dentist appointment']);

    await server.stop();
    await s.refresh();
    // Whether the dropped connection shows as unreachable or as cut off
    // depends on timing; either way it is reported.
    expect(s.subscriptions.single.error,
        anyOf(contains('Could not reach'), contains('Connection problem')));
    expect(titles(s, friday), ['Dentist appointment']);
    // The error never quotes the address.
    expect(s.subscriptions.single.error, isNot(contains(FakeCalendarServer.secret)));
  });

  test('the next start shows the saved events without a connection', () async {
    final first = service();
    await first.add(address: server.address);
    await server.stop();

    final second = service();
    await second.load();
    expect(second.subscriptions.single.name, 'Private diary');
    expect(titles(second, friday), ['Dentist appointment']);
  });

  test('removing a calendar forgets its address and its events', () async {
    final s = service();
    await s.add(address: server.address);
    await s.remove(s.subscriptions.single.id);
    expect(s.subscriptions, isEmpty);
    expect(titles(s, friday), isEmpty);
    expect(secrets.values, isEmpty);
    expect(cache.feeds, isEmpty);
    expect(db.meta('local.calendars'), isNull);
  });

  test('events of several calendars share a day, all-day ones first by title', () async {
    final s = service();
    await s.add(address: server.address);
    server.body = FakeCalendarServer.feed(['Birthday'], name: 'Family');
    await s.add(address: '${server.address}?second');
    expect(titles(s, friday), ['Birthday', 'Dentist appointment']);
    expect(s.subscriptions.map((c) => c.color).toSet(), hasLength(2));
  });

  test('a large calendar is read off the main thread and still answers', () async {
    server.body = FakeCalendarServer.feed([
      for (var i = 0; i < 1; i++) 'Dentist appointment',
    ]).replaceFirst('END:VCALENDAR', '${[
      for (var i = 0; i < 4000; i++) ...[
        'BEGIN:VEVENT',
        'UID:bulk-$i@test',
        'SUMMARY:Past event number $i with a reasonably long title',
        'DTSTART;VALUE=DATE:20200101',
        'DTEND;VALUE=DATE:20200102',
        'END:VEVENT',
      ],
    ].join('\r\n')}\r\nEND:VCALENDAR');
    expect(server.body.length, greaterThan(200 * 1024)); // far over the limit
    final s = service();
    expect(await s.add(address: server.address), isNull);
    expect(s.subscriptions.single.events, 4001);
    expect(titles(s, friday), ['Dentist appointment']);
  });
}
