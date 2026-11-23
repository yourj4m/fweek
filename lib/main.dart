import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'calendar/calendar_service.dart';
import 'data/database.dart';
import 'data/planner_store.dart';
import 'perf_log.dart';
import 'platform.dart';
import 'services/android_bridge.dart';
import 'data/models.dart';
import 'services/notifications.dart';
import 'services/opener.dart';
import 'services/places.dart';
import 'services/reminders.dart';
import 'sync/secrets.dart';
import 'sync/sync_service.dart';
import 'theme/app_theme.dart';
import 'ui/planner_page.dart';
import 'ui/task_dialog.dart' show showTaskDialog;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // FWEEK_DATA_DIR points the app at another data folder, for testing
  // without touching the real planner.
  final override = Platform.environment['FWEEK_DATA_DIR'];
  final directory = override != null && override.isNotEmpty
      ? Directory(override)
      : await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final store = PlannerStore(
    PlannerDatabase.open(p.join(directory.path, 'planner.db')),
  );
  seedForPerf(store, directory);
  startPerfLog();
  runApp(FweekApp(
    store: store,
    calendars: CalendarService(
      store,
      const KeyringSecretStore(),
      FileCalendarCache(directory),
    ),
  ));
}

class FweekApp extends StatefulWidget {
  const FweekApp({
    super.key,
    required this.store,
    this.notifications = true,
    this.sync,
    this.calendars,
    this.opener,
    this.places,
  });

  /// Opens links and places; by default through the system (tests record
  /// what would be opened instead).
  final Opener? opener;

  /// The place search; by default the online one.
  final PlaceSearch? places;

  final PlannerStore store;

  /// Subscribed calendars; by default none, kept in memory (widget tests).
  final CalendarService? calendars;

  /// The sync service to use; by default one backed by the system keyring.
  final SyncService? sync;

  /// Whether to deliver reminders through the system (off in widget tests).
  final bool notifications;

  @override
  State<FweekApp> createState() => _FweekAppState();
}

class _FweekAppState extends State<FweekApp> {
  late final AppController _controller = AppController(widget.store);
  late final SyncService _sync =
      widget.sync ?? SyncService(widget.store, const KeyringSecretStore());
  late final ReminderService _reminders;
  late final CalendarService _calendars = widget.calendars ??
      CalendarService(widget.store, MemorySecretStore(), MemoryCalendarCache());
  final _navigator = GlobalKey<NavigatorState>();
  AndroidBridge? _android;
  DesktopNotifications? _desktop;
  AppLifecycleListener? _lifecycle;
  late final Opener _opener =
      widget.opener ?? Opener(android: _android?.openUri);
  late final PlaceSearch _places = widget.places ?? PlaceSearch();

  /// Resolves once the calendars' saved events are in memory.
  late final Future<void> _calendarsLoaded;
  late bool _frameTiming = widget.store.setting<bool>(Settings.frameTiming);

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
      events: () => _calendars.eventsWithReminders,
    );
    widget.store.addListener(_onStore);
    _sync.load();
    // Saved events first, so the week is complete at once; then the news.
    _calendarsLoaded = _calendars.load().then((_) {
      if (!mounted) return;
      if (live) {
        _calendars.refresh();
        // Reminders set on events can be worked out now.
        _reminders.check();
      }
    });
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
          _calendars.resumed();
        },
        onHide: () {
          _sync.leaving();
          _calendars.leaving();
        },
      );
    }
  }

  void _onStore() {
    final frameTiming = widget.store.setting<bool>(Settings.frameTiming);
    if (frameTiming != _frameTiming) setState(() => _frameTiming = frameTiming);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    if (widget.places == null) _places.dispose();
    _lifecycle?.dispose();
    _reminders.dispose();
    if (widget.sync == null) _sync.dispose();
    if (widget.calendars == null) _calendars.dispose();
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

  /// A reminder notification was tapped: show that task (or event).
  Future<void> _openTask(String id) async {
    // An event is only known once its calendar has been read from disk,
    // which may still be under way when a notification starts the app.
    if (Task.isEventId(id)) await _calendarsLoaded;
    if (!mounted) return;
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
      title: 'fweek',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _frameTiming,
      theme: ThemeData(useMaterial3: true, fontFamily: AppText.family),
      builder: (context, child) => AppScope(
        store: widget.store,
        controller: _controller,
        sync: _sync,
        calendars: _calendars,
        opener: _opener,
        places: _places,
        android: _android,
        child: PerfMotion.watch(_Themed(child: child!)),
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
    final ink = theme.isDark ? Brightness.light : Brightness.dark;
    // Text follows the system's font size, within what ruled rows of a fixed
    // height can hold.
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.85,
      maxScaleFactor: 1.3,
      // The planner draws behind the system bars; their icons take its tone.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: const Color(0x00000000),
          statusBarIconBrightness: ink,
          statusBarBrightness: theme.isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: const Color(0x00000000),
          systemNavigationBarIconBrightness: ink,
          // With button navigation the system lays a veil behind the
          // buttons, so the list passing underneath stays readable; with
          // gesture navigation it draws nothing.
          systemNavigationBarContrastEnforced: true,
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
