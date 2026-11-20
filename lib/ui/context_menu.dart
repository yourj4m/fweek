import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'pickers.dart';
import 'strings.dart';
import 'task_actions.dart';
import 'task_dialog.dart';
import 'task_list.dart' show calendarColor, formatTime;
import 'widgets/controls.dart';

/// Opens the menu of things to do with [task] (a task or an imported
/// event) beside [anchor]: a point for a right-click, the row for a long
/// press or the menu key. With [keyboard], the first entry takes the focus
/// so that the arrow keys continue from there.
Future<void> showTaskMenu(
  BuildContext context,
  Task task, {
  required Rect anchor,
  ValueChanged<Task>? onOpen,
  bool keyboard = false,
}) {
  // The row that asked may be gone by the time an entry is chosen (the menu
  // outlives a rebuild), so everything is done through the app's root.
  final root = Navigator.of(context, rootNavigator: true).context;
  return showPopover<void>(
    context: context,
    anchor: anchor,
    align: -1,
    gap: 2,
    builder: (popover) => _TaskMenu(
      root: root,
      id: task.id,
      anchor: anchor,
      onOpen: onOpen,
      keyboard: keyboard,
    ),
  );
}

enum _Page { main, move, colour }

class _TaskMenu extends StatefulWidget {
  const _TaskMenu({
    required this.root,
    required this.id,
    required this.anchor,
    required this.onOpen,
    required this.keyboard,
  });

  final BuildContext root;
  final String id;
  final Rect anchor;
  final ValueChanged<Task>? onOpen;
  final bool keyboard;

  @override
  State<_TaskMenu> createState() => _TaskMenuState();
}

class _TaskMenuState extends State<_TaskMenu> {
  _Page _page = _Page.main;

  BuildContext get _root => widget.root;

  /// Closes the menu, then acts.
  void _run(VoidCallback action) {
    Navigator.of(context).pop();
    if (_root.mounted) action();
  }

