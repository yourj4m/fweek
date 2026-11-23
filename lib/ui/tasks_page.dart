import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show TextCapitalization, TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'drag.dart';
import 'icons.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// How the Tasks page lays its lists out.
enum ListsLayout {
  /// Every list a column, side by side: when the window has room for all.
  board,

  /// The names of the lists at the left, one list open beside them.
  names,

  /// The names in a row at the top, one list open below: a phone.
  tabs,
}

/// The lists of the Tasks page, laid out for the room there is.
///
/// A list holds tasks: those that have no day yet, and (unless the user has
/// such tasks leave their list) those that were given one and so show in
/// the week as well, marked here with their day.
class TasksBody extends StatelessWidget {
  const TasksBody({super.key, required this.onOpen});

  final ValueChanged<Task> onOpen;

  /// A column is never narrower than this; with less room per list the
  /// page shows one list at a time.
  static const minColumn = 220.0;

  /// Nor wider than this, however few lists there are.
  static const maxColumn = 360.0;

  /// Width of the column of names.
  static const namesWidth = 216.0;

  static double sidePadding(double width) =>
      width < Dim.breakpoint ? Dim.narrowPadding : Dim.pagePadding;

  /// How many columns a window [width] wide has room for.
  static int columnsThatFit(double width) =>
      ((width - 2 * sidePadding(width) + Dim.columnGap) / (minColumn + Dim.columnGap))
          .floor();

  /// Which layout a window [width] wide gets for [lists] lists.
  static ListsLayout layoutFor(double width, int lists) {
    if (isMobile || width < 560) return ListsLayout.tabs;
    return lists <= columnsThatFit(width) ? ListsLayout.board : ListsLayout.names;
  }

  /// Ruled rows of a list in a page [height] high, with [above] taken by
  /// what stands over them: as many as reach the bottom, where the line for
  /// the done tasks follows.
  static int rowsThatFit(double height, {double above = 0}) =>
      ((height - above - Dim.row - 24) / Dim.row).floor().clamp(4, 60);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final lists = context.store.lists;
          return switch (layoutFor(size.width, lists.length)) {
            ListsLayout.board => _Board(lists: lists, size: size, onOpen: onOpen),
            ListsLayout.names => _Names(lists: lists, size: size, onOpen: onOpen),
            ListsLayout.tabs => _Tabs(lists: lists, size: size, onOpen: onOpen),
          };
        },
      );
}

/// A vertically scrolling area that also scrolls by itself while a task is
/// dragged near its top or bottom edge.
class _Scroll extends StatefulWidget {
  const _Scroll({super.key, required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  State<_Scroll> createState() => _ScrollState();
}

class _ScrollState extends State<_Scroll> {
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
          // On a phone a list is pulled down to sync, also a short one
          // that has nothing to scroll.
          physics: isMobile ? const AlwaysScrollableScrollPhysics() : null,
          padding: widget.padding,
          child: RepaintBoundary(child: widget.child),
        ),
      );
}

double _bottomPadding(BuildContext context) =>
    24 + (isMobile ? 0 : MediaQuery.paddingOf(context).bottom);

// ------------------------------------------------------------------ board

class _Board extends StatelessWidget {
  const _Board({required this.lists, required this.size, required this.onOpen});

  final List<TaskList> lists;
  final Size size;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final drag = DragScope.layoutOf(context);
    final pad = TasksBody.sidePadding(size.width);
    final available = size.width - 2 * pad;
    // With room to spare, a blank column at the end invites a new list.
    final inviting = lists.length < TasksBody.columnsThatFit(size.width);
    final count = lists.length + (inviting ? 1 : 0);
    final column = ((available - (count - 1) * Dim.columnGap) / count)
        .clamp(TasksBody.minColumn, TasksBody.maxColumn)
        .floorToDouble();
    // The columns share a height in rows, as the days of the week do.
    var rows = TasksBody.rowsThatFit(size.height, above: Dim.listHeading);
    for (final list in lists) {
      rows = math.max(
          rows, rowsNeeded(drag, ListSlot(list.id), store.openIn(list.id), rows));
    }
    return _Scroll(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, _bottomPadding(context)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lists.length; i++) ...[
            if (i > 0) const SizedBox(width: Dim.columnGap),
            SizedBox(
              width: column,
              child: ListColumn(
                key: ValueKey(lists[i].id),
                list: lists[i],
                rows: rows,
                compact: false,
                onOpen: onOpen,
              ),
            ),
          ],
          if (inviting) ...[
            const SizedBox(width: Dim.columnGap),
            SizedBox(width: column, child: _NewListColumn(rows: rows)),
          ],
        ],
      ),
    );
  }
}

