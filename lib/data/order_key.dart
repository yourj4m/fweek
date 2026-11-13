/// Ordering keys for lists that several devices can reorder at once.
///
/// A key is a string read as a base-62 fraction between 0 and 1. A new key can
/// always be made between two neighbours without touching either of them, so
/// moving one task is a single small change that merges cleanly with moves
/// made elsewhere. Keys compare correctly as plain strings.
library;

const _digits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Returns a key that sorts strictly between [before] and [after].
///
/// A null [before] means "at the very start"; a null [after] means "at the
/// very end". Throws [ArgumentError] if [before] does not sort before [after].
String orderKeyBetween(String? before, String? after) {
  final a = before ?? '';
  if (after != null && a.compareTo(after) >= 0) {
    throw ArgumentError('Keys out of order: "$before" !< "$after"');
  }
  return _midpoint(a, after);
}

/// Returns [count] ascending keys strictly between [before] and [after].
List<String> orderKeysBetween(String? before, String? after, int count) {
  final keys = <String>[];
  var left = before;
  for (var i = 0; i < count; i++) {
    left = orderKeyBetween(left, after);
    keys.add(left);
  }
  return keys;
}

// [a] is a key or '' (zero); [b] is a key or null (one). Keys never end in
// the lowest digit, which guarantees room below every key.
String _midpoint(String a, String? b) {
  if (b != null) {
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) {
      return b.substring(0, n) +
          _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
    }
  }
  final digitA = a.isEmpty ? 0 : _digits.indexOf(a[0]);
  final digitB = b == null ? _digits.length : _digits.indexOf(b[0]);
  if (digitB - digitA > 1) {
    return _digits[(digitA + digitB + 1) ~/ 2];
  }
  // First digits are adjacent: keep a's digit and look for room further in.
  if (b != null && b.length > 1) return b.substring(0, 1);
  return _digits[digitA] + _midpoint(a.length > 1 ? a.substring(1) : '', null);
}
