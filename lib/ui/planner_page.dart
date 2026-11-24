import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show DragStartBehavior, PointerScrollEvent;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show RefreshIndicator;
import 'icons.dart';

import '../app_state.dart';
import '../calendar/calendar_service.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../services/file_drop.dart';
import '../services/sync_all.dart';
import '../sync/sync_service.dart';
import '../text/links.dart';
import '../theme/app_theme.dart';
import 'composer.dart';
import 'context_menu.dart';
import 'day_progress.dart';
import 'drag.dart';
import 'event_form.dart';
import 'event_rows.dart';
import 'calendar_settings.dart' show birthdaysRead;
import 'ics_import_dialog.dart';
import 'month_view.dart';
import 'search_dialog.dart';
import 'settings_dialog.dart';
import 'strings.dart';
import 'task_actions.dart';
import 'task_dialog.dart';
import 'task_list.dart';
import 'tasks_page.dart';
import 'widgets/controls.dart';

/// The main window: the header and, under it, the planner (a week or a
/// month) or the Tasks page.
class PlannerPage extends StatefulWidget {
  const PlannerPage({super.key});

  @override
  State<PlannerPage> createState() => _PlannerPageState();
}

class _PlannerPageState extends State<PlannerPage> {
  final _focus = FocusNode(debugLabel: 'planner');
  late final DragController _drag;
  final _composer = Composer();

  // Built once and handed to the tree again and again: a widget that is the
  // very same object as last time is not rebuilt, so what happens around
  // the layouts (the keyboard sliding in, a window resize within one
  // layout) leaves the week itself alone.
  late final Widget _narrow = _NarrowLayout(onOpen: _open);
  late final Widget _wide = _WideLayout(onOpen: _open);

  @override
  void initState() {
    super.initState();
    if (_dropping) FileDrop.listen(_dropped);
    FocusManager.instance.addListener(_keepKeyboard);
    _drag = DragController(
      onDrop: _drop,
      onEdge: (direction) =>
          direction < 0 ? context.readApp.previous() : context.readApp.next(),
      onHold: (task, row, from) =>
          showTaskMenu(context, task, anchor: row, onOpen: _open, from: from),
    )..edges = () => !context.readApp.monthView && !context.readApp.onTasks;
  }

  @override
  void dispose() {
    if (_dropping) FileDrop.listen(null);
    FocusManager.instance.removeListener(_keepKeyboard);
    _drag.dispose();
    _composer.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// When nothing in the window has the keyboard any more (a line that was
  /// typed on let go of it with Escape), the window itself takes it, so
  /// that its shortcuts work at once and not only after the next click.
  /// While a card or a menu is open the keyboard is theirs.
  void _keepKeyboard() {
    if (!mounted || _focus.hasFocus) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary == _focus.enclosingScope) _focus.requestFocus();
  }

  /// On a desktop: calendar files dropped anywhere on the window are taken
  /// into the planner. The window's own code (Linux and Windows) passes
  /// their paths on.
  late final bool _dropping = defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows;

  void _dropped(List<String> paths) {
    if (!mounted) return;
    final files = <CalendarFile>[];
    var others = 0;
    for (final path in paths) {
      // The file's name, after the last separator of either system.
      final name = path.split(RegExp(r'[/\\]')).last;
      final lower = name.toLowerCase();
      // A contacts file: its birthdays become the Birthdays calendar.
      if (lower.endsWith('.vcf') || lower.endsWith('.vcard') || lower.endsWith('.csv')) {
        _readContacts(path, name);
        continue;
      }
      if (!lower.endsWith('.ics') && !lower.endsWith('.ical')) {
        others++;
        continue;
      }
      try {
        final file = File(path);
        // A calendar is text of modest size; anything huge is something else.
        if (file.lengthSync() > 16 * 1024 * 1024) {
          others++;
          continue;
        }
        files.add((name: name, text: utf8.decode(file.readAsBytesSync(), allowMalformed: true)));
      } on FileSystemException {
        others++;
      }
    }
    if (files.isEmpty) {
      if (others > 0) {
        context.readApp.say(
            'Drop a calendar file (.ics) to add its events, or a contacts file for birthdays');
      }
      return;
    }
    importCalendarFiles(context, files);
  }

  Future<void> _readContacts(String path, String name) async {
    final app = context.readApp;
    final calendars = context.readCalendars;
    final String text;
    try {
      final file = File(path);
      if (file.lengthSync() > 64 * 1024 * 1024) {
        app.say('$name is too large to be a contacts file');
        return;
      }
      text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    } on FileSystemException {
      app.say('Could not read $name');
      return;
    }
    final error = await calendars.setBirthdays(text: text, file: name, path: path);
    app.say(error ?? birthdaysRead(calendars));
  }

  void _drop(Task task, Slot slot, int index, Slot? from) {
    if (task.fromCalendar && slot is ListSlot) {
      // An event has no place in a list; a task made of it does.
      copyIntoPlanner(context, task, slot: slot);
      return;
    }
    context.readStore.moveTask(
      task.id,
      slot,
      index: index >= DragController.atEnd ? null : index,
      // Taken from a list and put into a list: it keeps the day it is
      // planned for. Taken from its day: it has none any more.
      keepDay: slot is ListSlot && from is ListSlot,
    );
  }

  bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final control = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (control && key == LogicalKeyboardKey.keyF) {
      showSearchDialog(context);
      return KeyEventResult.handled;
    }
    if (control && key == LogicalKeyboardKey.comma) {
      showSettingsDialog(context);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _drag.active) {
      _drag.cancel();
      return KeyEventResult.handled;
    }
    if (_typing || control || HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final app = context.readApp;
    if (key == LogicalKeyboardKey.keyN) {
      showNewEvent(context);
    } else if (key == LogicalKeyboardKey.keyL) {
      app.togglePage();
    } else if (key == LogicalKeyboardKey.keyT) {
      app.goToday();
    } else if (key == LogicalKeyboardKey.keyM) {
      app.setMonthView(app.onTasks || !app.monthView);
    } else if (app.onTasks) {
      // Where one list shows at a time, the arrows turn to its neighbours.
      final by = key == LogicalKeyboardKey.arrowLeft
          ? -1
          : key == LogicalKeyboardKey.arrowRight
              ? 1
              : 0;
      if (by == 0) return KeyEventResult.ignored;
      final lists = context.readStore.lists;
      final at = lists.indexWhere((l) => l.id == app.openList) + by;
      if (at >= 0 && at < lists.length) app.setOpenList(lists[at].id);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      app.previous();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      app.next();
    } else if (key == LogicalKeyboardKey.keyP) {
      app.setPanel(!app.panel);
    } else if (key == LogicalKeyboardKey.keyS) {
      syncEverything(context);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _open(Task task) => showTaskDialog(context, task.id);

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return DragScope(
      controller: _drag,
      child: ComposerScope(
        composer: _composer,
        child: _BackToPlanner(child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final narrow = size.width < Dim.breakpoint;
              return Listener(
                onPointerMove: (e) => _drag.pointerMove(e.position, size),
                onPointerUp: (_) => _drag.pointerUp(),
                onPointerCancel: (_) => _drag.cancel(),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _focus.requestFocus,
                  child: ColoredBox(
                    color: theme.background,
                    child: _KeyboardInset(
                      child: Stack(
                        children: [
                          Positioned.fill(child: narrow ? _narrow : _wide),
                          const _EdgeEar(direction: -1),
                          const _EdgeEar(direction: 1),
                          const _DragGhost(),
                          const _ToastHost(),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        )),
      ),
    );
  }
}

/// On a phone: going back from the Tasks page leads to the planner rather
/// than out of the app. [child] is the same object throughout and is not
/// rebuilt when the page changes.
class _BackToPlanner extends StatelessWidget {
  const _BackToPlanner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PopScope(
      canPop: !app.onTasks,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.setPage(AppPage.planner);
      },
      child: child,
    );
  }
}

/// Ends the planner above the on-screen keyboard, so the row being typed in
/// can scroll into view. This is the only widget that follows the keyboard
/// as it slides: [child] is the same object throughout and is not rebuilt.
class _KeyboardInset extends StatefulWidget {
  const _KeyboardInset({required this.child});

  final Widget child;

  @override
  State<_KeyboardInset> createState() => _KeyboardInsetState();
}

class _KeyboardInsetState extends State<_KeyboardInset> {
  /// Height of the keyboard at the last build.
  double _keyboard = 0;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (isMobile && _keyboard > 0 && keyboard == 0) {
      // The keyboard was put away (the back gesture does that): typing is
      // over, so the field lets go as well. Android would otherwise leave
      // it focused, with its text unsaved.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => FocusManager.instance.primaryFocus?.unfocus());
    }
    _keyboard = keyboard;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: widget.child,
    );
  }
}

/// Shows the app's short messages ("Task deleted · Undo") at the bottom.
class _ToastHost extends StatelessWidget {
  const _ToastHost();

