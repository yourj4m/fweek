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
  if (task.isEvent) return hideWithUndo(context, task);
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

/// Turns an imported event into a task of the planner's own, in [slot] (by
/// default on its day): the task takes over its text, time and place, and
/// the event is hidden. Returns the task's id.
String makeTaskOf(BuildContext context, Task event, {Slot? slot}) {
  final store = context.readStore;
  final id = store.copyTask(event.id, slot ?? DaySlot(event.date!));
  store.setEventHidden(event.id, true);
  context.readApp.say(
    'Made a task; the event is hidden',
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
