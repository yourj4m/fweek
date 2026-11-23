import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:fweek/data/day.dart';
import 'package:fweek/data/export.dart';
import 'package:fweek/data/local_backups.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_service.dart';
import 'package:fweek/ui/icons.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  Finder syncButton() => find.bySemanticsLabel('Sync everything (S)');

  /// A sync service joined to a folder kept in memory, which [down] makes
  /// unreachable. Its timers stop with the returned service's dispose.
  Future<SyncService> connected(PlannerStore store, MemoryStorage folder,
      {bool Function()? down}) async {
    final service = SyncService(
      store,
      MemorySecretStore(),
      storageFor: (config, password) => folder
        ..failNext = (op, path) => down?.call() ?? false,
    );
    expect(
        await service.connect(
            server: 'cloud.example.com', user: 'me', password: 'right', folder: 'fweek'),
        isNull);
    return service;
  }

  desktopTest('the header has a button that syncs everything, between New event and the menu',
      (tester) async {
    final store = seededStore();
    await pumpApp(tester, store);
    expect(syncButton(), findsOneWidget);
    final x = tester.getCenter(syncButton()).dx;
    expect(x, greaterThan(tester.getCenter(find.bySemanticsLabel('New event (N)')).dx));
    expect(x, lessThan(tester.getCenter(find.bySemanticsLabel('Menu')).dx));
    // It is there on every page, in the same place.
    await tester.tap(find.bySemanticsLabel('Tasks'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(syncButton()).dx, x);
    await tester.tap(find.bySemanticsLabel('Month'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(syncButton()).dx, x);

    // With nothing connected and no place for copies (a test), it says so.
    await tester.tap(syncButton());
    await tester.pumpAndSettle();
    expect(find.text('Nothing to sync yet'), findsOneWidget);
  });

  desktopTest('one press brings what other devices changed, and says what was done',
      (tester) async {
    final monday = Day(2026, 11, 9);
    final folder = MemoryStorage();
    final phoneStore = seededStore();
    final phone = await connected(phoneStore, folder);
    final store = seededStore();
    final service = await connected(store, folder);
    try {
      await pumpApp(tester, store, sync: service);
      phoneStore.addTask(DaySlot(monday), 'From the phone');
      await phone.syncNow();
      expect(find.text('From the phone'), findsNothing);

      await tester.tap(syncButton());
      await tester.pumpAndSettle();
      expect(find.text('From the phone'), findsOneWidget);
      expect(find.text('Nextcloud in sync'), findsOneWidget);

      // S does the same, and so does the menu.
      phoneStore.addTask(DaySlot(monday), 'And another');
      await phone.syncNow();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.text('And another'), findsOneWidget);
      phoneStore.addTask(DaySlot(monday), 'A third');
      await phone.syncNow();
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync everything'));
      await tester.pumpAndSettle();
      expect(find.text('A third'), findsOneWidget);
    } finally {
      phone.dispose();
      service.dispose();
    }
  });

  desktopTest('a sync that fails is said, with the way to the settings, and the button warns',
      (tester) async {
    final folder = MemoryStorage();
    var down = false;
    final store = seededStore();
    final service = await connected(store, folder, down: () => down);
    try {
      await pumpApp(tester, store, sync: service);
      expect(find.byIcon(AppIcons.cloudAlert), findsNothing);
      down = true;
      await tester.tap(syncButton());
      await tester.pumpAndSettle();
      expect(find.textContaining('Nextcloud: '), findsOneWidget);
      // The button is a warning until a sync works again.
      expect(
        find.descendant(of: syncButton(), matching: find.byIcon(AppIcons.cloudAlert)),
        findsOneWidget,
      );
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/sync_failed.png'));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Sync now'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      down = false;
      await tester.tap(syncButton());
      await tester.pumpAndSettle();
      expect(find.text('Nextcloud in sync'), findsOneWidget);
      expect(find.byIcon(AppIcons.cloudAlert), findsNothing);
    } finally {
      service.dispose();
    }
  });

  phoneTest('on a phone the page, at its top, is pulled down to sync; the header has no button',
      (tester) async {
    final friday = Day(2026, 11, 13);
    final folder = MemoryStorage();
    final deskStore = seededStore();
    final desk = await connected(deskStore, folder);
    final store = seededStore();
    final service = await connected(store, folder);
    List<String> today() => [for (final t in store.tasksOn(friday)) t.title];
    // Lets the mark settle, the sync run and the mark go.
    Future<void> rest() async {
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
    }

    try {
      await pumpApp(tester, store, size: const Size(393, 851), sync: service);
      // Four buttons in the header, as before.
      expect(find.byIcon(AppIcons.refreshCw), findsNothing);
      expect(find.bySemanticsLabel('New event'), findsOneWidget);

      deskStore.addTask(DaySlot(friday), 'From the desk');
      await desk.syncNow();

      // The week opens with today at the top of the screen. Pulling down
      // there scrolls to the days before, however far the finger goes, and
      // syncs nothing.
      await tester.dragFrom(const Offset(196, 300), const Offset(0, 1500));
      await rest();
      expect(find.text('9 Nov'), findsOneWidget);
      expect(today(), isNot(contains('From the desk')));

      // At the top, a pull shows the mark that follows the finger ...
      final finger = await tester.startGesture(const Offset(196, 260));
      await finger.moveBy(const Offset(0, 40));
      await tester.pump();
      await finger.moveBy(const Offset(0, 240));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('goldens/phone_pull_to_sync.png'));
      // ... and letting go syncs.
      await finger.up();
      await rest();
      expect(today(), contains('From the desk'));
      expect(find.text('Nextcloud in sync'), findsOneWidget);

      // A short pull that is taken back does nothing.
      deskStore.addTask(DaySlot(friday), 'Not yet');
      await desk.syncNow();
      final hesitant = await tester.startGesture(const Offset(196, 260));
      await hesitant.moveBy(const Offset(0, 40));
      await tester.pump();
      await hesitant.moveBy(const Offset(0, 30));
      await tester.pump();
      await hesitant.up();
      await rest();
      expect(today(), isNot(contains('Not yet')));

      // The lists of the Tasks page are pulled the same way.
      await tester.tap(find.bySemanticsLabel('Tasks'));
      await tester.pumpAndSettle();
      await tester.flingFrom(const Offset(196, 300), const Offset(0, 320), 1000);
      await rest();
      expect(today(), contains('Not yet'));
    } finally {
      desk.dispose();
      service.dispose();
    }
  });

  desktopTest('the settings list the copies kept on this device and bring one back',
      (tester) async {
    final monday = Day(2026, 11, 9);
    final folder = Directory.systemTemp.createTempSync('fweek-copies-');
    addTearDown(() => folder.deleteSync(recursive: true));
    // Copies of yesterday and of three days ago, the older one from before
    // a task was deleted.
    final store = seededStore();
    final lost = store.addTask(DaySlot(monday), 'Deleted by mistake')!;
    File('${folder.path}/planner-2026-11-10.json')
      ..writeAsStringSync(Export.backup(store))
      ..setLastModifiedSync(DateTime(2026, 11, 10, 8, 5));
    store.deleteTask(lost);
    File('${folder.path}/planner-2026-11-12.json')
      ..writeAsStringSync(Export.backup(store))
      ..setLastModifiedSync(DateTime(2026, 11, 12, 18, 30));
    await pumpApp(tester, store,
        size: const Size(1440, 1500), backups: LocalBackups(folder));
    expect(find.text('Deleted by mistake'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copies kept on this device: 2, the latest from yesterday'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Restore a copy'));
    await tester.tap(find.text('Restore a copy'));
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/settings_copies.png'));
    await tester.tap(find.text('Tue, 10 Nov'));
    await tester.pumpAndSettle();
    expect(find.textContaining('from the copy of tue, 10 nov'), findsOneWidget);
    expect([for (final t in store.tasksOn(monday)) t.title], contains('Deleted by mistake'));
  });
}
