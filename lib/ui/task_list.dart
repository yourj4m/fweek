import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton, PointerDeviceKind;
import 'package:flutter/services.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'composer.dart';
import 'context_menu.dart';
import 'drag.dart';
import 'task_actions.dart';
import 'widgets/controls.dart';

/// Formats minutes after midnight as `9:30` / `09:30` or `9:30 AM`.
String formatTime(int minutes, {required bool use24h}) {
  final h = minutes ~/ 60, m = (minutes % 60).toString().padLeft(2, '0');
  if (use24h) return '$h:$m';
  final hour = h % 12 == 0 ? 12 : h % 12;
  return '$hour:$m ${h < 12 ? 'AM' : 'PM'}';
}

/// How often the widgets that make up the week were built, by name. Counted
/// in debug builds only; tests use it to make sure that, say, moving a
/// dragged task does not rebuild every row again.
final Map<String, int> debugBuildCounts = {};

void _count(String name) {
  assert(() {
    debugBuildCounts[name] = (debugBuildCounts[name] ?? 0) + 1;
    return true;
  }());
}

/// The colour that marks the calendar an imported event comes from.
Color calendarColor(AppTheme theme, String key) {
  final color = TaskColor.resolve(key);
  // "Black" follows the theme, as it does for tasks.
  if (color == null || color.key == 'black') return theme.text;
  return color.fill;
}

/// What a row or chip says for [task]: its time, if any, and its title.
String taskLabel(Task task, {required bool use24h}) {
  final title = task.title.isEmpty && task.isEvent ? '(No title)' : task.title;
  return task.time == null ? title : '${formatTime(task.time!, use24h: use24h)} $title';
}

/// The first part of a place, enough to recognise it by on one short line.
String shortPlace(String location) =>
    location.split(RegExp(r'[,\n]')).first.trim();

/// A task's text inside its highlight pill, with reminder and repeat marks.
class TaskPill extends StatelessWidget {
  const TaskPill({
    super.key,
    required this.task,
    required this.style,
    this.height,
    this.selected = false,
  });

  final Task task;
  final TextStyle style;

  /// Height of the pill; by default the one that fits a ruled row.
  final double? height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final color = TaskColor.resolve(task.color);
    // Done tasks and hidden events are drawn faint. The faintness is in the
    // colours themselves: fading the finished drawing instead would cost an
    // extra drawing surface per row.
    final faint = task.done || (task.event?.hidden ?? false);
    Color tone(Color c) => faint ? c.withValues(alpha: c.a * 0.3) : c;
    // "Black" follows the theme, so it stays a strong mark in dark themes.
    final fill = color == null
        ? null
        : tone(color.key == 'black' ? theme.text : color.fill);
    final onFill = tone(color == null
        ? theme.text
        : color.key == 'black'
            ? theme.background
            : color.onFill);
    final use24h = context.store.setting<bool>(Settings.use24h);
    final textStyle = style.copyWith(
      color: onFill,
      decoration: task.done ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: onFill,
    );
    final iconSize = style.fontSize! - 2;
    final height = this.height ?? Dim.pill;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: selected
            ? [BoxShadow(color: theme.accent, spreadRadius: 2)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.reminder != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(AppIcons.bell, size: iconSize, color: onFill),
            ),
          if (task.repeats || (task.event?.repeats ?? false))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(AppIcons.rotateCw, size: iconSize, color: onFill),
            ),
          Flexible(
            child: Text(
              taskLabel(task, use24h: use24h),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }
}

/// The circled check that toggles a task.
class CheckToggle extends StatelessWidget {
  const CheckToggle({
    super.key,
    required this.done,
    required this.onTap,
    this.size = 22,
    this.color,
  });

  final bool done;
  final VoidCallback onTap;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? context.theme.text;
    return Pressable(
      onTap: onTap,
      focusable: false,
      semanticLabel: done ? 'Mark as not done' : 'Mark as done',
      builder: (context, hovered, pressed) {
        final tone = ink.withValues(alpha: ink.a * (done ? 0.3 : (hovered ? 0.6 : 1)));
        return SizedBox(
          width: size + 13,
          height: double.infinity,
          child: Center(
            child: done
                ? Container(
                    width: size - 3,
                    height: size - 3,
                    decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
                    child: Icon(AppIcons.check,
                        size: size - 9, color: context.theme.background),
                  )
                : Icon(AppIcons.circleCheck, size: size - 2, color: tone),
          ),
        );
      },
    );
  }
}

