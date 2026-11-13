import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'data/database.dart';
import 'data/planner_store.dart';
import 'services/reminders.dart';
import 'sync/secrets.dart';
import 'sync/sync_service.dart';
import 'theme/app_theme.dart';
import 'ui/planner_page.dart';
import 'ui/task_list.dart' show formatTime;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // WEEKTODO_DATA_DIR points the app at another data folder, for testing
  // without touching the real planner.
  final override = Platform.environment['WEEKTODO_DATA_DIR'];
  final directory = override != null && override.isNotEmpty
      ? Directory(override)
      : await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final store = PlannerStore(
    PlannerDatabase.open(p.join(directory.path, 'planner.db')),
  );
  runApp(WeekToDoApp(store: store));
}

class WeekToDoApp extends StatefulWidget {
  const WeekToDoApp({
    super.key,
    required this.store,
    this.notifications = true,
    this.sync,
  });

  final PlannerStore store;

  /// The sync service to use; by default one backed by the system keyring.
  final SyncService? sync;

  /// Whether to deliver desktop notifications (off in widget tests).
  final bool notifications;

  @override
  State<WeekToDoApp> createState() => _WeekToDoAppState();
}

class _WeekToDoAppState extends State<WeekToDoApp> {
  late final AppController _controller = AppController(widget.store);
  late final ReminderService _reminders =
      ReminderService(widget.store, notify: _notify);
  late final SyncService _sync =
      widget.sync ?? SyncService(widget.store, const KeyringSecretStore());
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool?>? _pluginReady;
  int _notificationId = 0;

  @override
  void initState() {
    super.initState();
    if (widget.notifications) {
      _pluginReady = _plugin
          .initialize(
            settings: const InitializationSettings(
              linux: LinuxInitializationSettings(defaultActionName: 'Open'),
            ),
          )
          .catchError((Object error) {
        debugPrint('Notifications unavailable: $error');
        return false;
      });
    }
    _sync.load();
    // Tests run without the reminder timer; they still get the rollover.
    if (widget.notifications) {
      _reminders.start();
    } else {
      widget.store.rollOver();
    }
  }

  @override
  void dispose() {
    _reminders.dispose();
    if (widget.sync == null) _sync.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _notify(DueReminder due) async {
    final ready = await _pluginReady;
    if (ready != true) return;
    final task = due.task;
    final use24h = widget.store.setting<bool>(Settings.use24h);
    final time = task.time == null
        ? null
        : formatTime(task.time!, use24h: use24h);
    try {
      await _plugin.show(
        id: _notificationId++,
        title: task.title,
        body: [?time, if (task.note.trim().isNotEmpty) task.note.trim()]
            .join(' · '),
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      debugPrint('Could not show a notification: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeekToDo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: AppText.family),
      builder: (context, child) => AppScope(
        store: widget.store,
        controller: _controller,
        sync: _sync,
        child: _Themed(child: child!),
      ),
      home: const PlannerPage(),
    );
  }
}

/// Resolves the theme setting and applies it to everything below.
class _Themed extends StatelessWidget {
  const _Themed({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final theme = AppTheme.resolve(
      store.setting<String>(Settings.theme),
      MediaQuery.platformBrightnessOf(context),
    );
    return ThemeScope(
      theme: theme,
      child: TextSelectionTheme(
        data: TextSelectionThemeData(
          cursorColor: theme.text,
          selectionColor: theme.accent.withValues(alpha: 0.3),
          selectionHandleColor: theme.accent,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: AppText(theme.text).body17,
            child: child,
          ),
        ),
      ),
    );
  }
}
