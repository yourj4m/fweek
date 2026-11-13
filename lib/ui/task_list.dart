import 'package:flutter/gestures.dart' show kPrimaryButton, PointerDeviceKind;
import 'package:flutter/services.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'drag.dart';
import 'widgets/controls.dart';

/// Formats minutes after midnight as `9:30` / `09:30` or `9:30 AM`.
String formatTime(int minutes, {required bool use24h}) {
  final h = minutes ~/ 60, m = (minutes % 60).toString().padLeft(2, '0');
  if (use24h) return '$h:$m';
  final hour = h % 12 == 0 ? 12 : h % 12;
  return '$hour:$m ${h < 12 ? 'AM' : 'PM'}';
}

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
    // "Black" follows the theme, so it stays a strong mark in dark themes.
    final fill = color == null
        ? null
        : color.key == 'black'
            ? theme.text
            : color.fill;
    final onFill = color == null
        ? theme.text
        : color.key == 'black'
            ? theme.background
            : color.onFill;
    final use24h = context.store.setting<bool>(Settings.use24h);
    final textStyle = style.copyWith(
      color: onFill,
      decoration: task.done ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: onFill,
    );
    final label = task.time == null
        ? task.title
        : '${formatTime(task.time!, use24h: use24h)} ${task.title}';
    final iconSize = style.fontSize! - 2;
    final height = this.height ?? Dim.pill;
    return Opacity(
      opacity: task.done ? 0.3 : 1,
      child: Container(
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
            if (task.repeats)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(AppIcons.rotateCw, size: iconSize, color: onFill),
              ),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: textStyle,
              ),
            ),
          ],
        ),
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
      semanticLabel: done ? 'Mark as not done' : 'Mark as done',
      builder: (context, hovered, pressed) => SizedBox(
        width: size + 13,
        height: double.infinity,
        child: Center(
          child: Opacity(
            opacity: done ? 0.3 : (hovered ? 0.6 : 1),
            child: done
                ? Container(
                    width: size - 3,
                    height: size - 3,
                    decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
                    child: Icon(AppIcons.check,
                        size: size - 9, color: context.theme.background),
                  )
                : Icon(AppIcons.circleCheck, size: size - 2, color: ink),
          ),
        ),
      ),
    );
  }
}

/// One task on one ruled line.
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

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final task = widget.task;
    final dragging = DragScope.of(context).active;
    final showCheck = widget.compact || (_hovered && !dragging);
    return Listener(
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onOpen(task),
          child: _TouchPickUp(
            onPickUp: (position) => DragScope.read(context)
                .begin(task, position, globalRect(context)),
            child: SizedBox(
              height: Dim.row,
              child: Stack(
                children: [
                  Positioned.fill(
                    right: 35,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TaskPill(
                        task: task,
                        selected: context.app.highlightedTask == task.id,
                        style: widget.compact
                            ? context.text.taskCompact
                            : context.text.task14,
                      ),
                    ),
                  ),
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
                  if (_hovered && !dragging)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 1,
                      child: ColoredBox(color: theme.hoverRule),
                    ),
                ],
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

  /// Called with the typed text; the row then clears and stays focused so
  /// several tasks can be entered in a row.
  final ValueChanged<String> onSubmit;
  final bool compact;
  final FocusNode? focusNode;

  @override
  State<AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<AddRow> {
  final _controller = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    // Clicking away keeps what was typed, as a task.
    if (!_focus.hasFocus) _commit();
    if (mounted) setState(() {});
  }

  void _commit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final focused = _focus.hasFocus;
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
  final ValueChanged<String>? onAdd;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _drag = DragScope.of(context);
  }

  @override
  void didUpdateWidget(TaskListBody old) {
    super.didUpdateWidget(old);
    if (old.slot != widget.slot) _drag?.unregister(old.slot, _zoneKey);
  }

  @override
  void dispose() {
    _drag?.unregister(widget.slot, _zoneKey);
    _addFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final drag = _drag!;
    final draggedId = drag.task?.id;
    final shown = [
      for (final t in widget.tasks)
        if (t.id != draggedId) t,
    ];
    drag.register(widget.slot, _zoneKey, shown.length);
    final gapAt = drag.active && drag.targetSlot == widget.slot
        ? drag.targetIndex.clamp(0, shown.length)
        : -1;

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
                    gap(i),
                    TaskRow(
                      key: ValueKey(shown[i].id),
                      task: shown[i],
                      compact: widget.compact,
                      onOpen: widget.onOpen,
                    ),
                  ],
                  gap(shown.length),
                  AddRow(
                    compact: widget.compact,
                    focusNode: _addFocus,
                    onSubmit: widget.onAdd ??
                        (text) =>
                            context.readStore.addTask(widget.slot, text),
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
