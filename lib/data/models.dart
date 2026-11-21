import 'day.dart';
import 'recurrence.dart';

/// One line of a task's checklist.
class Subtask {
  const Subtask({
    required this.id,
    this.text = '',
    this.done = false,
    this.important = false,
    this.heading = false,
    this.indent = 0,
  });

  final String id;
  final String text;
  final bool done;

  /// Marked with a star.
  final bool important;

  /// A section title rather than a checkable item.
  final bool heading;

  /// Nesting level, 0 or 1.
  final int indent;

  Subtask copyWith({
    String? text,
    bool? done,
    bool? important,
    bool? heading,
    int? indent,
  }) =>
      Subtask(
        id: id,
        text: text ?? this.text,
        done: done ?? this.done,
        important: important ?? this.important,
        heading: heading ?? this.heading,
        indent: indent ?? this.indent,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        if (done) 'done': true,
        if (important) 'important': true,
        if (heading) 'heading': true,
        if (indent != 0) 'indent': indent,
      };

  static Subtask? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final indent = json['indent'];
    return Subtask(
      id: json['id'] as String,
      text: json['text'] is String ? json['text'] as String : '',
      done: json['done'] == true,
      important: json['important'] == true,
      heading: json['heading'] == true,
      indent: indent is int ? indent.clamp(0, 1) : 0,
    );
  }
}

/// What an item is: something to do, which is ticked off when done, or
/// something that takes place, which is not.
enum ItemKind {
  task,
  event;

  static ItemKind? tryParse(Object? name) => switch (name) {
        'task' => task,
        'event' => event,
        _ => null,
      };
}

/// What a subscribed calendar says about one of its events, kept beside the
/// planner's own view of it (a [Task] whose [Task.event] is this).
class EventSource {
  const EventSource({
    required this.key,
    required this.calendar,
    required this.calendarName,
    required this.calendarColor,
    required this.title,
    required this.location,
    required this.description,
    required this.allDay,
    required this.start,
    required this.end,
    required this.originalDay,
    required this.lastDay,
    required this.repeats,
    this.edited = false,
    this.hidden = false,
  });

  /// Names the event in synced data; see `calendar/identity.dart`.
  final String key;

  /// The calendar's synced id and how the user shows it.
  final String calendar;
  final String calendarName;
  final String calendarColor;

  /// Title, place and description as the calendar has them.
  final String title;
  final String location;
  final String description;

  final bool allDay;

  /// Start and end as the calendar has them, in this device's clock; null
  /// for an all-day event.
  final DateTime? start;
  final DateTime? end;

  /// The first day the calendar puts the event on.
  final Day originalDay;

  /// The last day shown, after any move made here. With the task's date
  /// this is the span of an event over several days.
  final Day lastDay;

  /// One occurrence of a repeating event.
  final bool repeats;

  /// Whether anything about the event was changed here.
  final bool edited;

  /// Hidden by the user; such an event is only handed out on request.
  final bool hidden;
}

/// What the user changed about one event of a subscribed calendar. A null
/// field follows the calendar.
class EventOverride {
  const EventOverride({
    required this.id,
    this.calendar,
    this.origin,
    this.hidden = false,
    this.color,
    this.title,
    this.note,
    this.location,
    this.geo,
    this.date,
    this.time,
    this.done = false,
    this.doneAt,
    this.reminder,
    this.subtasks = const [],
    this.kind,
    this.end,
    this.position,
  });

  final String id;

  /// Where the event stands among the items of its day, once the user has
  /// placed it; an ordering key like a task's. Null for an event that was
  /// never placed: such events stand above everything else, in time order.
  final String? position;

  /// Whether the event is shown as a task after all. Null follows the rule
  /// for calendars, see [shownAs].
  final ItemKind? kind;

  /// What comes from a calendar is an event, unless the user says otherwise
  /// or had ticked it off (when events still had a circle to tick).
  ItemKind get shownAs => kind ?? (done ? ItemKind.task : ItemKind.event);

  /// The end, in minutes after midnight, when the user set one of their own.
  final int? end;

  /// The calendar the event is in (its synced id), and the day the calendar
  /// had it on when it was first changed: where to look for it.
  final String? calendar;
  final Day? origin;

  final bool hidden;
  final String? color;
  final String? title;
  final String? note;
  final String? location;
  final String? geo;

  /// The day the event was moved to.
  final Day? date;

  /// Start in minutes after midnight; [noTime] shows a timed event without
  /// its time.
  final int? time;
  static const noTime = -1;

  final bool done;
  final int? doneAt;
  final DateTime? reminder;
  final List<Subtask> subtasks;

  /// Whether this changes how the event reads (hiding aside).
  bool get edits =>
      color != null ||
      title != null ||
      (note != null && note!.isNotEmpty) ||
      location != null ||
      date != null ||
      time != null ||
      end != null ||
      kind != null ||
      done ||
      reminder != null ||
      subtasks.isNotEmpty;
}

/// A subscribed calendar as the user arranged it, shared between devices.
class CalendarRow {
  const CalendarRow({
    required this.id,
    this.name = '',
    this.color,
    this.hidden = false,
    this.position = '',
    this.ids,
    this.deleted = false,
  });

