import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';

import 'harness.dart';

/// The app as it runs on Android: touch input and the phone's metrics.
void main() {
  setUpAll(loadFonts);

  const phone = Size(411, 914);
  final friday = referenceToday;
  final saturday = friday.addDays(1);
  List<String> titles(Iterable<Task> tasks) => [for (final t in tasks) t.title];

  phoneTest('the week opens at today, with rows sized for a finger', (tester) async {
    await pumpApp(tester, seededStore(), size: phone);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_week_light.png'));
    // Monday heads the week but today (Friday) is what the page starts on.
    expect(tester.getTopLeft(find.text('Water the plants')).dy, lessThan(phone.height / 2));
    expect(tester.getSize(find.text('Water the plants')).height, greaterThan(20));
  });

  phoneTest('a long press picks a task up and drops it on another day', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, size: phone);
    final from = tester.getCenter(find.text('Water the plants'));
    final target = tester.getCenter(find.text('Tap and edit'));
    final finger = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 700));
    await finger.moveTo(target);
    await tester.pumpAndSettle();
    await finger.up();
    await tester.pumpAndSettle();
    expect(titles(store.tasksOn(friday)), isEmpty);
    expect(titles(store.tasksOn(saturday)), contains('Water the plants'));
  });

  phoneTest('a finger that moves at once scrolls and leaves tasks alone', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, size: phone);
    final before = tester.getTopLeft(find.text('Mark me complete')).dy;
    final finger = await tester.startGesture(
        tester.getCenter(find.text('Mark me complete')),
        kind: PointerDeviceKind.touch);
    // The page opens with today at its top; the days before are above.
    await finger.moveBy(const Offset(0, 30));
    await finger.moveBy(const Offset(0, 90));
    await tester.pump();
    await finger.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Mark me complete')).dy, greaterThan(before));
    expect(titles(store.tasksOn(saturday)),
        ['Mark me complete', 'Tap and edit', 'Drag to the next day']);
    expect(titles(store.tasksOn(friday)), ['Water the plants']);
  });

  phoneTest('a sideways swipe turns the week, the title leads back to today', (tester) async {
    final store = seededStore();
    await pumpApp(tester, store, size: phone);
    expect(find.text('2026 · W46'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('2026 · W47'), findsOneWidget);
    expect(find.text('Water the plants'), findsNothing);

    await tester.tap(find.text('November'));
    await tester.pumpAndSettle();
    expect(find.text('2026 · W46'), findsOneWidget);
    expect(find.text('Water the plants'), findsOneWidget);

    // On the current week the title opens the month, and brings one back.
    await tester.tap(find.text('November'));
    await tester.pumpAndSettle();
    expect(store.setting<String>(Settings.view), 'month');
    await tester.tap(find.text('November'));
    await tester.pumpAndSettle();
    expect(store.setting<String>(Settings.view), 'week');
  });

  phoneTest('the task sheet and menus keep clear of the system bars', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 48);
    addTearDown(tester.view.reset);
    await pumpApp(tester, seededStore(), size: phone);
    // The header starts below the status bar.
    expect(tester.getTopLeft(find.text('November')).dy, greaterThanOrEqualTo(40));
    await tester.tap(find.text('Water the plants'));
    await tester.pumpAndSettle();
    // The sheet's toolbar ends above the navigation bar.
    final toolbar = tester.getBottomLeft(find.bySemanticsLabel('Add subtask')).dy;
    expect(toolbar, lessThanOrEqualTo(phone.height - 48));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_sheet.png'));
  });
}
