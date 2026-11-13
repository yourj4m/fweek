import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import 'strings.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// A whole month on one screen: each day lists its tasks as small chips.
class MonthView extends StatelessWidget {
  const MonthView({super.key, required this.onOpen});

  final ValueChanged<Task> onOpen;

  /// Chips shown per day before the rest collapse into "N more".
  static const _maxChips = 5;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final app = context.app;
    final month = app.anchor.startOfMonth;
    final weekStart = store.weekStart;
    final first = month.startOfWeek(weekStart);
    final lastOfMonth = month.addMonths(1).addDays(-1);
    final weeks = (lastOfMonth.difference(first) ~/ 7) + 1;
    final byDay = store.tasksBetween(first, first.addDays(weeks * 7 - 1));
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
    required this.maxChips,
    required this.narrow,
    required this.onOpen,
  });

  final Day day;
  final bool inMonth;
  final List<Task> tasks;
  final int maxChips;
  final bool narrow;
  final ValueChanged<Task> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final today = day == context.store.today;
    final shown = tasks.length > maxChips
        ? tasks.take(maxChips - 1).toList()
        : tasks;
    final hidden = tasks.length - shown.length;
    void openWeek() {
      final app = context.readApp;
      app.show(day);
      app.setMonthView(false);
    }

    return Pressable(
      onTap: openWeek,
      cursor: SystemMouseCursors.click,
      semanticLabel: 'Open the week of ${Strings.fullDate(day)}',
      builder: (context, hovered, pressed) => Container(
        constraints: BoxConstraints(minHeight: narrow ? 72 : 132),
        padding: const EdgeInsets.fromLTRB(0, 8, 8, 10),
        color: hovered ? theme.ink(5).withValues(alpha: 0.03) : null,
        child: Opacity(
          opacity: inMonth ? 1 : 0.35,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      color: today ? const Color(0xFFFFFFFF) : theme.text,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (final task in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onOpen(task),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TaskPill(
                          task: task,
                          height: 18,
                          style: context.text.tiny12,
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
      ),
    );
  }
}
