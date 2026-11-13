import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../platform.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import 'drag.dart';
import 'month_view.dart';
import 'search_dialog.dart';
import 'settings_dialog.dart';
import 'strings.dart';
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

  /// Height of the on-screen keyboard at the last build.
  double _keyboard = 0;

  @override
  void initState() {
    super.initState();
    _drag = DragController(
      onDrop: (task, slot, index) =>
          context.readStore.moveTask(task.id, slot, index: index),
      onEdge: (direction) =>
          direction < 0 ? context.readApp.previous() : context.readApp.next(),
    );
  }

  @override
  void dispose() {
    _drag.dispose();
    _focus.dispose();
    super.dispose();
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
    final app = context.app;
    return DragScope(
      controller: _drag,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final narrow = size.width < Dim.breakpoint;
            _drag.edgesEnabled = !app.monthView;
            // An on-screen keyboard covers the bottom of the window. The
            // planner ends above it, so the row being typed in can scroll
            // into view.
            final keyboard = MediaQuery.viewInsetsOf(context).bottom;
            if (isMobile && _keyboard > 0 && keyboard == 0) {
              // The keyboard was put away (the back gesture does that):
              // typing is over, so the field lets go as well. Android
              // would otherwise leave it focused, with its text unsaved.
              WidgetsBinding.instance.addPostFrameCallback(
                  (_) => FocusManager.instance.primaryFocus?.unfocus());
            }
            _keyboard = keyboard;
            return Listener(
              onPointerMove: (e) => _drag.pointerMove(e.position, size),
              onPointerUp: (_) => _drag.pointerUp(),
              onPointerCancel: (_) => _drag.cancel(),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _focus.requestFocus,
                child: ColoredBox(
                  color: theme.background,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: keyboard),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: narrow
                              ? _NarrowLayout(onOpen: _open)
                              : _WideLayout(onOpen: _open),
                        ),
                        _EdgeEar(direction: -1),
                        _EdgeEar(direction: 1),
                        const _DragGhost(),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header({required this.narrow});

  final bool narrow;

  void _menu(BuildContext context) {
    final app = context.readApp;
    final sync = context.readSync;
    showPopover<void>(
      context: context,
      anchor: globalRect(context),
      align: 1,
      builder: (popover) {
        void run(VoidCallback action) {
          Navigator.of(popover).pop();
          action();
        }

        return PopoverSurface(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 232,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MenuRow(
                  icon: AppIcons.calendarCheck,
                  label: 'Today',
                  hint: isMobile ? null : 'T',
                  onTap: () => run(app.goToday),
                ),
                MenuRow(
                  icon: AppIcons.search,
                  label: 'Search',
                  hint: isMobile ? null : 'Ctrl F',
                  onTap: () => run(() => showSearchDialog(context)),
                ),
                const _Divider(),
                MenuRow(
                  icon: AppIcons.columns3,
                  label: 'Week',
                  checked: !app.monthView,
                  onTap: () => run(() => app.setMonthView(false)),
                ),
                MenuRow(
                  icon: AppIcons.layoutGrid,
                  label: 'Month',
                  checked: app.monthView,
                  hint: isMobile ? null : 'M',
                  onTap: () => run(() => app.setMonthView(true)),
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
                    onTap: () => run(() => sync.syncNow()),
                  ),
                MenuRow(
                  icon: AppIcons.settings,
                  label: 'Settings',
                  hint: isMobile ? null : 'Ctrl ,',
                  onTap: () => run(() => showSettingsDialog(context)),
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
                      child: Opacity(
                        opacity: hovered ? 0.75 : 1,
                        child: Text(
                          '$month ${titled.year}',
                          style: style,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                        ),
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
    return Container(
      height: Dim.dayHeader,
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: color, width: 2)),
      ),
      child: Row(
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
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.tasks,
    required this.rows,
    required this.narrow,
    required this.onOpen,
  });

  final Day day;
  final List<Task> tasks;
  final int rows;
  final bool narrow;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _DayHeader(day: day, narrow: narrow),
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
int _rowsNeeded(BuildContext context, Slot slot, List<Task> tasks, int minimum) {
  final drag = DragScope.of(context);
  var count = tasks.length;
  if (drag.active) {
    if (tasks.any((t) => t.id == drag.task!.id)) count--;
    if (drag.targetSlot == slot) count++;
  }
  return TaskListBody.rowsFor(count, minimum);
}

// ------------------------------------------------------------ wide layout

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return _ScrollArea(
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
    );
  }
}

class _WeekGrid extends StatelessWidget {
  const _WeekGrid({required this.onOpen});

  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final first = context.app.weekStart;
    final days = [for (var i = 0; i < 7; i++) first.addDays(i)];
    final byDay = store.tasksBetween(days.first, days.last);
    List<Task> tasks(Day d) => byDay[d] ?? const [];

    // Five single columns, then the last two days stacked in the sixth.
    var rows = Dim.weekdayRows;
    for (final d in days.take(5)) {
      final needed = _rowsNeeded(context, DaySlot(d), tasks(d), Dim.weekdayRows);
      if (needed > rows) rows = needed;
    }
    final upper = days[5], lower = days[6];
    final upperRows =
        _rowsNeeded(context, DaySlot(upper), tasks(upper), Dim.weekendRows);
    var lowerRows =
        _rowsNeeded(context, DaySlot(lower), tasks(lower), Dim.weekendRows);
    // Both stacks share a height in rows: weekday = header + rows; weekend =
    // two headers, a one-row gap, and both bodies.
    final stacked = upperRows + lowerRows + 2;
    if (stacked > rows) {
      rows = stacked;
    } else {
      lowerRows = rows - upperRows - 2;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: Dim.columnGap,
      children: [
        for (final d in days.take(5))
          Expanded(
            child: _DayColumn(
              day: d,
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
                tasks: tasks(upper),
                rows: upperRows,
                narrow: false,
                onOpen: onOpen,
              ),
              SizedBox(height: Dim.row),
              _DayColumn(
                day: lower,
                tasks: tasks(lower),
                rows: lowerRows,
                narrow: false,
                onOpen: onOpen,
              ),
            ],
          ),
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
    // Pad with blank columns to a full row; typing in one creates a list.
    final cells = lists.length + (columns - lists.length % columns) % columns;
    final total = cells < columns ? columns : cells;
    final rowsOfCells = <List<TaskList?>>[];
    for (var i = 0; i < total; i += columns) {
      rowsOfCells.add([
        for (var j = i; j < i + columns; j++) j < lists.length ? lists[j] : null,
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: narrow ? 24 : Dim.somedayGap,
      children: [
        for (final cellRow in rowsOfCells)
          if (narrow)
            for (final list in cellRow.whereType<TaskList>())
              _ListColumn(
                list: list,
                first: list.id == lists.first.id,
                rows: _rowsNeeded(context, ListSlot(list.id),
                    store.tasksIn(list.id), Dim.somedayRows),
                narrow: true,
                onOpen: onOpen,
              )
          else
            Builder(builder: (context) {
              var rows = Dim.somedayRows;
              for (final list in cellRow.whereType<TaskList>()) {
                final needed = _rowsNeeded(context, ListSlot(list.id),
                    store.tasksIn(list.id), Dim.somedayRows);
                if (needed > rows) rows = needed;
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: Dim.columnGap,
                children: [
                  for (final list in cellRow)
                    Expanded(
                      child: _ListColumn(
                        list: list,
                        first: list != null && list.id == lists.first.id,
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
    required this.list,
    required this.first,
    required this.rows,
    required this.narrow,
    required this.onOpen,
  });

  final TaskList? list;

  /// The first list is titled "Someday" until renamed.
  final bool first;
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

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editing) _finish();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  String get _shownTitle {
    final title = widget.list?.title ?? '';
    if (title.isNotEmpty) return title;
    return widget.first ? 'Someday' : '';
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

  void _menu(BuildContext anchor) {
    final list = widget.list!;
    final store = context.readStore;
    final count = store.tasksIn(list.id).length;
    showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      align: 1,
      builder: (popover) => PopoverSurface(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MenuRow(
                icon: AppIcons.pencil,
                label: 'Rename',
                onTap: () {
                  Navigator.of(popover).pop();
                  _edit();
                },
              ),
              MenuRow(
                icon: AppIcons.trash2,
                label: count == 0 ? 'Delete list' : 'Delete list and $count tasks',
                danger: true,
                onTap: () {
                  Navigator.of(popover).pop();
                  store.deleteList(list.id);
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
    final store = context.store;
    final list = widget.list;
    final style = context.text.heading21.copyWith(height: 52 / 21);
    final title = _shownTitle;
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
                          decoration: InputDecoration.collapsed(
                            hintText: 'List name',
                            hintStyle: style.copyWith(color: theme.ink(20)),
                          ),
                          onSubmitted: (_) => _titleFocus.unfocus(),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _edit,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.text,
                            child: Text(
                              title.isEmpty && _hovered ? 'New list' : title,
                              style: style.copyWith(
                                color: title.isEmpty ? theme.ink(20) : theme.text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                      onTap: () => _menu(anchor),
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
                  store.addTask(ListSlot(id), text);
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
    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(
              16 + bars.left, 16 + bars.top, 16 + bars.right, 16),
          color: theme.background,
          child: const _Header(narrow: true),
        ),
        Expanded(child: _Pager(onOpen: onOpen)),
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

  /// What page numbers currently mean: month or week, and the week's first
  /// day. A change renumbers every page.
  (bool, int)? _mode;

  /// The page the pager is on or heading for.
  int _shown = 0;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  static Day _firstDay(int page, bool month, int weekStart) => month
      ? Day(page ~/ 12, page % 12 + 1, 1)
      : _origin.startOfWeek(weekStart).addDays(page * 7);

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final month = app.monthView;
    final weekStart = context.store.weekStart;
    final mode = (month, weekStart);
    final page = month
        ? app.anchor.year * 12 + app.anchor.month - 1
        : app.weekStart.difference(_origin.startOfWeek(weekStart)) ~/ 7;

    if (_pages == null || mode != _mode) {
      final old = _pages;
      if (old != null) {
        // Still attached to the view being replaced in this build.
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      _pages = PageController(initialPage: page);
      _mode = mode;
      _shown = page;
    } else if (page != _shown) {
      // Turned from outside: the arrows, Today, a search result.
      _shown = page;
      final pages = _pages!;
      final animate = !MediaQuery.disableAnimationsOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!pages.hasClients) return;
        final from = pages.page ?? page.toDouble();
        if (animate && (from - page).abs() < 1.5) {
          pages.animateToPage(
            page,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        } else {
          pages.jumpToPage(page);
        }
      });
    }

    return PageView.builder(
      key: ValueKey(mode),
      controller: _pages,
      onPageChanged: (index) {
        if (index == _shown) return;
        // Turned by hand: the header and everything else follow.
        _shown = index;
        context.readApp.show(_firstDay(index, month, weekStart));
      },
      itemBuilder: (context, index) {
        final first = _firstDay(index, month, weekStart);
        return month
            ? _ScrollArea(
                padding: _pagePadding(context),
                child: MonthView(month: first, onOpen: widget.onOpen),
              )
            : _WeekPage(first: first, onOpen: widget.onOpen);
      },
    );
  }
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

  /// The request to show a particular day that was last acted on.
  int? _seenFocus;

  /// Scrolls so that [day] heads the page.
  void _reveal(Day day, {required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _dayKeys[day]?.currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: animate ? Dim.medium : Duration.zero,
        curve: Curves.ease,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final app = context.app;
    final days = [for (var i = 0; i < 7; i++) widget.first.addDays(i)];
    final byDay = store.tasksBetween(days.first, days.last);

    // A week is longer than a phone screen. Start at the day that was asked
    // for (today when the app opens, or the day of a search result) rather
    // than at the week's first day.
    final focus = app.focusDay;
    if (_seenFocus != app.focusRequests && days.contains(focus)) {
      final first = _seenFocus == null;
      _seenFocus = app.focusRequests;
      if (isMobile || !first) _reveal(focus, animate: !first);
    }

    return _ScrollArea(
      padding: _pagePadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: Dim.narrowDayGap,
        children: [
          for (final d in days)
            _DayColumn(
              key: _dayKeys.putIfAbsent(d, GlobalKey.new),
              day: d,
              tasks: byDay[d] ?? const [],
              rows: _rowsNeeded(context, DaySlot(d), byDay[d] ?? const [],
                  d == store.today ? 2 : 1),
              narrow: true,
              onOpen: widget.onOpen,
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
  const _ScrollArea({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  State<_ScrollArea> createState() => _ScrollAreaState();
}

class _ScrollAreaState extends State<_ScrollArea> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragAutoScroll(
        controller: _controller,
        child: SingleChildScrollView(
          controller: _controller,
          padding: widget.padding,
          child: widget.child,
        ),
      );
}

// ------------------------------------------------------------ drag chrome

/// The dragged task, following the pointer.
class _DragGhost extends StatelessWidget {
  const _DragGhost();

  @override
  Widget build(BuildContext context) {
    final drag = DragScope.of(context);
    final task = drag.task;
    if (task == null) return const SizedBox.shrink();
    final narrow = MediaQuery.sizeOf(context).width < Dim.breakpoint;
    return Positioned(
      left: drag.position.dx,
      top: drag.position.dy,
      width: drag.width,
      height: Dim.row,
      child: IgnorePointer(
        child: MouseRegion(
          cursor: SystemMouseCursors.grabbing,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(right: 35),
              child: TaskPill(
                task: task,
                style: narrow ? context.text.taskCompact : context.text.task14,
              ),
            ),
          ),
        ),
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