  @override
  Widget build(BuildContext context) {
    final app = context.readApp;
    // Above the phone's bar of pages, which stays in reach under it. The
    // same height over the keyboard when that is up: this must not follow
    // the keyboard as it slides (nothing but the page's inset does).
    final bar = isMobile ? _BottomBar.height : 0.0;
    final bottom = MediaQuery.paddingOf(context).bottom + bar;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16 + bottom,
      child: ValueListenableBuilder<Toast?>(
        valueListenable: app.toast,
        builder: (context, toast, _) => AnimatedSwitcher(
          duration: Dim.medium,
          child: toast == null
              ? const SizedBox(width: double.infinity)
              : Center(
                  key: ObjectKey(toast),
                  child: _ToastCard(toast: toast, onClose: app.dismissToast),
                ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.toast, required this.onClose});

  final Toast toast;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    // The message reads against the page: light on dark where the page is
    // light, and the other way round.
    final ink = theme.isDark ? const Color(0xFF111111) : const Color(0xFFFFFFFF);
    final surface = theme.isDark ? const Color(0xFFF2F2F2) : const Color(0xFF222226);
    // The message is announced when it appears; the action beside it is a
    // button of its own, not part of what is read out.
    return Container(
      constraints: const BoxConstraints(maxWidth: 420, minHeight: 48),
      padding: const EdgeInsets.only(left: 18, right: 6),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Semantics(
              liveRegion: true,
              container: true,
              child: Text(
                toast.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.small15.copyWith(color: ink),
              ),
            ),
          ),
          if (toast.action != null)
            Pressable(
              onTap: () {
                onClose();
                toast.onAction?.call();
              },
              semanticLabel: toast.action,
              labelOnly: true,
              focusRadius: 20,
              builder: (context, hovered, pressed) => Container(
                height: 40,
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hovered || pressed ? ink.withValues(alpha: 0.12) : null,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  toast.action!,
                  style: context.text.small15
                      .copyWith(color: ink, fontWeight: FontWeight.w700),
                ),
              ),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.narrow, this.panelRoom = false});

  final bool narrow;

  /// Whether the window has room for the lists beside the week, and so for
  /// the button that shows them there.
  final bool panelRoom;

  void _menu(BuildContext context) {
    showPopover<void>(
      context: context,
      anchor: globalRect(context),
      align: 1,
      builder: (popover) => _MainMenu(page: context, panelRoom: panelRoom),
    );
  }

