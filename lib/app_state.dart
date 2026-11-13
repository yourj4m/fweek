import 'package:flutter/widgets.dart';

import 'data/day.dart';
import 'data/planner_store.dart';
import 'services/android_bridge.dart';
import 'sync/sync_service.dart';

/// What the window is showing: which week or month, and in which view.
class AppController extends ChangeNotifier {
  AppController(this.store) : _anchor = store.today;

  final PlannerStore store;

  Day _anchor;

  /// A day inside the visible week or month.
  Day get anchor => _anchor;

  bool get monthView => store.setting<String>(Settings.view) == 'month';

  /// First day of the visible week.
  Day get weekStart => _anchor.startOfWeek(store.weekStart);

  /// The task to draw attention to after a jump (from search), cleared once
  /// the highlight has played.
  String? highlightedTask;

  void setMonthView(bool month) =>
      store.setSetting(Settings.view, month ? 'month' : 'week');

  /// The day a list of days should scroll to, and a count of the times one
  /// was asked for (so that asking for the same day twice still scrolls).
  Day get focusDay => _focusDay;
  late Day _focusDay = store.today;
  int get focusRequests => _focusRequests;
  int _focusRequests = 0;

  /// Shows the week or month holding [day]. With [focus], lists also scroll
  /// to that day.
  void show(Day day, {String? highlight, bool focus = false}) {
    _anchor = day;
    highlightedTask = highlight;
    if (focus || highlight != null) {
      _focusDay = day;
      _focusRequests++;
    }
    notifyListeners();
  }

  void goToday() => show(store.today, focus: true);

  void previous() =>
      show(monthView ? _anchor.startOfMonth.addMonths(-1) : _anchor.addDays(-7));

  void next() =>
      show(monthView ? _anchor.startOfMonth.addMonths(1) : _anchor.addDays(7));
}

/// Gives the widget tree the store and view state, and rebuilds dependants
/// when either changes.
class AppScope extends InheritedNotifier<Listenable> {
  AppScope({
    super.key,
    required this.store,
    required this.controller,
    required this.sync,
    this.android,
    required super.child,
  }) : super(notifier: Listenable.merge([store, controller, sync]));

  final PlannerStore store;
  final AppController controller;
  final SyncService sync;

  /// Android's own services (reminders, file saving); null elsewhere.
  final AndroidBridge? android;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// Access without subscribing to changes (for event handlers).
  static AppScope read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!;
}

extension AppContext on BuildContext {
  /// The store, rebuilding this widget when data changes.
  PlannerStore get store => AppScope.of(this).store;

  /// The view state, rebuilding this widget when it changes.
  AppController get app => AppScope.of(this).controller;

  /// The store, for use in callbacks.
  PlannerStore get readStore => AppScope.read(this).store;

  /// The view state, for use in callbacks.
  AppController get readApp => AppScope.read(this).controller;

  /// The sync service, rebuilding this widget when its status changes.
  SyncService get sync => AppScope.of(this).sync;

  /// The sync service, for use in callbacks.
  SyncService get readSync => AppScope.read(this).sync;

  /// Android's own services, or null on other systems.
  AndroidBridge? get readAndroid => AppScope.read(this).android;
}
