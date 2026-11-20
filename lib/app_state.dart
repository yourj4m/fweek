import 'dart:async';

import 'package:flutter/widgets.dart';

import 'calendar/calendar_service.dart';
import 'data/day.dart';
import 'data/planner_store.dart';
import 'services/android_bridge.dart';
import 'services/opener.dart';
import 'services/places.dart';
import 'sync/sync_service.dart';

/// A short message at the bottom of the window, with at most one action
/// (usually Undo).
class Toast {
  const Toast(this.message, {this.action, this.onAction});

  final String message;
  final String? action;
  final VoidCallback? onAction;
}

/// The window's two pages: the planner (a week or a month) and the lists
/// of tasks.
enum AppPage { planner, tasks }

/// What the window is showing: the planner or the Tasks page, which week or
/// month, and in which view.
///
/// Listeners are told when the visible week or month, or the view, changes.
/// Things that change more often or concern fewer widgets have notifiers of
/// their own ([highlight], [focus], [toast]), so that, say, a search result
/// lighting up does not rebuild the week.
class AppController extends ChangeNotifier {
  AppController(this.store) : _anchor = store.today {
    _month = monthView;
    store.addListener(_onStore);
  }

  final PlannerStore store;

  Day _anchor;
  late bool _month;
  /// The page on show, for what follows that alone (and not, say, every
  /// turn of the week). The window opens on the planner.
  final pageNotifier = ValueNotifier<AppPage>(AppPage.planner);

  AppPage get page => pageNotifier.value;
  bool get onTasks => page == AppPage.tasks;

  void setPage(AppPage page) {
    if (page == pageNotifier.value) return;
    pageNotifier.value = page;
    notifyListeners();
  }

  void togglePage() => setPage(onTasks ? AppPage.planner : AppPage.tasks);

  /// Shows the Tasks page; with [list], with that list open where one list
  /// shows at a time. [highlight] is the task to draw attention to.
  void showTasks({String? list, String? highlight}) {
    if (list != null) setOpenList(list);
    this.highlight.value = highlight;
    setPage(AppPage.tasks);
  }

  /// The list that is open where the Tasks page shows one at a time: the
  /// one chosen last on this device, else the first.
  String get openList {
    final id = store.setting<String?>(Settings.openList);
    return id != null && store.list(id) != null ? id : store.lists.first.id;
  }

  void setOpenList(String id) => store.setSetting(Settings.openList, id);

  /// Whether the lists show in a panel beside the week (wide windows).
  bool get panel => store.setting<bool>(Settings.listPanel);

  void setPanel(bool open) => store.setSetting(Settings.listPanel, open);

  /// A day inside the visible week or month.
  Day get anchor => _anchor;

  bool get monthView => store.setting<String>(Settings.view) == 'month';

  /// First day of the visible week.
  Day get weekStart => _anchor.startOfWeek(store.weekStart);

  void _onStore() {
    // The view is a setting; whoever follows this controller follows it too.
    if (monthView != _month) {
      _month = monthView;
      notifyListeners();
    }
  }

  /// The task to draw attention to after a jump (from search).
  final highlight = ValueNotifier<String?>(null);

  String? get highlightedTask => highlight.value;

  void setMonthView(bool month) {
    setPage(AppPage.planner);
    store.setSetting(Settings.view, month ? 'month' : 'week');
  }

  /// Counts the requests to scroll a list of days to [focusDay] (so that
  /// asking for the same day twice still scrolls).
  final focus = ValueNotifier<int>(0);

  /// The day a list of days should scroll to.
  Day get focusDay => _focusDay;
  late Day _focusDay = store.today;
  int get focusRequests => focus.value;

  /// Shows the week or month holding [day], turning to the planner if the
  /// Tasks page is on show. With [focus], lists also scroll to that day.
  void show(Day day, {String? highlight, bool focus = false}) {
    final moved = day != _anchor || page != AppPage.planner;
    pageNotifier.value = AppPage.planner;
    _anchor = day;
    this.highlight.value = highlight;
    if (focus || highlight != null) {
      _focusDay = day;
      this.focus.value++;
    }
    if (moved) notifyListeners();
  }

  void goToday() => show(store.today, focus: true);

  void previous() =>
      show(monthView ? _anchor.startOfMonth.addMonths(-1) : _anchor.addDays(-7));

  void next() =>
      show(monthView ? _anchor.startOfMonth.addMonths(1) : _anchor.addDays(7));