/// The blank column after the lists of the board: a click starts a list.
class _NewListColumn extends StatelessWidget {
  const _NewListColumn({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final style = context.text.heading21.copyWith(height: 52 / 21);
    return Pressable(
      onTap: () => newList(context),
      semanticLabel: 'New list',
      labelOnly: true,
      builder: (context, hovered, pressed) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: Dim.listHeading,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.rule)),
            ),
            child: Row(
              children: [
                Icon(AppIcons.plus, size: 18, color: theme.ink(hovered ? 60 : 30)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New list',
                    style: style.copyWith(color: theme.ink(hovered ? 60 : 30)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          BlankRows(rows: rows),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- one list at a time

/// Names at the left, the open list beside them.
class _Names extends StatelessWidget {
  const _Names({required this.lists, required this.size, required this.onOpen});

  final List<TaskList> lists;
  final Size size;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final app = context.readApp;
    final pad = TasksBody.sidePadding(size.width);
    final openId = app.openList;
    final open = lists.firstWhere((l) => l.id == openId, orElse: () => lists.first);
    final tasks = store.openIn(open.id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: TasksBody.namesWidth + pad,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad - 10, 6, 0, _bottomPadding(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < lists.length; i++)
                  _ListName(
                    key: ValueKey(lists[i].id),
                    list: lists[i],
                    selected: lists[i].id == open.id,
                    tab: false,
                  ),
                const SizedBox(height: 6),
                Pressable(
                  onTap: () => newList(context),
                  semanticLabel: 'New list',
                  labelOnly: true,
                  builder: (context, hovered, pressed) => Container(
                    height: Dim.controlMedium,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(AppIcons.plus,
                            size: 16, color: context.theme.ink(hovered ? 70 : 40)),
                        const SizedBox(width: 8),
                        Text(
                          'New list',
                          style: context.text.small15
                              .copyWith(color: context.theme.ink(hovered ? 70 : 40)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: Dim.columnGap),
        Expanded(
          child: _Scroll(
            padding: EdgeInsets.fromLTRB(0, 0, pad, _bottomPadding(context)),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: LocalRows(
                  key: ValueKey(open.id),
                  slot: ListSlot(open.id),
                  tasks: tasks,
                  minimum: TasksBody.rowsThatFit(size.height, above: Dim.listHeading),
                  builder: (context, rows) => ListColumn(
                    list: open,
                    rows: rows,
                    compact: false,
                    onOpen: onOpen,
                    vertical: true,
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

/// Names in a row at the top, the open list below; a swipe sideways turns
/// to the next list.
class _Tabs extends StatefulWidget {
  const _Tabs({required this.lists, required this.size, required this.onOpen});

  final List<TaskList> lists;
  final Size size;
  final ValueChanged<Task> onOpen;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  PageController? _pages;
  late final AppController _app = context.readApp;

  /// The page the pager is on or heading for.
  int _shown = 0;

  /// How many pages the pager was made for.
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _app.renameList.addListener(_onRenameAsked);
    // A list made a moment ago, from the menu, asks for its name right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRenameAsked());
  }

  @override
  void dispose() {
    _app.renameList.removeListener(_onRenameAsked);
    _pages?.dispose();
    super.dispose();
  }

  /// A list just made asks for its name: here that is a small card under
  /// the row of names.
  void _onRenameAsked() {
    final id = _app.renameList.value;
    if (!mounted || id == null) return;
    _app.renameList.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final list = context.readStore.list(id);
      if (list != null) renameListCard(context, list, _stripRect());
    });
  }

  final _strip = GlobalKey();

  Rect _stripRect() {
    final box = _strip.currentContext?.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;
  }

  int _indexOf(String id) {
    final index = widget.lists.indexWhere((l) => l.id == id);
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final lists = widget.lists;
    final pad = TasksBody.sidePadding(widget.size.width);
    final index = _indexOf(_app.openList);
    final open = lists[index];

    if (_pages == null || _count != lists.length) {
      // A list was added or deleted: a pager of its own for the new number
      // of pages, opened at the right one. (Told to go to a page it has
      // only just been given, the old one stops a page short.)
      final old = _pages;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      _pages = PageController(initialPage: _shown = index);
      _count = lists.length;
    }
    final pages = _pages!;
    if (index != _shown) {
      // Chosen from outside: a tap on a name, a search result.
      _shown = index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !pages.hasClients) return;
        final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        if (!still && ((pages.page ?? index.toDouble()) - index).abs() < 1.5) {
          pages.animateToPage(index,
              duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
        } else {
          pages.jumpToPage(index);
        }
      });
    }

    final rows = TasksBody.rowsThatFit(widget.size.height, above: 49);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: _strip,
          height: 48,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(left: pad - 10, right: 4),
                  child: Row(
                    children: [
                      for (final list in lists)
                        _ListName(
                          key: ValueKey(list.id),
                          list: list,
                          selected: list.id == open.id,
                          tab: true,
                        ),
                      AppButton(
                        icon: AppIcons.plus,
                        kind: ButtonKind.ghost,
                        size: Dim.controlInline,
                        iconSize: 18,
                        tooltip: 'New list',
                        onTap: () => newList(context),
                      ),
                    ],
                  ),
                ),
              ),
              Builder(
                builder: (anchor) => AppButton(
                  icon: AppIcons.ellipsis,
                  kind: ButtonKind.ghost,
                  size: Dim.controlInline,
                  iconSize: 18,
                  tooltip: 'List options',
                  onTap: () => showListMenu(context, open, globalRect(anchor)),
                ),
              ),
              SizedBox(width: pad - 8),
            ],
          ),
        ),
        Container(height: 1, color: theme.rule),
        Expanded(
          child: PageView.builder(
            key: ValueKey(_count),
            controller: pages,
            itemCount: lists.length,
            onPageChanged: (page) {
              if (page == _shown || page >= lists.length) return;
              // Turned by hand: the names follow.
              _shown = page;
              _app.setOpenList(lists[page].id);
            },
            itemBuilder: (context, page) {
              final list = lists[page];
              return _Scroll(
                key: ValueKey(list.id),
                padding: EdgeInsets.fromLTRB(pad, 0, pad, _bottomPadding(context)),
                child: LocalRows(
                  slot: ListSlot(list.id),
                  tasks: store.openIn(list.id),
                  minimum: rows,
                  builder: (context, rows) => ListColumn(
                    list: list,
                    rows: rows,
                    compact: true,
                    onOpen: widget.onOpen,
                    heading: false,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A list's name where one list shows at a time: a row in the column of
/// names, or a tab. A tap opens the list. A dragged task can be dropped on
/// it (it goes to the end of that list), and held over it opens the list.
class _ListName extends StatefulWidget {
  const _ListName({
    super.key,
    required this.list,
    required this.selected,
    required this.tab,
  });

  final TaskList list;
  final bool selected;
  final bool tab;

  @override
  State<_ListName> createState() => _ListNameState();
}

class _ListNameState extends State<_ListName> {
  final _key = GlobalKey();
  DragController? _drag;
  bool _over = false;

  Object get _spot => ('list', widget.list.id);

  void _onDrag() {
    final over = _drag?.spot == _spot;
    if (over != _over && mounted) setState(() => _over = over);
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

  @override
  void didUpdateWidget(_ListName old) {
    super.didUpdateWidget(old);
    if (widget.tab && widget.selected && !old.selected) {
      // The open list's name stays in sight in the row of names.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(context,
              alignment: 0.5, duration: Dim.medium, curve: Curves.ease);
        }
      });
    }
  }

  @override
  void dispose() {
    _drag?.removeListener(_onDrag);
    _drag?.unregisterSpot(_spot, _key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final app = context.readApp;
    final list = widget.list;
    final name = store.listName(list.id);
    final count = store.openIn(list.id).length;
    _drag!.registerSpot(
      _spot,
      _key,
      drop: ListSlot(list.id),
      onDwell: () => app.setOpenList(list.id),
    );
    final selected = widget.selected;
    final text = context.text.small15.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
      color: selected ? theme.text : theme.ink(65),
    );
    final number = context.text.tiny12.copyWith(color: theme.ink(40));
    return Pressable(
      key: _key,
      onTap: () => app.setOpenList(list.id),
      onSecondaryTap: (at) => showListMenu(context, list, at & Size.zero),
      semanticLabel: '$name, $count to do${selected ? ', open' : ''}',
      labelOnly: true,
      builder: (context, hovered, pressed) {
        final fill = _over
            ? theme.ink(12)
            : widget.tab
                ? null
                : selected
                    ? theme.ink(8)
                    : hovered
                        ? theme.ink(5)
                        : null;
        if (widget.tab) {
          return Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: text, maxLines: 1),
                    if (count > 0) ...[
                      const SizedBox(width: 6),
                      Text('$count', style: number),
                    ],
                  ],
                ),
                if (selected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: ColoredBox(color: theme.text),
                  ),
              ],
            ),
          );
        }
        return Container(
          height: Dim.controlMedium,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(name, style: text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (count > 0) Text('$count', style: number),
            ],
          ),
        );
      },
    );
  }
}

// --------------------------------------------------------------- one list

/// One list: its heading, the tasks still to do with the line to add one,
/// and the done tasks folded away under them.
class ListColumn extends StatefulWidget {
  const ListColumn({
    super.key,
    required this.list,
    required this.rows,
    required this.compact,
    required this.onOpen,
    this.heading = true,
    this.vertical = false,
  });

  final TaskList list;

  /// Ruled lines for the tasks still to do.
  final int rows;
  final bool compact;
  final ValueChanged<Task> onOpen;

  /// Whether the list's name stands over it (not under a row of tabs,
  /// which says it already).
  final bool heading;

  /// Whether the lists are arranged one under another where this shows, so
  /// that a list moves up and down among them rather than left and right.
  final bool vertical;

  @override
  State<ListColumn> createState() => _ListColumnState();
}

class _ListColumnState extends State<ListColumn> {
  /// Whether the done tasks are on show.
  bool _doneOpen = false;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final list = widget.list;
    final slot = ListSlot(list.id);
    final tasks = store.openIn(list.id);
    final done = store.doneIn(list.id);
    var rows = widget.rows;
    if (_doneOpen && done.isNotEmpty) {
      // The done tasks take the place of blank lines, as far as there are
      // any: opened, they are in sight, not below the end of the page.
      final needed = rowsNeeded(DragScope.layoutOf(context), slot, tasks, 1);
      rows = math.max(needed, rows - done.length);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.heading) ListHeading(list: list, vertical: widget.vertical),
        TaskListBody(
          slot: slot,
          tasks: tasks,
          rows: rows,
          compact: widget.compact,
          onOpen: widget.onOpen,
        ),
        DoneFold(
          list: list,
          done: done,
          open: _doneOpen,
          onToggle: () => setState(() => _doneOpen = !_doneOpen),
          compact: widget.compact,
          onOpen: widget.onOpen,
        ),
      ],
    );
  }
}

