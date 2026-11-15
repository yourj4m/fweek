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
  });

  final String id;

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

/// A task on a day or in a Someday list.
///
/// Exactly one of [date] and [listId] places the task: a dated task belongs
/// to a day, an undated one to a list.
///
/// An event of a subscribed calendar is handed around as a task too, with
/// [event] set: it reads and edits like one, but what is stored is only
/// what the user changed about it.
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
  });

  /// Ids of imported events start with this.
  static const eventPrefix = 'ev:';

  static bool isEventId(String id) => id.startsWith(eventPrefix);

  final String id;

  /// Where the task takes place, as free text.
  final String location;

  /// Its position as `lat,lon`, when the place was picked from a search.
  final String? geo;

  /// Set when this is an event of a subscribed calendar.
  final EventSource? event;

  bool get isEvent => event != null;
  bool get hasLocation => location.trim().isNotEmpty;

  /// An event shown over several days.
  bool get spansDays => event != null && date != null && event!.lastDay > date!;

  /// The Someday list holding this task, or null for a dated task.
  final String? listId;

  /// The day this task is on, or null for a Someday task. For a repeating
  /// task this is the first occurrence.
  final Day? date;

  /// Ordering key within the day or list; see `order_key.dart`.
  final String position;

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
      );
}

/// A titled list in the Someday area.
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

/// Where a task lives: on a day or in a Someday list.
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