  /// The planner's title: the month and year, and the week's number. One
  /// line in a wide window; in a narrow one the month over the year, in
  /// smaller type, so that the month is read in full.
  Widget _plannerTitle(BuildContext context, AppController app) {
    final theme = context.theme;
    final first = app.monthView ? app.anchor.startOfMonth : app.weekStart;
    // A week that straddles two months is titled by the month holding most
    // of it (the month of its fourth day).
    final titled = app.monthView ? first : first.addDays(3);
    final week = app.monthView ? null : 'W${first.addDays(3).isoWeek}';
    return Pressable(
      onTap: () {
        final store = context.readStore;
        final onThisWeek =
            app.weekStart == store.today.startOfWeek(store.weekStart);
        if (!isMobile) {
          app.goToday();
        } else if (app.monthView) {
          // A phone has no keyboard shortcut for this: the title leads back
          // to the current week, and from there to the month.
          app.setMonthView(false);
          app.goToday();
        } else if (onThisWeek) {
          app.setMonthView(true);
        } else {
          app.goToday();
        }
      },
      semanticLabel: 'Go to today',
      builder: (context, hovered, pressed) {
        Color tone(Color c) => hovered ? c.withValues(alpha: c.a * 0.75) : c;
        if (narrow) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Strings.month(titled),
                style: context.text.heading24.copyWith(color: tone(theme.text)),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
              Text(
                week == null ? '${titled.year}' : '${titled.year} · $week',
                style: context.text.caption14.copyWith(color: theme.ink(50)),
                maxLines: 1,
                softWrap: false,
              ),
            ],
          );
        }
        final style = context.text.title36;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              // The title keeps its room; the week number yields.
              flex: 0,
              child: Text(
                '${Strings.month(titled)} ${titled.year}',
                style: style.copyWith(color: tone(theme.text)),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ),
            if (week != null) ...[
              const SizedBox(width: 12),
              // Fades out under the buttons when the header is tight.
              Flexible(
                child: Text(
                  week,
                  style: style.copyWith(color: theme.ink(20)),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The Tasks page's title, with how much is still to do.
  Widget _tasksTitle(BuildContext context) {
    final theme = context.theme;
    final open = context.store.openInLists;
    if (narrow) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tasks', style: context.text.heading24, maxLines: 1),
          Text(
            open == 0 ? 'Nothing to do' : '$open to do',
            style: context.text.caption14.copyWith(color: theme.ink(50)),
            maxLines: 1,
          ),
        ],
      );
    }
    final style = context.text.title36;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('Tasks', style: style, maxLines: 1),
        if (open > 0) ...[
          const SizedBox(width: 12),
          Text('$open', style: style.copyWith(color: theme.ink(20)), maxLines: 1),
        ],
      ],
    );
  }

  /// What an arrow does: on the planner it turns the week or month; on the
  /// Tasks page it turns to the neighbouring list where one list shows at a
  /// time, and has nothing to do where they all show.
  VoidCallback? _turn(BuildContext context, AppController app, int by) {
    if (!app.onTasks) return by < 0 ? app.previous : app.next;
    final lists = context.store.lists;
    final width = MediaQuery.sizeOf(context).width;
    if (TasksBody.layoutFor(width, lists.length) == ListsLayout.board) return null;
    final at = lists.indexWhere((l) => l.id == app.openList) + by;
    return at < 0 || at >= lists.length ? null : () => app.setOpenList(lists[at].id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.app;
    final tasks = app.onTasks;
    return SizedBox(
      height: Dim.headerHeight,
      child: LayoutBuilder(
        builder: (context, box) {
          // The three views by name where there is room for the words, by
          // icon in a tight window, and as one button in the tightest. A
          // phone has a bar at the bottom for this.
          final Widget? views = isMobile
              ? null
              : !narrow || box.maxWidth >= 646
                  ? const _ViewSwitch(labels: true)
                  : box.maxWidth >= 546
                      ? const _ViewSwitch(labels: false)
                      : const _PageSwitch();
          const gap = SizedBox(width: 6);
          return Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: tasks ? _tasksTitle(context) : _plannerTitle(context, app),
                ),
              ),
              const SizedBox(width: 12),
              if (views != null) ...[views, gap],
              AppButton(
                icon: AppIcons.calendarPlus,
                kind: ButtonKind.secondary,
                tooltip: isMobile ? 'New event' : 'New event (N)',
                onTap: () => showNewEvent(context),
              ),
              gap,
              // A phone's header is full as it is: there the page is pulled
              // down from its top instead (see [_PullToSync]).
              if (!isMobile) ...[const _SyncButton(), gap],
              Builder(
                builder: (context) => AppButton(
                  icon: AppIcons.menu,
                  kind: ButtonKind.secondary,
                  fill: theme.menuButton,
                  foreground: const Color(0xFF000000),
                  tooltip: 'Menu',
                  onTap: () => _menu(context),
                ),
              ),
              // The arrows keep their place on every page, so that the
              // buttons before them do too.
              gap,
              AppButton(
                icon: AppIcons.chevronLeft,
                kind: ButtonKind.primary,
                tooltip: tasks ? 'Previous list' : 'Previous',
                onTap: _turn(context, app, -1),
              ),
              gap,
              AppButton(
                icon: AppIcons.chevronRight,
                kind: ButtonKind.primary,
                tooltip: tasks ? 'Next list' : 'Next',
                onTap: _turn(context, app, 1),
              ),
              // The lists beside the week, where there is room for them: in
              // the window's top right corner. Opened, the panel has its
              // button that shuts it in that same corner, so the button
              // stays under the pointer either way. Where the lists cannot
              // open (the month, the Tasks page) its place stays, so that
              // the arrows keep theirs on every page.
              if (panelRoom && !(app.panel && !tasks && !app.monthView)) ...[
                gap,
                if (!tasks && !app.monthView)
                  AppButton(
                    icon: AppIcons.panelRightOpen,
                    kind: ButtonKind.ghost,
                    tooltip: 'Show the lists beside the week (P)',
                    onTap: () => app.setPanel(true),
                  )
                else
                  const SizedBox.square(dimension: Dim.controlMedium),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Runs everything the sync button stands for (see [SyncAll]) and says how
/// it went. Asked again while a run is under way, it waits for that run and
/// leaves the report to whoever started it.
Future<void> syncEverything(BuildContext context) async {
  final everything = AppScope.read(context).everything;
  final joined = everything.running;
  final app = context.readApp;
  final result = await everything.run();
  if (joined) return;
  if (result.ok) {
    app.say(result.message);
  } else {
    app.say(
      result.message,
      action: 'Settings',
      onAction: () {
        if (!context.mounted) return;
        // To the part that can put it right: the connection if that
        // failed, else a calendar that could not be read, else the copy.
        showSettingsDialog(
          context,
          section: context.readSync.state == SyncState.error
              ? SettingsSection.sync
              : context.readCalendars.subscriptions.any((c) => c.error != null)
                  ? SettingsSection.calendars
                  : SettingsSection.data,
        );
      },
    );
  }
}

/// The header's sync button, on a desktop: one press syncs with the
/// Nextcloud folder, reads the calendars again and keeps a copy of the
/// planner on this device. Its icon turns while that runs, and is a warning
/// while the last sync with Nextcloud stands failed.
class _SyncButton extends StatefulWidget {
  const _SyncButton();

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final SyncAll _everything = AppScope.read(context).everything;

  @override
  void initState() {
    super.initState();
    _everything.addListener(_onRun);
    if (_everything.running) _turn.repeat();
  }

  void _onRun() {
    if (!mounted) return;
    if (_everything.running) {
      _turn.repeat();
    } else {
      // The turn it is in is finished, so that a quick run shows as well.
      _turn.forward(from: _turn.value).whenComplete(() {
        if (mounted && !_everything.running) _turn.value = 0;
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _everything.removeListener(_onRun);
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = !_everything.running && context.sync.state == SyncState.error;
    return AppButton(
      icon: failed ? AppIcons.cloudAlert : AppIcons.refreshCw,
      kind: ButtonKind.secondary,
      foreground: failed ? AppTheme.danger : null,
      turning: _turn,
      tooltip: 'Sync everything (S)',
      onTap: () => syncEverything(context),
    );
  }
}

/// On a phone: the page, scrolled to its top and pulled further down,
/// syncs everything, as the header's button does on a desktop. A mark
/// follows the finger and turns until the sync is through.
class _PullToSync extends StatelessWidget {
  const _PullToSync({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isMobile) return child;
    final theme = context.theme;
    return RefreshIndicator(
      onRefresh: () => syncEverything(context),
      // The page's own scrolling up and down; not the turning of weeks or
      // lists, nor a line of text moving under the cursor.
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      color: theme.text,
      backgroundColor: theme.popover,
      strokeWidth: 2,
      displacement: 28,
      semanticsLabel: 'Syncing',
      child: child,
    );
  }
}

/// Something that leads to the other page (the header's button, a tab of
/// the phone's bar) and takes a dragged task there: held over it for a
/// moment, the page turns under the task, which is then dropped where it
/// should go.
mixin _PageSpot<T extends StatefulWidget> on State<T> {
  final spotKey = GlobalKey();
  DragController? _drag;

  /// Whether a task is being dragged, and whether it is held over this.
  bool dragging = false;
  bool over = false;

  Object get spotId;

  void _onDrag() {
    final drag = _drag;
    if (drag == null || !mounted) return;
    final nowOver = drag.spot == spotId;
    if (nowOver != over || drag.active != dragging) {
      setState(() {
        over = nowOver;
        dragging = drag.active;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drag = DragScope.read(context);
    if (drag != _drag) {
      _drag?.removeListener(_onDrag);
      _drag = drag..addListener(_onDrag);
    }
  }

  void registerSpot(VoidCallback onDwell) =>
      _drag!.registerSpot(spotId, spotKey, onDwell: onDwell);

  void unregisterSpot() => _drag?.unregisterSpot(spotId, spotKey);

  @override
  void dispose() {
    _drag?.removeListener(_onDrag);
    _drag?.unregisterSpot(spotId, spotKey);
    super.dispose();
  }
}

/// One of the three views the header switches between.
enum _View {
  week('Week'),
  month('Month'),
  tasks('Tasks');

  const _View(this.label);

  final String label;

  IconData get icon => switch (this) {
        week => AppIcons.calendarDays,
        month => AppIcons.layoutGrid,
        tasks => AppIcons.listChecks,
      };

  static _View of(AppController app) =>
      app.onTasks ? tasks : app.monthView ? month : week;

  void show(AppController app) => switch (this) {
        week => app.setMonthView(false),
        month => app.setMonthView(true),
        tasks => app.setPage(AppPage.tasks),
      };
}

/// The header's way from one view to another: the week, the month and the
/// Tasks page side by side, by name ([labels]) or by icon, the one on show
/// marked. It reads as a place to go, which the button that only shows the
/// lists beside the week is not.
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.labels});

  final bool labels;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final shown = _View.of(context.app);
    return Container(
      height: Dim.controlMedium,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.ink(5),
        borderRadius: BorderRadius.circular(256),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final view in _View.values)
            _ViewSegment(view: view, selected: view == shown, labels: labels),
        ],
      ),
    );
  }
}

class _ViewSegment extends StatefulWidget {
  const _ViewSegment({
    required this.view,
    required this.selected,
    required this.labels,
  });

  final _View view;
  final bool selected;
  final bool labels;

  @override
  State<_ViewSegment> createState() => _ViewSegmentState();
}

class _ViewSegmentState extends State<_ViewSegment> with _PageSpot {
  @override
  Object get spotId => ('view', widget.view);

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.readApp;
    final view = widget.view;
    final selected = widget.selected;
    // A task in hand can be carried to the week or to the lists: held over
    // the name for a moment, that page comes up under it. The month has no
    // place to put a task down.
    final carries = !selected && view != _View.month;
    if (carries) {
      registerSpot(() => view.show(app));
    } else {
      unregisterSpot();
    }
    return Semantics(
      selected: selected,
      child: Pressable(
        key: spotKey,
        // The view on show already: back to today, as on a phone's bar.
        onTap: () => selected && view != _View.tasks ? app.goToday() : view.show(app),
        semanticLabel: view.label,
        labelOnly: true,
        focusRadius: 256,
        builder: (context, hovered, pressed) {
          final color = selected ? theme.text : theme.ink(hovered || over ? 85 : 60);
          return AnimatedContainer(
            duration: Dim.fast,
            height: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: widget.labels ? 14 : 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? theme.background
                  : over
                      ? theme.ink(15)
                      : hovered
                          ? theme.ink(5)
                          : const Color(0x00000000),
              borderRadius: BorderRadius.circular(256),
              // While a task is in hand: this is somewhere it can be taken.
              border: Border.all(
                color: carries && dragging && !over
                    ? theme.ink(35)
                    : const Color(0x00000000),
              ),
            ),
            child: widget.labels
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      // The name takes the room of its bold form whether
                      // or not it is the one on show, so that marking
                      // another moves nothing.
                      Opacity(
                        opacity: 0,
                        child: Text(
                          view.label,
                          maxLines: 1,
                          style: context.text.small15
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        view.label,
                        maxLines: 1,
                        style: context.text.small15.copyWith(
                          color: color,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                : Icon(view.icon, size: 18, color: color),
          );
        },
      ),
    );
  }
}

/// The same in a window too tight for the three: one button that turns
/// from the planner to the Tasks page and back.
class _PageSwitch extends StatefulWidget {
  const _PageSwitch();

  @override
  State<_PageSwitch> createState() => _PageSwitchState();
}

class _PageSwitchState extends State<_PageSwitch> with _PageSpot {
  @override
  Object get spotId => 'page';

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.app;
    registerSpot(app.togglePage);
    return DecoratedBox(
      key: spotKey,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(256),
        // While a task is in hand: this is somewhere it can be taken.
        border: dragging && !over ? Border.all(color: theme.ink(35)) : null,
      ),
      child: AppButton(
        icon: !app.onTasks
            ? AppIcons.listChecks
            : app.monthView
                ? AppIcons.layoutGrid
                : AppIcons.calendarDays,
        kind: ButtonKind.secondary,
        selected: over,
        tooltip: !app.onTasks
            ? 'Tasks (L)'
            : app.monthView
                ? 'Back to the month (L)'
                : 'Back to the week (L)',
        onTap: app.togglePage,
      ),
    );
  }
}

/// The header's menu. Its second page lists the calendars with a switch
/// each: one tap shows or hides a whole calendar.
class _MainMenu extends StatefulWidget {
  const _MainMenu({required this.page, required this.panelRoom});

  /// The planner page's context, for what outlives the menu.
  final BuildContext page;
  final bool panelRoom;

  @override
  State<_MainMenu> createState() => _MainMenuState();
}

class _MainMenuState extends State<_MainMenu> {
  bool _calendars = false;

  void _run(VoidCallback action) {
    Navigator.of(context).pop();
    if (widget.page.mounted) action();
  }

  /// How many events of the visible week or month are hidden one by one.
  int _hiddenInView(AppController app, CalendarService calendars) {
    final Day first, last;
    if (app.monthView) {
      first = app.anchor.startOfMonth.startOfWeek(app.store.weekStart);
      last = first.addDays(41);
    } else {
      first = app.weekStart;
      last = first.addDays(6);
    }
    return calendars.eventsBetween(first, last).hidden;
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final theme = context.theme;
    final app = context.readApp;
    final sync = context.sync;
    final calendars = context.calendars;
    final subscriptions = calendars.subscriptions;

    if (_calendars) {
      return PopoverSurface(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 264,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MenuRow(
                icon: AppIcons.chevronLeft,
                label: 'Calendars',
                onTap: () => setState(() => _calendars = false),
              ),
              const _Divider(),
              for (final calendar in subscriptions)
                _CalendarToggle(
                  name: calendar.name,
                  color: calendarColor(theme, calendar.color),
                  shown: !calendar.hidden,
                  onTap: () => calendars.setHidden(calendar.id, !calendar.hidden),
                ),
              const _Divider(),
              MenuRow(
                icon: AppIcons.settings,
                label: 'Manage calendars…',
                onTap: () => _run(() => showSettingsDialog(page)),
              ),
            ],
          ),
        ),
      );
    }

    final hidden =
        subscriptions.isEmpty || app.onTasks ? 0 : _hiddenInView(app, calendars);
    return PopoverSurface(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 248,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MenuRow(
              icon: AppIcons.calendarCheck,
              label: 'Today',
              hint: isMobile ? null : 'T',
              onTap: () => _run(app.goToday),
            ),
            MenuRow(
              icon: AppIcons.search,
              label: 'Search',
              hint: isMobile ? null : 'Ctrl F',
              onTap: () => _run(() => showSearchDialog(page)),
            ),
            const _Divider(),
            MenuRow(
              icon: AppIcons.columns3,
              label: 'Week',
              checked: !app.onTasks && !app.monthView,
              onTap: () => _run(() => app.setMonthView(false)),
            ),
            MenuRow(
              icon: AppIcons.layoutGrid,
              label: 'Month',
              checked: !app.onTasks && app.monthView,
              hint: isMobile ? null : 'M',
              onTap: () => _run(() => app.setMonthView(true)),
            ),
            MenuRow(
              icon: AppIcons.listChecks,
              label: 'Tasks',
              checked: app.onTasks,
              hint: isMobile ? null : 'L',
              onTap: () => _run(() => app.setPage(AppPage.tasks)),
            ),
            // The lists beside the week: with the views, as it is ticked
            // like them.
            if (widget.panelRoom && !app.onTasks && !app.monthView) ...[
              const _Divider(),
              MenuRow(
                icon: AppIcons.panelRight,
                label: 'Lists panel',
                checked: app.panel,
                hint: 'P',
                onTap: () => _run(() => app.setPanel(!app.panel)),
              ),
            ],
            const _Divider(),
            MenuRow(
              icon: AppIcons.calendarPlus,
              label: 'New event',
              hint: isMobile ? null : 'N',
              onTap: () => _run(() => showNewEvent(page)),
            ),
            MenuRow(
              icon: AppIcons.listPlus,
              label: 'New list',
              onTap: () => _run(() {
                // Lists live on the Tasks page; show it, then name the list.
                app.setPage(AppPage.tasks);
                newList(page);
              }),
            ),
            if (subscriptions.isNotEmpty)
              MenuRow(
                icon: AppIcons.calendarDays,
                label: 'Calendars',
                hint: subscriptions.any((c) => c.hidden)
                    ? '${subscriptions.where((c) => !c.hidden).length}/${subscriptions.length}'
                    : null,
                trailing: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(AppIcons.chevronRight, size: 16, color: theme.ink(60)),
                ),
                onTap: () => setState(() => _calendars = true),
              ),
            if (hidden > 0 || calendars.showHidden)
              MenuRow(
                icon: calendars.showHidden ? AppIcons.eyeOff : AppIcons.eye,
                label: calendars.showHidden
                    ? 'Stop showing hidden events'
                    : 'Show hidden events',
                hint: hidden > 0 ? '$hidden' : null,
                onTap: () =>
                    _run(() => calendars.showHidden = !calendars.showHidden),
              ),
            const _Divider(),
            MenuRow(
              icon: sync.state == SyncState.error
                  ? AppIcons.cloudAlert
                  : AppIcons.refreshCw,
              label: 'Sync everything',
              hint: switch (sync.state) {
                SyncState.syncing => 'syncing',
                SyncState.error => 'failed',
                _ => isMobile ? null : 'S',
              },
              danger: sync.state == SyncState.error,
              onTap: () => _run(() => syncEverything(page)),
            ),
            MenuRow(
              icon: AppIcons.settings,
              label: 'Settings',
              hint: isMobile ? null : 'Ctrl ,',
              onTap: () => _run(() => showSettingsDialog(page)),
            ),
          ],
        ),
      ),
    );
  }
}

