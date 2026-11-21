import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/day.dart';
import '../data/planner_store.dart';
import '../data/recurrence.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'location_field.dart';
import 'note_field.dart';
import 'pickers.dart';
import 'strings.dart';
import 'task_dialog.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// Opens the form for a new event: its title and, laid out to be seen at
/// once, everything an event can have. Nothing is added to the planner
/// until the form says so.
///
/// The event starts on [day] unless another is picked; without one, on
/// today when the planner shows today, else on the first day it shows.
Future<void> showNewEvent(BuildContext context, {Day? day}) {
  final app = context.readApp;
  return showCard(
    context,
    (card) => _EventForm(day: day ?? suggestedEventDay(app), app: app),
  );
}

/// The day a new event is first put on: today while the planner shows it
/// (or the Tasks page is up), else the first day of the week or month on
/// show, which is where the user is looking.
Day suggestedEventDay(AppController app) {
  final today = app.store.today;
  if (app.onTasks) return today;
  if (app.monthView) {
    final first = app.anchor.startOfMonth;
    return today.year == first.year && today.month == first.month ? today : first;
  }
  final first = app.weekStart;
  return today >= first && today <= first.addDays(6) ? today : first;
}

class _EventForm extends StatefulWidget {
  const _EventForm({required this.day, required this.app});

  final Day day;
  final AppController app;