/// One task, or one imported event, on one ruled line.
///
/// An event is set apart by a bar in its calendar's colour at the left;
/// everything else about the row is the same: tap to open, the circle to
/// complete, drag (or long press and drag) to another day, right-click (or
/// long press and let go) for the menu.
class TaskRow extends StatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    required this.compact,
    required this.onOpen,
  });

  final Task task;

  /// Narrow layout: larger text and an always-visible check.
  final bool compact;
  final ValueChanged<Task> onOpen;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  bool _hovered = false;
  bool _focused = false;

  /// Opens the row's menu: at [at] for a click, by the row for the keyboard
  /// (the menu's first entry then takes the focus).
  void _menu([Offset? at]) => showTaskMenu(
        context,
        widget.task,
        anchor: at == null ? globalRect(context) : at & Size.zero,
        onOpen: widget.onOpen,
        keyboard: at == null,
      );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final task = widget.task;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      widget.onOpen(task);
    } else if (key == LogicalKeyboardKey.space) {
      context.readStore.setDone(task.id, !task.done);
    } else if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && HardwareKeyboard.instance.isShiftPressed)) {
      _menu();
    } else if (key == LogicalKeyboardKey.delete) {
      deleteWithUndo(context, task);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    _count('TaskRow');
    final theme = context.theme;
    final task = widget.task;
    final source = task.event;
    final dragging = DragScope.read(context).active;
    final keyed = _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final showCheck = widget.compact || ((_hovered || keyed) && !dragging);
    final style = widget.compact ? context.text.taskCompact : context.text.task14;
    final faint = task.done || (source?.hidden ?? false);
    final muted = theme.ink(faint ? 25 : 50);
    final place = task.hasLocation ? shortPlace(task.location) : '';
    final small = context.text.tiny12
        .copyWith(fontSize: isMobile ? 13 : 11.5, height: 1.2, color: muted);
    final done = task.subtasks.where((s) => !s.heading && s.done).length;
    final total = task.subtasks.where((s) => !s.heading).length;

    final marks = <Widget>[
      if (task.hasNote) Icon(AppIcons.text, size: style.fontSize! - 2, color: muted),
      if (total > 0) Text('$done/$total', style: small),
      if (source?.hidden ?? false)
        Icon(AppIcons.eyeOff, size: style.fontSize! - 2, color: muted),
    ];

    final content = Row(
      children: [
        if (source != null) ...[
          // A bar in the calendar's colour sets events apart from tasks.
          Container(
            width: 3,
            height: place.isEmpty ? Dim.pill - 6 : Dim.row - 16,
            decoration: BoxDecoration(
              color: calendarColor(theme, source.calendarColor)
                  .withValues(alpha: faint ? 0.3 : 1),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: ValueListenableBuilder<String?>(
                      valueListenable: context.readApp.highlight,
                      builder: (context, highlighted, _) => TaskPill(
                        task: task,
                        selected: highlighted == task.id,
                        style: style,
                      ),
                    ),
                  ),
                  for (final mark in marks)
                    Padding(padding: const EdgeInsets.only(left: 4), child: mark),
                ],
              ),
              if (place.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    place,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _onKey,
      child: Listener(
        onPointerDown: (event) {
          // A mouse drags as soon as it moves. A finger that moves is
          // scrolling; it picks a task up with a long press instead.
          if (event.kind != PointerDeviceKind.mouse ||
              event.buttons != kPrimaryButton) {
            return;
          }
          DragScope.read(context)
              .pointerDown(task, event.position, globalRect(context));
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Semantics(
            label: source == null ? null : 'Event',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onOpen(task),
              onSecondaryTapUp: (details) => _menu(details.globalPosition),
              child: _TouchPickUp(
                onPickUp: (position) => DragScope.read(context)
                    .begin(task, position, globalRect(context)),
                child: SizedBox(
                  height: Dim.row,
                  child: Stack(
                    children: [
                      Positioned.fill(right: 35, child: content),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: AnimatedOpacity(
                          duration: showCheck ? Duration.zero : Dim.medium,
                          opacity: showCheck ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !showCheck,
                            child: CheckToggle(
                              done: task.done,
                              onTap: () =>
                                  context.readStore.setDone(task.id, !task.done),
                            ),
                          ),
                        ),
                      ),
                      if ((_hovered || keyed) && !dragging)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: keyed ? 2 : 1,
                          child: ColoredBox(
                              color: keyed ? theme.accent : theme.hoverRule),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports a long press by a finger or pen, which picks a task up. A mouse
/// is left out on purpose: it drags by moving, and a slow click must stay a
/// click.
class _TouchPickUp extends StatelessWidget {
  const _TouchPickUp({required this.onPickUp, required this.child});

  /// Called with the global position of the press.
  final ValueChanged<Offset> onPickUp;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
        onLongPressStart: (details) {
          HapticFeedback.mediumImpact();
          onPickUp(details.globalPosition);
        },
        child: child,
      );
}

/// The empty ruled line at the end of a list where new tasks are typed.
class AddRow extends StatefulWidget {
  const AddRow({
    super.key,
    required this.onSubmit,
    required this.compact,
    this.focusNode,
  });

  /// Called with the typed text; returns the id of the task made of it.
  /// The row then clears and stays focused so several tasks can be entered
  /// in a row.
  final String? Function(String text) onSubmit;
  final bool compact;
  final FocusNode? focusNode;

  @override
  State<AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<AddRow> {
  final _controller = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _hovered = false;

  /// The phone's editing bar, which adds a time, a place and more to the
  /// task being typed; null on a desktop.
  Composer? _composer;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _composer = ComposerScope.maybeOf(context);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _composer?.detach(_focus);
    if (widget.focusNode == null) _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    final composer = _composer;
    if (_focus.hasFocus) {
      composer?.attach(_focus, _commit);
    } else if (composer == null || !composer.holds(_focus)) {
      // Clicking away keeps what was typed, as a task.
      _commit();
    } else if (!composer.busy) {
      _commit();
      composer.detach(_focus);
    }
    // Else one of the bar's own fields has the keyboard for a moment; the
    // task is still being written.
    if (mounted) setState(() {});
  }

  String? _commit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return null;
    _controller.clear();
    final id = widget.onSubmit(text);
    final composer = _composer;
    if (id != null && composer != null && composer.holds(_focus)) {
      composer.applyTo(context.readStore, id);
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final focused = _focus.hasFocus || (_composer?.holds(_focus) ?? false);
    final style = widget.compact ? context.text.taskCompact : context.text.task14;
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        height: Dim.row,
        child: Stack(
          clipBehavior: Clip.none,
          // Every layer carries a key: the layers shown change with hover and
          // focus, and the text field must keep its state through that (a
          // field recreated after focus arrived never opens the keyboard).
          children: [
            if (focused)
              Positioned(
                key: const ValueKey('card'),
                left: -8,
                right: -8,
                top: -2,
                bottom: -2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.isDark ? theme.dialog : theme.background,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1C000000),
                        blurRadius: 4,
                        spreadRadius: 1,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            if (_hovered && !focused)
              Positioned(
                key: const ValueKey('rule'),
                left: 0,
                right: 0,
                bottom: 0,
                height: 1,
                child: ColoredBox(color: theme.hoverRule),
              ),
            Positioned.fill(
              key: const ValueKey('field'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Center(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): () {
                        _controller.clear();
                        _focus.unfocus();
                      },
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      style: style,
                      cursorColor: theme.text,
                      cursorWidth: 1.5,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration.collapsed(hintText: ''),
                      onSubmitted: (_) {
                        _commit();
                        _focus.requestFocus();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ruled body of a day or list: its tasks, the add row, and blank lines
/// below. Also the drop zone for dragged tasks.
class TaskListBody extends StatefulWidget {
  const TaskListBody({
    super.key,
    required this.slot,
    required this.tasks,
    required this.rows,
    required this.compact,
    required this.onOpen,
    this.onAdd,
  });

  final Slot slot;
  final List<Task> tasks;

  /// Number of ruled lines to show.
  final int rows;
  final bool compact;
  final ValueChanged<Task> onOpen;

  /// Overrides how typed text becomes a task (used by list columns that do
  /// not exist yet). Defaults to adding to [slot].
  final String? Function(String text)? onAdd;

  /// Lines needed to show [taskCount] tasks plus the add row.
  static int rowsFor(int taskCount, int minimum) =>
      taskCount + 1 > minimum ? taskCount + 1 : minimum;

  @override
  State<TaskListBody> createState() => _TaskListBodyState();
}

class _TaskListBodyState extends State<TaskListBody> {
  final _zoneKey = GlobalKey();
  final _addFocus = FocusNode();
  DragController? _drag;

  /// What of the drag this list shows: whether one is on, whether the
  /// dragged task is one of its own, and where its gap is.
  (bool, bool, int)? _shown;

  (bool, bool, int) _view(DragController drag) {
    final dragged = drag.task;
    if (dragged == null) return (false, false, -1);
    final target = drag.targetSlot == widget.slot;
    return (
      true,
      widget.tasks.any((t) => t.id == dragged.id),
      // An event has no place among the tasks; its gap opens at the top.
      !target ? -1 : dragged.isEvent ? 0 : drag.targetIndex,
    );
  }

  /// The drag moved on: redraw only if that changes anything in this list.
  void _onDrag() {
    final drag = _drag;
    if (drag == null || !mounted) return;
    if (_view(drag) != _shown) setState(() {});
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
  void didUpdateWidget(TaskListBody old) {
    super.didUpdateWidget(old);
    if (old.slot != widget.slot) _drag?.unregister(old.slot, _zoneKey);
  }

  @override
  void dispose() {
    _drag?.removeListener(_onDrag);
    _drag?.unregister(widget.slot, _zoneKey);
    _addFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _count('TaskListBody');
    final theme = context.theme;
    final drag = _drag!;
    final view = _shown = _view(drag);
    final draggedId = drag.task?.id;
    final shown = view.$2
        ? [
            for (final t in widget.tasks)
              if (t.id != draggedId) t,
          ]
        : widget.tasks;
    drag.register(widget.slot, _zoneKey, shown.length);
    final active = view.$1;
    final gapAt = view.$3 < 0 ? -1 : view.$3.clamp(0, shown.length);

    // A gap opens smoothly but closes at once. The body is sized for its
    // rows as they will be, so a gap still closing (beside the task just
    // dropped, or in a list the pointer has left) would not fit in it.
    Widget gap(int index) => AnimatedContainer(
          duration: index == gapAt
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          curve: Curves.easeOut,
          height: index == gapAt ? Dim.row : 0,
        );

    return SizedBox(
      key: _zoneKey,
      height: widget.rows * Dim.row,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _RulePainter(theme.rule)),
          ),
          Positioned.fill(
            child: ClipRect(
              clipper: const _OverflowXClipper(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    // Gaps exist only while something is being dragged.
                    if (active) gap(i),
                    TaskRow(
                      key: ValueKey(shown[i].id),
                      task: shown[i],
                      compact: widget.compact,
                      onOpen: widget.onOpen,
                    ),
                  ],
                  if (active) gap(shown.length),
                  AddRow(
                    compact: widget.compact,
                    focusNode: _addFocus,
                    onSubmit: widget.onAdd ??
                        (text) => context.readStore.addTask(widget.slot, text),
                  ),
                  Expanded(
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _addFocus.requestFocus,
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

/// Clips vertically only, so the add row's raised card can extend sideways.
class _OverflowXClipper extends CustomClipper<Rect> {
  const _OverflowXClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-16, -4, size.width + 16, size.height + 4);

  @override
  bool shouldReclip(_OverflowXClipper oldClipper) => false;
}

class _RulePainter extends CustomPainter {
  const _RulePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var y = Dim.row - 0.5; y < size.height + 0.5; y += Dim.row) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_RulePainter old) => old.color != color;
}

/// Whether [listEquals] holds for two task lists by identity of their
/// entries: the same tasks in the same order, unchanged.
bool sameTasks(List<Task> a, List<Task> b) => listEquals(a, b);
