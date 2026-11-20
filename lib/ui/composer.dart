import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'location_field.dart';
import 'pickers.dart';
import 'task_dialog.dart' show showTaskDialog;
import 'task_list.dart' show formatTime, shortPlace;
import 'widgets/controls.dart';

/// What the editing bar has attached to the task being typed.
class TaskDraft {
  int? time;
  String? color;
  String location = '';
  String? geo;
  String note = '';

  bool get isEmpty =>
      time == null && color == null && location.trim().isEmpty && note.trim().isEmpty;

  void clear() {
    time = null;
    color = null;
    location = '';
    geo = null;
    note = '';
  }
}

/// Links the line a task is being typed on with the phone's editing bar.
///
/// The line reports when it gains the keyboard ([attach]); the bar then
/// shows, collects a time, a place, a note and a colour in [draft], and the
/// line hands the draft to the task it creates ([applyTo]).
class Composer extends ChangeNotifier {
  FocusNode? _field;
  String? Function()? _commit;

  final draft = TaskDraft();

  /// Whether the items being typed are tasks or events, when the bar's
  /// switch was used; null for what the settings say. Unlike the [draft],
  /// which is for one item, this holds for as long as typing goes on:
  /// several events can be entered one after the other.
  ItemKind? kind;

  void setKind(ItemKind? value) {
    kind = value;
    notifyListeners();
  }

  /// Whether one of the bar's own fields (place, note) has the keyboard.
  /// The line being typed on has lost it then, but is not finished.
  bool busy = false;

  /// Whether a task is being typed.
  bool get active => _field != null;

  /// Whether [field] is the line the bar belongs to at the moment.
  bool holds(FocusNode field) => _field == field;

  /// Whether the line being typed on is one of a list: what is made there
  /// is a task without a day, so there is no event to switch to and no
  /// time to give.
  bool tasksOnly = false;

  /// A line gained the keyboard. [commit] makes a task of what is typed on
  /// it and returns its id.
  void attach(FocusNode field, String? Function() commit, {bool tasksOnly = false}) {
    if (_field == field) return;
    // Typing moved to another line: what was on the old one becomes a task,
    // with what the bar collected for it.
    _commit?.call();
    _field = field;
    _commit = commit;
    this.tasksOnly = tasksOnly;
    if (tasksOnly) kind = null;
    busy = false;
    draft.clear();
    notifyListeners();
  }

  void detach(FocusNode field) {
    if (_field != field) return;
    _field = null;
    _commit = null;
    busy = false;
    kind = null;
    draft.clear();
    // The line may be going away with the whole page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasListeners) notifyListeners();
    });
  }

  void update(void Function(TaskDraft draft) change) {
    change(draft);
    notifyListeners();
  }

  /// Gives a task just created what the bar collected for it.
  void applyTo(PlannerStore store, String id) {
    if (kind case final kind? when !tasksOnly) store.setKind(id, kind);
    if (draft.isEmpty) return;
    store.updateTask(
      id,
      time: draft.time == null || tasksOnly ? null : () => draft.time,
      color: draft.color == null ? null : () => draft.color,
      note: draft.note.trim().isEmpty ? null : draft.note,
      location: draft.location.trim().isEmpty ? null : draft.location,
      geo: draft.geo == null ? null : () => draft.geo,
    );
    draft.clear();
    notifyListeners();
  }

  /// Makes a task of what is typed now; returns its id, or null if nothing
  /// is typed.
  String? commitNow() => _commit?.call();

  /// Gives the keyboard back to the line being typed on.
  void refocus() => _field?.requestFocus();

  bool get fieldHasFocus => _field?.hasFocus ?? false;

  /// Ends typing: the task is made, the bar goes away.
  void finish() {
    final field = _field;
    if (field == null) return;
    _commit?.call();
    detach(field);
  }
}

/// Makes the [Composer] available to the lines tasks are typed on.
class ComposerScope extends InheritedWidget {
  const ComposerScope({super.key, required this.composer, required super.child});

  final Composer composer;

  static Composer? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ComposerScope>()?.composer;

  @override
  bool updateShouldNotify(ComposerScope old) => old.composer != composer;
}

