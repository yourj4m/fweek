import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'data/database.dart';
import 'data/planner_store.dart';
import 'platform.dart';
import 'services/android_bridge.dart';
import 'services/notifications.dart';
import 'services/reminders.dart';
import 'sync/secrets.dart';
import 'sync/sync_service.dart';
import 'theme/app_theme.dart';
import 'ui/planner_page.dart';
import 'ui/task_dialog.dart' show showTaskDialog;

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

  /// Whether to deliver reminders through the system (off in widget tests).
  final bool notifications;

  @override
  State<WeekToDoApp> createState() => _WeekToDoAppState();
}

class _WeekToDoAppState extends State<WeekToDoApp> {
  late final AppController _controller = AppController(widget.store);
  late final SyncService _sync =
      widget.sync ?? SyncService(widget.store, const KeyringSecretStore());
  late final ReminderService _reminders;
  final _navigator = GlobalKey<NavigatorState>();
  AndroidBridge? _android;
  DesktopNotifications? _desktop;
  AppLifecycleListener? _lifecycle;

  static const _askedKey = 'local.notifications_asked';

  @override
  void initState() {
    super.initState();
    final live = widget.notifications;
    if (live && Platform.isAndroid) {
      final android = _android = AndroidBridge()..onOpenTask = _openTask;
      android.takeLaunchTask().then((id) {
        if (id != null) _openTask(id);
      });
    } else if (live && Platform.isLinux) {
      _desktop = DesktopNotifications()..init();
    }
    _reminders = ReminderService(
      widget.store,
      notify: _notifyNow,
      schedule: _android == null ? null : _handOver,
    );
    _sync.load();
    // Tests run without the reminder timer; they still get the rollover.
    if (live) {
      _reminders.start();
    } else {
      widget.store.rollOver();
    }
    if (live && isMobile) {
      // A phone suspends the app in the background: no timer runs there, so
      // catch up when it returns and push pending edits when it leaves.
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _reminders.check();
          _sync.resumed();
        },
        onHide: _sync.leaving,
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _reminders.dispose();
    if (widget.sync == null) _sync.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _use24h => widget.store.setting<bool>(Settings.use24h);

  /// Desktop: a reminder is due now.
  void _notifyNow(DueReminder due) {
    final text = reminderText(due, use24h: _use24h);
    _desktop?.show(title: text.title, body: text.body);
  }

  /// Android: the system takes over the reminders ahead.
  Future<void> _handOver(List<DueReminder> upcoming) async {
    final android = _android!;
    try {
      await android.syncReminders([
        for (final due in upcoming)
          () {
            final text = reminderText(due, use24h: _use24h);
            return ScheduledReminder(
              id: stableId('${due.task.id}|${due.at.toIso8601String()}|'
                  '${text.title}|${text.body}'),
              at: due.at,
              title: text.title,
              body: text.body,
              taskId: due.task.id,
            );
          }(),
      ]);
      // Ask for the permission when the first reminder exists, not at the
      // first start; and only once, the answer can be changed in Settings.
      if (upcoming.isNotEmpty && widget.store.db.meta(_askedKey) == null) {
        widget.store.db.setMeta(_askedKey, '1');
        await android.requestNotifications();
      }
    } on Object catch (error) {
      debugPrint('Could not schedule reminders: $error');
    }
  }

  /// A reminder notification was tapped: show that task.
  void _openTask(String id) {
    final task = widget.store.task(id);
    if (task == null) return;
    final date = task.date;
    if (date != null) _controller.show(date, highlight: task.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) showTaskDialog(context, task.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeekToDo',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: AppText.family),
      builder: (context, child) => AppScope(
        store: widget.store,
        controller: _controller,
        sync: _sync,
        android: _android,
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
    // Text follows the system's font size, within what ruled rows of a fixed
    // height can hold.
    final media = MediaQuery.of(context);
    final ink = theme.isDark ? Brightness.light : Brightness.dark;
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3),
      ),
      // The planner draws behind the system bars; their icons take its tone.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: const Color(0x00000000),
          statusBarIconBrightness: ink,
          statusBarBrightness: theme.isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: const Color(0x00000000),
          systemNavigationBarIconBrightness: ink,
          systemNavigationBarContrastEnforced: false,
        ),
        child: ThemeScope(
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
        ),
      ),
    );
  }
}
