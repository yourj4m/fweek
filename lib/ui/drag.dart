import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';

/// A place tasks can be dropped: the ruled body of a day or list.
class _Zone {
  _Zone(this.key);

  final GlobalKey key;

  /// Number of task rows shown, not counting the one being dragged.
  int count = 0;
}

/// Something a dragged task can be held over or dropped on that is not the
/// body of a day or list: a list's name, the button that leads to the other
/// page.
class _Spot {
  _Spot(this.key, this.onDwell, this.drop);

  final GlobalKey key;

  /// Called once when a task has been held here for a moment.
  final VoidCallback? onDwell;

  /// Where a task let go here ends up (at the end of it), if anywhere.
  final Slot? drop;
}

/// Tracks a task being dragged between days and lists.
///
/// Rows report pointer-down; the page forwards pointer moves and releases.
/// Day and list bodies register as drop zones and render a gap at
/// [targetIndex] while they are the [targetSlot].
///
/// Listeners are told when a drag starts or ends and when its target or
/// edge changes — not on every pointer move. What follows the pointer (the
/// dragged row's ghost) listens to [ghost] instead, so that moving a finger
/// redraws one small widget rather than the week.
class DragController extends ChangeNotifier {
  DragController({required this.onDrop, required this.onEdge, this.onHold});

  /// Called when a task is released over a zone, with the place its row was
  /// picked up from ([from]: the day or list that showed it).
  final void Function(Task task, Slot slot, int index, Slot? from) onDrop;

  /// Called when a dragged task is held at the left (−1) or right (+1) window
  /// edge, to turn to the previous or next week.
  final void Function(int direction) onEdge;

  /// Called when a task picked up by a long press is let go without having
  /// been moved: a hold, which asks for the task's menu. [row] is where the
  /// task's row is on screen, [from] the day or list that showed it.
  final void Function(Task task, Rect row, Slot? from)? onHold;

  /// A drop index that means "at the end".
  static const atEnd = 1 << 30;

  static const _slop = 5.0;

  /// How far a finger may wander during a long press and still be holding.
  static const _holdSlop = 10.0;
  static const _edgeWidth = 30.0;
  static const _edgeDelay = Duration(milliseconds: 650);

  final Map<Slot, _Zone> _zones = {};
  final Map<Object, _Spot> _spots = {};

  /// The day or list whose row is being dragged (a task can show in two
  /// places: on its day and in its list).
  Slot? get source => _source;
  Slot? _source;

  /// The id of the spot the dragged task is held over, if any; see
  /// [registerSpot].
  Object? get spot => _spot;
  Object? _spot;
  Timer? _spotTimer;

  Task? _candidate;
  Offset _downAt = Offset.zero;
  Offset _grab = Offset.zero;
  Rect _row = Rect.zero;

  /// Picked up by a long press and not moved since.
  bool _holding = false;

  /// The task being dragged, or null.
  Task? get task => _task;
  Task? _task;

  bool get active => _task != null;

  /// Top-left of the dragged row in global coordinates; changes with every
  /// pointer move.
  final ghost = ValueNotifier<Offset>(Offset.zero);

  /// Counts the changes that alter how many rows the days and lists need:
  /// a drag starting or ending, or its target moving to another day or
  /// list. (Moving within one list changes no height.)
  final layout = ValueNotifier<int>(0);

  /// Where the pointer is, in global coordinates.
  Offset get pointer => _pointer;
  Offset _pointer = Offset.zero;

  /// Width of the row when it was picked up.
  double get width => _width;
  double _width = 0;

  Slot? get targetSlot => _targetSlot;
  Slot? _targetSlot;

  int get targetIndex => _targetIndex;
  int _targetIndex = 0;

  /// −1 or +1 while the pointer rests in a window-edge zone, else 0.
  int get edge => _edge;
  int _edge = 0;
  Timer? _edgeTimer;

  /// Says whether edge zones are in use (the week view; a month has none).
  bool Function() edges = () => true;
  bool get edgesEnabled => edges();
  double _viewWidth = 0;

  void register(Slot slot, GlobalKey key, int count) {
    final zone = _zones[slot];
    if (zone == null || zone.key != key) {
      _zones[slot] = _Zone(key)..count = count;
    } else {
      zone.count = count;
    }
  }

  void unregister(Slot slot, GlobalKey key) {
    if (_zones[slot]?.key == key) _zones.remove(slot);
  }

  /// Makes the widget with [key] a spot under the name [id]: a dragged task
  /// held over it for a moment calls [onDwell] (once), and one let go over
  /// it goes to the end of [drop], when that is given.
  void registerSpot(Object id, GlobalKey key, {VoidCallback? onDwell, Slot? drop}) =>
      _spots[id] = _Spot(key, onDwell, drop);

