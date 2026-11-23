import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fweek/app_state.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/main.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_service.dart';
import 'package:fweek/ui/planner_page.dart';
import 'package:fweek/ui/task_list.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  final monday = referenceToday.startOfWeek();
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  desktopTest('typing in an empty row adds tasks, one per Enter', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final tuesday = monday.addDays(1);
    // The second add row on screen belongs to Tuesday.
    await tester.tap(find.byType(AddRow).at(1));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'Write report');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'Send it');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(tuesday)), ['Write report', 'Send it']);
    expect(find.text('Write report'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/add_focused.png'));
  });

  desktopTest('clicking an empty row makes it ready for typing', (tester) async {
    // Regression: the row used to rebuild its text field on focus, leaving a
    // focused field with no keyboard connection. This goes through the real
    // input channel rather than setting the field's text directly.
    for (final hover in [false, true]) {
      final store = seededStore();
      await pumpApp(tester, store);
      final row = tester.getCenter(find.byType(AddRow).at(2));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      if (hover) {
        await mouse.moveTo(row);
        await tester.pumpAndSettle();
      }
      await mouse.down(row);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'hover=$hover');
      tester.testTextInput.enterText('Typed for real');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(titles(store.tasksOn(monday.addDays(2))), ['Typed for real'],
          reason: 'hover=$hover');
      // Still connected, for the next task.
      tester.testTextInput.enterText('And another');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(titles(store.tasksOn(monday.addDays(2))), ['Typed for real', 'And another'],
          reason: 'hover=$hover');
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    }
  });

  desktopTest('the check button completes a task', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Tap and edit')));
    await tester.pumpAndSettle();
    final row = find.ancestor(of: find.text('Tap and edit'), matching: find.byType(TaskRow));
    await tester.tap(find.descendant(of: row, matching: find.byType(CheckToggle)));
    await tester.pumpAndSettle();
    final saturday = monday.addDays(5);
    expect(store.tasksOn(saturday).firstWhere((t) => t.title == 'Tap and edit').done, isTrue);
  });

  desktopTest('dragging moves a task to another day at the drop position', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final saturday = monday.addDays(5);
    final from = tester.getCenter(find.text('Tap and edit'));
    // Drop onto Monday's second row (between its first and second task).
    final target = tester.getCenter(find.text('Second task')) - const Offset(0, 14);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-20, 10));
    await tester.pump();
    await gesture.moveTo(target + const Offset(60, 0));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dragging.png'));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(saturday)), ['Mark me complete', 'Drag to the next day']);
    expect(titles(store.tasksOn(monday)).indexOf('Tap and edit'), 1);
  });

  desktopTest('two fingers swiped sideways on the trackpad turn the week, once per swipe',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final app = tester.element(find.byType(PlannerPage)).readApp;
    final start = app.weekStart;
    Future<void> swipe(Offset by) async {
      final fingers = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await fingers.panZoomStart(const Offset(700, 450));
      // In steps, as a trackpad reports it.
      for (var i = 1; i <= 8; i++) {
        await fingers.panZoomUpdate(const Offset(700, 450), pan: by * (i / 8));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await fingers.panZoomEnd();
      await tester.pumpAndSettle();
    }

    await swipe(const Offset(-240, 6));
    expect(app.weekStart, start.addDays(7), reason: 'to the left: the next week, and only one');
    await swipe(const Offset(240, -4));
    expect(app.weekStart, start);
    await swipe(const Offset(30, 0));
    expect(app.weekStart, start, reason: 'a short twitch turns nothing');
    await swipe(const Offset(60, 240));
    expect(app.weekStart, start, reason: 'up and down is scrolling');

    // The month view turns by months.
    app.setMonthView(true);
    await tester.pumpAndSettle();
    final month = app.anchor.startOfMonth;
    await swipe(const Offset(-200, 0));
    expect(app.anchor.startOfMonth, month.addMonths(1));
  });

  desktopTest('a swipe that arrives as sideways scroll steps turns once too', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final app = tester.element(find.byType(PlannerPage)).readApp;
    final start = app.weekStart;
    Future<void> scroll(double dx, {int steps = 12}) async {
      for (var i = 0; i < steps; i++) {
        tester.binding.handlePointerEvent(PointerScrollEvent(
          position: const Offset(700, 450),
          scrollDelta: Offset(dx / steps, 0),
        ));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The fingers have left the trackpad.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    await scroll(400);
    expect(app.weekStart, start.addDays(7), reason: 'one swipe, one week, however long it coasts');
    await scroll(-400);
    expect(app.weekStart, start);
  });

  desktopTest('holding a task at the window edge carries it to the next week', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    final from = tester.getCenter(find.text('Tap and edit'));
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(10, 10));
    await tester.pump();
    await gesture.moveTo(const Offset(1432, 400));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('W47'), findsOneWidget);
    // Drop onto the new week's Monday.
    await gesture.moveTo(const Offset(130, 210));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(monday.addDays(7))), ['Tap and edit']);
    expect(titles(store.tasksOn(monday.addDays(5))), ['Mark me complete', 'Drag to the next day']);
  });

  desktopTest('arrow keys change week, T returns to today', (tester) async {
    await pumpApp(tester, seededStore());
    expect(find.text('W46'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('W47'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('W45'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
  });

  desktopTest('task dialog: edit title, colour and repeat', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    await tester.tap(find.text('Mark me complete'));
    await tester.pumpAndSettle();
    expect(find.text('Sat, 14 Nov 2026'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog.png'));

    await tester.enterText(find.widgetWithText(TextField, 'Mark me complete'), 'Renamed');
    await tester.pump(const Duration(milliseconds: 600));
    final saturday = monday.addDays(5);
    expect(titles(store.tasksOn(saturday)).first, 'Renamed');

    await tester.tap(find.bySemanticsLabel('Colour'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_colour.png'));
    await tester.tap(find.bySemanticsLabel('Green'));
    await tester.pumpAndSettle();
    expect(store.tasksOn(saturday).first.color, 'green');

    await tester.tap(find.bySemanticsLabel('Repeat'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_repeat.png'));
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(store.tasksOn(saturday.addDays(7)).single.title, 'Renamed');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_green_weekly.png'));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Sat, 14 Nov 2026'), findsNothing);
  });

  desktopTest('task dialog: date, time, reminder, subtasks and custom repeat render', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    await tester.tap(find.text('Tap and edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sat, 14 Nov 2026'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_date.png'));
    await tester.tap(find.text('17'));
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(monday.addDays(8))), ['Tap and edit']);

    await tester.tap(find.bySemanticsLabel('Time'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_time.png'));
    await tester.tap(find.text('10:00'));
    await tester.pumpAndSettle();
    expect(store.tasksOn(monday.addDays(8)).single.time, 600);

    await tester.tap(find.bySemanticsLabel('Add subtask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subtask'), 'First step');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.tasksOn(monday.addDays(8)).single.subtasks.map((s) => s.text), ['First step', '']);

    await tester.tap(find.bySemanticsLabel('Reminder'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_reminder.png'));
    await tester.tap(find.text('Set reminder'));
    await tester.pumpAndSettle();
    expect(store.tasksOn(monday.addDays(8)).single.reminder, DateTime(2026, 11, 17, 10));

    await tester.tap(find.bySemanticsLabel('Repeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_custom_repeat.png'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(store.tasksOn(monday.addDays(15)).single.repeats, isTrue);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dialog_full.png'));
  });

  desktopTest('sync is set up from the settings and shows its state', (tester) async {
    final store = seededStore();
    final remote = MemoryStorage();
    final secrets = MemorySecretStore();
    final service = SyncService(
      store,
      secrets,
      storageFor: (config, password) {
        if (password != 'right') {
          return MemoryStorage()
            ..failNext = (op, path) => true; // rejects the first request
        }
        return remote;
      },
    );
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(FweekApp(store: store, notifications: false, sync: service));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Sync now'), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_sync_off.png'));

    Finder field(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
        matching: find.byType(TextField));
    // The settings are longer than the window; bring the button into view
    // before each press.
    Future<void> press(String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await press('Connect');
    expect(find.text('Enter the server address.'), findsOneWidget);

    await tester.enterText(field('Server'), 'cloud.example.com');
    await tester.enterText(field('Login name'), 'jonas');
    await tester.enterText(field('App password'), 'wrong');
    await press('Connect');
    expect(find.text('The connection was lost.'), findsOneWidget);
    expect(service.configured, isFalse);

    await tester.enterText(field('App password'), 'right');
    await press('Connect');
    expect(service.configured, isTrue);
    expect(find.text('jonas on cloud.example.com, folder fweek'), findsOneWidget);
    expect(find.text('Synced just now.'), findsOneWidget);
    expect(remote.files, isNotEmpty);
    expect(secrets.values.values.single, 'right');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_sync_on.png'));

    await press('Disconnect');
    expect(find.text('Connect'), findsOneWidget);
    expect(service.configured, isFalse);
    service.dispose();
  });

  desktopTest('menu, search and settings open and work', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/menu.png'));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings.png'));
    await tester.tap(find.text('Sunday'));
    await tester.pumpAndSettle();
    expect(store.weekStart, 7);
    await tester.tap(find.bySemanticsLabel(RegExp('^Dark theme')));
    await tester.pumpAndSettle();
    expect(store.setting<String>(Settings.theme), 'dark');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'color');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/search_dark.png'));
    expect(find.text('Choose a color'), findsWidgets);
  });
}
