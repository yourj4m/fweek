import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'context_menu.dart';
import 'event_rows.dart';
import 'day_progress.dart';
import 'strings.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// A whole month on one screen: each day lists its tasks as small chips.
class MonthView extends StatelessWidget {
  const MonthView({super.key, required this.onOpen, this.month});

  final ValueChanged<Task> onOpen;

  /// The month to show; by default the one the app is on.
  final Day? month;

  /// Chips shown per day before the rest collapse into "N more".
  static const _maxChips = 5;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    // Asked for only when this view follows the app's month (the wide
    // layout); a page of the pager is given its month.
    final month = (this.month ?? context.app.anchor).startOfMonth;
    final weekStart = store.weekStart;
    final first = month.startOfWeek(weekStart);
    final lastOfMonth = month.addMonths(1).addDays(-1);
    final weeks = (lastOfMonth.difference(first) ~/ 7) + 1;
    final byDay = store.tasksBetween(first, first.addDays(weeks * 7 - 1));
    final range =
        context.calendars.eventsBetween(first, first.addDays(weeks * 7 - 1));
    final narrow = MediaQuery.sizeOf(context).width < Dim.breakpoint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: Dim.dayHeader,
          padding: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.text, width: 2)),
          ),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Text(
                    narrow
                        ? Strings.weekdaysInitial[(weekStart - 1 + i) % 7]
                        : Strings.weekdaysShort[(weekStart - 1 + i) % 7],
                    style: (narrow ? context.text.label18 : context.text.label21)
                        .copyWith(color: theme.text.withValues(alpha: 0.3)),
                  ),
                ),
            ],
          ),
        ),
        for (var w = 0; w < weeks; w++)
          IntrinsicHeight(
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.rule)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: _MonthCell(
                        day: first.addDays(w * 7 + i),
                        inMonth: first.addDays(w * 7 + i).month == month.month,
                        tasks: byDay[first.addDays(w * 7 + i)] ?? const [],
                        events: range.on(first.addDays(w * 7 + i)),
                        spans: range.spans.isEmpty
                            ? const []
                            : range.spansOn(first.addDays(w * 7 + i)).toList(),
                        // A bar runs on into the next cell unless the week
                        // ends here.
                        lastOfRow: i == 6,
                        firstOfRow: i == 0,
                        maxChips: _maxChips,
                        narrow: narrow,
                        onOpen: onOpen,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.inMonth,
    required this.tasks,
    required this.events,
    required this.spans,
    required this.firstOfRow,
    required this.lastOfRow,
    required this.maxChips,
    required this.narrow,
    required this.onOpen,
  });

  final Day day;
  final bool inMonth;
  final List<Task> tasks;
  final List<Task> events;

  /// Events over several days that cover this day.
  final List<Task> spans;
  final bool firstOfRow;
  final bool lastOfRow;
  final int maxChips;
  final bool narrow;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final today = day == context.store.today;
    final use24h = context.store.setting<bool>(Settings.use24h);
    // Days outside the month are drawn faint, by their colours.
    final faint = inMonth ? 1.0 : 0.35;
    // The day's events and tasks in the order the week shows them; with
    // the bars of events over several days they share the cell's few lines.
    final items = context.store.arrangeDay(tasks, events);
    final total = spans.length + items.length;
    final room = total > maxChips ? maxChips - 1 : maxChips;
    final shownSpans = spans.take(room).toList();
    final shown = items.take(room - shownSpans.length).toList();
    final hidden = total - shownSpans.length - shown.length;
    void openWeek() {
      final app = context.readApp;
      app.show(day);
      app.setMonthView(false);
    }

    return Pressable(
      onTap: openWeek,
      cursor: SystemMouseCursors.click,
      focusable: false,
      semanticLabel: 'Open the week of ${Strings.fullDate(day)}',
      builder: (context, hovered, pressed) => Container(
        constraints: BoxConstraints(minHeight: narrow ? 72 : 132),
        padding: const EdgeInsets.only(bottom: 10),
        color: hovered ? theme.ink(5).withValues(alpha: 0.03) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Today's cell carries the bar that fills as the day goes by.
            if (today)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: DayProgress(day: day, height: 2),
              )
            else
              const SizedBox(height: 2),
            const SizedBox(height: 6),
            Container(
              height: 26,
              constraints: const BoxConstraints(minWidth: 26),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: today
                  ? BoxDecoration(
                      color: theme.accent,
                      borderRadius: BorderRadius.circular(13),
                    )
                  : null,
              // Sized to the number, so today's marker is a disc, not a bar.
              child: Center(
                widthFactor: 1,
                child: Text(
                  '${day.day}',
                  style: context.text.bodyBold17.copyWith(
                    fontSize: 15,
                    color: today
                        ? theme.onAccent
                        : theme.text.withValues(alpha: faint),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            for (final span in shownSpans)
              Padding(
                // Flush with the cell's edge where the event goes on, so
                // that the bars of neighbouring days read as one.
                padding: EdgeInsets.only(
                  bottom: 2,
                  right: span.event!.lastDay > day && !lastOfRow ? 0 : 8,
                ),
                child: Opacity(
                  opacity: faint,
                  child: SpanBar(
                    task: span,
                    onOpen: onOpen,
                    height: 18,
                    style: context.text.tiny12,
                    startsBefore: span.date! < day,
                    endsAfter: span.event!.lastDay > day,
                    // The title is said once per row of the grid.
                    quiet: span.date! < day && !firstOfRow,
                  ),
                ),
              ),
            for (final task in shown)
              if (task.fromCalendar)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2, right: 8),
                  child: _EventChip(
                    event: task,
                    label: taskLabel(task, use24h: use24h),
                    faint: faint,
                    onOpen: onOpen,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 2, right: 8),
                  child: Builder(
                    builder: (anchor) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onOpen(task),
                      onSecondaryTapUp: (details) => showTaskMenu(anchor, task,
                          anchor: details.globalPosition & Size.zero, onOpen: onOpen),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Opacity(
                            opacity: faint,
                            child: TaskPill(
                              task: task,
                              height: 18,
                              style: context.text.tiny12,
                              over: task.overAt(context.readStore.clock),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 1),
                child: Text(
                  '$hidden more',
                  style: context.text.tiny12.copyWith(color: theme.ink(40)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An imported event in a month cell: its calendar's bar and its title.
class _EventChip extends StatelessWidget {
  const _EventChip({
    required this.event,
    required this.label,
    required this.faint,
    required this.onOpen,
  });

  final Task event;
  final String label;
  final double faint;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final source = event.event!;
    final dim = faint *
        (event.done || source.hidden || event.overAt(context.readStore.clock) ? 0.4 : 1);
    final own = TaskColor.resolve(event.color);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpen(event),
      onSecondaryTapUp: (details) => showTaskMenu(context, event,
          anchor: details.globalPosition & Size.zero, onOpen: onOpen),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: 18,
          child: Row(
            children: [
              const SizedBox(width: 6),
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: calendarColor(theme, source.calendarColor)
                      .withValues(alpha: dim),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.tiny12.copyWith(
                    color: (own == null || own.key == 'black'
                            ? theme.ink(60)
                            : theme.isDark
                                ? own.fill
                                : theme.text)
                        .withValues(alpha: dim * (own == null ? 0.6 : 1)),
                    decoration: event.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