  void unregisterSpot(Object id, GlobalKey key) {
    if (_spots[id]?.key == key) _spots.remove(id);
  }

  /// A mouse press on a task row: the drag starts once the pointer moves.
  void pointerDown(Task task, Offset global, Rect row, {Slot? from}) {
    _candidate = task;
    _source = from;
    _downAt = global;
    _grab = global - row.topLeft;
    _width = row.width;
    _row = row;
  }

  /// A long press on a task row: the row is picked up at once. A finger
  /// that moves right away scrolls instead, so touch never goes through
  /// [pointerDown]. Moving on from here drags; letting go without moving is
  /// a hold ([onHold]).
  void begin(Task task, Offset global, Rect row, {Slot? from}) {
    _candidate = null;
    _source = from;
    _grab = global - row.topLeft;
    _width = row.width;
    _row = row;
    _downAt = global;
    _holding = true;
    _task = task;
    _pointer = global;
    ghost.value = global - _grab;
    _retarget();
    layout.value++;
    notifyListeners();
  }

  /// Works out the drop target again after the content moved under a
  /// resting pointer (the list scrolled, or the week changed).
  void refresh() {
    if (_task == null) return;
    if (_retarget()) notifyListeners();
  }

  void pointerMove(Offset global, Size view) {
    _viewWidth = view.width;
    var changed = false;
    if (_task == null) {
      final candidate = _candidate;
      if (candidate == null || (global - _downAt).distance < _slop) return;
      _task = candidate;
      _candidate = null;
      changed = true;
      layout.value++;
    }
    if (_holding && (global - _downAt).distance > _holdSlop) _holding = false;
    _pointer = global;
    ghost.value = global - _grab;
    if (_retarget()) changed = true;
    if (_updateEdge()) changed = true;
    if (changed) notifyListeners();
  }

  void pointerUp() {
    _candidate = null;
    final task = _task;
    if (task == null) return;
    final held = _holding;
    final slot = _targetSlot;
    final index = _targetIndex;
    final from = _source;
    _reset();
    if (held) {
      onHold?.call(task, _row, from);
    } else if (slot != null) {
      onDrop(task, slot, index, from);
    }
  }

  void cancel() {
    _candidate = null;
    if (_task != null) _reset();
  }

  void _reset() {
    _task = null;
    _targetSlot = null;
    _holding = false;
    _spot = null;
    _spotTimer?.cancel();
    _spotTimer = null;
    _edge = 0;
    _edgeTimer?.cancel();
    _edgeTimer = null;
    layout.value++;
    notifyListeners();
  }

