import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'location_field.dart';
import 'note_field.dart';
import 'pickers.dart';
import 'strings.dart';
import 'task_actions.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// A part of the task card to start typing in when it opens.
enum TaskField { note, place }

/// Opens the card for the task, or the imported event, with [id]. With
/// [focus], typing starts in that field.
Future<void> showTaskDialog(BuildContext context, String id, {TaskField? focus}) {
  final theme = context.theme;
  return Navigator.of(context, rootNavigator: true).push<void>(
    _CardRoute(
      barrier: theme.barrier,
      builder: (context) => _TaskDialog(id: id, focus: focus),
    ),
  );
}

/// A dimmed backdrop with a card that fades and rises into place.
class _CardRoute extends PopupRoute<void> {
  _CardRoute({required this.barrier, required this.builder});

  final Color barrier;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => barrier;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => Dim.medium;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.ease);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.02), end: Offset.zero)
            .animate(curved),
        // What a card says (details, descriptions, explanations) can be
        // selected; its buttons take themselves out of that.
        child: DialogArea(
          child: Selectable(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The backdrop: a click or tap beside the card closes it.
                // The layer that selects text spans the whole page and
                // would otherwise keep that click for itself, leaving the
                // route's own barrier underneath without it.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                Builder(builder: builder),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows a card route with the standard backdrop (used by other dialogs).
Future<void> showCard(BuildContext context, WidgetBuilder builder) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    _CardRoute(barrier: context.theme.barrier, builder: builder),
  );
}

class _TaskDialog extends StatefulWidget {
  const _TaskDialog({required this.id, this.focus});

  final String id;
  final TaskField? focus;

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late String _id = widget.id;
  bool _expanded = false;

  final _title = TextEditingController();
  final _note = LinkTextController();
  final _titleFocus = FocusNode();
  final _noteFocus = FocusNode();
  final _placeFocus = FocusNode();

  /// Whether the place is being typed: shown as a field (with suggestions)
  /// rather than as the link it is otherwise. Also true while a place is
  /// being added to a task that has none yet.
  bool _editingPlace = false;

  @override
  void initState() {
    super.initState();
    _noteFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _placeFocus.addListener(() {
      // Done typing: the place becomes a link to the map again.
      if (!_placeFocus.hasFocus && _editingPlace && mounted) {
        setState(() => _editingPlace = false);
      }
    });
  }

  void _editPlace() {
    setState(() => _editingPlace = true);
    _placeFocus.requestFocus();
  }
  final _subtaskText = <String, TextEditingController>{};
  final _subtaskFocus = <String, FocusNode>{};
  Timer? _saveTimer;
  bool _loaded = false;
  late PlannerStore _store;
  final _rng = Random();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = context.readStore;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Typing is saved when the card starts to close (see build). Should the
    // card be taken away some other way, what is left is saved once the
    // widgets are done being taken down: the planner may not change while
    // they are.
    final save = _pendingSave();
    if (save != null) scheduleMicrotask(save);
    _title.dispose();
    _note.dispose();
    _titleFocus.dispose();
    _noteFocus.dispose();
    _placeFocus.dispose();
    for (final c in _subtaskText.values) {
      c.dispose();
    }
    for (final f in _subtaskFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------- saving

  /// Saves typed text shortly after the last keystroke rather than on each
  /// one, so the change log holds edits, not letters.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _flush);
  }

