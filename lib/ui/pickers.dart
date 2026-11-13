import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/day.dart';
import '../data/planner_store.dart';
import '../data/recurrence.dart';
import '../theme/app_theme.dart';
import 'strings.dart';
import 'task_list.dart' show formatTime;
import 'widgets/controls.dart';

/// A month grid for choosing a day.
class MonthPicker extends StatefulWidget {
  const MonthPicker({super.key, required this.selected, required this.onPick});

  final Day? selected;
  final ValueChanged<Day> onPick;

  @override
  State<MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<MonthPicker> {
  late Day _month =
      (widget.selected ?? context.readStore.today).startOfMonth;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final weekStart = store.weekStart;
    final first = _month.startOfWeek(weekStart);
    return SizedBox(
      width: 288,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AppButton(
                  icon: AppIcons.chevronLeft,
                  kind: ButtonKind.ghost,
                  size: Dim.controlInline,
                  iconSize: 18,
                  tooltip: 'Previous month',
                  onTap: () => setState(() => _month = _month.addMonths(-1)),
                ),
                Expanded(
                  child: Text(
                    '${Strings.month(_month)} ${_month.year}',
                    textAlign: TextAlign.center,
                    style: context.text.small15,
                  ),
                ),
                AppButton(
                  icon: AppIcons.chevronRight,
                  kind: ButtonKind.ghost,
                  size: Dim.controlInline,
                  iconSize: 18,
                  tooltip: 'Next month',
                  onTap: () => setState(() => _month = _month.addMonths(1)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Center(
                      child: Text(
                        Strings.weekdaysInitial[(weekStart - 1 + i) % 7],
                        style: context.text.tiny12.copyWith(color: theme.ink(40)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var week = 0; week < 6; week++)
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: _DayCell(
                        day: first.addDays(week * 7 + i),
                        inMonth: first.addDays(week * 7 + i).month == _month.month,
                        selected: first.addDays(week * 7 + i) == widget.selected,
                        today: first.addDays(week * 7 + i) == store.today,
                        onTap: widget.onPick,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final Day day;
  final bool inMonth;
  final bool selected;
  final bool today;
  final ValueChanged<Day> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: () => onTap(day),
      builder: (context, hovered, pressed) => Container(
        height: 38,
        alignment: Alignment.center,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? theme.text
                : hovered
                    ? theme.ink(10)
                    : null,
          ),
          child: Text(
            '${day.day}',
            style: context.text.small15.copyWith(
              color: selected
                  ? theme.background
                  : today
                      ? theme.accent
                      : inMonth
                          ? theme.text
                          : theme.ink(25),
              fontWeight: today && !selected ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Parses `9`, `930`, `9:30`, `9.30`, `9:30pm`, `21:30` into minutes after
/// midnight; null if it is not a time.
int? parseTime(String input) {
  final m = RegExp(r'^\s*(\d{1,2})(?:[:.h]?(\d{2}))?\s*([ap])?\.?m?\.?\s*$',
          caseSensitive: false)
      .firstMatch(input);
  if (m == null) return null;
  var hour = int.parse(m[1]!);
  final minute = m[2] == null ? 0 : int.parse(m[2]!);
  final half = m[3]?.toLowerCase();
  if (half != null) {
    if (hour < 1 || hour > 12) return null;
    hour = hour % 12 + (half == 'p' ? 12 : 0);
  }
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

/// A field to type a time plus a scrolling list in half-hour steps.
class TimePicker extends StatefulWidget {
  const TimePicker({super.key, required this.selected, required this.onPick});

  final int? selected;

  /// Called with minutes after midnight, or null for "no time".
  final ValueChanged<int?> onPick;

  @override
  State<TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<TimePicker> {
  final _field = TextEditingController();
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    // Open with the current time, or mid-morning, near the top of the list.
    final around = widget.selected ?? 9 * 60;
    _scroll = ScrollController(
      initialScrollOffset: ((around ~/ 30) * 36.0 - 72).clamp(0, 48 * 36.0),
    );
  }

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final use24h = context.store.setting<bool>(Settings.use24h);
    return SizedBox(
      width: 176,
      height: 400,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Container(
              height: Dim.controlInline,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: theme.ink(5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _field,
                autofocus: true,
                style: context.text.body17,
                cursorColor: theme.text,
                decoration: InputDecoration.collapsed(
                  hintText: use24h ? '9:30' : '9:30 am',
                  hintStyle: context.text.body17.copyWith(color: theme.ink(25)),
                ),
                onSubmitted: (text) {
                  final minutes = parseTime(text);
                  if (minutes != null) widget.onPick(minutes);
                },
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              itemExtent: 36,
              children: [
                MenuRow(
                  label: 'No time',
                  checked: widget.selected == null,
                  onTap: () => widget.onPick(null),
                ),
                for (var t = 0; t < 24 * 60; t += 30)
                  MenuRow(
                    label: formatTime(t, use24h: use24h),
                    checked: widget.selected == t,
                    onTap: () => widget.onPick(t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Round swatches for choosing a task's highlight colour.
class ColorPalette extends StatefulWidget {
  const ColorPalette({super.key, required this.selected, required this.onPick});

  final String? selected;

  /// Called with a palette key, a `#RRGGBB` string, or null for no colour.
  final ValueChanged<String?> onPick;

  @override
  State<ColorPalette> createState() => _ColorPaletteState();
}

class _ColorPaletteState extends State<ColorPalette> {
  final _hex = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _addCustom() {
    final color = TaskColor.parseHex(_hex.text);
    if (color == null) return;
    final hex = TaskColor.toHex(color);
    final store = context.readStore;
    final custom = [...store.setting<List<Object?>>(Settings.customColors)];
    if (!custom.contains(hex)) {
      store.setSetting(Settings.customColors, [...custom, hex]);
    }
    widget.onPick(hex);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final custom = context.store
        .setting<List<Object?>>(Settings.customColors)
        .whereType<String>();
    final swatches = [
      ...TaskColor.palette,
      for (final hex in custom) ?TaskColor.resolve(hex),
    ];
    final preview = TaskColor.parseHex(_hex.text);
    return SizedBox(
      width: 6 * 40 + 24,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _Swatch(
                  color: null,
                  selected: widget.selected == null,
                  tooltip: 'No colour',
                  onTap: () => widget.onPick(null),
                ),
                for (final c in swatches)
                  _Swatch(
                    color: c.key == 'black' ? theme.text : c.fill,
                    selected: widget.selected == c.key,
                    check: c.key == 'black' ? theme.background : c.onFill,
                    tooltip: c.name,
                    onTap: () => widget.onPick(c.key),
                  ),
                Pressable(
                  onTap: () => setState(() => _adding = !_adding),
                  semanticLabel: 'Add a colour',
                  builder: (context, hovered, pressed) => Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hovered ? theme.ink(10) : null,
                    ),
                    child: Icon(AppIcons.plus, size: 18, color: theme.ink(60)),
                  ),
                ),
              ],
            ),
            if (_adding) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: preview,
                      border: preview == null
                          ? Border.all(color: theme.ink(20))
                          : null,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: Dim.controlInline,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: theme.ink(5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: TextField(
                        controller: _hex,
                        autofocus: true,
                        style: context.text.body17,
                        cursorColor: theme.text,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                          LengthLimitingTextInputFormatter(7),
                        ],
                        decoration: InputDecoration.collapsed(
                          hintText: '#C3FBE7',
                          hintStyle:
                              context.text.body17.copyWith(color: theme.ink(25)),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _addCustom(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: 'Add',
                    size: Dim.controlInline,
                    kind: ButtonKind.primary,
                    onTap: preview == null ? null : _addCustom,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    required this.tooltip,
    this.check,
  });

  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  final String tooltip;
  final Color? check;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      semanticLabel: tooltip,
      builder: (context, hovered, pressed) => SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: AnimatedContainer(
            duration: Dim.fast,
            width: hovered ? 26 : 22,
            height: hovered ? 26 : 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border:
                  color == null ? Border.all(color: theme.ink(40), width: 1.5) : null,
            ),
            child: selected
                ? Icon(AppIcons.check, size: 14, color: check ?? theme.text)
                : null,
          ),
        ),
      ),
    );
  }
}

/// The repeat presets, with a way into the custom editor.
class RepeatMenu extends StatelessWidget {
  const RepeatMenu({
    super.key,
    required this.current,
    required this.anchor,
    required this.onPick,
    required this.onCustom,
  });

  final Recurrence? current;

  /// The task's date (first occurrence).
  final Day anchor;
  final ValueChanged<Recurrence?> onPick;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    const presets = <(String, Recurrence?)>[
      ('Never', null),
      ('Daily', Recurrence.daily),
      ('Weekly', Recurrence.weekly),
      ('Weekdays', Recurrence.weekdaysOnly),
      ('Biweekly', Recurrence.biweekly),
      ('Monthly', Recurrence.monthly),
      ('Annually', Recurrence.yearly),
    ];
    final isPreset = presets.any((p) => p.$2 == current);
    return SizedBox(
      width: 216,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, rule) in presets)
              MenuRow(
                label: label,
                checked: rule == current,
                onTap: () => onPick(rule),
              ),
            MenuRow(
              label: 'Custom',
              checked: !isPreset,
              trailing: Icon(AppIcons.chevronRight,
                  size: 16, color: context.theme.ink(60)),
              onTap: onCustom,
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor for a repeat rule: interval, unit, days, and an end date.
class CustomRepeat extends StatefulWidget {
  const CustomRepeat({
    super.key,
    required this.initial,
    required this.anchor,
    required this.onApply,
  });

  final Recurrence? initial;
  final Day anchor;
  final ValueChanged<Recurrence> onApply;

  @override
  State<CustomRepeat> createState() => _CustomRepeatState();
}

class _CustomRepeatState extends State<CustomRepeat> {
  late Recurrence _rule = widget.initial ?? Recurrence.weekly;
  bool _pickingEnd = false;

  void _set(Recurrence rule) => setState(() => _rule = rule);

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final anchor = widget.anchor;
    final weekStart = context.store.weekStart;
    final days = _rule.weekdays.isEmpty ? {anchor.weekday} : _rule.weekdays;
    final isLastOfKind = anchor.addDays(7).month != anchor.month;
    final nth = (anchor.day - 1) ~/ 7 + 1;
    return SizedBox(
      width: 320,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Every', style: context.text.body17),
                const SizedBox(width: 10),
                AppButton(
                  icon: AppIcons.minus,
                  size: Dim.controlSmall,
                  iconSize: 16,
                  tooltip: 'Less often',
                  onTap: _rule.interval > 1
                      ? () => _set(_rule.copyWith(interval: _rule.interval - 1))
                      : null,
                ),
                SizedBox(
                  width: 40,
                  child: Text('${_rule.interval}',
                      textAlign: TextAlign.center,
                      style: context.text.bodyBold17),
                ),
                AppButton(
                  icon: AppIcons.plus,
                  size: Dim.controlSmall,
                  iconSize: 16,
                  tooltip: 'More often',
                  onTap: _rule.interval < 99
                      ? () => _set(_rule.copyWith(interval: _rule.interval + 1))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Segmented<Frequency>(
              value: _rule.frequency,
              options: {
                Frequency.daily: _rule.interval == 1 ? 'day' : 'days',
                Frequency.weekly: _rule.interval == 1 ? 'week' : 'weeks',
                Frequency.monthly: _rule.interval == 1 ? 'month' : 'months',
                Frequency.yearly: _rule.interval == 1 ? 'year' : 'years',
              },
              onChanged: (f) => _set(Recurrence(
                frequency: f,
                interval: _rule.interval,
                until: _rule.until,
              )),
            ),
            if (_rule.frequency == Frequency.weekly) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var i = 0; i < 7; i++)
                    Builder(builder: (context) {
                      final weekday = (weekStart - 1 + i) % 7 + 1;
                      final on = days.contains(weekday);
                      return Pressable(
                        semanticLabel: Strings.weekdays[weekday - 1],
                        onTap: () {
                          final next = {...days};
                          on ? next.remove(weekday) : next.add(weekday);
                          if (next.isEmpty) return;
                          _set(_rule.copyWith(weekdays: next));
                        },
                        builder: (context, hovered, pressed) => AnimatedContainer(
                          duration: Dim.fast,
                          width: Dim.controlInline,
                          height: Dim.controlInline,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? theme.text : theme.ink(hovered ? 10 : 5),
                          ),
                          child: Text(
                            Strings.weekdaysInitial[weekday - 1],
                            style: context.text.small15.copyWith(
                              color: on ? theme.background : theme.text,
                              fontWeight: on ? FontWeight.w700 : null,
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ],
            if (_rule.frequency == Frequency.monthly) ...[
              const SizedBox(height: 6),
              MenuRow(
                label: 'On day ${anchor.day}',
                checked: _rule.nthWeekday == null,
                onTap: () => _set(_rule.copyWith(nthWeekday: () => null)),
              ),
              if (nth <= 4)
                MenuRow(
                  label: 'On the ${Strings.ordinals[nth - 1]} ${Strings.weekday(anchor)}',
                  checked: _rule.nthWeekday == nth,
                  onTap: () => _set(_rule.copyWith(nthWeekday: () => nth)),
                ),
              if (isLastOfKind)
                MenuRow(
                  label: 'On the last ${Strings.weekday(anchor)}',
                  checked: _rule.nthWeekday == -1,
                  onTap: () => _set(_rule.copyWith(nthWeekday: () => -1)),
                ),
            ],
            const SizedBox(height: 6),
            MenuRow(
              label: 'Ends',
              hint: _rule.until == null
                  ? 'Never'
                  : '${Strings.dayMonth(_rule.until!)} ${_rule.until!.year}',
              trailing: Icon(
                _pickingEnd ? AppIcons.chevronUp : AppIcons.chevronDown,
                size: 16,
                color: theme.ink(60),
              ),
              onTap: () => setState(() => _pickingEnd = !_pickingEnd),
            ),
            if (_pickingEnd) ...[
              MonthPicker(
                selected: _rule.until,
                onPick: (day) {
                  if (day < anchor) return;
                  setState(() {
                    _rule = _rule.copyWith(until: () => day);
                    _pickingEnd = false;
                  });
                },
              ),
              if (_rule.until != null)
                MenuRow(
                  label: 'Never end',
                  onTap: () => setState(() {
                    _rule = _rule.copyWith(until: () => null);
                    _pickingEnd = false;
                  }),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              Strings.describe(_rule, anchor),
              textAlign: TextAlign.center,
              style: context.text.caption14.copyWith(color: theme.ink(60)),
            ),
            const SizedBox(height: 10),
            AppButton(
              label: 'Apply',
              kind: ButtonKind.primary,
              expand: true,
              onTap: () => widget.onApply(_rule),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chooses the day and time of a reminder.
class ReminderPicker extends StatefulWidget {
  const ReminderPicker({
    super.key,
    required this.initial,
    required this.suggested,
    required this.onSet,
  });

  final DateTime? initial;

  /// Shown when no reminder is set yet.
  final DateTime suggested;

  /// Called with the chosen moment, or null to remove the reminder.
  final ValueChanged<DateTime?> onSet;

  @override
  State<ReminderPicker> createState() => _ReminderPickerState();
}

class _ReminderPickerState extends State<ReminderPicker> {
  late Day _day = Day.fromDateTime(widget.initial ?? widget.suggested);
  late int _minutes = (widget.initial ?? widget.suggested).hour * 60 +
      (widget.initial ?? widget.suggested).minute;
  late final _time = TextEditingController();
  bool _valid = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_time.text.isEmpty) {
      _time.text = formatTime(_minutes,
          use24h: context.readStore.setting<bool>(Settings.use24h));
    }
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return SizedBox(
      width: 288,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MonthPicker(selected: _day, onPick: (d) => setState(() => _day = d)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: Dim.controlMedium,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: theme.ink(5),
                    borderRadius: BorderRadius.circular(Dim.radiusM),
                    border: _valid ? null : Border.all(color: AppTheme.danger),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.clock, size: 16, color: theme.ink(60)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _time,
                          style: context.text.body17,
                          cursorColor: theme.text,
                          decoration: const InputDecoration.collapsed(hintText: ''),
                          onChanged: (text) {
                            final parsed = parseTime(text);
                            setState(() {
                              _valid = parsed != null;
                              if (parsed != null) _minutes = parsed;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppButton(
                  label: 'Set reminder',
                  kind: ButtonKind.primary,
                  expand: true,
                  onTap: _valid
                      ? () => widget.onSet(DateTime(_day.year, _day.month,
                          _day.day, _minutes ~/ 60, _minutes % 60))
                      : null,
                ),
                if (widget.initial != null) ...[
                  const SizedBox(height: 6),
                  AppButton(
                    label: 'Remove reminder',
                    kind: ButtonKind.ghost,
                    expand: true,
                    onTap: () => widget.onSet(null),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
