import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../calendar/calendar_service.dart';
import '../data/day.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'strings.dart';
import 'task_list.dart' show formatTime;
import 'widgets/controls.dart';

/// The colour that marks a calendar's events.
Color calendarColor(BuildContext context, CalendarSubscription calendar) {
  final color = TaskColor.resolve(calendar.color);
  // "Black" follows the theme, as it does for tasks.
  if (color == null || color.key == 'black') return context.theme.text;
  return color.fill;
}

/// What an event row says: its time, if it has one on this day, and title.
String eventLabel(BuildContext context, CalendarEvent event) {
  final occurrence = event.occurrence;
  final title = occurrence.title.trim().isEmpty ? '(No title)' : occurrence.title.trim();
  if (occurrence.allDay || occurrence.continues) return title;
  final start = occurrence.start!;
  final time = formatTime(start.hour * 60 + start.minute,
      use24h: context.store.setting<bool>(Settings.use24h));
  return '$time $title';
}

/// A day's calendar events, as ruled rows above its tasks. They can be
/// looked at but not changed or completed: they belong to the calendar they
/// come from.
class EventRows extends StatelessWidget {
  const EventRows({super.key, required this.events, required this.compact});

  final List<CalendarEvent> events;

  /// Narrow layout: the larger text, as for tasks.
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final event in events) _EventRow(event: event, compact: compact),
        ],
      );
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.compact});

  final CalendarEvent event;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final label = eventLabel(context, event);
    final style = (compact ? context.text.taskCompact : context.text.task14)
        .copyWith(color: theme.ink(60));
    return Semantics(
      button: true,
      label: 'Event: $label',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showEventDetails(context, event),
          child: Container(
            height: Dim.row,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.rule)),
            ),
            child: Row(
              children: [
                // A bar in the calendar's colour sets events apart from
                // tasks, which carry a check circle instead.
                Container(
                  width: 3,
                  height: Dim.pill - 6,
                  decoration: BoxDecoration(
                    color: calendarColor(context, event.calendar),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows an event's details beside the widget owning [context].
void showEventDetails(BuildContext context, CalendarEvent event) {
  final occurrence = event.occurrence;
  final use24h = context.readStore.setting<bool>(Settings.use24h);
  String clock(DateTime t) => formatTime(t.hour * 60 + t.minute, use24h: use24h);
  final first = Strings.fullDate(occurrence.firstDay);
  final String when;
  if (occurrence.allDay) {
    when = occurrence.firstDay == occurrence.lastDay
        ? '$first · all day'
        : '$first – ${Strings.fullDate(occurrence.lastDay)}';
  } else {
    final start = occurrence.start!, end = occurrence.end!;
    final lastDay = Day.fromDateTime(end);
    if (!end.isAfter(start)) {
      when = '$first · ${clock(start)}';
    } else if (lastDay == occurrence.firstDay) {
      when = '$first · ${clock(start)} – ${clock(end)}';
    } else {
      when = '$first ${clock(start)} – ${Strings.fullDate(lastDay)} ${clock(end)}';
    }
  }
  final title = occurrence.title.trim().isEmpty ? '(No title)' : occurrence.title.trim();
  final location = occurrence.location.trim();
  final description = occurrence.description.trim();
  final color = calendarColor(context, event.calendar);

  showPopover<void>(
    context: context,
    anchor: globalRect(context),
    align: -1,
    builder: (popover) {
      final theme = popover.theme;
      final muted = popover.text.caption14.copyWith(color: theme.ink(60));
      return PopoverSurface(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: popover.text.bodyBold17),
              const SizedBox(height: 4),
              Text(when, style: muted),
              if (location.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3, right: 6),
                      child: Icon(AppIcons.mapPin, size: 14, color: theme.ink(60)),
                    ),
                    Flexible(child: Text(location, style: popover.text.caption14)),
                  ],
                ),
              ],
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: popover.text.caption14,
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      event.calendar.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