  void _flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _pendingSave()?.call();
  }

  /// What typing has changed and is not saved yet, as the step that saves
  /// it; null when there is nothing.
  VoidCallback? _pendingSave() {
    final store = _store;
    final id = _id;
    final task = store.task(id);
    if (task == null) return null;
    final title = _title.text.trim();
    final subtasks = [
      for (final s in task.subtasks)
        s.copyWith(text: _subtaskText[s.id]?.text ?? s.text),
    ];
    final subtasksChanged = [
      for (var i = 0; i < subtasks.length; i++)
        subtasks[i].text != task.subtasks[i].text,
    ].contains(true);
    // An emptied title keeps the previous one: a task needs some text.
    final newTitle = title.isNotEmpty && title != task.title ? title : null;
    final newNote = _note.text != task.note ? _note.text : null;
    if (newTitle == null && newNote == null && !subtasksChanged) return null;
    return () => store.updateTask(
          id,
          title: newTitle,
          note: newNote,
          subtasks: subtasksChanged ? subtasks : null,
        );
  }

  /// Runs a structural edit after saving pending text, and follows the task
  /// if the edit gave it a new id.
  void _apply(String Function() edit) {
    _flush();
    final id = edit();
    if (mounted && id != _id) setState(() => _id = id);
  }

  // ------------------------------------------------------------ popovers

  Future<void> _pickDate(BuildContext anchor, Task task) async {
    final picked = await showPopover<Day>(
      context: context,
      anchor: globalRect(anchor),
      align: -1,
      builder: (popover) => PopoverSurface(
        child: MonthPicker(
          selected: task.date,
          onPick: (day) => Navigator.of(popover).pop(day),
        ),
      ),
    );
    if (picked != null && picked != task.date) {
      _apply(() => _store.moveTask(_id, DaySlot(picked)));
    }
  }

  Future<void> _pickTime(BuildContext anchor, Task task) async {
    var chose = false;
    int? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      builder: (popover) => PopoverSurface(
        child: TimePicker(
          selected: task.time,
          onPick: (minutes) {
            chose = true;
            picked = minutes;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose) {
      _apply(() {
        _store.updateTask(_id, time: () => picked);
        return _id;
      });
    }
  }

  Future<void> _pickEnd(BuildContext anchor, Task task) async {
    final start = task.time;
    if (start == null) return;
    var chose = false;
    int? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      builder: (popover) => PopoverSurface(
        child: TimePicker(
          selected: task.end,
          after: start,
          onPick: (minutes) {
            chose = true;
            picked = minutes;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose) {
      _apply(() {
        _store.updateTask(_id, end: () => picked);
        return _id;
      });
    }
  }

  Future<void> _pickColor(BuildContext anchor, Task task) async {
    var chose = false;
    String? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      side: PopoverSide.above,
      builder: (popover) => PopoverSurface(
        child: ColorPalette(
          selected: task.color,
          onPick: (color) {
            chose = true;
            picked = color;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose) {
      _apply(() {
        _store.updateTask(_id, color: () => picked);
        return _id;
      });
    }
  }

  Future<void> _pickRepeat(BuildContext anchor, Task task) async {
    final date = task.date;
    if (date == null) return;
    final rect = globalRect(anchor);
    var custom = false;
    var chose = false;
    var rule = task.recurrence;
    await showPopover<void>(
      context: context,
      anchor: rect,
      side: PopoverSide.above,
      builder: (popover) => PopoverSurface(
        child: RepeatMenu(
          current: task.recurrence,
          anchor: date,
          onPick: (picked) {
            chose = true;
            rule = picked;
            Navigator.of(popover).pop();
          },
          onCustom: () {
            custom = true;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (custom && mounted) {
      await showPopover<void>(
        context: context,
        anchor: rect,
        side: PopoverSide.above,
        builder: (popover) => PopoverSurface(
          child: CustomRepeat(
            initial: task.recurrence,
            anchor: date,
            onApply: (picked) {
              chose = true;
              rule = picked;
              Navigator.of(popover).pop();
            },
          ),
        ),
      );
    }
    if (chose && rule != task.recurrence) {
      _apply(() => _store.setRecurrence(_id, rule));
    }
  }

  Future<void> _pickReminder(BuildContext anchor, Task task) async {
    final day = task.date ?? _store.today;
    final suggested = task.time != null
        ? DateTime(day.year, day.month, day.day, task.time! ~/ 60, task.time! % 60)
        : DateTime(day.year, day.month, day.day, 9);
    var chose = false;
    DateTime? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      side: PopoverSide.above,
      builder: (popover) => PopoverSurface(
        child: ReminderPicker(
          initial: task.reminder,
          suggested: suggested,
          onSet: (moment) {
            chose = true;
            picked = moment;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose) {
      _apply(() {
        _store.updateTask(_id, reminder: () => picked);
        return _id;
      });
    }
  }

  void _more(BuildContext anchor, Task task) {
    final rect = globalRect(anchor);
    final source = task.event;
    showPopover<void>(
      context: context,
      anchor: rect,
      side: PopoverSide.above,
      align: 1,
      builder: (popover) {
        void close() => Navigator.of(popover).pop();
        Widget chevron() =>
            Icon(AppIcons.chevronRight, size: 16, color: context.theme.ink(60));
        return PopoverSurface(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 248,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MenuRow(
                  icon: AppIcons.arrowRight,
                  label: 'Move',
                  trailing: chevron(),
                  onTap: () {
                    close();
                    _targets(rect, task, copy: false);
                  },
                ),
                if (source == null)
                  MenuRow(
                    icon: AppIcons.copy,
                    label: 'Copy',
                    trailing: chevron(),
                    onTap: () {
                      close();
                      _targets(rect, task, copy: true);
                    },
                  ),
                // A task is ticked off, an event is not: either can be made
                // the other.
                MenuRow(
                  icon: task.checkable ? AppIcons.calendarClock : AppIcons.circleCheck,
                  label: task.checkable ? 'Turn into an event' : 'Turn into a task',
                  onTap: () {
                    close();
                    _flush();
                    _store.setKind(_id, task.checkable ? ItemKind.event : ItemKind.task);
                  },
                ),
                if (source != null) ...[
                  if (source.edited)
                    MenuRow(
                      icon: AppIcons.rotateCcw,
                      label: 'Reset to the calendar\'s version',
                      onTap: () {
                        close();
                        _reset();
                      },
                    ),
                  if (source.hidden)
                    MenuRow(
                      icon: AppIcons.eye,
                      label: 'Show again',
                      onTap: () {
                        close();
                        _store.setEventHidden(_id, false);
                      },
                    )
                  else
                    MenuRow(
                      icon: AppIcons.eyeOff,
                      label: 'Hide',
                      onTap: () {
                        close();
                        _leave(() => hideWithUndo(context, task));
                      },
                    ),
                  MenuRow(
                    icon: AppIcons.calendarOff,
                    label: 'Hide ${source.calendarName}',
                    onTap: () {
                      close();
                      _leave(() => hideCalendarWithUndo(context, source.calendar));
                    },
                  ),
                ] else if (task.isOccurrence) ...[
                  MenuRow(
                    icon: AppIcons.trash2,
                    label: 'Delete this one',
                    danger: true,
                    onTap: () {
                      close();
                      _leave(() => deleteWithUndo(context, task));
                    },
                  ),
                  MenuRow(
                    icon: AppIcons.trash2,
                    label: 'Delete all repeats',
                    danger: true,
                    onTap: () {
                      close();
                      _leave(() => deleteWithUndo(context, task, wholeSeries: true));
                    },
                  ),
                ] else
                  MenuRow(
                    icon: AppIcons.trash2,
                    label: 'Delete',
                    danger: true,
                    onTap: () {
                      close();
                      _leave(() => deleteWithUndo(context, task, wholeSeries: true));
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Saves what is being typed, does [action] (which removes the task from
  /// view), and closes the card.
  void _leave(VoidCallback action) {
    _flush();
    action();
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Drops everything changed about an imported event.
  void _reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _store.resetEvent(_id);
    final fresh = _store.task(_id);
    if (fresh != null) {
      _title.text = fresh.title;
      _note.text = fresh.note;
    }
  }

  void _targets(Rect rect, Task task, {required bool copy}) {
    final targets = moveTargets(_store);
    showPopover<void>(
      context: context,
      anchor: rect,
      side: PopoverSide.above,
      align: 1,
      builder: (popover) => PopoverSurface(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 232,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, slot) in targets)
                MenuRow(
                  icon: slot is DaySlot ? AppIcons.calendar : AppIcons.list,
                  label: label,
                  onTap: () {
                    Navigator.of(popover).pop();
                    if (copy) {
                      _flush();
                      _store.copyTask(_id, slot);
                    } else if (task.fromCalendar && slot is ListSlot) {
                      // Nothing of a calendar can be in a list: a copy of
                      // it goes there.
                      _leave(() => copyIntoPlanner(context, task, slot: slot));
                    } else {
                      _apply(() => _store.moveTask(_id, slot));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ subtasks

  String _newSubtaskId() =>
      List.generate(8, (_) => _rng.nextInt(36).toRadixString(36)).join();

  // Subtask edits first save any text still being typed and then work on
  // the stored list, so a structural change never overwrites fresh text.

  void _addSubtask({int? after}) {
    _flush();
    final task = _store.task(_id);
    if (task == null) return;
    final id = _newSubtaskId();
    final index = after == null || after >= task.subtasks.length
        ? task.subtasks.length
        : after + 1;
    final indent = index > 0 ? task.subtasks[index - 1].indent : 0;
    _store.updateTask(
      _id,
      subtasks: [...task.subtasks]..insert(index, Subtask(id: id, indent: indent)),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subtaskFocus[id]?.requestFocus();
    });
  }

  void _removeSubtask(String subtaskId) {
    _flush();
    final task = _store.task(_id);
    if (task == null) return;
    final index = task.subtasks.indexWhere((s) => s.id == subtaskId);
    if (index < 0) return;
    final focusPrevious = index > 0 ? task.subtasks[index - 1].id : null;
    _store.updateTask(_id, subtasks: [...task.subtasks]..removeAt(index));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subtaskText.remove(subtaskId)?.dispose();
      _subtaskFocus.remove(subtaskId)?.dispose();
      if (focusPrevious != null) _subtaskFocus[focusPrevious]?.requestFocus();
    });
  }

  void _changeSubtask(Task task, int index, Subtask Function(Subtask) change) {
    _flush();
    final current = _store.task(_id) ?? task;
    final next = [...current.subtasks];
    if (index >= next.length) return;
    next[index] = change(next[index]);
    _store.updateTask(_id, subtasks: next);
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final task = store.task(_id);
    if (task == null) {
      // Deleted elsewhere (or by this dialog): close.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    if (!_loaded) {
      _title.text = task.title;
      _note.text = task.note;
      _loaded = true;
      final focus = widget.focus;
      if (focus != null) {
        _editingPlace = focus == TaskField.place;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          (focus == TaskField.note ? _noteFocus : _placeFocus).requestFocus();
        });
      }
    } else {
      // Pick up changes made elsewhere, but never under the cursor.
      if (!_titleFocus.hasFocus && _saveTimer == null && _title.text != task.title) {
        _title.text = task.title;
      }
      if (!_noteFocus.hasFocus && _saveTimer == null && _note.text != task.note) {
        _note.text = task.note;
      }
    }
    for (final s in task.subtasks) {
      _subtaskText.putIfAbsent(s.id, () => TextEditingController(text: s.text));
      _subtaskFocus.putIfAbsent(s.id, FocusNode.new);
    }

    final base = context.theme;
    final color = TaskColor.resolve(task.color);
    final theme = color == null
        ? base
        : color.key == 'black'
            ? base.onSurface(base.text, base.background)
            : base.onSurface(color.fill, color.onFill);
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < Dim.breakpoint;

    final card = ThemeScope(
      theme: theme,
      child: Builder(builder: (context) => _card(context, task, narrow)),
    );

    final Widget placed;
    if (narrow) {
      placed = Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: size.height * (_expanded ? 1 : 0.88),
            minHeight: _expanded ? size.height : 0,
          ),
          // The sheet's surface continues under the navigation bar; its
          // content stops above it.
          child: _surface(
            theme,
            Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom),
              child: card,
            ),
            radius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
      );
    } else if (_expanded) {
      placed = Padding(
        padding: const EdgeInsets.fromLTRB(24, Dim.dialogTop, 24, 24),
        child: _surface(theme, card),
      );
    } else {
      placed = Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: size.height > 640 ? Dim.dialogTop : 24,
            bottom: 24,
          ),
          child: SizedBox(
            width: Dim.dialogWidth,
            child: _surface(theme, card),
          ),
        ),
      );
    }
    return PopScope(
      // Closing saves what was being typed, at once: the week behind the
      // card shows it while the card fades.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flush();
      },
      child: EscapeToClose(child: placed),
    );
  }

  Widget _surface(AppTheme theme, Widget child, {BorderRadius? radius}) =>
      AnimatedContainer(
        duration: Dim.medium,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: theme.dialog,
          borderRadius: radius ?? BorderRadius.circular(Dim.dialogRadius),
        ),
        child: child,
      );

  Widget _card(BuildContext context, Task task, bool narrow) {
    final theme = context.theme;
    final size = MediaQuery.sizeOf(context);
    final use24h = context.store.setting<bool>(Settings.use24h);
    final date = task.date;
    final list = task.listId == null ? null : context.store.list(task.listId!);
    final source = task.event;
    final where = date != null
        ? (task.spansDays
            ? '${Strings.fullDate(date)} – ${Strings.fullDate(source!.lastDay)}'
            : Strings.fullDate(date))
        : (list == null ? 'Someday' : listTitle(context.store, list));
    final side = narrow ? 24.0 : 32.0;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));

    // Which calendar it is from, for what a calendar brought.
    final Widget? origin = source == null
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: calendarColor(theme, source.calendarColor),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      [
                        source.calendarName,
                        if (source.repeats) 'repeats',
                        if (source.hidden) 'hidden',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.small15.copyWith(color: theme.ink(60)),
                    ),
                  ),
                  if (source.edited)
                    Pressable(
                      onTap: _reset,
                      semanticLabel: 'Reset to the calendar\'s version',
                      builder: (context, hovered, pressed) => Padding(
                        padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6),
                        child: Text(
                          'Edited · Reset',
                          style: muted.copyWith(
                            color: theme.ink(hovered ? 90 : 60),
                            decoration: TextDecoration.underline,
                            decorationColor: theme.ink(30),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );

    // Along the top: the day, the time from start to end, and the calendar.
    // What does not fit beside the rest goes on a line of its own.
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Builder(
                builder: (anchor) => _HeaderButton(
                  icon: AppIcons.calendar,
                  label: where,
                  onTap: () => _pickDate(anchor, task),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (anchor) => _HeaderButton(
                      icon: AppIcons.clock,
                      label: task.time == null
                          ? null
                          : formatTime(task.time!, use24h: use24h),
                      muted: task.time == null,
                      tooltip: 'Time',
                      // The end follows closely.
                      close: task.time != null,
                      onTap: () => _pickTime(anchor, task),
                    ),
                  ),
                  // With a start there can be an end.
                  if (task.time != null)
                    Builder(
                      builder: (anchor) => _HeaderButton(
                        label: task.end == null
                            ? '– end'
                            : '– ${formatTime(task.end!, use24h: use24h)}',
                        muted: task.end == null,
                        tooltip: task.end == null ? 'Add an end time' : 'End time',
                        tight: true,
                        onTap: () => _pickEnd(anchor, task),
                      ),
                    ),
                ],
              ),
              ?origin,
            ],
          ),
        ),
        _HeaderButton(
          icon: _expanded ? AppIcons.minimize2 : AppIcons.maximize2,
          // The word only where there is room for it.
          label: narrow && size.width < 480 ? null : (_expanded ? 'Compact' : 'Expand'),
          tooltip: _expanded ? 'Compact' : 'Expand',
          muted: true,
          onTap: () => setState(() => _expanded = !_expanded),
        ),
      ],
    );

    final title = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _title,
            focusNode: _titleFocus,
            style: context.text.title28.copyWith(
              decoration: task.done ? TextDecoration.lineThrough : null,
              color: task.done ? theme.ink(40) : theme.text,
            ),
            cursorColor: theme.text,
            maxLines: null,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration.collapsed(
              hintText: task.checkable ? 'Task' : 'Event',
              hintStyle: context.text.title28.copyWith(color: theme.ink(25)),
            ),
            onChanged: (_) => _scheduleSave(),
            onSubmitted: (_) => _noteFocus.requestFocus(),
          ),
        ),
        // A task has the circle to tick it off; an event has none. A task
        // moved to today unfinished is first asked whether it was done.
        if (task.waitsForWord) ...[
          const SizedBox(width: 8),
          SizedBox(height: 34, child: MovedAnswer(task: task, size: 24)),
        ] else if (task.checkable) ...[
          const SizedBox(width: 8),
          SizedBox(
            height: 34,
            child: CheckToggle(
              done: task.done,
              size: 24,
              color: theme.text,
              onTap: () => _apply(() => _store.setDone(_id, !task.done)),
            ),
          ),
        ],
      ],
    );

    final notes = NoteField(
      controller: _note,
      focusNode: _noteFocus,
      style: context.text.body17,
      // A note takes the room it needs, with the place right under it; an
      // empty one, or one being typed in, has a few lines to write on. For
      // what a calendar brought, the note is the calendar's description
      // until it is edited here.
      minLines: _expanded ? 8 : (task.hasNote && !_noteFocus.hasFocus ? 1 : 3),
      hint: 'Add some extra notes here…',
      onChanged: _scheduleSave,
    );

    // Where it takes place. While it is typed: a field with suggestions.
    // Otherwise the place is a link: a click opens it in the map program,
    // the pencil beside it changes it.
    final Widget? place;
    if (_editingPlace) {
      place = Padding(
        padding: const EdgeInsets.only(top: 14),
        child: LocationField(
          location: task.location,
          geo: task.geo,
          focusNode: _placeFocus,
          autofocus: true,
          onChanged: (location, geo) =>
              _store.updateTask(_id, location: location, geo: () => geo),
          onDone: () => _placeFocus.unfocus(),
        ),
      );
    } else if (task.hasLocation) {
      place = Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 8),
              child: Icon(AppIcons.mapPin, size: 16, color: theme.ink(60)),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Pressable(
                  onTap: () => context.readOpener
                      .openMap(label: task.location, geo: task.geo),
                  semanticLabel: 'Open ${task.location} in the map app',
                  labelOnly: true,
                  builder: (context, hovered, pressed) => Text(
                    task.location,
                    style: context.text.body17.copyWith(
                      color: hovered ? theme.ink(75) : theme.text,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.ink(40),
                    ),
                  ),
                ),
              ),
            ),
            AppButton(
              icon: AppIcons.pencil,
              kind: ButtonKind.ghost,
              size: Dim.controlSmall,
              iconSize: 15,
              tooltip: 'Change the place',
              foreground: theme.ink(40),
              onTap: _editPlace,
            ),
          ],
        ),
      );
    } else {
      place = null;
    }

    final subtasks = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < task.subtasks.length; i++)
          _SubtaskRow(
            key: ValueKey(task.subtasks[i].id),
            subtask: task.subtasks[i],
            controller: _subtaskText[task.subtasks[i].id]!,
            focusNode: _subtaskFocus[task.subtasks[i].id]!,
            onChanged: _scheduleSave,
            onToggle: () => _changeSubtask(task, i, (s) => s.copyWith(done: !s.done)),
            onStar: () =>
                _changeSubtask(task, i, (s) => s.copyWith(important: !s.important)),
            onHeading: () =>
                _changeSubtask(task, i, (s) => s.copyWith(heading: !s.heading, done: false)),
            onIndent: (delta) => _changeSubtask(
                task, i, (s) => s.copyWith(indent: (s.indent + delta).clamp(0, 1))),
            onEnter: () => _addSubtask(after: i),
            onRemove: () => _removeSubtask(task.subtasks[i].id),
          ),
      ],
    );

    final footer = SizedBox(
      height: 44,
      child: Row(
        mainAxisAlignment: _expanded
            ? MainAxisAlignment.center
            : MainAxisAlignment.spaceBetween,
        spacing: _expanded ? 24 : 0,
        children: [
          AppButton(
            icon: AppIcons.listTodo,
            kind: ButtonKind.ghost,
            size: Dim.controlLarge,
            tooltip: 'Add subtask',
            foreground: task.hasSubtasks ? theme.text : theme.ink(40),
            onTap: _addSubtask,
          ),
          Builder(
            builder: (anchor) => AppButton(
              icon: AppIcons.rotateCw,
              kind: ButtonKind.ghost,
              size: Dim.controlLarge,
              tooltip: source != null
                  ? 'How an event repeats is set in its calendar'
                  : date == null
                      ? 'Only dated tasks can repeat'
                      : 'Repeat',
              foreground: task.repeats ? theme.text : theme.ink(40),
              onTap: date == null || source != null
                  ? null
                  : () => _pickRepeat(anchor, task),
            ),
          ),
          Builder(
            builder: (anchor) => AppButton(
              icon: AppIcons.droplet,
              kind: ButtonKind.ghost,
              size: Dim.controlLarge,
              tooltip: 'Colour',
              onTap: () => _pickColor(anchor, task),
            ),
          ),
          AppButton(
            icon: AppIcons.mapPin,
            kind: ButtonKind.ghost,
            size: Dim.controlLarge,
            tooltip: task.hasLocation ? 'Place' : 'Add a place',
            foreground: task.hasLocation ? theme.text : theme.ink(40),
            // The place line appears under the notes, ready to type in.
            onTap: _editPlace,
          ),
          Builder(
            builder: (anchor) => AppButton(
              icon: task.reminder == null ? AppIcons.bell : AppIcons.bellRing,
              kind: ButtonKind.ghost,
              size: Dim.controlLarge,
              tooltip: 'Reminder',
              foreground: task.reminder != null ? theme.text : theme.ink(40),
              onTap: () => _pickReminder(anchor, task),
            ),
          ),
          Builder(
            builder: (anchor) => AppButton(
              icon: AppIcons.ellipsisVertical,
              kind: ButtonKind.ghost,
              size: Dim.controlLarge,
              tooltip: 'More',
              onTap: () => _more(anchor, task),
            ),
          ),
        ],
      ),
    );

    final details = <Widget>[
      if (task.rolledFrom case final from? when task.waitsForWord)
        _Detail(
          icon: AppIcons.history,
          text: 'Not ticked on ${Strings.fullDate(from)}, so moved to today. '
              'Green if it was done that day, red if it is still to do.',
        ),
      if (task.repeats && date != null)
        _Detail(
          icon: AppIcons.rotateCw,
          text: Strings.describe(
            task.recurrence!,
            // Describe the series by its first day, not this occurrence.
            (task.isOccurrence ? _store.task(task.occurrenceOf!)?.date : null) ??
                date,
          ),
        ),
      if (task.reminder != null)
        _Detail(
          icon: AppIcons.bell,
          text: 'Reminder ${Strings.fullDate(Day.fromDateTime(task.reminder!))}, '
              '${formatTime(task.reminder!.hour * 60 + task.reminder!.minute, use24h: use24h)}',
        ),
    ];

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        const SizedBox(height: 20),
        Container(height: 1, color: theme.ink(10)),
        const SizedBox(height: 24),
        notes,
        ?place,
        if (task.hasSubtasks) ...[
          const SizedBox(height: 12),
          subtasks,
        ],
        if (details.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...details,
        ],
        const SizedBox(height: 16),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(side - 12, 20, side - 12, 20),
      child: Column(
        mainAxisSize: _expanded ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 22),
          Flexible(
            fit: _expanded ? FlexFit.tight : FlexFit.loose,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _expanded
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 696),
                        child: body,
                      ),
                    )
                  : body,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: footer,
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    this.icon,
    required this.onTap,
    this.label,
    this.muted = false,
    this.tooltip,
    this.tight = false,
    this.close = false,
  });

  final IconData? icon;

  /// Follows another button closely, as its second half; [close] is for the
  /// first half.
  final bool tight;
  final bool close;
  final String? label;
  final bool muted;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      // What it is for and what it shows, said once.
      semanticLabel: tooltip == null || label == null ? (tooltip ?? label) : '$tooltip, $label',
      labelOnly: true,
      builder: (context, hovered, pressed) {
        final color = muted ? theme.ink(hovered ? 75 : 40) : theme.text;
        return Container(
          height: 44,
          padding: EdgeInsets.only(left: tight ? 0 : 12, right: close ? 6 : 12),
          child: Opacity(
            opacity: hovered && !muted ? 0.75 : 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                if (icon != null) Icon(icon, size: 16, color: color),
                if (label != null)
                  Text(label!,
                      style: context.text.small15.copyWith(color: color)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = context.theme.ink(60);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        spacing: 8,
        children: [
          Icon(icon, size: 14, color: color),
          Expanded(
            child: Text(text, style: context.text.caption14.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    super.key,
    required this.subtask,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onToggle,
    required this.onStar,
    required this.onHeading,
    required this.onIndent,
    required this.onEnter,
    required this.onRemove,
  });

  final Subtask subtask;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onChanged;
  final VoidCallback onToggle;
  final VoidCallback onStar;
  final VoidCallback onHeading;
  final ValueChanged<int> onIndent;
  final VoidCallback onEnter;
  final VoidCallback onRemove;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final s = widget.subtask;
    final style = s.heading
        ? context.text.bodyBold17
        : context.text.body17.copyWith(
            decoration: s.done ? TextDecoration.lineThrough : null,
            color: s.done ? theme.ink(40) : theme.text,
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: EdgeInsets.only(left: s.indent * 28.0, top: s.heading ? 8 : 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!s.heading)
              Pressable(
                onTap: widget.onToggle,
                semanticLabel: s.done ? 'Mark as not done' : 'Mark as done',
                builder: (context, hovered, pressed) => Padding(
                  padding: const EdgeInsets.fromLTRB(0, 9, 10, 9),
                  child: Icon(
                    s.done ? AppIcons.circleCheck : AppIcons.circle,
                    size: 20,
                    color: s.done ? theme.ink(40) : theme.text,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.tab): () =>
                        widget.onIndent(1),
                    const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
                        widget.onIndent(-1),
                  },
                  child: Focus(
                    // Backspace in an empty line removes the line; otherwise
                    // the key is left to the text field.
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.backspace &&
                          widget.controller.text.isEmpty) {
                        widget.onRemove();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    style: style,
                    cursorColor: theme.text,
                    maxLines: null,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration.collapsed(
                      hintText: s.heading ? 'Section' : 'Subtask',
                      hintStyle: style.copyWith(
                        color: theme.ink(25),
                        decoration: TextDecoration.none,
                      ),
                    ),
                    onChanged: (_) => widget.onChanged(),
                    onSubmitted: (_) => widget.onEnter(),
                  ),
                  ),
                ),
              ),
            ),
            if (_hovered || s.important || widget.focusNode.hasFocus) ...[
              if (_hovered || widget.focusNode.hasFocus)
                AppButton(
                  icon: AppIcons.heading,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 15,
                  tooltip: s.heading ? 'Make a subtask' : 'Make a section title',
                  foreground: s.heading ? theme.text : theme.ink(40),
                  onTap: widget.onHeading,
                ),
              if (!s.heading)
                AppButton(
                  icon: AppIcons.star,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 15,
                  tooltip: s.important ? 'Not important' : 'Important',
                  foreground: s.important ? theme.text : theme.ink(40),
                  onTap: widget.onStar,
                ),
              if (_hovered || widget.focusNode.hasFocus)
                AppButton(
                  icon: AppIcons.x,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 15,
                  tooltip: 'Remove',
                  foreground: theme.ink(40),
                  onTap: widget.onRemove,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