/// One calendar in the menu: its colour, its name, and whether it is shown.
class _CalendarToggle extends StatelessWidget {
  const _CalendarToggle({
    required this.name,
    required this.color,
    required this.shown,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      semanticLabel: shown ? 'Hide $name' : 'Show $name',
      builder: (context, hovered, pressed) => Container(
        height: isMobile ? Dim.controlLarge : Dim.controlInline,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: hovered ? theme.ink(5) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color.withValues(alpha: shown ? 1 : 0.3),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body17
                    .copyWith(color: shown ? theme.text : theme.ink(40)),
              ),
            ),
            Icon(
              shown ? AppIcons.eye : AppIcons.eyeOff,
              size: 18,
              color: shown ? theme.text : theme.ink(40),
            ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        color: context.theme.ink(10),
      );
}

// ------------------------------------------------------------ day pieces

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.narrow});

  final Day day;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final today = day == context.store.today;
    final color = today ? theme.accent : theme.text;
    // A narrow desktop window uses the smaller pair; a phone, read at
    // arm's length, keeps the larger one.
    final small = narrow && !isMobile;
    final bold = small ? context.text.heading18 : context.text.heading21;
    final regular = small ? context.text.label18 : context.text.label21;
    final texts = Row(
      children: [
        Expanded(
          child: Text(
            Strings.dayMonth(day),
            style: bold.copyWith(color: color),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        ),
        // What is due this day, wherever it is planned or kept.
        if (context.store.dueOn(day) case final due when due.isNotEmpty)
          _DueFlag(day: day, tasks: due),
        Text(
          today ? 'Today' : Strings.weekdayShort(day),
          style: regular.copyWith(
            color: today ? theme.accent : theme.text.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
    return SizedBox(
      height: Dim.dayHeader,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // On a phone the week is swiped sideways; text that could be
          // selected there would take the swipe for itself.
          Expanded(child: isMobile ? texts : Selectable(child: texts)),
          if (today)
            // The rule under today's heading fills from left to right as
            // the day goes by.
            DayProgress(day: day, height: 3)
          else
            Container(height: 2, color: color),
        ],
      ),
    );
  }
}

/// A flag in a day's heading: tasks have their deadline that day. A click
/// lists them; one of them clicked opens.
class _DueFlag extends StatelessWidget {
  const _DueFlag({required this.day, required this.tasks});

  final Day day;
  final List<Task> tasks;

  void _list(BuildContext context) {
    final root = Navigator.of(context, rootNavigator: true).context;
    showPopover<void>(
      context: context,
      anchor: globalRect(context),
      align: 1,
      builder: (popover) => PopoverSurface(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 248,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                child: Text(
                  'Due ${Strings.dayMonth(day)}',
                  style: context.text.caption14.copyWith(color: context.theme.ink(60)),
                ),
              ),
              for (final task in tasks)
                MenuRow(
                  icon: AppIcons.flag,
                  label: tidyText(task.title),
                  onTap: () {
                    Navigator.of(popover).pop();
                    if (root.mounted) showTaskDialog(root, task.id);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final today = context.store.today;
    final color = day < today
        ? AppTheme.danger
        : day == today
            ? theme.accent
            : theme.ink(55);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Pressable(
        onTap: () => _list(context),
        semanticLabel: tasks.length == 1
            ? 'One task is due ${Strings.dayMonth(day)}'
            : '${tasks.length} tasks are due ${Strings.dayMonth(day)}',
        labelOnly: true,
        builder: (context, hovered, pressed) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.flag,
                  size: 15, color: color.withValues(alpha: hovered ? 0.7 : 1)),
              if (tasks.length > 1) ...[
                const SizedBox(width: 2),
                Text(
                  '${tasks.length}',
                  style: context.text.badge12.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One day: its heading (unless drawn elsewhere), the imported events that
/// cover it, and its tasks.
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.tasks,
    required this.rows,
    required this.narrow,
    required this.onOpen,
    this.spans = const [],
    this.heading = true,
  });

  final Day day;

  /// The day's items in the order shown: its tasks and what calendars bring
  /// within the day, as one list (see [PlannerStore.arrangeDay]).
  final List<Task> tasks;

  /// Ruled lines for them.
  final int rows;
  final bool narrow;
  final ValueChanged<Task> onOpen;

  /// Events over several days that cover this day, when they are shown per
  /// day rather than in a band across the week.
  final List<Task> spans;

  final bool heading;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (heading) _DayHeader(day: day, narrow: narrow),
          if (spans.isNotEmpty)
            DaySpans(day: day, spans: spans, onOpen: onOpen),
          TaskListBody(
            slot: DaySlot(day),
            tasks: tasks,
            rows: rows,
            compact: narrow,
            onOpen: onOpen,
          ),
        ],
      );
}

// ------------------------------------------------------------ wide layout

/// How the wide week is laid out in a window of a given height: as many
/// ruled rows per day as reach the bottom of the window, so that the week
/// fills it and nothing scrolls unless a day holds more than that. The week
/// keeps its place under the header whatever the height: what is left over
/// of a row stays blank at the bottom.
class _Fit {
  const _Fit({required this.rows});

  /// Ruled rows of a weekday, unless a day needs more.
  final int rows;

  /// Never fewer rows than this: a shorter window scrolls.
  static const fewestRows = 4;

  /// Nor more than this, on the tallest of screens.
  static const mostRows = 40;

  /// Between the header and the days.
  static const headerGap = 40.0;

  /// Under the last row.
  static const bottom = 8.0;

  /// For a page [height] high inside its padding, with a band of
  /// several-day events [band] high over the week.
  factory _Fit.of(double height, {required double band}) {
    final fixed = Dim.headerHeight + headerGap + Dim.dayHeader + band + bottom;
    return _Fit(
      rows: ((height - fixed) / Dim.row).floor().clamp(fewestRows, mostRows),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.onOpen});

  final ValueChanged<Task> onOpen;

  /// From this window width on there is room for the lists beside the week.
  static const panelFrom = 1240.0;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final padding =
        const EdgeInsets.all(Dim.pagePadding) + MediaQuery.paddingOf(context);
    if (app.onTasks) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding:
                EdgeInsets.fromLTRB(padding.left, padding.top, padding.right, 0),
            child: _Header(
              narrow: false,
              panelRoom: MediaQuery.sizeOf(context).width >= panelFrom,
            ),
          ),
          const SizedBox(height: 28),
          Expanded(child: TasksBody(onOpen: onOpen)),
        ],
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final panelRoom = constraints.maxWidth >= panelFrom;
      // Read through the store, so that opening the panel lays this out
      // again.
      final panel = panelRoom &&
          !app.monthView &&
          context.store.setting<bool>(Settings.listPanel);
      final first = app.weekStart;
      final band = app.monthView
          ? 0
          : SpanLanes.pack(
              context.calendars
                  .eventsBetween(first, first.addDays(6))
                  .withSpans(context.store.spansBetween(first, first.addDays(6)))
                  .spans,
              first,
              first.addDays(4),
            ).length;
      final fit = _Fit.of(
        constraints.maxHeight - padding.vertical,
        band: band == 0 ? 0 : 6 + band * SpanBar.lane,
      );
      final planner = _TrackpadTurn(
        child: _ScrollArea(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(narrow: false, panelRoom: panelRoom),
              SizedBox(height: app.monthView ? Dim.headerGap : _Fit.headerGap),
              if (app.monthView)
                MonthView(onOpen: onOpen)
              else
                _WeekGrid(onOpen: onOpen, minRows: fit.rows),
              SizedBox(height: app.monthView ? 20 : _Fit.bottom),
            ],
          ),
        ),
      );
      if (!panel) return planner;
      return _PanelSplit(
        window: constraints.maxWidth,
        planner: planner,
        onOpen: onOpen,
      );
    });
  }
}

