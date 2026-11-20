import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../theme/app_theme.dart';
import 'task_list.dart' show calendarColor;

/// One item of the day on the progress bar: from [start] to [end] in
/// minutes after midnight, or at [start] alone when it has no end.
class DayMark {
  const DayMark({required this.start, this.end, required this.color});

  final int start;
  final int? end;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is DayMark && other.start == start && other.end == end && other.color == color;

  @override
  int get hashCode => Object.hash(start, end, color);
}

/// A stretch of the bar and the colours of the marks that cover it: one
/// colour is painted plain, several as a checkered pattern.
typedef MarkSegment = ({double left, double right, List<Color> colors});

/// Where [marks] lie on a bar [width] wide, as rectangles [size] high: an
/// item with an end reaches from its start to its end; one without is a dot
/// centred on its start. Nothing is narrower than a dot.
List<Rect> markRects(List<DayMark> marks, double width, double size) {
  double at(int minutes) => width * minutes.clamp(0, 24 * 60) / (24 * 60);
  return [
    for (final mark in marks)
      () {
        final end = mark.end;
        // A dot is centred on its time; a pill begins at its start.
        var left = end == null ? at(mark.start) - size / 2 : at(mark.start);
        var right = end == null ? left + size : math.max(at(end), left + size);
        // Kept on the bar: a dot at midnight is not cut in half.
        if (right > width) {
          left -= right - width;
          right = width;
        }
        if (left < 0) {
          right = math.min(width, right - left);
          left = 0;
        }
        return Rect.fromLTRB(left, 0, right, size);
      }(),
  ];
}

/// Cuts the bar where marks begin and end, and says for each stretch which
/// marks cover it. Stretches nothing covers are left out.
List<MarkSegment> markSegments(List<DayMark> marks, double width, double size) {
  final rects = markRects(marks, width, size);
  final cuts = <double>{
    for (final r in rects) ...[r.left, r.right],
  }.toList()
    ..sort();
  final segments = <MarkSegment>[];
  for (var i = 0; i + 1 < cuts.length; i++) {
    final middle = (cuts[i] + cuts[i + 1]) / 2;
    final colors = [
      for (var k = 0; k < rects.length; k++)
        if (rects[k].left < middle && rects[k].right > middle) marks[k].color,
    ];
    if (colors.isNotEmpty) {
      segments.add((left: cuts[i], right: cuts[i + 1], colors: colors));
    }
  }
  return segments;
}

/// A thin bar that fills from left to right over the course of [day], from
/// midnight to midnight, with the day's timed items marked on it: a dot
/// where one starts, a pill from start to end for one that has an end, each
/// in its item's colour. Where items overlap, their colours are checkered.
/// No clock, no number.
class DayProgress extends StatefulWidget {
  const DayProgress({super.key, required this.day, this.height = 3});

  final Day day;
  final double height;

  @override
  State<DayProgress> createState() => _DayProgressState();
}

class _DayProgressState extends State<DayProgress> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Wakes at the start of the next minute.
  void _arm() {
    final now = context.readStore.clock;
    _timer?.cancel();
    _timer = Timer(
      Duration(seconds: 60 - now.second, milliseconds: 50),
      () {
        if (!mounted) return;
        final store = context.readStore;
        if (store.today != widget.day) {
          // Midnight: another day is today now.
          store.dayTurned();
        } else {
          setState(() {});
        }
        _arm();
      },
    );
  }

  /// The day's items that have a time, in the colour each shows in: its
  /// own, else its calendar's, else the colour of text.
  List<DayMark> _marks(BuildContext context) {
    final theme = context.theme;
    final day = widget.day;
    final items = [
      ...context.store.tasksOn(day),
      ...context.calendars.eventsBetween(day, day).on(day),
    ];
    return [
      for (final item in items)
        if (item.time case final start? when !(item.event?.hidden ?? false))
          DayMark(
            start: start,
            end: item.end,
            color: () {
              final own = TaskColor.resolve(item.color);
              final color = own != null
                  ? (own.key == 'black' ? theme.text : own.fill)
                  : item.event != null
                      ? calendarColor(theme, item.event!.calendarColor)
                      : theme.text;
              // What is ticked off steps back.
              return item.done ? color.withValues(alpha: color.a * 0.35) : color;
            }(),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final now = context.readStore.clock;
    final fraction =
        ((now.hour * 60 + now.minute) * 60 + now.second) / Duration.secondsPerDay;
    final marks = _marks(context);
    // Marks stand out of the thin bar, above and below.
    final size = widget.height + 4;
    return RepaintBoundary(
      child: Semantics(
        label: marks.isEmpty
            ? 'Progress of the day'
            : 'Progress of the day, with ${marks.length} timed '
                '${marks.length == 1 ? 'item' : 'items'} marked',
        child: SizedBox(
          height: widget.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(widget.height / 2),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: theme.accent.withValues(alpha: 0.22)),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction.clamp(0.0, 1.0),
                        child: ColoredBox(color: theme.accent),
                      ),
                    ],
                  ),
                ),
              ),
              if (marks.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  top: -2,
                  bottom: -2,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _MarksPainter(marks, size, theme.background),
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

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.marks, this.markSize, this.background);

  final List<DayMark> marks;
  final double markSize;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final rects = markRects(marks, size.width, markSize);
    final shape = Path();
    for (final rect in rects) {
      shape.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(markSize / 2)));
    }
    // A rim in the page's colour sets the marks off from the bar, which may
    // be of the very colour of one of them.
    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = background,
    );
    canvas.save();
    canvas.clipPath(shape);
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final paint = Paint();
    // Squares of half the mark's height: two rows of them.
    final cell = markSize / 2;
    for (final segment in markSegments(marks, size.width, markSize)) {
      final colors = segment.colors;
      if (colors.length == 1) {
        canvas.drawRect(
          Rect.fromLTRB(segment.left, 0, segment.right, markSize),
          paint..color = colors.single,
        );
        continue;
      }
      // Several at once: their colours take turns, square by square.
      var column = 0;
      for (var x = segment.left; x < segment.right; x += cell, column++) {
        for (var row = 0; row < 2; row++) {
          canvas.drawRect(
            Rect.fromLTRB(x, row * cell, math.min(x + cell, segment.right), (row + 1) * cell),
            paint..color = colors[(column + row) % colors.length],
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarksPainter old) =>
      old.markSize != markSize ||
      old.background != background ||
      old.marks.length != marks.length ||
      [for (var i = 0; i < marks.length; i++) marks[i] != old.marks[i]].contains(true);
}
