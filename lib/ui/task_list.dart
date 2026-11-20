import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton, PointerDeviceKind;
import 'package:flutter/services.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../text/links.dart';
import '../theme/app_theme.dart';
import 'composer.dart';
import 'context_menu.dart';
import 'drag.dart';
import 'strings.dart';
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
///
/// A web address in the title reads in its short form ([shortLink]); with
/// [raw] it is left as typed, for a widget that shortens it itself and
/// needs the address to open.
String taskLabel(Task task, {required bool use24h, bool raw = false}) {
  final title = task.title.isEmpty && task.fromCalendar
      ? '(No title)'
      : raw
          ? task.title
          : tidyText(task.title);
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
    this.over = false,
  });

  final Task task;
  final TextStyle style;

  /// An event that lies in the past: drawn faint, like a done task, but not
  /// struck through.
  final bool over;

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
    final faint = task.done || over || (task.event?.hidden ?? false);
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
            // A web address in the title reads in its short form,
            // underlined. It is not what a click opens here: a click on a
            // row opens the task, wherever it lands (the row has a button
            // for the address).
            child: mayHaveLinks(task.title) && hasLinks(task.title)
                ? Text.rich(
                    TextSpan(
                      children: [
                        for (final piece
                            in tidyLinks(taskLabel(task, use24h: use24h, raw: true)))
                          TextSpan(
                            text: piece.text,
                            style: piece.isLink
                                ? TextStyle(
                                    decoration: TextDecoration.combine([
                                      TextDecoration.underline,
                                      if (task.done) TextDecoration.lineThrough,
                                    ]),
                                    decorationColor: onFill.withValues(alpha: onFill.a * 0.55),
                                  )
                                : null,
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: textStyle,
                  )
                : Text(
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

/// Shown in place of the circle on a task that the daily move of unfinished
/// tasks brought to today. Often such a task was done on its day and only
/// left unticked. Green: it was; it goes back to where it stood, ticked.
/// Red: it is still to do; it stays here, with the usual circle.
class MovedAnswer extends StatelessWidget {
  const MovedAnswer({super.key, required this.task, this.size = 22});

  final Task task;
  final double size;

  static const yes = Color(0xFF2FA36B);
  static const no = AppTheme.danger;

  @override
  Widget build(BuildContext context) {
    final from = task.rolledFrom;
    if (from == null) return const SizedBox.shrink();
    Widget button(IconData icon, Color color, String label, VoidCallback onTap) => Pressable(
          onTap: onTap,
          focusable: false,
          semanticLabel: label,
          builder: (context, hovered, pressed) => SizedBox(
            width: size + (isMobile ? 16 : 8),
            height: double.infinity,
            child: Center(
              child: Icon(
                icon,
                size: size - 1,
                color: color.withValues(alpha: hovered || pressed ? 0.65 : 1),
              ),
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          AppIcons.circleCheck,
          yes,
          'Done on ${Strings.dayMonth(from)}: put it back there, ticked',
          () => doneWhereItWas(context, task),
        ),
        button(
          AppIcons.circleX,
          no,
          'Still to do: keep it on today',
          () => context.readStore.stillToDo(task.id),
        ),
      ],
    );
  }
}

/// One task or one event on one ruled line.
///
/// A task has a circle to tick it off. An event has none; it is set apart
/// by a bar at the left (in its calendar's colour when it comes from one)
/// and turns faint once it is over. Everything else about the row is the
/// same: tap to open, drag (or long press and drag) to another day,
/// right-click (or long press and let go) for the menu.
class TaskRow extends StatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    required this.compact,
    required this.onOpen,
    this.slot,
  });

  final Task task;

  /// The day or list that shows this row. A list's task that has a day
  /// shows twice, on its day and in its list; what a drag or the menu does
  /// with it depends on which of the two rows is taken.
  final Slot? slot;

  /// Narrow layout: larger text and an always-visible check.
  final bool compact;
  final ValueChanged<Task> onOpen;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  bool _hovered = false;
  bool _focused = false;

  /// Runs out when an event of today ends: the row then turns faint.
  Timer? _overTimer;

  @override
  void initState() {
    super.initState();
    _watchOver();
  }

  @override
  void didUpdateWidget(TaskRow old) {
    super.didUpdateWidget(old);
    _watchOver();
  }

  @override
  void dispose() {
    _overTimer?.cancel();
    super.dispose();
  }

  void _watchOver() {
    _overTimer?.cancel();
    _overTimer = null;
    final task = widget.task;
    if (!task.happens || task.time == null) return;
    final store = context.readStore;
    final now = store.clock;
    if (task.date != store.today || task.overAt(now)) return;
    final until = task.end ?? task.time! + Task.assumedMinutes;
    _overTimer = Timer(
      Duration(minutes: until - (now.hour * 60 + now.minute), seconds: -now.second, milliseconds: 200),
      () {
        if (mounted) setState(_watchOver);
      },
    );
  }

  /// Opens the row's menu: at [at] for a click, by the row for the keyboard
  /// (the menu's first entry then takes the focus).
  void _menu([Offset? at]) => showTaskMenu(
        context,
        widget.task,
        anchor: at == null ? globalRect(context) : at & Size.zero,
        onOpen: widget.onOpen,
        keyboard: at == null,
        from: widget.slot,
      );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final task = widget.task;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      widget.onOpen(task);
    } else if (key == LogicalKeyboardKey.space) {
      // Only a task is ticked off.
      if (!task.checkable) return KeyEventResult.ignored;
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
    final showCheck =
        task.checkable && (widget.compact || ((_hovered || keyed) && !dragging));
    final style = widget.compact ? context.text.taskCompact : context.text.task14;
    final over = task.overAt(context.readStore.clock);
    final waits = task.waitsForWord;
    final faint = task.done || over || (source?.hidden ?? false);
    // What marks an event, or what a calendar brought: a bar in the
    // calendar's colour, or a plain one for an event made here.
    final bar = source != null
        ? calendarColor(theme, source.calendarColor)
        : task.happens
            ? theme.ink(55)
            : null;
    final muted = theme.ink(faint ? 25 : 50);
    final place = task.hasLocation ? shortPlace(task.location) : '';
    final small = context.text.tiny12
        .copyWith(fontSize: isMobile ? 13 : 11.5, height: 1.2, color: muted);
    final done = task.subtasks.where((s) => !s.heading && s.done).length;
    final total = task.subtasks.where((s) => !s.heading).length;

    // The first web address in the title, if it has one.
    final link = mayHaveLinks(task.title)
        ? linkify(task.title).where((p) => p.isLink).firstOrNull
        : null;

    // In a list: the day the task is planned for, if it has one.
    final inList = widget.slot is ListSlot;
    final today = context.readStore.today;
    final day = inList ? task.date : null;
    final due = task.due;

    final marks = <Widget>[
      if (day != null)
        Text(
          Strings.near(day, today),
          style: small.copyWith(
            color: day == today && !faint ? theme.accent : muted,
            fontWeight: FontWeight.w500,
          ),
        ),
      // A deadline: the date in a list, where there is room for it; in the
      // week a flag. Red once the day has passed.
      if (due != null)
        DueMark(due: due, today: today, done: faint, size: style.fontSize! - 2, dated: inList),
      // A title with an address in it: a button that opens the address.
      if (link != null)
        // A button of its own for a screen reader too, not part of what
        // the row says.
        Semantics(
          container: true,
          child: Pressable(
            onTap: () => context.readOpener.open(link.url!),
            focusable: false,
            semanticLabel: 'Open ${shortLink(link.url!)}',
            builder: (context, hovered, pressed) => SizedBox(
              width: isMobile ? 32 : 20,
              height: isMobile ? 40 : 24,
              child: Icon(
                AppIcons.externalLink,
                size: style.fontSize! - 1,
                color: hovered || pressed ? theme.text : muted,
              ),
            ),
          ),
        ),
      // A task's note is marked. An event's is not: what a calendar brings
      // nearly always says something about itself, and a mark on every such
      // row tells nothing.
      if (task.hasNote && !task.happens && !task.fromCalendar)
        Icon(AppIcons.text, size: style.fontSize! - 2, color: muted),
      if (total > 0) Text('$done/$total', style: small),
      if (source?.hidden ?? false)
        Icon(AppIcons.eyeOff, size: style.fontSize! - 2, color: muted),
    ];

    final content = Row(
      children: [
        if (bar != null) ...[
          Container(
            width: 3,
            height: place.isEmpty ? Dim.pill - 6 : Dim.row - 16,
            decoration: BoxDecoration(
              color: bar.withValues(alpha: bar.a * (faint ? 0.3 : 1)),
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
                        over: over,
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
          DragScope.read(context).pointerDown(
              task, event.position, globalRect(context),
              from: widget.slot);
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Semantics(
            label: task.happens ? 'Event' : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onOpen(task),
              onSecondaryTapUp: (details) => _menu(details.globalPosition),
              child: _TouchPickUp(
                onPickUp: (position) => DragScope.read(context)
                    .begin(task, position, globalRect(context), from: widget.slot),
                child: SizedBox(
                  height: Dim.row,
                  child: Stack(
                    children: [
                      // An event has no circle and uses the room; a task
                      // moved to today unfinished has two buttons there.
                      Positioned.fill(
                        right: waits
                            ? (isMobile ? 80 : 64)
                            : task.checkable
                                ? 35
                                : 6,
                        child: content,
                      ),
                      if (waits)
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: MovedAnswer(task: task),
                        )
                      else if (task.checkable)
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

/// A task's deadline as a small mark: a flag, with the date when [dated].
/// Red once the day has passed and the task is not done; in the text colour
/// on the day itself.
class DueMark extends StatelessWidget {
  const DueMark({
    super.key,
    required this.due,
    required this.today,
    required this.done,
    required this.size,
    this.dated = true,
  });

  final Day due;
  final Day today;
  final bool done;
  final double size;
  final bool dated;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final color = done
        ? theme.ink(25)
        : due < today
            ? AppTheme.danger
            : due == today
                ? theme.text
                : theme.ink(50);
    final label = 'Due ${Strings.near(due, today).toLowerCase()}';
    return Semantics(
      container: true,
      label: due < today && !done ? '$label, passed' : label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.flag, size: size, color: color),
          if (dated) ...[
            const SizedBox(width: 2),
            Text(
              Strings.near(due, today),
              style: context.text.tiny12.copyWith(
                fontSize: isMobile ? 13 : 11.5,
                height: 1.2,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
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
        // The whole row, not only where its text is: a press beside a short
        // title picks the task up as well.
        behavior: HitTestBehavior.opaque,
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
    this.tasksOnly = false,
    this.hint,
  });

  /// Called with the typed text; returns the id of the task made of it.
  /// The row then clears and stays focused so several tasks can be entered
  /// in a row.
  final String? Function(String text) onSubmit;
  final bool compact;
  final FocusNode? focusNode;

  /// The line of a list: what is typed there is a task, never an event.
  final bool tasksOnly;

  /// Shown faintly while the line is empty.
  final String? hint;

  @override
  State<AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<AddRow> {
  final _controller = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _hovered = false;

  /// What goes with the item being typed besides its text: on a phone the
  /// editing bar fills it in (a time, a place and more); everywhere it says
  /// whether a task or an event is being made, once that was switched.
  Composer? _composer;

  /// The same switch where there is no composer around the line.
  ItemKind? _kind;

  /// A task or an event: what was switched to, else what the settings say.
  ItemKind get _making =>
      _composer?.kind ?? _kind ?? context.readStore.newItemKind;

  void _switchKind() {
    final next = _making == ItemKind.event ? ItemKind.task : ItemKind.event;
    setState(() {
      final composer = _composer;
      composer != null ? composer.setKind(next) : _kind = next;
    });
  }

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
      composer?.attach(_focus, _commit, tasksOnly: widget.tasksOnly);
    } else if (composer == null || !composer.holds(_focus)) {
      // Clicking away keeps what was typed, as a task.
      _commit();
      _kind = null;
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
    } else if (id != null && !widget.tasksOnly) {
      if (_kind case final kind?) context.readStore.setKind(id, kind);
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final focused = _focus.hasFocus || (_composer?.holds(_focus) ?? false);
    final style = widget.compact ? context.text.taskCompact : context.text.task14;
    // On a desktop the line itself says, and switches, whether a task or an
    // event is being typed; on a phone the bar above the keyboard does.
    final ownSwitch = !isMobile && focused && !widget.tasksOnly;
    final asEvent = ownSwitch && _making == ItemKind.event;
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
            if (asEvent)
              // As an event's row has it.
              Positioned(
                key: const ValueKey('bar'),
                left: 0,
                top: (Dim.row - (Dim.pill - 6)) / 2,
                width: 3,
                height: Dim.pill - 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.ink(55),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
            if (ownSwitch)
              Positioned(
                key: const ValueKey('kind'),
                right: 0,
                top: 0,
                bottom: 0,
                // A click on it is part of typing: the line keeps the keyboard.
                child: TextFieldTapRegion(
                  child: Pressable(
                    onTap: _switchKind,
                    focusable: false,
                    semanticLabel: asEvent
                        ? 'An event; switch to a task (Ctrl+E)'
                        : 'A task; switch to an event (Ctrl+E)',
                    builder: (context, hovered, pressed) => SizedBox(
                      width: 30,
                      child: Icon(
                        asEvent ? AppIcons.calendarClock : AppIcons.circleCheck,
                        size: 18,
                        color: theme.ink(hovered ? 75 : (asEvent ? 60 : 30)),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              key: const ValueKey('field'),
              child: Padding(
                padding: EdgeInsets.only(left: 6, right: ownSwitch ? 32 : 6),
                child: Center(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): () {
                        _controller.clear();
                        _focus.unfocus();
                      },
                      if (!isMobile && !widget.tasksOnly)
                        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
                            _switchKind,
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      style: style,
                      cursorColor: theme.text,
                      cursorWidth: 1.5,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration.collapsed(
                        hintText: widget.hint ?? '',
                        hintStyle: style.copyWith(color: theme.ink(25)),
                      ),
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
    this.addHint,
  });

  /// Shown faintly on the empty line new tasks are typed on.
  final String? addHint;

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

  /// What of the drag this list shows: whether the dragged task is one of
  /// its own (and so missing from it), and where its gap is (−1: none). A
  /// drag that neither took a task from this list nor points at it changes
  /// nothing here.
  (bool, int)? _shown;

  /// Whether the gaps of this list exist yet at their resting height, so
  /// that the one under the pointer can open with a movement.
  bool _gapsReady = false;

  (bool, int) _view(DragController drag) {
    final dragged = drag.task;
    if (dragged == null) return (false, -1);
    final target = drag.targetSlot == widget.slot;
    return (
      widget.tasks.any((t) => t.id == dragged.id),
      !target ? -1 : drag.targetIndex,
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
    final shown = view.$1
        ? [
            for (final t in widget.tasks)
              if (t.id != draggedId) t,
          ]
        : widget.tasks;
    drag.register(widget.slot, _zoneKey, shown.length);
    // Gaps exist only in the list the dragged task is over: a week has
    // hundreds of places a gap could open, and making them all the moment a
    // task is picked up cost a long frame.
    final target = view.$2 >= 0;
    if (!target) {
      _gapsReady = false;
    } else if (!_gapsReady) {
      if (view.$1) {
        // Picked up from this very list: the gap takes the lifted row's
        // place at once.
        _gapsReady = true;
      } else {
        // Just arrived over this list: first the gaps closed, then (next
        // frame) the one under the pointer opens with a movement.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_gapsReady) setState(() => _gapsReady = true);
        });
      }
    }
    final gapAt = target && _gapsReady ? view.$2.clamp(0, shown.length) : -1;

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
                    if (target) gap(i),
                    TaskRow(
                      key: ValueKey(shown[i].id),
                      task: shown[i],
                      compact: widget.compact,
                      onOpen: widget.onOpen,
                      slot: widget.slot,
                    ),
                  ],
                  if (target) gap(shown.length),
                  AddRow(
                    compact: widget.compact,
                    focusNode: _addFocus,
                    tasksOnly: widget.slot is ListSlot,
                    hint: widget.addHint,
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

/// How many rows a body needs right now: its tasks (minus one being dragged
/// away), a gap if it is the drop target, and the add row.
int rowsNeeded(DragController drag, Slot slot, List<Task> tasks, int minimum) {
  var count = tasks.length;
  if (drag.active) {
    if (tasks.any((t) => t.id == drag.task!.id)) count--;
    if (drag.targetSlot == slot) count++;
  }
  return TaskListBody.rowsFor(count, minimum);
}

/// Gives one day or list that stands alone its number of rows, and builds
/// it again only when that number changes.
///
/// While a task is dragged, the day it is over grows by a row and the day
/// it left shrinks by one. In the wide week all columns share a height, so
/// the grid works that out as a whole; where each day or list stands alone,
/// a task crossing from one to the next concerns those two only.
class LocalRows extends StatefulWidget {
  const LocalRows({
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
  State<LocalRows> createState() => _LocalRowsState();
}

class _LocalRowsState extends State<LocalRows> {
  DragController? _drag;
  int _rows = 0;

  int _needed() => rowsNeeded(_drag!, widget.slot, widget.tasks, widget.minimum);

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
  void didUpdateWidget(LocalRows old) {
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

/// Ruled lines with nothing on them: the body of a column that holds no
/// list or day yet.
class BlankRows extends StatelessWidget {
  const BlankRows({super.key, required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: rows * Dim.row,
        child: CustomPaint(painter: _RulePainter(context.theme.rule)),
      );
}

/// Whether [listEquals] holds for two task lists by identity of their
/// entries: the same tasks in the same order, unchanged.
bool sameTasks(List<Task> a, List<Task> b) => listEquals(a, b);
