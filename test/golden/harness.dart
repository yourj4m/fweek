import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekleaf/data/database.dart';
import 'package:weekleaf/data/day.dart';
import 'package:weekleaf/data/models.dart';
import 'package:weekleaf/data/planner_store.dart';
import 'package:weekleaf/main.dart';

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

/// A store holding tasks comparable to the reference demo week.
PlannerStore seededStore({Day? today}) {
  final now = today ?? referenceToday;
  final store = PlannerStore(PlannerDatabase.inMemory(), today: () => now)
    ..setSetting(Settings.rollover, false);
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

/// Pumps the whole app at a window size, with the given store.
Future<void> pumpApp(
  WidgetTester tester,
  PlannerStore store, {
  Size size = const Size(1440, 900),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  await tester.pumpWidget(WeekleafApp(store: store, notifications: false));
  await tester.pumpAndSettle();
}