  @override
  State<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<_EventForm> {
  final _title = TextEditingController();
  final _note = LinkTextController();
  final _titleFocus = FocusNode();
  final _noteFocus = FocusNode();

  late Day _start = widget.day;
  late Day _end = widget.day;

  /// Without a time of day. The times are kept while this is on, so that
  /// switching it off again brings them back.
  bool _allDay = true;
  int? _time;
  int? _endTime;

  Recurrence? _repeat;
  DateTime? _reminder;
  String _location = '';
  String? _geo;
  String? _color;

  /// Set once the form has been answered (added or cancelled): closing it
  /// then does nothing more.
  bool _answered = false;

  PlannerStore get _store => widget.app.store;
  bool get _several => _end > _start;
  bool get _timed => !_allDay && _time != null;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _titleFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- answers

  /// Adds the event as the form has it. Returns whether there was a title
  /// to add it under.
  bool _add() {
    final title = _title.text.trim();
    if (title.isEmpty || _answered) return false;
    _answered = true;
    final app = widget.app;
    final store = _store;
    final start = _start, end = _end;
    final id = store.addItem(
      day: start,
      endDay: _several ? end : null,
      title: title,
      time: _timed ? _time : null,
      end: _timed ? _endTime : null,
      note: _note.text,
      location: _location,
      geo: _geo,
      color: _color,
      recurrence: _repeat,
      reminder: _reminder,
    );
    // In sight where it was put: say so, with a way back. Elsewhere: say
    // where, with the way there.
    if (_inSight(app, start, end)) {
      app.say('Event added', action: 'Undo', onAction: () => store.deleteTask(id));
    } else {
      app.say(
        'Added on ${Strings.dateRange(start, end)}',
        action: 'Show',
        onAction: () => app.show(start, highlight: id, focus: true),
      );
    }
    return true;
  }

  /// Whether the planner is showing any of the days [first]..[last].
  static bool _inSight(AppController app, Day first, Day last) {
    if (app.onTasks) return false;
    final Day from, to;
    if (app.monthView) {
      from = app.anchor.startOfMonth.startOfWeek(app.store.weekStart);
      to = from.addDays(41);
    } else {
      from = app.weekStart;
      to = from.addDays(6);
    }
    return first <= to && last >= from;
  }

  void _submit() {
    if (_add()) Navigator.of(context).maybePop();
  }

  void _cancel() {
    _answered = true;
    Navigator.of(context).maybePop();
  }

  // ---------------------------------------------------------------- when

  /// The time a new event is given when it gets one: the next full hour
  /// today, nine in the morning on another day.
  int get _defaultTime {
    if (_start != _store.today) return 9 * 60;
    final now = _store.clock;
    return (now.hour + 1).clamp(0, 23) * 60;
  }

  void _setAllDay(bool allDay) => setState(() {
        _allDay = allDay;
        if (!allDay && _time == null) {
          _time = _defaultTime;
          final end = _time! + 60;
          _endTime = _several || end < 24 * 60 ? end % (24 * 60) : null;
        }
      });

  /// Within one day an end comes after the start; one that no longer does
  /// is moved to an hour after it, or dropped at the day's end.
  void _mendEnd() {
    final time = _time, end = _endTime;
    if (_several || time == null || end == null || end > time) return;
    _endTime = time + 60 < 24 * 60 ? time + 60 : null;
  }

  static DateTime _shifted(DateTime moment, int days) => DateTime(
      moment.year, moment.month, moment.day + days, moment.hour, moment.minute);

  Future<Day?> _pickDay(BuildContext anchor, Day selected) => showPopover<Day>(
        context: context,
        anchor: globalRect(anchor),
        align: -1,
        builder: (popover) => PopoverSurface(
          child: MonthPicker(
            selected: selected,
            onPick: (day) => Navigator.of(popover).pop(day),
          ),
        ),
      );

  Future<void> _pickStart(BuildContext anchor) async {
    final picked = await _pickDay(anchor, _start);
    if (picked == null || !mounted) return;
    setState(() {
      // The event moves as a whole: as long as before, reminded as long
      // before.
      final by = picked.difference(_start);
      _end = _end.addDays(by);
      _start = picked;
      if (_reminder != null) _reminder = _shifted(_reminder!, by);
    });
  }

  Future<void> _pickEnd(BuildContext anchor) async {
    final picked = await _pickDay(anchor, _end);
    if (picked == null || !mounted) return;
    setState(() {
      // An end before the start: the event is on that day.
      if (picked < _start) {
        final by = picked.difference(_start);
        _start = picked;
        if (_reminder != null) _reminder = _shifted(_reminder!, by);
      }
      _end = picked;
      _mendEnd();
    });
  }

  Future<int?> _pickMinutes(
    BuildContext anchor,
    int? selected, {
    int? after,
    required String none,
  }) async {
    var chose = false;
    int? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      builder: (popover) => PopoverSurface(
        child: TimePicker(
          selected: selected,
          after: after,
          none: none,
          onPick: (minutes) {
            chose = true;
            picked = minutes;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    // "No time" (said as [none]) comes back as -1, nothing chosen as null.
    return chose ? picked ?? -1 : null;
  }

  Future<void> _pickTime(BuildContext anchor) async {
    final picked = await _pickMinutes(anchor, _time, none: 'All day');
    if (picked == null || !mounted) return;
    setState(() {
      if (picked < 0) {
        _allDay = true;
        return;
      }
      // Within a day the end keeps its distance from the start.
      final before = _time, end = _endTime;
      if (!_several && before != null && end != null) {
        final moved = end + picked - before;
        _endTime = moved > picked && moved < 24 * 60 ? moved : null;
      }
      _time = picked;
      _mendEnd();
    });
  }

  Future<void> _pickEndTime(BuildContext anchor) async {
    final picked = await _pickMinutes(
      anchor,
      _endTime,
      after: _several ? null : _time,
      none: 'No end time',
    );
    if (picked == null || !mounted) return;
    setState(() => _endTime = picked < 0 ? null : picked);
  }

  // ------------------------------------------------------------- the rest

  Future<void> _pickRepeat(BuildContext anchor) async {
    final rect = globalRect(anchor);
    var custom = false;
    var chose = false;
    var rule = _repeat;
    await showPopover<void>(
      context: context,
      anchor: rect,
      align: -1,
      builder: (popover) => PopoverSurface(
        child: RepeatMenu(
          current: _repeat,
          anchor: _start,
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
        align: -1,
        builder: (popover) => PopoverSurface(
          child: CustomRepeat(
            initial: _repeat,
            anchor: _start,
            onApply: (picked) {
              chose = true;
              rule = picked;
              Navigator.of(popover).pop();
            },
          ),
        ),
      );
    }
    if (chose && mounted) setState(() => _repeat = rule);
  }

  Future<void> _pickReminder(BuildContext anchor) async {
    final time = _timed ? _time! : 9 * 60;
    var chose = false;
    DateTime? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      align: -1,
      builder: (popover) => PopoverSurface(
        child: ReminderPicker(
          initial: _reminder,
          suggested:
              DateTime(_start.year, _start.month, _start.day, time ~/ 60, time % 60),
          onSet: (moment) {
            chose = true;
            picked = moment;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose && mounted) setState(() => _reminder = picked);
  }

  Future<void> _pickColor(BuildContext anchor) async {
    var chose = false;
    String? picked;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      align: -1,
      builder: (popover) => PopoverSurface(
        child: ColorPalette(
          selected: _color,
          onPick: (color) {
            chose = true;
            picked = color;
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
    if (chose && mounted) setState(() => _color = picked);
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < Dim.breakpoint;
    final form = _form(context, narrow);

    final Widget placed;
    if (narrow) {
      // A sheet from the bottom, as tall as it needs to be; its surface
      // continues under the navigation bar.
      placed = Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.94),
          child: _surface(
            theme,
            Padding(
              padding:
                  EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              child: form,
            ),
            radius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
      );
    } else {
      final top = size.height > 720 ? Dim.dialogTop : 24.0;
      placed = Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: top, bottom: 24),
          child: SizedBox(width: Dim.dialogWidth, child: _surface(theme, form)),
        ),
      );
    }
    return PopScope(
      // Closed by a click beside it, or by going back: what has a title is
      // kept, as a card keeps what was typed into it. Cancel and Escape
      // are the ways to drop it.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_answered) _add();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
        },
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: 'New event',
          child: placed,
        ),
      ),
    );
  }

  Widget _surface(AppTheme theme, Widget child, {BorderRadius? radius}) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: theme.dialog,
          borderRadius: radius ?? BorderRadius.circular(Dim.dialogRadius),
        ),
        // A tap on the form itself is not one beside it.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: child,
        ),
      );