/// The week with the lists beside it. The line between the two is dragged
/// to make the panel wider or narrower; a double click on it gives the
/// panel the width it came with. The width is this device's own.
class _PanelSplit extends StatefulWidget {
  const _PanelSplit({required this.window, required this.planner, required this.onOpen});

  final double window;
  final Widget planner;
  final ValueChanged<Task> onOpen;

  /// How far to either side of the line the pointer takes hold of it.
  static const reach = 5.0;

  @override
  State<_PanelSplit> createState() => _PanelSplitState();
}

class _PanelSplitState extends State<_PanelSplit> {
  /// The width while the line is being dragged; stored when it is let go.
  double? _dragged;
  double _from = 0, _grabbedAt = 0;
  bool _hovered = false;

  double _stored(PlannerStore store) =>
      store.setting<num?>(Settings.panelWidth)?.toDouble() ?? ListPanel.defaultWidth;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final width = ListPanel.fit(_dragged ?? _stored(store), widget.window);
    final active = _hovered || _dragged != null;
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: widget.planner),
            ListPanel(onOpen: widget.onOpen, width: width),
          ],
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: width + Dim.pagePadding - _PanelSplit.reach,
          width: 2 * _PanelSplit.reach,
          child: Semantics(
            container: true,
            label: 'Width of the lists panel',
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // From where the button went down, so that the line stays
                // under the pointer.
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragStart: (details) {
                  _from = width;
                  _grabbedAt = details.globalPosition.dx;
                  setState(() => _dragged = width);
                },
                onHorizontalDragUpdate: (details) => setState(() => _dragged =
                    ListPanel.fit(_from - (details.globalPosition.dx - _grabbedAt), widget.window)),
                onHorizontalDragEnd: (_) {
                  final to = _dragged;
                  setState(() => _dragged = null);
                  if (to != null) store.setSetting(Settings.panelWidth, to.roundToDouble());
                },
                onHorizontalDragCancel: () => setState(() => _dragged = null),
                onDoubleTap: () => store.setSetting(Settings.panelWidth, null),
                // The line itself, drawn stronger while the pointer is on it.
                child: Center(
                  child: AnimatedContainer(
                    duration: Dim.fast,
                    width: active ? 3 : 0,
                    color: _dragged != null ? theme.ink(45) : theme.ink(25),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// On a desktop: a sideways swipe with two fingers on the trackpad turns to
/// the next or the previous week (or month), as the arrows in the header
/// do. Swiping to the left brings what comes next, the way a page follows
/// the fingers. One swipe turns once, however long it coasts.
///
/// The wide layout needs this; the single-column one is a row of pages,
/// which a trackpad moves by itself.
class _TrackpadTurn extends StatefulWidget {
  const _TrackpadTurn({required this.child});

  final Widget child;

  @override
  State<_TrackpadTurn> createState() => _TrackpadTurnState();
}

class _TrackpadTurnState extends State<_TrackpadTurn> {
  /// How far sideways the fingers travel before the page turns.
  static const _far = 56.0;

  bool _turned = false;

  // Some systems report the swipe as a run of sideways scroll steps.
  double _scrolled = 0;
  bool _scrollTurned = false;
  Timer? _rest;

  @override
  void dispose() {
    _rest?.cancel();
    super.dispose();
  }

  void _turn({required bool forward}) {
    final app = context.readApp;
    forward ? app.next() : app.previous();
  }

  /// Mostly sideways: a swipe up or down that drifts is scrolling.
  static bool _sideways(Offset by) => by.dx.abs() > 2 * by.dy.abs();

  @override
  Widget build(BuildContext context) => Listener(
        onPointerPanZoomStart: (_) => _turned = false,
        onPointerPanZoomUpdate: (event) {
          final pan = event.pan;
          if (_turned || pan.dx.abs() < _far || !_sideways(pan)) return;
          _turned = true;
          _turn(forward: pan.dx < 0);
        },
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          final by = event.scrollDelta;
          if (by.dx == 0 || !_sideways(by)) return;
          // The steps of one swipe come close together; a pause ends it.
          _rest?.cancel();
          _rest = Timer(const Duration(milliseconds: 200), () {
            _scrolled = 0;
            _scrollTurned = false;
          });
          if (_scrollTurned) return;
          _scrolled += by.dx;
          if (_scrolled.abs() < _far) return;
          _scrollTurned = true;
          // Scrolling to the right shows what lies to the right: the next.
          _turn(forward: _scrolled > 0);
        },
        child: widget.child,
      );
}

class _WeekGrid extends StatelessWidget {
  const _WeekGrid({required this.onOpen, this.minRows = Dim.weekdayRows});

  final ValueChanged<Task> onOpen;

  /// Ruled rows the window has room for under the weekdays' headings (see
  /// [_Fit]): the weekdays take what the weekend below them leaves.
  final int minRows;

  /// Empty lines under the last item of Saturday and Sunday.
  static const weekendSpare = 3;

  /// Between the weekdays and the weekend.
  static double get weekendGap => Dim.row;

  /// The weekdays never get fewer rows than this; a shorter window scrolls.
  static const fewestWeekdayRows = _Fit.fewestRows;

  /// Height of a band of several-day events with [lanes] lanes.
  static double bandHeight(int lanes) => lanes == 0 ? 0 : 6 + lanes * SpanBar.lane;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final drag = DragScope.layoutOf(context);
    final first = context.app.weekStart;
    final days = [for (var i = 0; i < 7; i++) first.addDays(i)];
    final byDay = store.tasksBetween(days.first, days.last);
    // The calendars' events, with what runs over several days of the
    // planner's own among theirs.
    final range = context.calendars
        .eventsBetween(days.first, days.last)
        .withSpans(store.spansBetween(days.first, days.last));
    // Each day's tasks and events as one list, in one order.
    final items = {
      for (final d in days) d: store.arrangeDay(byDay[d] ?? const [], range.on(d)),
    };
    List<Task> tasks(Day d) => items[d]!;

    // The five weekdays side by side across the page, and the weekend in a
    // row of its own under them, the two days sharing the page's width.
    // Events over several days lie in a band right under each row's
    // headings; one running into the weekend shows in both bands.
    final weekdays = days.take(5).toList();
    final weekend = days.skip(5).toList();
    final weekdayBand = SpanLanes.pack(range.spans, weekdays.first, weekdays.last);
    final weekendBand = SpanLanes.pack(range.spans, weekend.first, weekend.last);

    // The weekend: its items and three empty lines, the fuller day's count
    // for both (the first empty line is the one typed on).
    var weekendRows = 0;
    for (final d in weekend) {
      final items = rowsNeeded(drag, DaySlot(d), tasks(d), 0) - 1;
      if (items + weekendSpare > weekendRows) weekendRows = items + weekendSpare;
    }
    // The weekdays fill what the window has left above it.
    final weekendHeight = weekendGap +
        Dim.dayHeader +
        bandHeight(weekendBand.length) +
        weekendRows * Dim.row;
    var rows = (minRows - (weekendHeight / Dim.row).ceil())
        .clamp(fewestWeekdayRows, _Fit.mostRows);
    for (final d in weekdays) {
      final needed = rowsNeeded(drag, DaySlot(d), tasks(d), rows);
      if (needed > rows) rows = needed;
    }

    Widget headings(List<Day> row) => Row(
          spacing: Dim.columnGap,
          children: [
            for (final d in row) Expanded(child: _DayHeader(day: d, narrow: false)),
          ],
        );
    Widget columns(List<Day> row, int rows) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: Dim.columnGap,
          children: [
            for (final d in row)
              Expanded(
                child: _DayColumn(
                  day: d,
                  heading: false,
                  tasks: tasks(d),
                  rows: rows,
                  narrow: false,
                  onOpen: onOpen,
                ),
              ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        headings(weekdays),
        if (!weekdayBand.isEmpty)
          SpanBand(
            first: weekdays.first,
            columns: weekdays.length,
            lanes: weekdayBand,
            gap: Dim.columnGap,
            onOpen: onOpen,
          ),
        columns(weekdays, rows),
        SizedBox(height: weekendGap),
        headings(weekend),
        if (!weekendBand.isEmpty)
          SpanBand(
            first: weekend.first,
            columns: weekend.length,
            lanes: weekendBand,
            gap: Dim.columnGap,
            onOpen: onOpen,
          ),
        columns(weekend, weekendRows),
      ],
    );
  }
}

// ---------------------------------------------------------- narrow layout

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    // Status bar, display cutout, rounded corners.
    final bars = MediaQuery.paddingOf(context);
    final composer = ComposerScope.maybeOf(context);
    // Built here, once: which page shows changes below, and must not build
    // the week again each time the week turns.
    final pager = _Pager(onOpen: onOpen);
    final lists = Padding(
      padding: EdgeInsets.only(left: bars.left, right: bars.right),
      child: TasksBody(onOpen: onOpen),
    );
    return Column(
      children: [
        ValueListenableBuilder<AppPage>(
          valueListenable: context.readApp.pageNotifier,
          builder: (context, page, header) => Container(
            padding: EdgeInsets.fromLTRB(16 + bars.left, 12 + bars.top,
                16 + bars.right, page == AppPage.tasks ? 4 : 12),
            color: theme.background,
            child: header,
          ),
          child: const _Header(narrow: true),
        ),
        Expanded(
          child: _PullToSync(
            child: ValueListenableBuilder<AppPage>(
              valueListenable: context.readApp.pageNotifier,
              builder: (context, page, _) => page == AppPage.tasks ? lists : pager,
            ),
          ),
        ),
        // While a task is typed on a phone: a bar right above the keyboard
        // to give it a time, a place, a note, a colour.
        if (isMobile && composer != null) ComposerBar(composer: composer),
        // And at the very bottom, the way from the week to the tasks and
        // back.
        if (isMobile) const _BottomBar(),
      ],
    );
  }
}

