/// Hybrid logical clock.
///
/// Every change is stamped with a timestamp that orders correctly across
/// devices even when their wall clocks disagree: it never goes backwards
/// locally, and it jumps ahead of any timestamp it has seen from elsewhere.
/// Timestamps compare correctly as plain strings.
///
/// Format: `<millis, 12 hex digits>-<counter, 4 hex digits>-<device id>`.
class Hlc {
  Hlc({required this.deviceId, int Function()? now, String? last})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (last != null) _restore(last);
  }

  /// Stable identifier of this device; breaks ties between simultaneous edits.
  final String deviceId;
  final int Function() _now;

  int _millis = 0;
  int _counter = 0;

  /// Returns a new timestamp, strictly greater than every earlier one.
  String next() {
    final wall = _now();
    if (wall > _millis) {
      _millis = wall;
      _counter = 0;
    } else {
      _bump();
    }
    return _format();
  }

  /// Notes a timestamp from another device so later local timestamps sort
  /// after it.
  void observe(String remote) {
    final parts = _parse(remote);
    if (parts == null) return;
    final (millis, counter) = parts;
    if (millis > _millis || (millis == _millis && counter > _counter)) {
      _millis = millis;
      _counter = counter;
    }
  }

  /// The most recent timestamp issued or observed, without advancing.
  String get current => _format();

  void _restore(String last) {
    final parts = _parse(last);
    if (parts == null) return;
    _millis = parts.$1;
    _counter = parts.$2;
  }

  void _bump() {
    _counter++;
    if (_counter > 0xffff) {
      _millis++;
      _counter = 0;
    }
  }

  String _format() =>
      '${_millis.toRadixString(16).padLeft(12, '0')}-${_counter.toRadixString(16).padLeft(4, '0')}-$deviceId';

  static (int, int)? _parse(String stamp) {
    if (stamp.length < 18 || stamp[12] != '-' || stamp[17] != '-') return null;
    final millis = int.tryParse(stamp.substring(0, 12), radix: 16);
    final counter = int.tryParse(stamp.substring(13, 17), radix: 16);
    if (millis == null || counter == null) return null;
    return (millis, counter);
  }

  /// The wall-clock time encoded in a timestamp, or null if it is malformed.
  static DateTime? timeOf(String stamp) {
    final parts = _parse(stamp);
    return parts == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(parts.$1);
  }
}
