import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import 'strings.dart';

/// Things done to a task or an imported event from more than one place
/// (the row's menu, the card, the keyboard), each with a way back.

/// The name a list goes by: its title, or what stands in for a blank one.
String listTitle(PlannerStore store, TaskList list) {
  if (list.title.isNotEmpty) return list.title;
  return list.id == store.lists.first.id ? 'Someday' : 'Untitled list';
}

/// Where a task can be sent: a few near days, then the lists.
List<(String, Slot)> moveTargets(PlannerStore store, {bool lists = true}) {
  final today = store.today;
  return [
    ('Today', DaySlot(today)),
    ('Tomorrow', DaySlot(today.addDays(1))),
    ('Next week', DaySlot(today.startOfWeek(store.weekStart).addDays(7))),
    if (lists)
      for (final list in store.lists) (listTitle(store, list), ListSlot(list.id)),
  ];
}

/// Deletes a task and offers to undo. One day of a repeating task is taken
/// out on its own unless [wholeSeries]; an imported event is hidden, which
/// is all that can be done to it from here.
void deleteWithUndo(BuildContext context, Task task, {bool wholeSeries = false}) {
  if (task.fromCalendar) return hideWithUndo(context, task);
  final store = context.readStore;
  final app = context.readApp;
  final day = task.date;
  if (task.isOccurrence && !wholeSeries && day != null) {
    final series = task.occurrenceOf!;
    store.deleteTask(task.id);
    app.say(
      'Removed from ${Strings.dayMonth(day)}',
      action: 'Undo',
      onAction: () => store.restoreOccurrence(series, day),
    );
    return;
  }
  final id = task.occurrenceOf ?? task.id;
  store.deleteTask(task.id, wholeSeries: true);
  app.say(
    task.repeats ? 'Repeating task deleted' : 'Task deleted',
    action: 'Undo',
    onAction: () => store.restoreTask(id),
  );
}

/// For a task the daily move of unfinished tasks brought to today: it had
/// been done on its day after all. Back it goes to where it stood, ticked;
/// since that takes it out of sight, there is a way to take it back.
void doneWhereItWas(BuildContext context, Task task) {
  final store = context.readStore;
  final before = store.task(task.id);
  final from = before?.rolledFrom;
  if (before == null || from == null) return;
  store.doneWhereItWas(task.id);
  context.readApp.say(
    'Ticked on ${Strings.dayMonth(from)}',
    action: 'Undo',
    onAction: () => store.restoreMoved(before),
  );
}

/// Hides one imported event and offers to undo.
void hideWithUndo(BuildContext context, Task event) {
  final store = context.readStore;
  store.setEventHidden(event.id, true);
  context.readApp.say(
    'Event hidden',
    action: 'Undo',
    onAction: () => store.setEventHidden(event.id, false),
  );
}

/// Makes an item of the planner's own out of what a calendar brought, in
/// [slot] (by default on its day): it takes over the text, time and place,
/// and the calendar's event is hidden. For a Someday list, where nothing of
/// a calendar can be. Returns the new item's id.
String copyIntoPlanner(BuildContext context, Task event, {Slot? slot}) {
  final store = context.readStore;
  final id = store.copyTask(event.id, slot ?? DaySlot(event.date!));
  store.setEventHidden(event.id, true);
  context.readApp.say(
    'Copied into the planner; the calendar\'s event is hidden',
    action: 'Undo',
    onAction: () {
      store.deleteTask(id);
      store.setEventHidden(event.id, false);
    },
  );
  return id;
}

/// Keeps a whole calendar out of the planner and offers to undo.
void hideCalendarWithUndo(BuildContext context, String calendarKey) {
  final calendars = context.readCalendars;
  final subscription = calendars.byKey(calendarKey);
  if (subscription == null) return;
  calendars.setHidden(subscription.id, true);
  context.readApp.say(
    '${subscription.name} hidden',
    action: 'Undo',
    onAction: () => calendars.setHidden(subscription.id, false),
  );
}
