import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/calendar_service.dart';
import 'package:fweek/calendar/ics.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/local_backups.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/main.dart';
import 'package:fweek/services/opener.dart';
import 'package:fweek/services/places.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/sync_service.dart';

/// The day the reference captures were taken, so renders line up with them.
final referenceToday = Day(2026, 11, 13);

/// Loads the real fonts; without this, tests render every glyph as a box.
Future<void> loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File(file).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ]);
  final cache = Platform.environment['PUB_CACHE'] ?? '.tools/pub-cache';
  final lucide = Directory('$cache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('lucide_icons_flutter-'))
      .first;
  final font = File('${lucide.path}/assets/build_font/LucideVariable-w300.ttf');
  final loader = FontLoader('packages/lucide_icons_flutter/Lucide300')
    ..addFont(Future.value(ByteData.view(font.readAsBytesSync().buffer)));
  await loader.load();
}

/// How far the clock of every [seededStore] is ahead of its morning. A test
/// sets it to let time pass (a day end), and back when it is done.
Duration seededClockAhead = Duration.zero;

/// A store holding tasks comparable to the reference demo week.
PlannerStore seededStore({Day? today}) {
  final start = today ?? referenceToday;
  // Twenty to ten in the morning: two fifths of the day are over, which is
  // how far the bar under today's heading is filled in every render.
  DateTime moment() =>
      DateTime(start.year, start.month, start.day, 9, 36).add(seededClockAhead);
  final now = Day.fromDateTime(moment());
  final store = PlannerStore(
    PlannerDatabase.inMemory(),
    today: () => Day.fromDateTime(moment()),
    now: () => moment().millisecondsSinceEpoch,
  )..setSetting(Settings.rollover, false);
  final monday = now.startOfWeek();
  store.addTask(DaySlot(monday), 'Buy oat milk and a very long task title that should be cut off');
  final second = store.addTask(DaySlot(monday), 'Second task')!;
  store.setDone(second, true);
  final dentist = store.addTask(DaySlot(monday), 'Call dentist')!;
  store.updateTask(dentist, color: () => 'yellow', time: () => 9 * 60 + 30);
  store.addTask(DaySlot(now), 'Water the plants');
  final sat = monday.addDays(5), sun = monday.addDays(6);
  store.addTask(DaySlot(sat), 'Mark me complete');
  store.addTask(DaySlot(sat), 'Tap and edit');
  store.addTask(DaySlot(sat), 'Drag to the next day');
  final color = store.addTask(DaySlot(sun), 'Choose a color')!;
  store.updateTask(color, color: () => 'yellow');
  final timed = store.addTask(DaySlot(sun), 'Set a time')!;
  store.updateTask(timed, time: () => 12 * 60);
  store.addTask(ListSlot(store.lists.first.id), 'Keep tasks here without a date');
  return store;
}

/// Ticks the task [id] as it would have been ticked [daysAgo] days ago: a
/// list keeps what was ticked today among its rows, and puts away what was
/// ticked before.
void tickEarlier(PlannerStore store, String id, {int daysAgo = 1}) {
  final at = store.clock.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch;
  store.refresh(store.db.apply(store.db.stamp('tasks', id, {'done': true, 'done_at': at})));
}

/// A widget test of the Linux desktop app. The test framework otherwise
/// poses as Android, where the app uses its phone metrics.
void desktopTest(String description, WidgetTesterCallback body) => testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

/// A widget test of the Android app.
void phoneTest(String description, WidgetTesterCallback body) => testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

/// Pumps the whole app at a window size, with the given store.
Future<void> pumpApp(
  WidgetTester tester,
  PlannerStore store, {
  Size size = const Size(1440, 900),
  Brightness brightness = Brightness.light,
  CalendarService? calendars,
  Opener? opener,
  PlaceSearch? places,
  SyncService? sync,
  LocalBackups? backups,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  await tester.pumpWidget(FweekApp(
    store: store,
    notifications: false,
    calendars: calendars,
    sync: sync,
    backups: backups,
    // Nothing leaves a test: links are recorded, places come from a list.
    opener: opener ?? Opener(android: (uri) async => true),
    places: places ?? FakePlaces(),
  ));
  await tester.pumpAndSettle();
}

/// A click with the secondary mouse button on the centre of [target].
Future<void> rightClick(WidgetTester tester, Finder target) async {
  final mouse = await tester.startGesture(tester.getCenter(target),
      kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
  await mouse.up();
  await tester.pumpAndSettle();
}

/// An [Opener] that records what it was asked to open.
Opener recordingOpener(List<String> opened) => Opener(android: (uri) async {
      opened.add(uri);
      return true;
    });

/// A place search that answers from a fixed list, without a network.
class FakePlaces extends PlaceSearch {
  FakePlaces([this.places = const []]);

  final List<Place> places;
  final List<String> asked = [];

  @override
  Future<List<Place>> search(
    String query, {
    String server = PlaceSearch.defaultServer,
    String? language,
    (double, double)? near,
  }) async {
    asked.add(query);
    final needle = query.trim().toLowerCase();
    return [
      for (final place in places)
        if (place.label.toLowerCase().contains(needle)) place,
    ];
  }
}

/// A calendar feed for the reference week (9 to 15 November 2026): a timed
/// event, one over two whole days, and a weekly one.
const referenceFeed = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Calendar//EN
BEGIN:VEVENT
UID:meeting@test
SUMMARY:Team meeting
LOCATION:Room 204
DESCRIPTION:Bring the draft.
DTSTART:20261109T090000Z
DTEND:20261109T100000Z
END:VEVENT
BEGIN:VEVENT
UID:conference@test
SUMMARY:Conference
DTSTART;VALUE=DATE:20261113
DTEND;VALUE=DATE:20261115
END:VEVENT
BEGIN:VEVENT
UID:committee@test
SUMMARY:Thesis committee
DTSTART:20261113T133000Z
DTEND:20261113T150000Z
END:VEVENT
BEGIN:VEVENT
UID:seminar@test
SUMMARY:Group seminar
DTSTART:20261104T080000Z
DTEND:20261104T090000Z
RRULE:FREQ=WEEKLY;BYDAY=WE
END:VEVENT
END:VCALENDAR
''';

/// A calendar service that already holds [feed], as if it had been read on
/// an earlier run. Times are shown one hour ahead of UTC whatever the
/// machine's zone, and nothing goes online.
Future<CalendarService> calendarWith(
  WidgetTester tester,
  PlannerStore store, {
  String feed = referenceFeed,
  String name = 'Work',
  String color = 'blue',
}) async {
  final cache = MemoryCalendarCache()..feeds['c1'] = feed;
  store.db.setMeta(
    'local.calendars',
    jsonEncode([
      {'id': 'c1', 'name': name, 'color': color},
    ]),
  );
  late CalendarService service;
  // Outside the test's fake clock, so the service's refresh timer is not
  // mistaken for one the test left behind.
  await tester.runAsync(() async {
    service = CalendarService(
      store,
      MemorySecretStore(),
      cache,
      parse: (text) async => IcsCalendar.parse(
        text,
        toLocal: (utc) =>
            DateTime(utc.year, utc.month, utc.day, utc.hour + 1, utc.minute),
      ),
    );
    await service.load();
  });
  addTearDown(service.dispose);
  return service;
}
