import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/main.dart';
import 'package:fweek/services/notifications.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/ui/task_list.dart' show TaskListBody;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart' show TextField;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The real desktop app on the machine it was built for (Windows in the
/// build service, Linux too), with the platform's own services: the folder
/// for the app's data, the store for passwords, notifications, files
/// dropped on the window. Widget tests stand in for all of these.
///
///     flutter test integration_test -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('fweek-it'));
  tearDown(() {
    try {
      folder.deleteSync(recursive: true);
    } on FileSystemException {
      // The database may still be open on Windows; the system cleans up.
    }
  });

  testWidgets('the folder for the app\'s data can be written', (tester) async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final probe = File(p.join(directory.path, 'probe-${DateTime.now().microsecondsSinceEpoch}'));
    probe.writeAsStringSync('ok');
    expect(probe.readAsStringSync(), 'ok');
    probe.deleteSync();
  });

  testWidgets('a password is kept by the system and read back', (tester) async {
    const secrets = KeyringSecretStore();
    const key = 'fweek-integration-test';
    await secrets.write(key, 'säkret & "quoted"');
    expect(await secrets.read(key), 'säkret & "quoted"');
    await secrets.delete(key);
    expect(await secrets.read(key), isNull);
  });

  testWidgets('notifications start without failing', (tester) async {
    final notifications = DesktopNotifications()..init();
    // Whether one appears depends on the session (the build service has no
    // one to see it); it must not throw either way.
    await notifications.show(title: 'fweek test', body: 'From the integration test');
  });

  testWidgets('a task typed into the week is stored, and is there after a restart',
      (tester) async {
    final path = p.join(folder.path, 'planner.db');
    var store = PlannerStore(PlannerDatabase.open(path));
    await tester.pumpWidget(FweekApp(store: store, notifications: false));
    await tester.pumpAndSettle();

    final today = find.descendant(
      of: find.byWidgetPredicate(
          (w) => w is TaskListBody && w.slot == DaySlot(store.today)),
      matching: find.byType(TextField),
    );
    expect(today, findsWidgets);
    await tester.tap(today.first);
    await tester.pumpAndSettle();
    await tester.enterText(today.first, 'Typed on ${Platform.operatingSystem}');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.allTasks.map((t) => t.title), contains('Typed on ${Platform.operatingSystem}'));

    // The settings open from the keyboard, in their sections.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sync settings'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Sync settings'));
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Closed and opened again.
    await tester.pumpWidget(const SizedBox());
    store.db.close();
    store = PlannerStore(PlannerDatabase.open(path));
    await tester.pumpWidget(FweekApp(store: store, notifications: false));
    await tester.pumpAndSettle();
    expect(find.text('Typed on ${Platform.operatingSystem}'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    store.db.close();
  });

  testWidgets('a calendar file dropped on the window, under this system\'s paths, is added',
      (tester) async {
    final store = PlannerStore(PlannerDatabase.open(p.join(folder.path, 'planner.db')));
    await tester.pumpWidget(FweekApp(store: store, notifications: false));
    await tester.pumpAndSettle();
    final day = store.today;
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${day.year}${two(day.month)}${two(day.day)}';
    // A folder with a space and an accent, as user folders on Windows have.
    final inside = Directory(p.join(folder.path, 'Mes documents é'))..createSync();
    final file = File(p.join(inside.path, 'invite.ics'))
      ..writeAsStringSync([
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'BEGIN:VEVENT',
        'UID:dropped@example.org',
        'SUMMARY:Dropped seminar',
        'DTSTART;VALUE=DATE:$date',
        'END:VEVENT',
        'END:VCALENDAR',
        '',
      ].join('\r\n'));
    // What the window's own code sends when files are dropped on it.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'fweek/drop',
      const StandardMethodCodec().encodeMethodCall(MethodCall('files', [file.path])),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(store.allTasks.map((t) => t.title), contains('Dropped seminar'));
    await tester.pumpWidget(const SizedBox());
    store.db.close();
  });
}
