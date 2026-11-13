import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:weekleaf/data/models.dart';
import 'package:weekleaf/data/planner_store.dart';
import 'package:weekleaf/ui/task_list.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  final monday = referenceToday.startOfWeek();
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  testWidgets('typing in an empty row adds tasks, one per Enter', (tester) async {
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

  testWidgets('clicking an empty row makes it ready for typing', (tester) async {
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

  testWidgets('the check button completes a task', (tester) async {
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

  testWidgets('dragging moves a task to another day at the drop position', (tester) async {
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

  testWidgets('arrow keys change week, T returns to today', (tester) async {
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

  testWidgets('task dialog: edit title, colour and repeat', (tester) async {
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

  testWidgets('task dialog: date, time, reminder, subtasks and custom repeat render', (tester) async {
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

  testWidgets('menu, search and settings open and work', (tester) async {
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
    await tester.tap(find.text('Dark'));
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