/// A list's name over its tasks. A click on it renames the list in place.
class ListHeading extends StatefulWidget {
  const ListHeading({super.key, required this.list, required this.vertical});

  final TaskList list;
  final bool vertical;

  @override
  State<ListHeading> createState() => _ListHeadingState();
}

class _ListHeadingState extends State<ListHeading> {
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  bool _editing = false;
  bool _hovered = false;
  late final AppController _app = context.readApp;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editing) _finish();
    });
    _app.renameList.addListener(_onRenameAsked);
    // A list made a moment ago asks for its name right away.
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
    if (!mounted || _app.renameList.value != widget.list.id) return;
    _app.renameList.value = null;
    _edit();
    Scrollable.ensureVisible(context,
        alignment: 0.3, duration: Dim.medium, curve: Curves.ease);
  }

  void _edit() {
    _title.text = widget.list.title;
    setState(() => _editing = true);
    _titleFocus.requestFocus();
  }

  void _finish() {
    context.readStore.renameList(widget.list.id, _title.text.trim());
    if (mounted) setState(() => _editing = false);
  }

  void _menu(Rect anchor) => showListMenu(
        context,
        widget.list,
        anchor,
        vertical: widget.vertical,
        onRename: _edit,
      );

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final list = widget.list;
    final style = context.text.heading21.copyWith(height: 52 / 21);
    final name = store.listName(list.id);
    final untitled = list.title.isEmpty;
    final count = store.openIn(list.id).length;
    return MouseRegion(
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
                      label: 'Rename $name',
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _edit,
                        onSecondaryTapUp: (details) =>
                            _menu(details.globalPosition & Size.zero),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.text,
                          child: Text(
                            name,
                            style: style.copyWith(
                              color: untitled ? theme.ink(55) : theme.text,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
            ),
            if (!_editing && (_hovered || isMobile))
              Builder(
                builder: (anchor) => AppButton(
                  icon: AppIcons.ellipsis,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 18,
                  tooltip: 'List options',
                  onTap: () => _menu(globalRect(anchor)),
                ),
              )
            else if (!_editing && count > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: Text(
                  '$count',
                  style: context.text.caption14.copyWith(color: theme.ink(35)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The done tasks of a list, folded into one line ("4 done") that opens
/// them, the one ticked last first.
class DoneFold extends StatelessWidget {
  const DoneFold({
    super.key,
    required this.list,
    required this.done,
    required this.open,
    required this.onToggle,
    required this.compact,
    required this.onOpen,
  });

  final TaskList list;
  final List<Task> done;
  final bool open;
  final VoidCallback onToggle;
  final bool compact;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    if (done.isEmpty) return const SizedBox.shrink();
    final muted = context.text.caption14.copyWith(color: theme.ink(45));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: Dim.row,
          child: Row(
            children: [
              Expanded(
                child: Pressable(
                  onTap: onToggle,
                  semanticLabel:
                      '${done.length} done, ${open ? 'hide them' : 'show them'}',
                  labelOnly: true,
                  builder: (context, hovered, pressed) => Row(
                    children: [
                      Icon(
                        open ? AppIcons.chevronDown : AppIcons.chevronRight,
                        size: 16,
                        color: theme.ink(hovered ? 70 : 40),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${done.length} done',
                        style: hovered ? muted.copyWith(color: theme.ink(70)) : muted,
                      ),
                    ],
                  ),
                ),
              ),
              if (open)
                Pressable(
                  onTap: () => clearDoneWithUndo(context, list),
                  semanticLabel: 'Clear done tasks',
                  labelOnly: true,
                  builder: (context, hovered, pressed) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Text(
                      'Clear',
                      style: muted.copyWith(
                        color: theme.ink(hovered ? 90 : 55),
                        decoration: TextDecoration.underline,
                        decorationColor: theme.ink(30),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (open)
          for (final task in done)
            TaskRow(
              key: ValueKey(task.id),
              task: task,
              compact: compact,
              onOpen: onOpen,
              slot: ListSlot(list.id),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------- list actions

/// Makes a list after the others, opens it and asks for its name.
void newList(BuildContext context) {
  final app = context.readApp;
  final id = context.readStore.addList();
  app.setOpenList(id);
  app.renameList.value = id;
}

/// Deletes a list and offers to undo. Its tasks that are on a day stay
/// there.
void deleteListWithUndo(BuildContext context, TaskList list) {
  final store = context.readStore;
  final name = store.listName(list.id);
  final removal = store.deleteList(list.id);
  final gone = removal.deleted.length, kept = removal.detached.length;
  context.readApp.say(
    [
      gone == 0 ? '$name deleted' : '$name and $gone ${gone == 1 ? 'task' : 'tasks'} deleted',
      if (kept > 0) '$kept with a day ${kept == 1 ? 'stays' : 'stay'} in the week',
    ].join('; '),
    action: 'Undo',
    onAction: () => store.restoreList(removal),
  );
}

/// Clears a list's done tasks and offers to undo.
void clearDoneWithUndo(BuildContext context, TaskList list) {
  final store = context.readStore;
  final removal = store.clearDone(list.id);
  final count = removal.deleted.length + removal.detached.length;
  if (count == 0) return;
  context.readApp.say(
    '$count done ${count == 1 ? 'task' : 'tasks'} cleared from ${store.listName(list.id)}',
    action: 'Undo',
    onAction: () => store.restoreList(removal),
  );
}

/// The menu of a list. [onRename] renames it where its name stands; without
/// it a small card asks for the name. With [vertical], the lists are one
/// under another where the menu was asked for.
void showListMenu(
  BuildContext context,
  TaskList list,
  Rect anchor, {
  bool vertical = false,
  VoidCallback? onRename,
}) {
  final store = context.readStore;
  final lists = store.lists;
  final index = lists.indexWhere((l) => l.id == list.id);
  final open = store.openIn(list.id).where((t) => t.date == null).length;
  final done = store.doneIn(list.id).length;
  final root = Navigator.of(context, rootNavigator: true).context;
  showPopover<void>(
    context: context,
    anchor: anchor,
    align: anchor.width == 0 ? -1 : 1,
    builder: (popover) {
      void run(VoidCallback action) {
        Navigator.of(popover).pop();
        if (root.mounted) action();
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
                onTap: () => run(onRename ?? () => renameListCard(root, list, anchor)),
              ),
              if (index > 0)
                MenuRow(
                  icon: vertical ? AppIcons.arrowUp : AppIcons.arrowLeft,
                  label: vertical ? 'Move up' : 'Move left',
                  onTap: () => run(() => store.moveList(list.id, -1)),
                ),
              if (index < lists.length - 1)
                MenuRow(
                  icon: vertical ? AppIcons.arrowDown : AppIcons.arrowRight,
                  label: vertical ? 'Move down' : 'Move right',
                  onTap: () => run(() => store.moveList(list.id, 1)),
                ),
              MenuRow(
                icon: AppIcons.listPlus,
                label: 'New list',
                onTap: () => run(() => newList(root)),
              ),
              if (done > 0)
                MenuRow(
                  icon: AppIcons.eraser,
                  label: 'Clear $done done',
                  onTap: () => run(() => clearDoneWithUndo(root, list)),
                ),
              MenuRow(
                icon: AppIcons.trash2,
                label: open == 0 ? 'Delete list' : 'Delete list and $open tasks',
                danger: true,
                onTap: () => run(() => deleteListWithUndo(root, list)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Asks for a list's name in a small card by [anchor].
Future<void> renameListCard(BuildContext context, TaskList list, Rect anchor) =>
    showPopover<void>(
      context: context,
      anchor: anchor,
      align: -1,
      builder: (popover) => PopoverSurface(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SizedBox(width: 240, child: _RenameField(list: list)),
      ),
    );

class _RenameField extends StatefulWidget {
  const _RenameField({required this.list});

  final TaskList list;

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final _controller = TextEditingController(text: widget.list.title);
  late final PlannerStore _store;

  @override
  void initState() {
    super.initState();
    _store = context.readStore;
  }

  void _save() {
    final text = _controller.text.trim();
    final list = _store.list(widget.list.id);
    if (list != null && list.title != text) _store.renameList(list.id, text);
  }

  @override
  void dispose() {
    // Closed by a tap beside the card: what was typed is the name. Not
    // written right here, while the card is being taken down.
    final text = _controller.text.trim();
    final id = widget.list.id;
    final store = _store;
    scheduleMicrotask(() {
      final list = store.list(id);
      if (list != null && list.title != text) store.renameList(id, text);
    });
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final style = context.text.body17;
    return TextField(
      controller: _controller,
      autofocus: true,
      style: style,
      cursorColor: theme.text,
      maxLines: 1,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration.collapsed(
        hintText: 'List name',
        hintStyle: style.copyWith(color: theme.ink(25)),
      ),
      onSubmitted: (_) {
        _save();
        Navigator.of(context).maybePop();
      },
    );
  }
}

// ------------------------------------------------------------ side panel

/// The lists in a panel beside the week (wide windows): a task is dragged
/// from here straight onto a day, or from a day back into a list.
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.onOpen, this.width = defaultWidth});

  final ValueChanged<Task> onOpen;

  /// Room for the lists, without the page's padding at the window's edge.
  final double width;

  /// The width the panel comes with, and the limits its edge is dragged
  /// between. The week keeps [weekRoom] at least, so in a window that only
  /// just has room for the panel there is little to widen.
  static const defaultWidth = 280.0;
  static const minWidth = 220.0;
  static const maxWidth = 640.0;
  static const weekRoom = 920.0;

  /// [wanted] brought within what a window [window] wide allows.
  static double fit(double wanted, double window) {
    final most = (window - weekRoom - Dim.pagePadding).clamp(defaultWidth, maxWidth);
    return wanted.clamp(minWidth, most);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final app = context.readApp;
    final folded = {
      ...?(store.setting<Object?>(Settings.foldedLists) as List?)?.whereType<String>(),
    };
    void fold(String id, bool shut) => store.setSetting(Settings.foldedLists, [
          for (final l in store.lists)
            if (l.id == id ? shut : folded.contains(l.id)) l.id,
        ]);
    final bars = MediaQuery.paddingOf(context);
    return Container(
      width: width + Dim.pagePadding,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Dim.pagePadding, Dim.pagePadding + bars.top, Dim.pagePadding - 8, 0),
            child: SizedBox(
              height: Dim.headerHeight,
              child: Row(
                children: [
                  Expanded(
                    child: Text('Lists', style: context.text.heading24, maxLines: 1),
                  ),
                  // The one button that shuts the panel. The Tasks page
                  // itself is a view, chosen in the header.
                  Semantics(
                    container: true,
                    child: AppButton(
                      icon: AppIcons.panelRightClose,
                      kind: ButtonKind.ghost,
                      tooltip: 'Hide the lists (P)',
                      onTap: () => app.setPanel(false),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _Scroll(
              padding: EdgeInsets.fromLTRB(
                  Dim.pagePadding, 0, Dim.pagePadding, 24 + bars.bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final list in store.lists)
                    _PanelList(
                      key: ValueKey(list.id),
                      list: list,
                      folded: folded.contains(list.id),
                      onFold: (shut) => fold(list.id, shut),
                      onOpen: onOpen,
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Pressable(
                      onTap: () => newListFromPanel(context),
                      semanticLabel: 'New list',
                      labelOnly: true,
                      builder: (context, hovered, pressed) => SizedBox(
                        height: Dim.controlMedium,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(AppIcons.plus,
                                size: 16, color: theme.ink(hovered ? 70 : 40)),
                            const SizedBox(width: 8),
                            Text(
                              'New list',
                              style: context.text.small15
                                  .copyWith(color: theme.ink(hovered ? 70 : 40)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// From the panel: a list after the others, its name typed where it stands.
void newListFromPanel(BuildContext context) {
  final id = context.readStore.addList();
  context.readApp.renameList.value = id;
}

/// One list of the panel: its name, which folds it shut or open, and under
/// it the tasks still to do.
class _PanelList extends StatefulWidget {
  const _PanelList({
    super.key,
    required this.list,
    required this.folded,
    required this.onFold,
    required this.onOpen,
  });

  final TaskList list;
  final bool folded;
  final ValueChanged<bool> onFold;
  final ValueChanged<Task> onOpen;

  @override
  State<_PanelList> createState() => _PanelListState();
}

class _PanelListState extends State<_PanelList> {
  final _key = GlobalKey();
  DragController? _drag;
  bool _over = false;

  // The name is typed where it stands, as on the Tasks page.
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  bool _editing = false;
  late final AppController _app = context.readApp;

  Object get _spot => ('panel', widget.list.id);

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editing) _finish();
    });
    _app.renameList.addListener(_onRenameAsked);
    // A list made a moment ago asks for its name right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRenameAsked());
  }

  void _onRenameAsked() {
    if (!mounted || _app.renameList.value != widget.list.id) return;
    _app.renameList.value = null;
    _edit();
    Scrollable.ensureVisible(context,
        alignment: 0.5, duration: Dim.medium, curve: Curves.ease);
  }

  void _edit() {
    _title.text = widget.list.title;
    _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
    setState(() => _editing = true);
    _titleFocus.requestFocus();
  }

  void _finish() {
    context.readStore.renameList(widget.list.id, _title.text.trim());
    if (mounted) setState(() => _editing = false);
  }

  void _onDrag() {
    final over = _drag?.spot == _spot;
    if (over != _over && mounted) setState(() => _over = over);
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

  @override
  void dispose() {
    _app.renameList.removeListener(_onRenameAsked);
    _drag?.removeListener(_onDrag);
    _drag?.unregisterSpot(_spot, _key);
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  /// The heading while its name is typed: the same line, with a field in
  /// the place of the name.
  Widget _nameField(BuildContext context) {
    final theme = context.theme;
    final style = context.text.heading18;
    return Container(
      key: _key,
      height: Dim.dayHeader,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.text, width: 2)),
      ),
      child: TextField(
        controller: _title,
        focusNode: _titleFocus,
        style: style,
        cursorColor: theme.text,
        maxLines: 1,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration.collapsed(
          hintText: 'List name',
          hintStyle: style.copyWith(color: theme.ink(25)),
        ),
        onSubmitted: (_) => _titleFocus.unfocus(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final list = widget.list;
    final name = store.listName(list.id);
    final tasks = store.openIn(list.id);
    final folded = widget.folded;
    // A task dropped on the name goes to the end of the list; held over a
    // folded list, it opens it.
    _drag!.registerSpot(
      _spot,
      _key,
      drop: ListSlot(list.id),
      onDwell: folded ? () => widget.onFold(false) : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editing)
          _nameField(context)
        else
          Pressable(
            key: _key,
            onTap: () => widget.onFold(!folded),
            onSecondaryTap: (at) => showListMenu(context, list, at & Size.zero,
                vertical: true, onRename: _edit),
            semanticLabel:
                '$name, ${tasks.length} to do, ${folded ? 'folded' : 'open'}',
            labelOnly: true,
            builder: (context, hovered, pressed) => Container(
              height: Dim.dayHeader,
              decoration: BoxDecoration(
                color: _over ? theme.ink(8) : null,
                border: Border(
                  bottom: BorderSide(color: folded ? theme.rule : theme.text, width: folded ? 1 : 2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: context.text.heading18,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (tasks.isNotEmpty)
                    Text(
                      '${tasks.length}',
                      style: context.text.caption14.copyWith(color: theme.ink(40)),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    folded ? AppIcons.chevronRight : AppIcons.chevronDown,
                    size: 16,
                    color: theme.ink(hovered ? 70 : 40),
                  ),
                ],
              ),
            ),
          ),
        if (!folded)
          LocalRows(
            slot: ListSlot(list.id),
            tasks: tasks,
            minimum: 2,
            builder: (context, rows) => TaskListBody(
              slot: ListSlot(list.id),
              tasks: tasks,
              rows: rows,
              compact: false,
              onOpen: widget.onOpen,
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }
}