  final String id;
  final String name;
  final String? color;
  final bool hidden;
  final String position;

  /// `content` when the calendar's event identifiers are not stable and its
  /// events are named by what they say instead.
  final String? ids;
  final bool deleted;
}

/// A task on a day, in a list, or both.
///
/// [date] and [listId] place the task, and at least one of them is set: a
/// task with a day shows in the week, one in a list shows on the Tasks page,
/// and a list's task that was given a day shows in both (unless the user has
/// such tasks leave their list; see `Settings.keepInList`).
///
/// An event of a subscribed calendar is handed around as a task too, with
/// [event] set: it reads and edits like one, but what is stored is only
/// what the user changed about it.
///
/// Where an item comes from and what it is are two things. [kind] says what
/// it is: a task, which is ticked off, or an event, which is not. Items made
/// in the planner are tasks unless made otherwise; what a calendar brings is
/// an event unless turned into a task.
class Task {
  const Task({
    required this.id,
    this.listId,
    this.date,
    this.position = '',
    this.title = '',
    this.note = '',
    this.color,
    this.time,
    this.done = false,
    this.doneAt,
    this.subtasks = const [],
    this.recurrence,
    this.exdates = const {},
    this.seriesId,
    this.seriesDate,
    this.reminder,
    this.createdAt = 0,
    this.deleted = false,
    this.occurrenceOf,
    this.location = '',
    this.geo,
    this.event,
    this.kind = ItemKind.task,
    this.end,
    this.rolledFrom,
    this.rolledPosition,
    this.listPos = '',
    this.due,
    this.endDay,
  });

  /// Ids of imported events start with this.
  static const eventPrefix = 'ev:';

  static bool isEventId(String id) => id.startsWith(eventPrefix);

  final String id;

  /// Where the task takes place, as free text.
  final String location;

  /// Its position as `lat,lon`, when the place was picked from a search.
  final String? geo;

  /// Set when this comes from a subscribed calendar.
  final EventSource? event;

  bool get fromCalendar => event != null;
  bool get hasLocation => location.trim().isNotEmpty;

  /// A task or an event; see the class comment.
  final ItemKind kind;

  /// Whether this is ticked off when done. An event never reads as done.
  bool get checkable => kind == ItemKind.task;
  bool get happens => kind == ItemKind.event;

  /// When it ends, in minutes after midnight; only with a [time]. Within
  /// one day it is later than the start; for an item over several days it
  /// is a time of the last day. Shown in the card, not in the week.
  final int? end;

  /// For an item made here that runs over several days: the last of them,
  /// later than [date]. What a calendar brings says this in [event].
  final Day? endDay;

  /// The last day this is shown on: its own day unless it runs over
  /// several. Null without a day.
  Day? get lastDay => event?.lastDay ?? endDay ?? date;

  /// For a task that the daily move of unfinished tasks brought to today:
  /// the day it comes from and where it stood there. Kept until the user
  /// says whether it had been done after all ([waitsForWord]).
  final Day? rolledFrom;
  final String? rolledPosition;

  /// Moved to today unfinished, and not yet told apart: done that day and
  /// only left unticked, or really still to do.
  bool get waitsForWord => rolledFrom != null && checkable && !done;

  /// How long an event without an end is taken to last, to tell when it is
  /// over.
  static const assumedMinutes = 60;

  /// Whether an event lies in the past at [now]: its day has gone by, or
  /// today its end has (an hour after the start when it has none). A task is
  /// never over, only done.
  bool overAt(DateTime now) {
    final date = this.date;
    if (!happens || date == null) return false;
    final last = lastDay ?? date;
    final today = Day(now.year, now.month, now.day);
    if (last < today) return true;
    if (last > today || time == null) return false;
    final until = end ?? time! + assumedMinutes;
    return now.hour * 60 + now.minute >= until;
  }

  /// Shown over several days, as a bar across them.
  bool get spansDays {
    final first = date, last = lastDay;
    return first != null && last != null && last > first;
  }

  /// The list holding this task, or null for one that is only on a day.
  final String? listId;

  /// The day this task is on, or null for one that has none yet (it is in a
  /// list then). For a repeating task this is the first occurrence.
  final Day? date;

  /// Ordering key within the day; see `order_key.dart`. For a task without
  /// a day that was made before lists had keys of their own, it is the key
  /// within its list ([listPosition]).
  final String position;

  /// Ordering key within the list, as stored.
  final String listPos;

  /// Where the task stands in its list.
  String get listPosition => listPos.isNotEmpty ? listPos : position;

  /// Has a day: shows in the week.
  bool get planned => date != null;

  /// The day by which it is to be done, if it has a deadline. This is not
  /// the day it is planned for.
  final Day? due;

  /// Its deadline has passed at [today] and it is not done.
  bool overdueAt(Day today) => due != null && !done && due! < today;

  final String title;
  final String note;

  /// Highlight colour as a palette key or `#RRGGBB`; null for none.
  final String? color;

  /// Time of day in minutes after midnight, or null.
  final int? time;

  final bool done;