/// The phone's bar at the bottom: the planner and the Tasks page, one tap
/// apart and in reach of the thumb.
class _BottomBar extends StatelessWidget {
  const _BottomBar();

  static const height = 56.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.app;
    final bars = MediaQuery.paddingOf(context);
    // Out of the way while the keyboard is up: the room is for typing.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: theme.background,
        border: Border(top: BorderSide(color: theme.rule)),
      ),
      padding: EdgeInsets.only(left: bars.left, right: bars.right, bottom: bars.bottom),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: _BarTab(
                page: AppPage.planner,
                icon: app.monthView ? AppIcons.layoutGrid : AppIcons.calendarDays,
                label: app.monthView ? 'Month' : 'Week',
                selected: !app.onTasks,
              ),
            ),
            Expanded(
              child: _BarTab(
                page: AppPage.tasks,
                icon: AppIcons.listChecks,
                label: 'Tasks',
                selected: app.onTasks,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarTab extends StatefulWidget {
  const _BarTab({
    required this.page,
    required this.icon,
    required this.label,
    required this.selected,
  });

  final AppPage page;
  final IconData icon;
  final String label;
  final bool selected;

  @override
  State<_BarTab> createState() => _BarTabState();
}

class _BarTabState extends State<_BarTab> with _PageSpot {
  @override
  Object get spotId => ('tab', widget.page);

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.readApp;
    registerSpot(() => app.setPage(widget.page));
    final selected = widget.selected;
    return Semantics(
      selected: selected,
      child: Pressable(
        key: spotKey,
        // A tap on the tab that is open already leads back to today.
        onTap: () => selected && widget.page == AppPage.planner
            ? app.goToday()
            : app.setPage(widget.page),
        semanticLabel: widget.label,
        labelOnly: true,
        builder: (context, hovered, pressed) {
          final color = selected ? theme.text : theme.ink(pressed ? 70 : 45);
          return ColoredBox(
            color: over ? theme.ink(10) : const Color(0x00000000),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 22, color: color),
                const SizedBox(height: 3),
                Text(
                  widget.label,
                  style: context.text.tiny12.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The narrow layout's pages, one week (or month) each. A swipe sideways
/// turns the page, as the header's arrows do.
class _Pager extends StatefulWidget {
  const _Pager({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  /// Week pages count from the week holding this day; month pages count
  /// months from year 0.
  static final _origin = Day(2000, 1, 3);

  PageController? _pages;
  AppController? _app;

  /// What page numbers currently mean: month or week, and the week's first
  /// day. A change renumbers every page.
  (bool, int)? _mode;

  /// The page the pager is on or heading for.
  int _shown = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.readApp;
    if (app != _app) {
      _app?.removeListener(_onApp);
      _app = app..addListener(_onApp);
    }
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    _pages?.dispose();
    super.dispose();
  }

  static Day _firstDay(int page, bool month, int weekStart) => month
      ? Day(page ~/ 12, page % 12 + 1, 1)
      : _origin.startOfWeek(weekStart).addDays(page * 7);

  static int _pageOf(AppController app, bool month, int weekStart) => month
      ? app.anchor.year * 12 + app.anchor.month - 1
      : app.weekStart.difference(_origin.startOfWeek(weekStart)) ~/ 7;

  /// The visible week or month changed. The pager follows by turning its
  /// pages, not by being rebuilt: the pages themselves stay as they are.
  void _onApp() {
    if (!mounted) return;
    final app = _app!;
    final mode = (app.monthView, app.store.weekStart);
    if (mode != _mode) {
      setState(() {});
      return;
    }
    final page = _pageOf(app, mode.$1, mode.$2);
    if (page == _shown) return;
    // Turned from outside: the arrows, Today, a search result.
    _shown = page;
    final pages = _pages;
    if (pages == null || !pages.hasClients) return;
    final still = context
            .getInheritedWidgetOfExactType<MediaQuery>()
            ?.data
            .disableAnimations ??
        false;
    final from = pages.page ?? page.toDouble();
    if (!still && (from - page).abs() < 1.5) {
      pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      pages.jumpToPage(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The first day of the week is a setting; follow it.
    final weekStart = context.store.weekStart;
    final app = _app!;
    final month = app.monthView;
    final mode = (month, weekStart);

    if (_pages == null || mode != _mode) {
      final old = _pages;
      if (old != null) {
        // Still attached to the view being replaced in this build.
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      _shown = _pageOf(app, month, weekStart);
      _pages = PageController(initialPage: _shown);
      _mode = mode;
    }

    return PageView.builder(
      key: ValueKey(mode),
      controller: _pages,
      // The neighbouring pages are built ahead, in idle time, rather than
      // in the first frame of the swipe that brings them in.
      allowImplicitScrolling: true,
      onPageChanged: (index) {
        if (index == _shown) return;
        // Turned by hand: the header follows.
        _shown = index;
        context.readApp.show(_firstDay(index, month, weekStart));
      },
      itemBuilder: (context, index) {
        final first = _firstDay(index, month, weekStart);
        return _DeferredPage(
          key: ValueKey(index),
          index: index,
          immediate: index == _shown,
          child: month
              ? _ScrollArea(
                  padding: _pagePadding(context),
                  child: MonthView(month: first, onOpen: widget.onOpen),
                )
              : _WeekPage(first: first, onOpen: widget.onOpen),
        );
      },
    );
  }
}

/// A page of the pager that is built when it is needed and no sooner.
///
/// The pager keeps the pages beside the visible one ready. Building a week
/// takes long enough to drop frames on a slow phone, and the pager asks for
/// the next page to keep ready just as a swipe starts: the worst moment. So
/// a page that is not in view stays blank until scrolling has stopped, and
/// is built then, while nothing moves. A page that comes into view before
/// that is built at once.
class _DeferredPage extends StatefulWidget {
  const _DeferredPage({
    super.key,
    required this.index,
    required this.immediate,
    required this.child,
  });

  final int index;

  /// The page the pager is on: built without waiting.
  final bool immediate;
  final Widget child;

  @override
  State<_DeferredPage> createState() => _DeferredPageState();
}

class _DeferredPageState extends State<_DeferredPage> {
  /// How long after scrolling stops a page out of view is built.
  static const _rest = Duration(milliseconds: 120);

  late bool _ready = widget.immediate;
  ScrollPosition? _pager;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    final pager = Scrollable.maybeOf(context)?.position;
    if (pager != _pager) {
      _unlisten();
      _pager = pager;
      pager?.addListener(_check);
      pager?.isScrollingNotifier.addListener(_check);
    }
    _check();
  }

  @override
  void dispose() {
    _unlisten();
    _timer?.cancel();
    super.dispose();
  }

  void _unlisten() {
    _pager?.removeListener(_check);
    _pager?.isScrollingNotifier.removeListener(_check);
    _pager = null;
  }

  /// Whether any part of this page is on screen.
  bool get _inView {
    final pager = _pager;
    if (pager == null) return true;
    if (!pager.hasPixels || !pager.hasViewportDimension || pager.viewportDimension <= 0) {
      return false;
    }
    return (pager.pixels / pager.viewportDimension - widget.index).abs() < 1;
  }

  void _check() {
    if (_ready) return;
    final pager = _pager;
    if (pager == null || _inView) {
      _show();
    } else if (pager.isScrollingNotifier.value) {
      // Moving again: wait for the next rest.
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer(_rest, _show);
    }
  }

  void _show() {
    if (_ready || !mounted) return;
    _timer?.cancel();
    _unlisten();
    // The pager reports its position while it is being laid out, when
    // nothing may be marked for rebuilding; then wait for the frame's end.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _ready = true);
      });
    } else {
      setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _ready ? widget.child : const SizedBox.expand();
}

/// Padding around a narrow page's content, clear of the system bars.
EdgeInsets _pagePadding(BuildContext context) {
  final bars = MediaQuery.paddingOf(context);
  // On a phone the bar at the bottom keeps clear of the system's own.
  return EdgeInsets.fromLTRB(Dim.narrowPadding + bars.left, 8,
      Dim.narrowPadding + bars.right, 48 + (isMobile ? 0 : bars.bottom));
}

/// One week of the narrow layout: the days below one another.
class _WeekPage extends StatefulWidget {
  const _WeekPage({required this.first, required this.onOpen});

  final Day first;
  final ValueChanged<Task> onOpen;

  @override
  State<_WeekPage> createState() => _WeekPageState();
}

class _WeekPageState extends State<_WeekPage> {
  final Map<Day, GlobalKey> _dayKeys = {};
  final _scroll = ScrollController();
  late final AppController _app = context.readApp;

  @override
  void initState() {
    super.initState();
    _app.focus.addListener(_onFocusAsked);
    // A week is longer than a phone screen. Start at the day that was asked
    // for (today when the app opens) rather than at the week's first day.
    if (isMobile && _holds(_app.focusDay)) _reveal(_app.focusDay, animate: false);
  }

  @override
  void dispose() {
    _app.focus.removeListener(_onFocusAsked);
    _scroll.dispose();
    super.dispose();
  }

  bool _holds(Day day) =>
      day >= widget.first && day.difference(widget.first) < 7;

  void _onFocusAsked() {
    if (mounted && _holds(_app.focusDay)) _reveal(_app.focusDay, animate: true);
  }

  /// Scrolls this page so that [day] heads it. Only this page's own list is
  /// moved: a neighbouring page built ahead must not pull the pager over.
  void _reveal(Day day, {required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _dayKeys[day]?.currentContext?.findRenderObject();
      if (target == null || !target.attached || !_scroll.hasClients) return;
      final position = _scroll.position;
      final offset = RenderAbstractViewport.of(target)
          .getOffsetToReveal(target, 0)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (animate) {
        _scroll.animateTo(offset, duration: Dim.medium, curve: Curves.ease);
      } else {
        _scroll.jumpTo(offset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final days = [for (var i = 0; i < 7; i++) widget.first.addDays(i)];
    final byDay = store.tasksBetween(days.first, days.last);
    // The calendars' events, with what runs over several days of the
    // planner's own among theirs.
    final range = context.calendars
        .eventsBetween(days.first, days.last)
        .withSpans(store.spansBetween(days.first, days.last));
    // Each day's tasks and events as one list, in one order.
    final items = {
      for (final d in days) d: store.arrangeDay(byDay[d] ?? const [], range.on(d)),
    };

    final today = store.today;
    int minimum(Day d) => d == today ? 2 : 1;
    // What today and the days after it take of the page, about: with less
    // than a screenful of it, the page gets room below its last day, so
    // that today can still head the page late in the week.
    double? fromToday;
    if (_holds(today)) {
      fromToday = 0;
      for (final d in days) {
        if (d < today) continue;
        fromToday = fromToday! +
            Dim.dayHeader +
            TaskListBody.rowsFor(items[d]!.length, minimum(d)) * Dim.row +
            (d == days.last ? 0 : Dim.narrowDayGap);
      }
    }
    final padding = _pagePadding(context);
    // The height of the page as the window gives it (not as the keyboard
    // leaves it: the week is not built again while that slides).
    final bars = MediaQuery.paddingOf(context);
    final page = MediaQuery.sizeOf(context).height -
        bars.top -
        (Dim.headerHeight + 24) -
        (isMobile ? _BottomBar.height + bars.bottom : 0);
    return _ScrollArea(
      controller: _scroll,
      padding: fromToday == null
          ? padding
          : padding.copyWith(
              bottom: (page - padding.top - fromToday).clamp(padding.bottom, page),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: Dim.narrowDayGap,
        children: [
          for (final d in days)
            LocalRows(
              key: _dayKeys.putIfAbsent(d, GlobalKey.new),
              slot: DaySlot(d),
              tasks: items[d]!,
              minimum: minimum(d),
              builder: (context, rows) => _DayColumn(
                day: d,
                tasks: items[d]!,
                spans: range.spans.isEmpty ? const [] : range.spansOn(d).toList(),
                rows: rows,
                narrow: true,
                onOpen: widget.onOpen,
              ),
            ),
        ],
      ),
    );
  }
}

/// A vertically scrolling area that also scrolls by itself while a task is
/// dragged near its top or bottom edge.
class _ScrollArea extends StatefulWidget {
  const _ScrollArea({required this.padding, required this.child, this.controller});

  final EdgeInsetsGeometry padding;
  final Widget child;
  final ScrollController? controller;

  @override
  State<_ScrollArea> createState() => _ScrollAreaState();
}

class _ScrollAreaState extends State<_ScrollArea> {
  late final ScrollController _controller = widget.controller ?? ScrollController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragAutoScroll(
        controller: _controller,
        child: SingleChildScrollView(
          controller: _controller,
          padding: widget.padding,
          // Drawn once and then only moved while scrolling, instead of
          // being drawn anew for every frame of it.
          child: RepaintBoundary(child: widget.child),
        ),
      );
}

// ------------------------------------------------------------ drag chrome

/// The dragged task, lifted off the page and following the pointer.
class _DragGhost extends StatelessWidget {
  const _DragGhost();

  @override
  Widget build(BuildContext context) {
    final drag = DragScope.of(context);
    final task = drag.task;
    if (task == null) return const SizedBox.shrink();
    final theme = context.theme;
    final narrow = MediaQuery.sizeOf(context).width < Dim.breakpoint;
    final source = task.event;
    final lifted = IgnorePointer(
      child: MouseRegion(
        cursor: SystemMouseCursors.grabbing,
        // A card with a shadow: the row is plainly off the page, in hand.
        child: Container(
          padding: const EdgeInsets.only(left: 8, right: 27),
          decoration: BoxDecoration(
            color: theme.isDark ? theme.dialog : theme.background,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 6)),
            ],
          ),
          child: Row(
            children: [
              if (source != null) ...[
                Container(
                  width: 3,
                  height: Dim.pill - 6,
                  decoration: BoxDecoration(
                    color: calendarColor(theme, source.calendarColor),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: TaskPill(
                  task: task,
                  style: narrow ? context.text.taskCompact : context.text.task14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Only this follows the pointer; nothing else is redrawn as it moves.
    return ValueListenableBuilder<Offset>(
      valueListenable: drag.ghost,
      child: lifted,
      // The card reaches a little beyond the row it lifts, on both sides.
      builder: (context, position, child) => Positioned(
        left: position.dx - 8,
        top: position.dy,
        width: drag.width + 16,
        height: Dim.row,
        child: child!,
      ),
    );
  }
}

/// The tab at a window edge that turns the week while a task is held on it.
class _EdgeEar extends StatelessWidget {
  const _EdgeEar({required this.direction});

  final int direction;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final drag = DragScope.of(context);
    final over = drag.active && drag.edge == direction;
    final visible = drag.active && drag.edgesEnabled;
    // Hidden: fully off-window. Visible: 24 of 34 px peeking in (14 on a
    // phone, whose margins are too slim for more).
    final shift = !visible ? 34.0 : over ? 0.0 : (isMobile ? 20.0 : 10.0);
    final radius = direction < 0
        ? const BorderRadius.horizontal(right: Radius.circular(100))
        : const BorderRadius.horizontal(left: Radius.circular(100));
    return AnimatedPositioned(
      duration: Dim.medium,
      curve: Curves.ease,
      left: direction < 0 ? -shift : null,
      right: direction > 0 ? -shift : null,
      top: 0,
      bottom: 0,
      width: 34,
      child: IgnorePointer(
        child: Center(
          child: AnimatedScale(
            duration: Dim.medium,
            scale: over ? 1.15 : 1,
            alignment:
                direction < 0 ? Alignment.centerLeft : Alignment.centerRight,
            child: AnimatedContainer(
              duration: Dim.medium,
              height: 200,
              decoration: BoxDecoration(
                color: theme.text.withValues(alpha: over ? 0.25 : 0.1),
                borderRadius: radius,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