  Future<void> _pickTime(Task task) async {
    var chose = false;
    int? picked;
    await showPopover<void>(
      context: _root,
      anchor: widget.anchor,
      align: -1,
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
    final root = _root;
    if (chose && root.mounted) {
      root.readStore.updateTask(task.id, time: () => picked);
    }
  }

  Future<void> _pickDay(Task task) async {
    final picked = await showPopover<Day>(
      context: _root,
      anchor: widget.anchor,
      align: -1,
      builder: (popover) => PopoverSurface(
        child: MonthPicker(
          selected: task.date,
          onPick: (day) => Navigator.of(popover).pop(day),
        ),
      ),
    );
    final root = _root;
    if (picked != null && picked != task.date && root.mounted) {
      root.readStore.moveTask(task.id, DaySlot(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.readStore;
    final theme = context.theme;
    final task = store.task(widget.id);
    if (task == null) return const SizedBox.shrink();
    final source = task.event;
    final use24h = store.setting<bool>(Settings.use24h);
    Widget chevron() => Icon(AppIcons.chevronRight, size: 16, color: theme.ink(60));
    Widget divider() => Container(
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          color: theme.ink(10),
        );

    final List<Widget> rows;
    switch (_page) {
      case _Page.colour:
        return PopoverSurface(
          child: ColorPalette(
            selected: task.color,
            onPick: (color) =>
                _run(() => _root.readStore.updateTask(task.id, color: () => color)),
          ),
        );
      case _Page.move:
        rows = [
          for (final (label, slot) in moveTargets(store, lists: true))
            MenuRow(
              icon: slot is DaySlot ? AppIcons.calendar : AppIcons.list,
              label: label,
              onTap: () => _run(() {
                if (source != null && slot is ListSlot) {
                  copyIntoPlanner(_root, task, slot: slot);
                } else {
                  _root.readStore.moveTask(task.id, slot);
                }
              }),
            ),
          MenuRow(
            icon: AppIcons.calendarSearch,
            label: 'Pick a day…',
            onTap: () => _run(() => _pickDay(task)),
          ),
        ];
      case _Page.main:
        rows = [
          MenuRow(
            icon: AppIcons.squarePen,
            label: 'Open',
            autofocus: widget.keyboard,
            hint: isMobile ? null : 'Enter',
            onTap: () => _run(() {
              final open = widget.onOpen;
              open != null ? open(task) : showTaskDialog(_root, task.id);
            }),
          ),
          // Moved to today unfinished: done on its day after all, or
          // still to do?
          if (task.rolledFrom case final from? when task.waitsForWord) ...[
            MenuRow(
              icon: AppIcons.circleCheck,
              label: 'Done on ${Strings.dayMonth(from)}',
              onTap: () => _run(() => doneWhereItWas(_root, task)),
            ),
            MenuRow(
              icon: AppIcons.circleX,
              label: 'Still to do',
              onTap: () => _run(() => _root.readStore.stillToDo(task.id)),
            ),
          ],
          if (task.checkable)
            MenuRow(
              icon: AppIcons.circleCheck,
              label: task.done ? 'Mark as not done' : 'Mark as done',
              hint: isMobile ? null : 'Space',
              onTap: () => _run(() => _root.readStore.setDone(task.id, !task.done)),
            ),
          // A task is ticked off, an event is not: either can be made the
          // other.
          MenuRow(
            icon: task.checkable ? AppIcons.calendarClock : AppIcons.circleCheck,
            label: task.checkable ? 'Turn into an event' : 'Turn into a task',
            onTap: () => _run(() => _root.readStore.setKind(
                task.id, task.checkable ? ItemKind.event : ItemKind.task)),
          ),
          divider(),
          MenuRow(
            icon: AppIcons.arrowRight,
            label: 'Move to',
            trailing: chevron(),
            onTap: () => setState(() => _page = _Page.move),
          ),
          MenuRow(
            icon: AppIcons.clock,
            label: 'Time',
            hint: task.time == null ? null : formatTime(task.time!, use24h: use24h),
            onTap: () => _run(() => _pickTime(task)),
          ),
          MenuRow(
            icon: AppIcons.droplet,
            label: 'Colour',
            trailing: chevron(),
            onTap: () => setState(() => _page = _Page.colour),
          ),
          MenuRow(
            icon: AppIcons.text,
            label: task.hasNote ? 'Edit note' : 'Add a note',
            onTap: () =>
                _run(() => showTaskDialog(_root, task.id, focus: TaskField.note)),
          ),
          MenuRow(
            icon: AppIcons.mapPin,
            label: task.hasLocation ? 'Change place' : 'Add a place',
            onTap: () =>
                _run(() => showTaskDialog(_root, task.id, focus: TaskField.place)),
          ),
          if (task.hasLocation)
            MenuRow(
              icon: AppIcons.navigation,
              label: 'Open map',
              onTap: () => _run(() =>
                  _root.readOpener.openMap(label: task.location, geo: task.geo)),
            ),
          divider(),
          if (source == null) ...[
            MenuRow(
              icon: AppIcons.copy,
              label: 'Duplicate',
              onTap: () => _run(() {
                final slot = task.date != null
                    ? DaySlot(task.date!) as Slot
                    : ListSlot(task.listId!);
                _root.readStore.copyTask(task.id, slot);
              }),
            ),
            if (task.isOccurrence) ...[
              MenuRow(
                icon: AppIcons.trash2,
                label: 'Delete this one',
                danger: true,
                onTap: () => _run(() => deleteWithUndo(_root, task)),
              ),
              MenuRow(
                icon: AppIcons.trash2,
                label: 'Delete all repeats',
                danger: true,
                onTap: () =>
                    _run(() => deleteWithUndo(_root, task, wholeSeries: true)),
              ),
            ] else
              MenuRow(
                icon: AppIcons.trash2,
                label: 'Delete',
                danger: true,
                hint: isMobile ? null : 'Del',
                onTap: () =>
                    _run(() => deleteWithUndo(_root, task, wholeSeries: true)),
              ),
          ] else ...[
            if (source.edited)
              MenuRow(
                icon: AppIcons.rotateCcw,
                label: 'Reset to the calendar\'s version',
                onTap: () => _run(() => _root.readStore.resetEvent(task.id)),
              ),
            if (source.hidden)
              MenuRow(
                icon: AppIcons.eye,
                label: 'Show again',
                onTap: () =>
                    _run(() => _root.readStore.setEventHidden(task.id, false)),
              )
            else
              MenuRow(
                icon: AppIcons.eyeOff,
                label: 'Hide',
                hint: isMobile ? null : 'Del',
                onTap: () => _run(() => hideWithUndo(_root, task)),
              ),
            MenuRow(
              icon: AppIcons.calendarOff,
              label: 'Hide ${source.calendarName}',
              onTap: () => _run(() => hideCalendarWithUndo(_root, source.calendar)),
            ),
          ],
        ];
    }

    return PopoverSurface(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 248,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_page == _Page.main && source != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                  child: Row(
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
                      Expanded(
                        child: Text(
                          '${source.calendarName} · '
                          '${Strings.dayMonth(task.date!)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.caption14.copyWith(color: theme.ink(60)),
                        ),
                      ),
                    ],
                  ),
                ),
              ...rows,
            ],
          ),
        ),
      ),
    );
  }
}
