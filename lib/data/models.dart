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

/// A task on a day or in a Someday list.
///
/// Exactly one of [date] and [listId] places the task: a dated task belongs
/// to a day, an undated one to a list.
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
  });

  final String id;

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