  Widget _form(BuildContext context, bool narrow) {
    final theme = context.theme;
    final use24h = context.store.setting<bool>(Settings.use24h);
    final side = narrow ? 24.0 : 32.0;
    final muted = context.text.small15.copyWith(color: theme.ink(60));
    final color = TaskColor.resolve(_color);
    final titled = _title.text.trim().isNotEmpty;

    String clock(int minutes) => formatTime(minutes, use24h: use24h);

    // One line of the form: what it is about, in muted words with its
    // icon before the first line of a group, then the value.
    Widget line(String label, Widget value, {IconData? icon}) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 42),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: icon == null
                    ? null
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(icon, size: 16, color: theme.ink(60)),
                      ),
              ),
              SizedBox(width: 76, child: Text(label, style: muted, maxLines: 1)),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: value)),
            ],
          ),
        );

    final title = TextField(
      controller: _title,
      focusNode: _titleFocus,
      autofocus: true,
      style: context.text.title28,
      cursorColor: theme.text,
      maxLines: 1,
      textCapitalization: TextCapitalization.sentences,
      // On a phone the keyboard's key puts the keyboard away, so that the
      // rest of the form can be seen to; with a keyboard of keys, Enter
      // adds the event.
      textInputAction: isMobile ? TextInputAction.done : TextInputAction.go,
      decoration: InputDecoration.collapsed(
        hintText: 'Event title',
        hintStyle: context.text.title28.copyWith(color: theme.ink(25)),
      ),
      onSubmitted: (_) => isMobile ? _titleFocus.unfocus() : _submit(),
    );

    final when = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line(
          'Starts',
          icon: AppIcons.clock,
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Builder(
                builder: (anchor) => _Value(
                  label: Strings.fullDate(_start),
                  tooltip: 'Start day',
                  onTap: () => _pickStart(anchor),
                ),
              ),
              if (!_allDay)
                Builder(
                  builder: (anchor) => _Value(
                    label: clock(_time!),
                    tooltip: 'Start time',
                    onTap: () => _pickTime(anchor),
                  ),
                ),
            ],
          ),
        ),
        line(
          'Ends',
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Builder(
                builder: (anchor) => _Value(
                  label: Strings.fullDate(_end),
                  tooltip: 'End day',
                  onTap: () => _pickEnd(anchor),
                ),
              ),
              if (!_allDay)
                Builder(
                  builder: (anchor) => _Value(
                    label: _endTime == null ? 'No end time' : clock(_endTime!),
                    muted: _endTime == null,
                    tooltip: 'End time',
                    onTap: () => _pickEndTime(anchor),
                  ),
                ),
            ],
          ),
        ),
        // The whole line is the switch: its words can be pressed too.
        Semantics(
          label: 'All day',
          toggled: _allDay,
          button: true,
          excludeSemantics: true,
          onTap: () => _setAllDay(!_allDay),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setAllDay(!_allDay),
            child: line(
              'All day',
              IgnorePointer(child: AppSwitch(value: _allDay, onChanged: _setAllDay)),
            ),
          ),
        ),
      ],
    );

    final reminder = _reminder;
    final options = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line(
          'Repeat',
          icon: AppIcons.rotateCw,
          Builder(
            builder: (anchor) => _Value(
              label: _repeat == null
                  ? 'Does not repeat'
                  : Strings.describe(_repeat!, _start).replaceFirst('Repeats e', 'E'),
              muted: _repeat == null,
              tooltip: 'Repeat',
              onTap: () => _pickRepeat(anchor),
            ),
          ),
        ),
        line(
          'Reminder',
          icon: AppIcons.bell,
          Builder(
            builder: (anchor) => _Value(
              label: reminder == null
                  ? 'None'
                  : '${Strings.fullDate(Day.fromDateTime(reminder))}, '
                      '${clock(reminder.hour * 60 + reminder.minute)}',
              muted: reminder == null,
              tooltip: 'Reminder',
              onTap: () => _pickReminder(anchor),
            ),
          ),
        ),
        line(
          'Colour',
          icon: AppIcons.droplet,
          Builder(
            builder: (anchor) => _Value(
              label: color?.name ?? 'None',
              muted: color == null,
              tooltip: 'Colour',
              dot: color == null
                  ? null
                  : color.key == 'black'
                      ? theme.text
                      : color.fill,
              onTap: () => _pickColor(anchor),
            ),
          ),
        ),
      ],
    );

    final place = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LocationField(
        location: _location,
        geo: _geo,
        onChanged: (location, geo) {
          _location = location;
          _geo = geo;
        },
      ),
    );

    final notes = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 8),
            child: Icon(AppIcons.text, size: 16, color: theme.ink(60)),
          ),
          Expanded(
            child: NoteField(
              controller: _note,
              focusNode: _noteFocus,
              style: context.text.body17,
              minLines: 2,
              hint: 'Add some notes…',
              onChanged: () {},
            ),
          ),
        ],
      ),
    );

    final buttons = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 8,
      children: [
        AppButton(label: 'Cancel', kind: ButtonKind.ghost, onTap: _cancel),
        AppButton(
          label: 'Add event',
          kind: ButtonKind.primary,
          onTap: titled ? _submit : null,
        ),
      ],
    );

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(side, 26, side, narrow ? 16 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New event', style: muted),
          const SizedBox(height: 10),
          title,
          const SizedBox(height: 14),
          Container(height: 1, color: theme.rule),
          const SizedBox(height: 8),
          when,
          options,
          place,
          notes,
          const SizedBox(height: 8),
          buttons,
        ],
      ),
    );
  }
}

/// A value of the form that is changed by pressing it: a rounded label on
/// a faint ground, with a spot of colour before it where it names one.
class _Value extends StatelessWidget {
  const _Value({
    required this.label,
    required this.onTap,
    this.tooltip,
    this.muted = false,
    this.dot,
  });

  final String label;
  final VoidCallback onTap;
  final String? tooltip;
  final bool muted;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      // What it is for and what it shows, said once.
      semanticLabel: tooltip == null ? label : '$tooltip, $label',
      labelOnly: true,
      focusRadius: 10,
      builder: (context, hovered, pressed) => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: theme.ink(pressed ? 12 : hovered ? 9 : 5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (dot != null)
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.small15
                    .copyWith(color: muted ? theme.ink(60) : theme.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
