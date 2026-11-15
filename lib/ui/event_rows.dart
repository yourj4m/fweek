import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'context_menu.dart';
import 'drag.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// A day's imported events that fall within the day, as ruled rows above
/// its tasks. They are rows like any other ([TaskRow]); the bar in their
/// calendar's colour tells them apart.
class EventRows extends StatelessWidget {
  const EventRows({
    super.key,
    required this.events,
    required this.compact,
    required this.onOpen,
  });

  final List<Task> events;

  /// Narrow layout: the larger text, as for tasks.
  final bool compact;
  final ValueChanged<Task> onOpen;

  /// How many of [events] show while [drag] carries one of them away.
  static int shownCount(List<Task> events, DragController drag) {
    final dragged = drag.task?.id;
    if (dragged == null) return events.length;
    return events.where((e) => e.id != dragged).length;
  }

  @override
  Widget build(BuildContext context) {
    final rule = context.theme.rule;
    final dragged = DragScope.layoutOf(context).task?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final event in events)
          if (event.id != dragged)
            DecoratedBox(
              key: ValueKey(event.id),
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: rule)),
              ),
              child: TaskRow(task: event, compact: compact, onOpen: onOpen),
            ),
      ],
    );
  }
}

/// An imported event that runs over several days, drawn as a bar: tinted in
/// its calendar's colour (or filled in the colour the user gave it), with
/// the calendar's bar at its start. Its ends are square where the event
/// goes on beyond what is shown.
class SpanBar extends StatelessWidget {
  const SpanBar({
    super.key,
    required this.task,
    required this.onOpen,
    this.startsBefore = false,
    this.endsAfter = false,
    this.suffix,
    this.height,
    this.style,
    this.quiet = false,
  });

  /// Draws the bar without its title: the continuation of a bar whose title
  /// stands in the cell before.
  final bool quiet;

  final Task task;
  final ValueChanged<Task> onOpen;

  /// The event began before the first day this bar covers.
  final bool startsBefore;

  /// The event goes on after the last day this bar covers.
  final bool endsAfter;

  /// Added to the title in muted text, such as `2/3` for the second of
  /// three days.
  final String? suffix;

  final double? height;
  final TextStyle? style;

  /// Height of a bar in the week's band.
  static double get barHeight => isMobile ? 30.0 : 24.0;

  /// Space a bar takes with the gap below it.
  static double get lane => barHeight + 4;