  /// The spot under the pointer, if any.
  Object? _spotAt() {
    for (final entry in _spots.entries) {
      final box = entry.value.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(_pointer)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Finds the spot, or else the zone and row, under the pointer. True if
  /// the target or the spot changed.
  bool _retarget() {
    final spot = _spotAt();
    final spotChanged = spot != _spot;
    if (spotChanged) {
      _spot = spot;
      _spotTimer?.cancel();
      _spotTimer = spot == null
          ? null
          : Timer(_edgeDelay, () {
              if (_task != null && _spot == spot) _spots[spot]?.onDwell?.call();
            });
    }
    if (spot != null) {
      // Over a spot nothing else is aimed at, however near a list may be.
      final drop = _spots[spot]?.drop;
      final moved = drop != _targetSlot;
      if (!moved && _targetIndex == atEnd) return spotChanged;
      _targetSlot = drop;
      _targetIndex = atEnd;
      if (moved) layout.value++;
      return true;
    }
    Slot? best;
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (final entry in _zones.entries) {
      final box = entry.value.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      // Horizontal distance decides the column; a pointer above or below a
      // column still targets its nearest end.
      final dx = _pointer.dx < rect.left
          ? rect.left - _pointer.dx
          : _pointer.dx > rect.right
              ? _pointer.dx - rect.right
              : 0.0;
      final dy = _pointer.dy < rect.top
          ? rect.top - _pointer.dy
          : _pointer.dy > rect.bottom
              ? _pointer.dy - rect.bottom
              : 0.0;
      final distance = dx * 4 + dy;
      if (distance >= bestDistance) continue;
      bestDistance = distance;
      best = entry.key;
      final rowCentre = _pointer.dy - _grab.dy + Dim.row / 2;
      bestIndex = ((rowCentre - rect.top) / Dim.row)
          .floor()
          .clamp(0, entry.value.count);
    }
    final slot = bestDistance < 160 ? best : null;
    if (slot == _targetSlot && bestIndex == _targetIndex) return spotChanged;
    final moved = slot != _targetSlot;
    _targetSlot = slot;
    _targetIndex = bestIndex;
    // Told only once the new target is in place: whoever listens works out
    // its height from it right away.
    if (moved) layout.value++;
    return true;
  }

  /// True if the pointer entered or left an edge zone.
  bool _updateEdge() {
    final edge = !edgesEnabled || _viewWidth <= 0
        ? 0
        : _pointer.dx < _edgeWidth
            ? -1
            : _pointer.dx > _viewWidth - _edgeWidth
                ? 1
                : 0;
    if (edge == _edge) return false;
    _edge = edge;
    _edgeTimer?.cancel();
    _edgeTimer = edge == 0
        ? null
        : Timer.periodic(_edgeDelay, (_) {
            if (_task != null && _edge != 0) onEdge(_edge);
          });
    return true;
  }

  @override
  void dispose() {
    _edgeTimer?.cancel();
    _spotTimer?.cancel();
    ghost.dispose();
    layout.dispose();
    super.dispose();
  }
}

/// Makes the [DragController] available to rows and drop zones.
class DragScope extends StatelessWidget {
  const DragScope({super.key, required this.controller, required this.child});

  final DragController controller;
  final Widget child;

  /// The controller, rebuilding the caller whenever a drag starts or ends
  /// or its target or edge changes.
  static DragController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DragState>()!.notifier!;

  /// The controller, rebuilding the caller only when the heights of days
  /// and lists change; see [DragController.layout].
  static DragController layoutOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DragLayout>()!.controller;

  /// The controller, without subscribing to anything.
  static DragController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DragState>()!.notifier!;

  @override
  Widget build(BuildContext context) => _DragState(
        notifier: controller,
        child: _DragLayout(
          controller: controller,
          notifier: controller.layout,
          child: child,
        ),
      );
}

class _DragState extends InheritedNotifier<DragController> {
  const _DragState({required super.notifier, required super.child});
}

class _DragLayout extends InheritedNotifier<ValueNotifier<int>> {
  const _DragLayout({
    required this.controller,
    required super.notifier,
    required super.child,
  });

  final DragController controller;
}

/// Scrolls its child's list while a task is dragged near its top or bottom
/// edge, so a drop target outside the visible part can be reached.
class DragAutoScroll extends StatefulWidget {
  const DragAutoScroll({super.key, required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  State<DragAutoScroll> createState() => _DragAutoScrollState();
}

class _DragAutoScrollState extends State<DragAutoScroll>
    with SingleTickerProviderStateMixin {
  /// Height of the band at each edge in which scrolling starts.
  static const _band = 72.0;

  /// Speed at the very edge, in logical pixels per second.
  static const _maxSpeed = 900.0;

  late final Ticker _ticker = createTicker(_tick);
  DragController? _drag;
  Duration _last = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drag = DragScope.read(context);
    if (drag == _drag) return;
    _unlisten();
    _drag = drag
      ..addListener(_onDrag)
      ..ghost.addListener(_onDrag);
  }

  void _unlisten() {
    _drag?.removeListener(_onDrag);
    _drag?.ghost.removeListener(_onDrag);
  }

  @override
  void dispose() {
    _unlisten();
    _ticker.dispose();
    super.dispose();
  }

  /// Signed scroll speed for where the pointer is now; 0 outside the bands.
  double _speed() {
    final drag = _drag;
    final box = context.findRenderObject();
    if (drag == null || !drag.active || box is! RenderBox || !box.attached) {
      return 0;
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final pointer = drag.pointer;
    // Another page of the pager is not under the pointer: leave it alone.
    if (pointer.dx < rect.left || pointer.dx > rect.right) return 0;
    final fromTop = pointer.dy - rect.top;
    final fromBottom = rect.bottom - pointer.dy;
    // Nothing to do at an end that is reached already: no frames are spent
    // on a page that cannot move.
    final position = widget.controller.hasClients ? widget.controller.position : null;
    if (fromTop < _band) {
      if (position != null && position.pixels <= position.minScrollExtent) return 0;
      return -_maxSpeed * (1 - fromTop / _band).clamp(0.0, 1.0);
    }
    if (fromBottom < _band) {
      if (position != null && position.pixels >= position.maxScrollExtent) return 0;
      return _maxSpeed * (1 - fromBottom / _band).clamp(0.0, 1.0);
    }
    return 0;
  }

  void _onDrag() {
    if (!mounted) return;
    final wanted = _speed() != 0;
    if (wanted && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!wanted && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final seconds = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final speed = _speed();
    if (speed == 0 || !widget.controller.hasClients) {
      _ticker.stop();
      return;
    }
    final position = widget.controller.position;
    final target = (position.pixels + speed * seconds)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    position.jumpTo(target);
    _drag?.refresh();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