  /// The message on show, if any.
  final toast = ValueNotifier<Toast?>(null);
  Timer? _toastTimer;

  /// Shows [message] for a few seconds, with an optional action.
  void say(String message, {String? action, VoidCallback? onAction}) {
    _toastTimer?.cancel();
    toast.value = Toast(message, action: action, onAction: onAction);
    _toastTimer = Timer(const Duration(seconds: 6), dismissToast);
  }

  void dismissToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    toast.value = null;
  }

  /// Asks the list with the given id to start naming itself (a list just
  /// created from the menu).
  final renameList = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _toastTimer?.cancel();
    store.removeListener(_onStore);
    pageNotifier.dispose();
    highlight.dispose();
    focus.dispose();
    toast.dispose();
    renameList.dispose();
    super.dispose();
  }
}

/// Gives the widget tree the planner's parts.
///
/// Each part that changes has an inherited scope of its own, so a widget is
/// rebuilt only by what it reads: `context.store` by the data, `context.app`
/// by the visible week, `context.sync` by the sync status and
/// `context.calendars` by the calendars. The `read…` getters subscribe to
/// nothing; they are for event handlers.
class AppScope extends StatelessWidget {
  const AppScope({
    super.key,
    required this.store,
    required this.controller,
    required this.sync,
    required this.calendars,
    required this.opener,
    required this.places,
    this.android,
    required this.child,
  });

  final PlannerStore store;
  final AppController controller;
  final SyncService sync;

  /// Subscribed calendars and their events.
  final CalendarService calendars;

  /// Opens links and places in the system's programs.
  final Opener opener;

  /// The online place search.
  final PlaceSearch places;

  /// Android's own services (reminders, file saving); null elsewhere.
  final AndroidBridge? android;

  final Widget child;

  /// Access without subscribing to changes (for event handlers).
  static AppScope read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Parts>()!.scope;

  @override
  Widget build(BuildContext context) => _Parts(
        scope: this,
        child: _StoreScope(
          notifier: store,
          child: _ViewScope(
            notifier: controller,
            child: _SyncScope(
              notifier: sync,
              child: _CalendarScope(notifier: calendars, child: child),
            ),
          ),
        ),
      );
}

class _Parts extends InheritedWidget {
  const _Parts({required this.scope, required super.child});

  final AppScope scope;

  @override
  bool updateShouldNotify(_Parts old) => false;
}

class _StoreScope extends InheritedNotifier<PlannerStore> {
  const _StoreScope({required super.notifier, required super.child});
}

class _ViewScope extends InheritedNotifier<AppController> {
  const _ViewScope({required super.notifier, required super.child});
}

class _SyncScope extends InheritedNotifier<SyncService> {
  const _SyncScope({required super.notifier, required super.child});
}

class _CalendarScope extends InheritedNotifier<CalendarService> {
  const _CalendarScope({required super.notifier, required super.child});
}

extension AppContext on BuildContext {
  /// The store, rebuilding this widget when data changes.
  PlannerStore get store =>
      dependOnInheritedWidgetOfExactType<_StoreScope>()!.notifier!;

  /// The view state, rebuilding this widget when the visible week or month
  /// or the view changes.
  AppController get app =>
      dependOnInheritedWidgetOfExactType<_ViewScope>()!.notifier!;

  /// The store, for use in callbacks.
  PlannerStore get readStore => AppScope.read(this).store;

  /// The view state, for use in callbacks.
  AppController get readApp => AppScope.read(this).controller;

  /// The sync service, rebuilding this widget when its status changes.
  SyncService get sync =>
      dependOnInheritedWidgetOfExactType<_SyncScope>()!.notifier!;

  /// The sync service, for use in callbacks.
  SyncService get readSync => AppScope.read(this).sync;

  /// Subscribed calendars, rebuilding this widget when their events change.
  CalendarService get calendars =>
      dependOnInheritedWidgetOfExactType<_CalendarScope>()!.notifier!;

  /// Subscribed calendars, for use in callbacks.
  CalendarService get readCalendars => AppScope.read(this).calendars;

  /// Android's own services, or null on other systems.
  AndroidBridge? get readAndroid => AppScope.read(this).android;

  /// Opens links and places outside the app.
  Opener get readOpener => AppScope.read(this).opener;

  /// The online place search.
  PlaceSearch get readPlaces => AppScope.read(this).places;
}