  void _menu(BuildContext context, [Offset? at]) => showTaskMenu(
        context,
        task,
        anchor: at == null ? globalRect(context) : at & Size.zero,
        onOpen: onOpen,
      );

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final source = task.event!;
    final faint = task.done || source.hidden;
    final own = TaskColor.resolve(task.color);
    final calendar = calendarColor(theme, source.calendarColor);
    // A colour the user gave the event fills the bar, as it would a task's
    // pill; otherwise the bar is a wash of its calendar's colour.
    final fill = own == null
        ? calendar.withValues(alpha: theme.isDark ? 0.26 : 0.18)
        : own.key == 'black'
            ? theme.text
            : own.fill;
    final ink = own == null
        ? theme.text
        : own.key == 'black'
            ? theme.background
            : own.onFill;
    Color tone(Color c) => faint ? c.withValues(alpha: c.a * 0.35) : c;
    final height = this.height ?? barHeight;
    final radius = Radius.circular(height > 20 ? 6 : 4);
    final use24h = context.store.setting<bool>(Settings.use24h);
    final style = (this.style ?? (isMobile ? context.text.small15 : context.text.task14))
        .copyWith(
      color: tone(ink),
      decoration: task.done ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: tone(ink),
    );
    return Semantics(
      button: true,
      label: 'Event over several days: ${taskLabel(task, use24h: use24h)}',
      excludeSemantics: true,
      child: SelectionContainer.disabled(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onOpen(task),
            onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
            child: GestureDetector(
              // A finger opens the menu by a long press; there is nothing to
              // drag: a bar is moved from its menu.
              supportedDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
              onLongPress: () {
                HapticFeedback.mediumImpact();
                _menu(context);
              },
              child: Container(
                height: height,
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: tone(fill),
                  borderRadius: BorderRadius.horizontal(
                    left: startsBefore ? Radius.zero : radius,
                    right: endsAfter ? Radius.zero : radius,
                  ),
                ),
                child: Row(
                  children: [
                    if (!startsBefore) Container(width: 3, color: tone(calendar)),
                    const SizedBox(width: 7),
                    if (!quiet)
                      Flexible(
                        child: Text(
                          taskLabel(task, use24h: use24h),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                    if (suffix != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        suffix!,
                        maxLines: 1,
                        style: style.copyWith(
                          color: tone(ink).withValues(alpha: tone(ink).a * 0.55),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                    const SizedBox(width: 7),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Events over several days laid out in lanes, so that no two bars of one
/// lane share a day.
class SpanLanes {
  SpanLanes._(this.lanes);

  /// Packs [spans] (in display order) for the days [first]..[last]. Each
  /// entry gives the task and the first and last day it covers within that
  /// range.
  factory SpanLanes.pack(List<Task> spans, Day first, Day last) {
    final lanes = <List<(Task, Day, Day)>>[];
    for (final span in spans) {
      final end = span.event!.lastDay;
      if (span.date! > last || end < first) continue;
      final from = span.date! < first ? first : span.date!;
      final to = end > last ? last : end;
      var placed = false;
      for (final lane in lanes) {
        if (lane.last.$3 < from) {
          lane.add((span, from, to));
          placed = true;
          break;
        }
      }
      if (!placed) lanes.add([(span, from, to)]);
    }
    return SpanLanes._(lanes);
  }

  final List<List<(Task, Day, Day)>> lanes;

  int get length => lanes.length;
  bool get isEmpty => lanes.isEmpty;
}

/// The band under the week's day headings: events over several days as bars
/// reaching across the columns of their days.
class SpanBand extends StatelessWidget {
  const SpanBand({
    super.key,
    required this.first,
    required this.columns,
    required this.lanes,
    required this.gap,
    required this.onOpen,
  });

  /// The day of the first column.
  final Day first;

  /// Number of day columns the band spans.
  final int columns;
  final SpanLanes lanes;

  /// Space between two columns.
  final double gap;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final last = first.addDays(columns - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final column = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return SizedBox(
          // A little air between the headings' rule and the first bar.
          height: 6 + lanes.length * SpanBar.lane,
          child: Stack(
            children: [
              for (var lane = 0; lane < lanes.length; lane++)
                for (final (task, from, to) in lanes.lanes[lane])
                  Positioned(
                    left: from.difference(first) * (column + gap),
                    width: (to.difference(from) + 1) * column +
                        to.difference(from) * gap,
                    top: 6 + lane * SpanBar.lane,
                    child: SpanBar(
                      key: ValueKey(task.id),
                      task: task,
                      onOpen: onOpen,
                      startsBefore: task.date! < first,
                      endsAfter: task.event!.lastDay > last,
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// The events over several days that cover [day], one bar each, for a day
/// shown on its own (the single-column week, the stacked Sunday). The bar
/// says which day of the event this is.
class DaySpans extends StatelessWidget {
  const DaySpans({
    super.key,
    required this.day,
    required this.spans,
    required this.onOpen,
    this.rowHeight,
  });

  final Day day;
  final List<Task> spans;
  final ValueChanged<Task> onOpen;

  /// When set, each bar sits in a slot of this height (a ruled row), so
  /// that the day still lines up with its neighbours.
  final double? rowHeight;

  @override
  Widget build(BuildContext context) {
    final rule = context.theme.rule;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final span in spans)
          Builder(builder: (context) {
            final length = span.event!.lastDay.difference(span.date!) + 1;
            final bar = SpanBar(
              key: ValueKey(span.id),
              task: span,
              onOpen: onOpen,
              startsBefore: span.date! < day,
              endsAfter: span.event!.lastDay > day,
              suffix: '${day.difference(span.date!) + 1}/$length',
            );
            final height = rowHeight;
            if (height == null) {
              return Padding(padding: const EdgeInsets.only(top: 4), child: bar);
            }
            return Container(
              height: height,
              padding: EdgeInsets.symmetric(vertical: (height - SpanBar.barHeight) / 2),
              foregroundDecoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: rule)),
              ),
              child: bar,
            );
          }),
      ],
    );
  }
}