enum _Panel { time, place, note, colour }

/// The bar above the phone's keyboard while a task is typed: one tap to
/// give the task a time, a place, a note or a colour, without leaving the
/// line. What is attached shows on the buttons themselves.
class ComposerBar extends StatefulWidget {
  const ComposerBar({super.key, required this.composer});

  final Composer composer;

  @override
  State<ComposerBar> createState() => _ComposerBarState();
}

class _ComposerBarState extends State<ComposerBar> {
  _Panel? _panel;
  final _placeFocus = FocusNode(debugLabel: 'composer place');
  final _noteFocus = FocusNode(debugLabel: 'composer note');
  final _note = TextEditingController();

  Composer get _composer => widget.composer;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposer);
    _placeFocus.addListener(_onPanelFocus);
    _noteFocus.addListener(_onPanelFocus);
  }

  @override
  void dispose() {
    _composer.removeListener(_onComposer);
    _placeFocus.dispose();
    _noteFocus.dispose();
    _note.dispose();
    super.dispose();
  }

  void _onComposer() {
    if (!mounted) return;
    setState(() {
      if (!_composer.active) _panel = null;
    });
  }

  /// One of the bar's fields lost the keyboard. If it did not go back to
  /// the line (the keyboard was put away, or something else was tapped),
  /// typing is over.
  void _onPanelFocus() {
    if (_placeFocus.hasFocus || _noteFocus.hasFocus || !_composer.busy) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _placeFocus.hasFocus || _noteFocus.hasFocus) return;
      if (_composer.busy && !_composer.fieldHasFocus) _composer.finish();
    });
  }

  void _open(_Panel panel) {
    if (_panel == panel) return _close();
    final typing = panel == _Panel.place || panel == _Panel.note;
    if (panel == _Panel.time && _composer.draft.time == null) {
      // Opening the wheels sets a time to start from: the next full hour.
      final now = context.readStore.clock;
      _composer.update((d) => d.time = ((now.hour + 1) % 24) * 60);
    }
    if (panel == _Panel.note) _note.text = _composer.draft.note;
    // Set before the field takes the keyboard, so that the line knows it is
    // only lending it.
    _composer.busy = typing;
    setState(() => _panel = panel);
    if (!typing) _composer.refocus();
  }

  void _close() {
    final typing = _composer.busy;
    setState(() => _panel = null);
    if (typing) {
      _composer.refocus();
      // The keyboard goes back to the line during the next frame; until
      // then the line must not take its loss for the end of typing.
      WidgetsBinding.instance.addPostFrameCallback((_) => _composer.busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_composer.active) return const SizedBox.shrink();
    final theme = context.theme;
    final draft = _composer.draft;
    final usual = context.store.newItemKind;
    final kind = _composer.kind ?? usual;
    final use24h = context.store.setting<bool>(Settings.use24h);
    final color = TaskColor.resolve(draft.color);

    Widget? panel;
    switch (_panel) {
      case _Panel.time:
        panel = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TimeWheels(
              key: const ValueKey('time'),
              minutes: draft.time ?? 9 * 60,
              onChanged: (minutes) => _composer.update((d) => d.time = minutes),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                AppButton(
                  label: 'No time',
                  size: Dim.controlInline,
                  onTap: () {
                    _composer.update((d) => d.time = null);
                    _close();
                  },
                ),
                AppButton(
                  label: 'Set',
                  kind: ButtonKind.primary,
                  size: Dim.controlInline,
                  onTap: _close,
                ),
              ],
            ),
          ],
        );
      case _Panel.place:
        panel = LocationField(
          key: const ValueKey('place'),
          location: draft.location,
          geo: draft.geo,
          focusNode: _placeFocus,
          autofocus: true,
          hint: 'Where?',
          onChanged: (location, geo) => _composer.update((d) {
            d.location = location;
            d.geo = geo;
          }),
          onDone: _close,
        );
      case _Panel.note:
        panel = TextField(
          key: const ValueKey('note'),
          controller: _note,
          focusNode: _noteFocus,
          autofocus: true,
          style: context.text.body17,
          cursorColor: theme.text,
          minLines: 2,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration.collapsed(
            hintText: 'A note for this task…',
            hintStyle: context.text.body17.copyWith(color: theme.ink(25)),
          ),
          onChanged: (text) => _composer.update((d) => d.note = text),
        );
      case _Panel.colour:
        panel = ColorPalette(
          key: const ValueKey('colour'),
          selected: draft.color,
          onPick: (picked) {
            _composer.update((d) => d.color = picked);
            _close();
          },
        );
      case null:
        panel = null;
    }

    return Semantics(
      container: true,
      label: 'Task details',
      child: Container(
        decoration: BoxDecoration(
          color: theme.isDark ? theme.dialog : theme.background,
          border: Border(top: BorderSide(color: theme.rule)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (panel != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: panel,
                ),
              ),
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // A task or an event: what the settings say, until
                          // tapped. The word shows when it is the other.
                          if (!_composer.tasksOnly)
                          _BarButton(
                            icon: kind == ItemKind.event
                                ? AppIcons.calendarClock
                                : AppIcons.circleCheck,
                            tooltip: kind == ItemKind.event
                                ? 'An event; tap to make it a task'
                                : 'A task; tap to make it an event',
                            label: kind == usual
                                ? null
                                : kind == ItemKind.event
                                    ? 'Event'
                                    : 'Task',
                            onTap: () => _composer.setKind(
                                kind == ItemKind.event ? ItemKind.task : ItemKind.event),
                          ),
                          if (!_composer.tasksOnly)
                          _BarButton(
                            icon: AppIcons.clock,
                            tooltip: 'Time',
                            label: draft.time == null
                                ? null
                                : formatTime(draft.time!, use24h: use24h),
                            on: _panel == _Panel.time,
                            onTap: () => _open(_Panel.time),
                          ),
                          _BarButton(
                            icon: AppIcons.mapPin,
                            tooltip: 'Place',
                            label: draft.location.trim().isEmpty
                                ? null
                                : shortPlace(draft.location),
                            on: _panel == _Panel.place,
                            onTap: () => _open(_Panel.place),
                          ),
                          _BarButton(
                            icon: AppIcons.text,
                            tooltip: 'Note',
                            label: draft.note.trim().isEmpty ? null : 'Note',
                            on: _panel == _Panel.note,
                            onTap: () => _open(_Panel.note),
                          ),
                          _BarButton(
                            icon: AppIcons.droplet,
                            tooltip: 'Colour',
                            dot: color == null
                                ? null
                                : color.key == 'black'
                                    ? theme.text
                                    : color.fill,
                            on: _panel == _Panel.colour,
                            onTap: () => _open(_Panel.colour),
                          ),
                          _BarButton(
                            icon: AppIcons.maximize2,
                            tooltip: 'All details',
                            onTap: () {
                              // The task is made now and opened in full.
                              final id = _composer.commitNow();
                              if (id == null) return;
                              FocusManager.instance.primaryFocus?.unfocus();
                              showTaskDialog(context, id);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  AppButton(
                    icon: AppIcons.check,
                    kind: ButtonKind.primary,
                    size: Dim.controlInline,
                    iconSize: 18,
                    tooltip: 'Done',
                    onTap: () {
                      _composer.commitNow();
                      FocusManager.instance.primaryFocus?.unfocus();
                    },
                  ),
                  const SizedBox(width: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.dot,
    this.on = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// What is attached, shown beside the icon.
  final String? label;

  /// A colour shown instead of the icon.
  final Color? dot;

  /// Its panel is open.
  final bool on;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final set = label != null || dot != null;
    final ink = set || on ? theme.text : theme.ink(60);
    return Pressable(
      onTap: onTap,
      focusable: false,
      semanticLabel: tooltip,
      builder: (context, hovered, pressed) => Container(
        height: 40,
        constraints: const BoxConstraints(minWidth: 44, maxWidth: 150),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on || pressed ? theme.ink(10) : set ? theme.ink(5) : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            if (dot != null)
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              )
            else
              Icon(icon, size: 18, color: ink),
            if (label != null)
              Flexible(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.small15.copyWith(color: ink),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
