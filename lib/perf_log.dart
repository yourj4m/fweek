import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/scheduler.dart';

import 'data/models.dart';
import 'data/planner_store.dart';

/// Frame timing for performance work. Compiled in only with
/// `--dart-define=WEEKTODO_PERF=true`; see tools/android-perf.py, which
/// drives the app and reads these lines from the device log.
const perfLog = bool.fromEnvironment('WEEKTODO_PERF');

/// Logs, about once a second while frames are drawn, how long each frame
/// took to build (the interface thread) and to raster (the graphics thread),
/// in microseconds: `PERF b=…,… r=…,…`.
void startPerfLog() {
  if (!perfLog) return;
  final build = <int>[], raster = <int>[];
  void flush() {
    if (build.isEmpty) return;
    // ignore: avoid_print
    print('PERF b=${build.join(',')} r=${raster.join(',')}');
    build.clear();
    raster.clear();
  }

  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds);
      raster.add(t.rasterDuration.inMicroseconds);
      // A log line holds a few thousand characters at most.
      if (build.length >= 40) flush();
    }
  });
  Timer.periodic(const Duration(seconds: 1), (_) => flush());
}

/// Fills an empty planner with a well-used one's worth of tasks, lists and
/// calendar events, the same every time, so that timings can be compared
/// between builds.
void seedForPerf(PlannerStore store, Directory data) {
  if (!perfLog || store.allTasks.isNotEmpty) return;
  final rng = Random(7);
  const words = [
    'Review', 'Call', 'Write', 'Plan', 'Fix', 'Read', 'Send', 'Book', 'Check', //
    'Prepare', 'notes', 'report', 'the dentist', 'groceries', 'slides', 'budget',
    'tickets', 'the draft', 'a walk', 'emails', 'laundry', 'the paper',
  ];
  const colors = ['red', 'yellow', 'blue', 'green', 'orange', 'purple', 'lilac', 'cyan'];
  String title(int n) =>
      '${words[rng.nextInt(10)]} ${words[10 + rng.nextInt(12)]} $n';

  store.setSetting(Settings.rollover, false);
  final first = store.today.startOfWeek(store.weekStart).addDays(-28);
  var n = 0;
  for (var d = 0; d < 70; d++) {
    final day = first.addDays(d);
    final count = 4 + rng.nextInt(6);
    for (var i = 0; i < count; i++) {
      final id = store.addTask(DaySlot(day), title(++n))!;
      final roll = rng.nextInt(10);
      if (roll < 3) store.updateTask(id, color: () => colors[rng.nextInt(colors.length)]);
      if (roll == 3 || roll == 4) store.updateTask(id, time: () => (8 + rng.nextInt(10)) * 60);
      if (roll == 5) store.updateTask(id, note: 'A note for task $n.\nhttps://example.org/$n');
      if (day < store.today && rng.nextBool()) store.setDone(id, true);
    }
  }
  final lists = [store.lists.first.id, store.addList('Reading'), store.addList('Home')];
  for (final list in lists) {
    for (var i = 0; i < 6; i++) {
      store.addTask(ListSlot(list), title(++n));
    }
  }

  // A calendar as an earlier run would have left it: the list in the
  // database, the feed in the cache beside it.
  String stamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';
  final start = first.toLocal();
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//WeekToDo//Perf//EN',
    'X-WR-CALNAME:Calendar',
  ];
  void event(String uid, String summary, List<String> rest) => lines.addAll([
        'BEGIN:VEVENT',
        'UID:$uid@perf',
        'SUMMARY:$summary',
        ...rest,
        'END:VEVENT',
      ]);
  for (var i = 0; i < 3; i++) {
    final day = stamp(start.add(Duration(days: i * 2)));
    event('series-$i', 'Weekly meeting ${i + 1}', [
      'DTSTART:${day}T0${8 + i}0000Z',
      'DTEND:${day}T0${9 + i}0000Z',
      'RRULE:FREQ=WEEKLY',
      'LOCATION:Room ${200 + i}',
    ]);
  }
  for (var i = 0; i < 40; i++) {
    final day = stamp(start.add(Duration(days: rng.nextInt(70))));
    final hour = (9 + rng.nextInt(8)).toString().padLeft(2, '0');
    event('single-$i', 'Appointment ${i + 1}', [
      'DTSTART:${day}T${hour}0000Z',
      'DTEND:${day}T${hour}4500Z',
      'DESCRIPTION:Details at https://example.org/a/$i',
    ]);
  }
  for (var i = 0; i < 8; i++) {
    final from = start.add(Duration(days: 3 + i * 8));
    event('long-$i', 'Trip ${i + 1}', [
      'DTSTART;VALUE=DATE:${stamp(from)}',
      'DTEND;VALUE=DATE:${stamp(from.add(Duration(days: 2 + i % 3)))}',
    ]);
  }
  lines.add('END:VCALENDAR');
  Directory('${data.path}/calendars').createSync(recursive: true);
  File('${data.path}/calendars/perf.ics').writeAsStringSync(lines.join('\r\n'));
  store.db.setMeta(
    'local.calendars',
    jsonEncode([
      {'id': 'perf', 'name': 'Calendar', 'color': 'blue'},
    ]),
  );
}
