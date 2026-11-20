import 'dart:async';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../calendar/calendar_service.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../platform.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import 'composer.dart';
import 'context_menu.dart';
import 'day_progress.dart';
import 'drag.dart';
import 'event_rows.dart';
import 'month_view.dart';
import 'search_dialog.dart';
import 'settings_dialog.dart';
import 'strings.dart';
import 'task_actions.dart';
import 'task_dialog.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// The main window: header, the week (or month), and the Someday lists.
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
    _drag = DragController(
      onDrop: _drop,
      onEdge: (direction) =>
          direction < 0 ? context.readApp.previous() : context.readApp.next(),
      onHold: (task, row) =>
          showTaskMenu(context, task, anchor: row, onOpen: _open),
    )..edges = () => !context.readApp.monthView;
  }

  @override
  void dispose() {
    _drag.dispose();
    _composer.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _drop(Task task, Slot slot, int index) {
    if (task.fromCalendar && slot is ListSlot) {
      // An event has no place in a list; a task made of it does.
      copyIntoPlanner(context, task, slot: slot);
      return;
    }
    context.readStore.moveTask(task.id, slot, index: index);
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
    if (key == LogicalKeyboardKey.arrowLeft) {
      app.previous();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      app.next();
    } else if (key == LogicalKeyboardKey.keyT) {
      app.goToday();
    } else if (key == LogicalKeyboardKey.keyM) {
      app.setMonthView(!app.monthView);
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
        child: Focus(
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
        ),
      ),
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
    final bottom = MediaQuery.paddingOf(context).bottom;
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
  const _Header({required this.narrow});

  final bool narrow;

  void _menu(BuildContext context) {
    showPopover<void>(
      context: context,
      anchor: globalRect(context),
      align: 1,
      builder: (popover) => _MainMenu(page: context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final app = context.app;
    final first = app.monthView ? app.anchor.startOfMonth : app.weekStart;
    // A week that straddles two months is titled by the month holding most
    // of it (the month of its fourth day).
    final titled = app.monthView ? first : first.addDays(3);
    final month = narrow ? Strings.monthShort(titled) : Strings.month(titled);
    final style = narrow ? context.text.title31 : context.text.title36;
    return SizedBox(
      height: narrow ? 40 : Dim.headerHeight,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Pressable(
                onTap: () {
                  final store = context.readStore;
                  final onThisWeek = app.weekStart ==
                      store.today.startOfWeek(store.weekStart);
                  if (!isMobile) {
                    app.goToday();
                  } else if (app.monthView) {
                    // A phone has no keyboard shortcut for this: the title
                    // leads back to the current week, and from there to the
                    // month.
                    app.setMonthView(false);
                    app.goToday();
                  } else if (onThisWeek) {
                    app.setMonthView(true);
                  } else {
                    app.goToday();
                  }
                },
                semanticLabel: 'Go to today',
                builder: (context, hovered, pressed) => Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      // The title keeps its room; the week number yields.
                      flex: 0,
                      child: Text(
                        '$month ${titled.year}',
                        style: hovered
                            ? style.copyWith(color: theme.text.withValues(alpha: 0.75))
                            : style,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                    if (!app.monthView) ...[
                      const SizedBox(width: 12),
                      // Fades out under the buttons when the header is tight.
                      Flexible(
                        child: Text(
                          'W${first.addDays(3).isoWeek}',
                          style: style.copyWith(color: theme.ink(20)),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
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
          const SizedBox(width: 6),
          AppButton(
            icon: AppIcons.chevronLeft,
            kind: ButtonKind.primary,
            tooltip: 'Previous',
            onTap: app.previous,
          ),
          const SizedBox(width: 6),
          AppButton(
            icon: AppIcons.chevronRight,
            kind: ButtonKind.primary,
            tooltip: 'Next',
            onTap: app.next,
          ),
        ],
      ),
    );
  }
}

/// The header's menu. Its second page lists the calendars with a switch
/// each: one tap shows or hides a whole calendar.
class _MainMenu extends StatefulWidget {
  const _MainMenu({required this.page});

  /// The planner page's context, for what outlives the menu.
  final BuildContext page;

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

    final hidden = subscriptions.isEmpty ? 0 : _hiddenInView(app, calendars);
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
              checked: !app.monthView,
              onTap: () => _run(() => app.setMonthView(false)),
            ),
            MenuRow(
              icon: AppIcons.layoutGrid,
              label: 'Month',
              checked: app.monthView,
              hint: isMobile ? null : 'M',
              onTap: () => _run(() => app.setMonthView(true)),
            ),
            const _Divider(),
            MenuRow(
              icon: AppIcons.listPlus,
              label: 'New list',
              onTap: () => _run(() {
                // Lists live under the week; show it, then name the list.
                if (app.monthView) app.setMonthView(false);
                app.renameList.value = page.readStore.addList();
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
            if (sync.configured)
              MenuRow(
                icon: sync.state == SyncState.error
                    ? AppIcons.cloudAlert
                    : AppIcons.refreshCw,
                label: 'Sync now',
                hint: switch (sync.state) {
                  SyncState.syncing => 'syncing',
                  SyncState.error => 'failed',
                  _ => null,
                },
                danger: sync.state == SyncState.error,
                onTap: () => _run(() => sync.syncNow()),
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
    this.spanRow,
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

  /// Height of the slot each of [spans] takes, when they must keep to the
  /// ruled grid.
  final double? spanRow;

  final bool heading;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (heading) _DayHeader(day: day, narrow: narrow),
          if (spans.isNotEmpty)
            DaySpans(day: day, spans: spans, onOpen: onOpen, rowHeight: spanRow),
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

/// How many rows a body needs right now: its tasks (minus one being dragged
/// away), a gap if it is the drop target, and the add row.
int _rowsNeeded(DragController drag, Slot slot, List<Task> tasks, int minimum) {
  var count = tasks.length;
  if (drag.active) {
    if (tasks.any((t) => t.id == drag.task!.id)) count--;
    if (drag.targetSlot == slot) count++;
  }
  return TaskListBody.rowsFor(count, minimum);
}

/// Gives one day or list of the single-column layout its number of rows,
/// and builds it again only when that number changes.
///
/// While a task is dragged, the day it is over grows by a row and the day
/// it left shrinks by one. In the wide week all columns share a height, so
/// the grid works that out as a whole; here each day stands alone, and a
/// task crossing from one day to the next concerns those two days only, not
/// the three weeks the pager holds.
class _LocalRows extends StatefulWidget {
  const _LocalRows({
    super.key,
    required this.slot,
    required this.tasks,
    required this.minimum,
    required this.builder,
  });

  final Slot slot;
  final List<Task> tasks;
  final int minimum;
  final Widget Function(BuildContext context, int rows) builder;

  @override
  State<_LocalRows> createState() => _LocalRowsState();
}

class _LocalRowsState extends State<_LocalRows> {
  DragController? _drag;
  int _rows = 0;

  int _needed() => _rowsNeeded(_drag!, widget.slot, widget.tasks, widget.minimum);

  void _onDrag() {
    if (!mounted) return;
    final rows = _needed();
    if (rows != _rows) setState(() => _rows = rows);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drag = DragScope.read(context);
    if (drag != _drag) {
      _drag?.layout.removeListener(_onDrag);
      _drag = drag..layout.addListener(_onDrag);
    }
    _rows = _needed();
  }

  @override
  void didUpdateWidget(_LocalRows old) {
    super.didUpdateWidget(old);
    _rows = _needed();
  }

  @override
  void dispose() {
    _drag?.layout.removeListener(_onDrag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _rows);
}

// ------------------------------------------------------------ wide layout

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return _TrackpadTurn(
      child: _ScrollArea(
      padding: const EdgeInsets.all(Dim.pagePadding) +
          MediaQuery.paddingOf(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(narrow: false),
          const SizedBox(height: Dim.headerGap),
          if (app.monthView)
            MonthView(onOpen: onOpen)
          else ...[
            _WeekGrid(onOpen: onOpen),
            const SizedBox(height: Dim.somedayGap),
            _SomedayGrid(onOpen: onOpen, columns: 3, narrow: false),
          ],
          const SizedBox(height: 20),
        ],
      ),
      ),
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
  const _WeekGrid({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final drag = DragScope.layoutOf(context);
    final first = context.app.weekStart;
    final days = [for (var i = 0; i < 7; i++) first.addDays(i)];
    final byDay = store.tasksBetween(days.first, days.last);
    final range = context.calendars.eventsBetween(days.first, days.last);
    // Each day's tasks and events as one list, in one order.
    final items = {
      for (final d in days) d: store.arrangeDay(byDay[d] ?? const [], range.on(d)),
    };
    List<Task> tasks(Day d) => items[d]!;

    // Five single columns, then the last two days stacked in the sixth.
    // Events over several days lie in a band across the six columns, right
    // under the headings; those reaching the seventh day show again under
    // its heading, each on a ruled row of its own.
    final upper = days[5], lower = days[6];
    final band = SpanLanes.pack(range.spans, days.first, upper);
    final lowerSpans = range.spansOn(lower).toList();

    /// Lines a day takes in all: its items and the line to type on, but no
    /// fewer than [minimum].
    int lines(Day d, int minimum) => _rowsNeeded(drag, DaySlot(d), tasks(d), minimum);

    var rows = Dim.weekdayRows;
    for (final d in days.take(5)) {
      final needed = lines(d, Dim.weekdayRows);
      if (needed > rows) rows = needed;
    }
    final upperRows = lines(upper, Dim.weekendRows);
    var lowerRows = lines(lower, Dim.weekendRows) + lowerSpans.length;
    // Both stacks share a height in rows: a weekday is its rows; the
    // weekend is both bodies, a one-row gap and the second heading.
    final stacked = upperRows + lowerRows + 2;
    if (stacked > rows) {
      rows = stacked;
    } else {
      lowerRows = rows - upperRows - 2;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          spacing: Dim.columnGap,
          children: [
            for (final d in days.take(6))
              Expanded(child: _DayHeader(day: d, narrow: false)),
          ],
        ),
        if (!band.isEmpty)
          SpanBand(
            first: days.first,
            columns: 6,
            lanes: band,
            gap: Dim.columnGap,
            onOpen: onOpen,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: Dim.columnGap,
          children: [
            for (final d in days.take(5))
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DayColumn(
                    day: upper,
                    heading: false,
                    tasks: tasks(upper),
                    rows: upperRows,
                    narrow: false,
                    onOpen: onOpen,
                  ),
                  SizedBox(height: Dim.row),
                  _DayColumn(
                    day: lower,
                    tasks: tasks(lower),
                    spans: lowerSpans,
                    spanRow: Dim.row,
                    rows: lowerRows - lowerSpans.length,
                    narrow: false,
                    onOpen: onOpen,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- someday

class _SomedayGrid extends StatelessWidget {
  const _SomedayGrid({
    required this.onOpen,
    required this.columns,
    required this.narrow,
  });

  final ValueChanged<Task> onOpen;
  final int columns;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final lists = store.lists;

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 24,
        children: [
          for (var i = 0; i < lists.length; i++)
            _LocalRows(
              key: ValueKey(lists[i].id),
              slot: ListSlot(lists[i].id),
              tasks: store.tasksIn(lists[i].id),
              minimum: Dim.somedayRows,
              builder: (context, rows) => _ListColumn(
                list: lists[i],
                index: i,
                count: lists.length,
                rows: rows,
                narrow: true,
                onOpen: onOpen,
              ),
            ),
          // One column has no blank neighbour to type a new list into; it
          // gets a button instead.
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              icon: AppIcons.plus,
              label: 'New list',
              size: Dim.controlMedium,
              iconSize: 18,
              onTap: () =>
                  context.readApp.renameList.value = context.readStore.addList(),
            ),
          ),
        ],
      );
    }

    final drag = DragScope.layoutOf(context);
    // There is always at least one blank column after the lists: typing in
    // it creates a list. A full row therefore starts a new one.
    final total = ((lists.length + 1 + columns - 1) ~/ columns) * columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Dim.somedayGap,
      children: [
        for (var start = 0; start < total; start += columns)
          Builder(builder: (context) {
            var rows = Dim.somedayRows;
            for (var j = start; j < start + columns && j < lists.length; j++) {
              final needed = _rowsNeeded(drag, ListSlot(lists[j].id),
                  store.tasksIn(lists[j].id), Dim.somedayRows);
              if (needed > rows) rows = needed;
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: Dim.columnGap,
              children: [
                for (var j = start; j < start + columns; j++)
                  Expanded(
                    child: _ListColumn(
                      // A blank column that becomes a list keeps its state
                      // (and with it the keyboard) through the change.
                      key: ValueKey(j < lists.length ? lists[j].id : 'blank$j'),
                      list: j < lists.length ? lists[j] : null,
                      index: j,
                      count: lists.length,
                      // Only the first blank column invites a new list.
                      inviting: j == lists.length,
                      rows: rows,
                      narrow: false,
                      onOpen: onOpen,
                    ),
                  ),
              ],
            );
          }),
      ],
    );
  }
}

/// One Someday list, or a blank column that becomes a list when used.
class _ListColumn extends StatefulWidget {
  const _ListColumn({
    super.key,
    required this.list,
    required this.index,
    required this.count,
    required this.rows,
    required this.narrow,
    required this.onOpen,
    this.inviting = false,
  });

  final TaskList? list;

  /// Place among the lists (the first one is titled "Someday" until
  /// renamed), and how many lists there are.
  final int index;
  final int count;

  /// A blank column that says "New list".
  final bool inviting;
  final int rows;
  final bool narrow;
  final ValueChanged<Task> onOpen;

  @override
  State<_ListColumn> createState() => _ListColumnState();
}

class _ListColumnState extends State<_ListColumn> {
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  bool _editing = false;
  bool _hovered = false;
  String? _pendingListId;
  late final AppController _app = context.readApp;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editing) _finish();
    });
    _app.renameList.addListener(_onRenameAsked);
    // A list made from the menu a moment ago asks for its name right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRenameAsked());
  }

  @override
  void dispose() {
    _app.renameList.removeListener(_onRenameAsked);
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _onRenameAsked() {
    final id = widget.list?.id;
    if (!mounted || id == null || _app.renameList.value != id) return;
    _app.renameList.value = null;
    _edit();
    Scrollable.ensureVisible(context,
        alignment: 0.3, duration: Dim.medium, curve: Curves.ease);
  }

  String get _shownTitle {
    final title = widget.list?.title ?? '';
    if (title.isNotEmpty) return title;
    return widget.list != null && widget.index == 0 ? 'Someday' : '';
  }

  void _edit() {
    _title.text = widget.list?.title ?? '';
    setState(() => _editing = true);
    _titleFocus.requestFocus();
  }

  void _finish() {
    final store = context.readStore;
    final text = _title.text.trim();
    final id = widget.list?.id ?? _pendingListId;
    if (id != null) {
      store.renameList(id, text);
    } else if (text.isNotEmpty) {
      _pendingListId = store.addList(text);
    }
    if (mounted) setState(() => _editing = false);
  }

  void _delete() {
    final list = widget.list!;
    final store = context.readStore;
    final name = listTitle(store, list);
    final tasks = store.deleteList(list.id);
    context.readApp.say(
      tasks.isEmpty
          ? '$name deleted'
          : '$name and ${tasks.length} ${tasks.length == 1 ? 'task' : 'tasks'} deleted',
      action: 'Undo',
      onAction: () => store.restoreList(list.id, tasks),
    );
  }

  void _menu(Rect anchor) {
    final list = widget.list!;
    final store = context.readStore;
    final count = store.tasksIn(list.id).length;
    showPopover<void>(
      context: context,
      anchor: anchor,
      align: anchor.width == 0 ? -1 : 1,
      builder: (popover) {
        void run(VoidCallback action) {
          Navigator.of(popover).pop();
          if (mounted) action();
        }

        return PopoverSurface(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 232,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MenuRow(
                  icon: AppIcons.pencil,
                  label: 'Rename',
                  onTap: () => run(_edit),
                ),
                if (widget.index > 0)
                  MenuRow(
                    icon: widget.narrow ? AppIcons.arrowUp : AppIcons.arrowLeft,
                    label: widget.narrow ? 'Move up' : 'Move left',
                    onTap: () => run(() => store.moveList(list.id, -1)),
                  ),
                if (widget.index < widget.count - 1)
                  MenuRow(
                    icon: widget.narrow ? AppIcons.arrowDown : AppIcons.arrowRight,
                    label: widget.narrow ? 'Move down' : 'Move right',
                    onTap: () => run(() => store.moveList(list.id, 1)),
                  ),
                MenuRow(
                  icon: AppIcons.listPlus,
                  label: 'New list',
                  onTap: () => run(
                      () => context.readApp.renameList.value = store.addList()),
                ),
                MenuRow(
                  icon: AppIcons.trash2,
                  label: count == 0 ? 'Delete list' : 'Delete list and $count tasks',
                  danger: true,
                  onTap: () => run(_delete),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final list = widget.list;
    final style = context.text.heading21.copyWith(height: 52 / 21);
    final title = _shownTitle;
    final blank = title.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            height: Dim.listHeading,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.rule)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _title,
                          focusNode: _titleFocus,
                          style: style,
                          cursorColor: theme.text,
                          maxLines: 1,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration.collapsed(
                            hintText: 'List name',
                            hintStyle: style.copyWith(color: theme.ink(20)),
                          ),
                          onSubmitted: (_) => _titleFocus.unfocus(),
                        )
                      : Semantics(
                          button: true,
                          label: blank && list == null ? 'New list' : 'Rename $title',
                          excludeSemantics: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _edit,
                            onSecondaryTapUp: list == null
                                ? null
                                : (details) =>
                                    _menu(details.globalPosition & Size.zero),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.text,
                              child: Row(
                                children: [
                                  // The first blank column says what it is
                                  // for; before, that showed only under the
                                  // mouse, and lists went undiscovered.
                                  if (blank && widget.inviting) ...[
                                    Icon(AppIcons.plus,
                                        size: 18,
                                        color: theme.ink(_hovered ? 60 : 30)),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      !blank
                                          ? title
                                          : widget.inviting || _hovered
                                              ? 'New list'
                                              : '',
                                      style: style.copyWith(
                                        color: !blank
                                            ? theme.text
                                            : theme.ink(_hovered ? 60 : 30),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
                if (list != null && !_editing && (_hovered || widget.narrow))
                  Builder(
                    builder: (anchor) => AppButton(
                      icon: AppIcons.ellipsis,
                      kind: ButtonKind.ghost,
                      size: Dim.controlSmall,
                      iconSize: 18,
                      tooltip: 'List options',
                      onTap: () => _menu(globalRect(anchor)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        TaskListBody(
          // A blank column has no list yet: the first task typed creates one.
          slot: ListSlot(list?.id ?? _pendingListId ?? '\u0000blank${identityHashCode(this)}'),
          tasks: list == null ? const [] : store.tasksIn(list.id),
          rows: widget.rows,
          compact: widget.narrow,
          onOpen: widget.onOpen,
          onAdd: list != null
              ? null
              : (text) {
                  final store = context.readStore;
                  final id = _pendingListId ??= store.addList();
                  return store.addTask(ListSlot(id), text);
                },
        ),
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
    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(
              16 + bars.left, 16 + bars.top, 16 + bars.right, 16),
          color: theme.background,
          child: const _Header(narrow: true),
        ),
        Expanded(child: _Pager(onOpen: onOpen)),
        // While a task is typed on a phone: a bar right above the keyboard
        // to give it a time, a place, a note, a colour.
        if (isMobile && composer != null) ComposerBar(composer: composer),
      ],
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
  return EdgeInsets.fromLTRB(Dim.narrowPadding + bars.left, 8,
      Dim.narrowPadding + bars.right, 48 + bars.bottom);
}

/// One week of the narrow layout: the days below one another, then Someday.
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
    final range = context.calendars.eventsBetween(days.first, days.last);
    // Each day's tasks and events as one list, in one order.
    final items = {
      for (final d in days) d: store.arrangeDay(byDay[d] ?? const [], range.on(d)),
    };

    return _ScrollArea(
      controller: _scroll,
      padding: _pagePadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: Dim.narrowDayGap,
        children: [
          for (final d in days)
            _LocalRows(
              key: _dayKeys.putIfAbsent(d, GlobalKey.new),
              slot: DaySlot(d),
              tasks: items[d]!,
              minimum: d == store.today ? 2 : 1,
              builder: (context, rows) => _DayColumn(
                day: d,
                tasks: items[d]!,
                spans: range.spans.isEmpty ? const [] : range.spansOn(d).toList(),
                rows: rows,
                narrow: true,
                onOpen: widget.onOpen,
              ),
            ),
          _SomedayGrid(onOpen: widget.onOpen, columns: 1, narrow: true),
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