  /// When the task was completed, in milliseconds since the epoch.
  final int? doneAt;

  final List<Subtask> subtasks;

  /// Set on the series task of a repeating task.
  final Recurrence? recurrence;

  /// Days on which a repeating task does not occur, because that occurrence
  /// was completed, moved, changed or deleted on its own.
  final Set<Day> exdates;

  /// For a task split off from a repeating task: the series it came from…
  final String? seriesId;

  /// …and the day it originally fell on.
  final Day? seriesDate;

  /// When to notify, as local wall-clock time. For a repeating task this is
  /// relative to the first occurrence and shifts with each later one.
  final DateTime? reminder;

  final int createdAt;
  final bool deleted;

  /// For a computed occurrence of a repeating task: the id of the series.
  /// Such a task is not stored; its [id] is `<series id>@<date>`.
  final String? occurrenceOf;

  bool get isOccurrence => occurrenceOf != null;
  bool get isSeries => recurrence != null && !isOccurrence;
  bool get repeats => recurrence != null;
  bool get hasNote => note.trim().isNotEmpty;
  bool get hasSubtasks => subtasks.isNotEmpty;

  Task copyWith({
    String? id,
    String? Function()? listId,
    Day? Function()? date,
    String? position,
    String? title,
    String? note,
    String? Function()? color,
    int? Function()? time,
    bool? done,
    int? Function()? doneAt,
    List<Subtask>? subtasks,
    Recurrence? Function()? recurrence,
    Set<Day>? exdates,
    String? Function()? seriesId,
    Day? Function()? seriesDate,
    DateTime? Function()? reminder,
    int? createdAt,
    bool? deleted,
    String? Function()? occurrenceOf,
    String? location,
    String? Function()? geo,
    EventSource? Function()? event,
    ItemKind? kind,
    int? Function()? end,
    Day? Function()? rolledFrom,
    String? Function()? rolledPosition,
    String? listPos,
    Day? Function()? due,
    Day? Function()? endDay,
  }) =>
      Task(
        id: id ?? this.id,
        listId: listId != null ? listId() : this.listId,
        date: date != null ? date() : this.date,
        position: position ?? this.position,
        title: title ?? this.title,
        note: note ?? this.note,
        color: color != null ? color() : this.color,
        time: time != null ? time() : this.time,
        done: done ?? this.done,
        doneAt: doneAt != null ? doneAt() : this.doneAt,
        subtasks: subtasks ?? this.subtasks,
        recurrence: recurrence != null ? recurrence() : this.recurrence,
        exdates: exdates ?? this.exdates,
        seriesId: seriesId != null ? seriesId() : this.seriesId,
        seriesDate: seriesDate != null ? seriesDate() : this.seriesDate,
        reminder: reminder != null ? reminder() : this.reminder,
        createdAt: createdAt ?? this.createdAt,
        deleted: deleted ?? this.deleted,
        occurrenceOf: occurrenceOf != null ? occurrenceOf() : this.occurrenceOf,
        location: location ?? this.location,
        geo: geo != null ? geo() : this.geo,
        event: event != null ? event() : this.event,
        kind: kind ?? this.kind,
        end: end != null ? end() : this.end,
        rolledFrom: rolledFrom != null ? rolledFrom() : this.rolledFrom,
        rolledPosition:
            rolledPosition != null ? rolledPosition() : this.rolledPosition,
        listPos: listPos ?? this.listPos,
        due: due != null ? due() : this.due,
        endDay: endDay != null ? endDay() : this.endDay,
      );
}

/// A titled list on the Tasks page.
class TaskList {
  const TaskList({
    required this.id,
    this.title = '',
    this.position = '',
    this.deleted = false,
  });

  final String id;
  final String title;
  final String position;
  final bool deleted;

  TaskList copyWith({String? title, String? position, bool? deleted}) =>
      TaskList(
        id: id,
        title: title ?? this.title,
        position: position ?? this.position,
        deleted: deleted ?? this.deleted,
      );
}

/// What deleting a list, or clearing its done tasks, took away; enough to
/// put it back.
class ListRemoval {
  const ListRemoval({
    required this.listId,
    this.list = false,
    this.deleted = const [],
    this.detached = const [],
  });

  final String listId;

  /// Whether the list itself was deleted.
  final bool list;

  /// Tasks deleted: those that had no day and so were nowhere else.
  final List<String> deleted;

  /// Tasks that stay on their day and only left the list.
  final List<String> detached;
}

/// A place a task can be put or shown: a day or a list.
sealed class Slot {
  const Slot();
}

class DaySlot extends Slot {
  const DaySlot(this.day);
  final Day day;

  @override
  bool operator ==(Object other) => other is DaySlot && other.day == day;

  @override
  int get hashCode => day.hashCode;

  @override
  String toString() => 'DaySlot($day)';
}

class ListSlot extends Slot {
  const ListSlot(this.listId);
  final String listId;

  @override
  bool operator ==(Object other) =>
      other is ListSlot && other.listId == listId;

  @override
  int get hashCode => listId.hashCode;

  @override
  String toString() => 'ListSlot($listId)';
}
