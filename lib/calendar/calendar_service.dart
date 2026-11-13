import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/day.dart';
import '../sync/secrets.dart';
import 'ics.dart';

/// A calendar the planner shows events from: any calendar that hands out an
/// iCalendar address, such as Google Calendar's "secret address in iCal
/// format". Events are only ever read.
class CalendarSubscription {
  CalendarSubscription({
    required this.id,
    required this.name,
    required this.color,
    this.fetched,
    this.etag,
    this.modified,
  });

  final String id;
  String name;

  /// Key of a task highlight colour that marks this calendar's events.
  String color;

  /// When the feed was last read successfully.
  DateTime? fetched;

  /// Validators from the last download, to ask only for what changed.
  String? etag;
  String? modified;

  /// Why the last attempt failed; null after a success.
  String? error;

  /// Events in the feed, repeating ones counted once. Null until loaded.
  int? events;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        if (fetched != null) 'fetched': fetched!.toIso8601String(),
        if (etag != null) 'etag': etag,
        if (modified != null) 'modified': modified,
      };

  static CalendarSubscription? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], color = json['color'];
    if (id is! String || name is! String || color is! String) return null;
    final fetched = json['fetched'], etag = json['etag'], modified = json['modified'];
    return CalendarSubscription(
      id: id,
      name: name,
      color: color,
      fetched: fetched is String ? DateTime.tryParse(fetched) : null,
      etag: etag is String ? etag : null,
      modified: modified is String ? modified : null,
    );
  }
}

/// An event on one day, with the calendar it comes from.
class CalendarEvent {
  const CalendarEvent(this.occurrence, this.calendar);

  final EventOccurrence occurrence;
  final CalendarSubscription calendar;
}

/// Where downloaded feeds are kept between runs, so events show at once on
/// the next start and without a connection.
abstract class CalendarCache {
  Future<String?> read(String id);
  Future<void> write(String id, String text);
  Future<void> remove(String id);
}

/// Feeds as files in a folder beside the planner database.
class FileCalendarCache implements CalendarCache {
  FileCalendarCache(Directory data) : _folder = Directory(p.join(data.path, 'calendars'));

  final Directory _folder;

  File _file(String id) => File(p.join(_folder.path, '$id.ics'));

  @override
  Future<String?> read(String id) async {
    try {
      return await _file(id).readAsString();
    } on IOException {
      return null;
    }
  }

  @override
  Future<void> write(String id, String text) async {
    await _folder.create(recursive: true);
    // Written beside and renamed, so a crash never leaves half a feed.
    final partial = File('${_file(id).path}.part');
    await partial.writeAsString(text, flush: true);
    await partial.rename(_file(id).path);
  }

  @override
  Future<void> remove(String id) async {
    try {
      await _file(id).delete();
    } on IOException {
      // Already gone.
    }
  }
}

/// Feeds held in memory, for tests.
class MemoryCalendarCache implements CalendarCache {
  final Map<String, String> feeds = {};

  @override
  Future<String?> read(String id) async => feeds[id];

  @override
  Future<void> write(String id, String text) async => feeds[id] = text;

  @override
  Future<void> remove(String id) async => feeds.remove(id);
}

/// Tidies a calendar address as typed or pasted. Throws [FormatException]
/// with a message for the user if it cannot be used.
Uri calendarAddress(String typed) {
  var text = typed.trim();
  if (text.isEmpty) throw const FormatException('Enter the calendar address.');
  // Calendar links are often handed out with these schemes; both mean https.
  text = text.replaceFirst(RegExp(r'^webcals?://', caseSensitive: false), 'https://');
  if (!text.contains('://')) text = 'https://$text';
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    throw const FormatException('That is not a valid address.');
  }
  if (uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const FormatException('That is not a valid address.');
  }
  // The address is the key to the calendar, so it must not travel in the
  // clear. Plain http is for a server on this machine only (10.0.2.2 is how
  // an Android emulator reaches the computer it runs on).
  const local = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  if (uri.scheme == 'http' && !local.contains(uri.host)) {
    throw const FormatException(
        'Use an https address; over plain http anyone on the way could read the calendar.');
  }
  return uri;
}

/// Reads subscribed calendars and answers which events fall on which days.
///
/// The address of a private calendar works like a password: whoever has it
/// can read the calendar. It is therefore kept with the passwords (system
/// keyring, Android keystore), never in the planner database and never
/// synced; each device is given the address itself.
class CalendarService extends ChangeNotifier {
  CalendarService(
    this.db,
    this.secrets,
    this.cache, {
    HttpClient? client,
    DateTime Function()? clock,
    Future<IcsCalendar> Function(String text)? parse,
    this.interval = const Duration(minutes: 15),
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? HttpClient(),
        _ownsClient = client == null,
        _clock = clock ?? DateTime.now,
        _parse = parse ?? _parseOffThread {
    _client.userAgent = 'WeekToDo';
  }

  final PlannerDatabase db;
  final SecretStore secrets;
  final CalendarCache cache;
  final HttpClient _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Future<IcsCalendar> Function(String text) _parse;

  /// Time between automatic refreshes while the app is open.
  final Duration interval;
  final Duration timeout;

  static const _metaKey = 'local.calendars';
  static const _maxBytes = 32 * 1024 * 1024;

  /// Colours handed to new calendars in turn.
  static const _colors = ['blue', 'green', 'orange', 'lilac', 'cyan', 'red'];

  final List<CalendarSubscription> _subscriptions = [];
  final Map<String, IcsCalendar> _feeds = {};
  final Map<(Day, Day), Map<Day, List<CalendarEvent>>> _ranges = {};
  Timer? _timer;
  Future<void>? _refreshing;
  DateTime? _lastRefresh;
  bool _loaded = false;
  bool _disposed = false;

  List<CalendarSubscription> get subscriptions => List.unmodifiable(_subscriptions);

  bool get refreshing => _refreshing != null;

  static String _secretKey(String id) => 'calendar-address-$id';

  /// A big feed (years of events) takes long enough to read that it would
  /// stall the interface; that work goes to another thread.
  static Future<IcsCalendar> _parseOffThread(String text) => text.length < 200 * 1024
      ? Future.sync(() => IcsCalendar.parse(text))
      : Isolate.run(() => IcsCalendar.parse(text));

  void _changed() {
    _ranges.clear();
    if (!_disposed) notifyListeners();
  }

  void _save() => db.setMeta(
        _metaKey,
        _subscriptions.isEmpty ? null : jsonEncode([for (final s in _subscriptions) s.toJson()]),
      );

  /// Restores the subscriptions with the events last downloaded. It does not
  /// go online; follow it with [refresh] for that. Safe to call when there
  /// are none.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = db.meta(_metaKey);
    if (raw == null) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! List) return;
    for (final entry in decoded) {
      final subscription = CalendarSubscription.fromJson(entry);
      if (subscription != null) _subscriptions.add(subscription);
    }
    if (_subscriptions.isEmpty) return;
    for (final subscription in List.of(_subscriptions)) {
      final text = await cache.read(subscription.id);
      if (text == null) continue;
      try {
        final feed = await _parse(text);
        _feeds[subscription.id] = feed;
        subscription.events = feed.eventCount;
      } on FormatException {
        // A damaged copy; the next download replaces it.
      }
    }
    _changed();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = _subscriptions.isEmpty || _disposed
        ? null
        : Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Subscribes to the calendar at [address]. Returns null on success,
  /// otherwise a message for the user; nothing is kept unless the address
  /// answers with a calendar.
  Future<String?> add({required String address, String name = ''}) async {
    final Uri url;
    try {
      url = calendarAddress(address);
    } on FormatException catch (error) {
      return error.message;
    }
    final _Download download;
    final IcsCalendar feed;
    try {
      download = await _download(url);
      feed = await _parse(download.text!);
    } on _FetchFailure catch (error) {
      return error.message;
    } on FormatException {
      return 'That address did not answer with a calendar. Copy the address '
          'of the calendar in iCal format.';
    }
    final id = '${_clock().microsecondsSinceEpoch.toRadixString(36)}'
        '${_subscriptions.length}';
    try {
      await secrets.write(_secretKey(id), url.toString());
    } on Object catch (error) {
      return 'The calendar answered, but its address could not be saved in the keyring: $error';
    }
    final title = name.trim().isNotEmpty ? name.trim() : (feed.name ?? '').trim();
    final subscription = CalendarSubscription(
      id: id,
      name: title.isNotEmpty ? title : 'Calendar',
      color: _colors[_subscriptions.length % _colors.length],
      fetched: _clock(),
      etag: download.etag,
      modified: download.modified,
    )..events = feed.eventCount;
    _subscriptions.add(subscription);
    _feeds[id] = feed;
    await cache.write(id, download.text!);
    _save();
    _schedule();
    _changed();
    return null;
  }

  /// Forgets a calendar: its address, its events and its place in the list.
  Future<void> remove(String id) async {
    _subscriptions.removeWhere((s) => s.id == id);
    _feeds.remove(id);
    _save();
    _schedule();
    _changed();
    await cache.remove(id);
    try {
      await secrets.delete(_secretKey(id));
    } on Object {
      // The keyring is unavailable; the entry is of no use without the list.
    }
  }

  void rename(String id, String name) {
    final subscription = _find(id);
    if (subscription == null || name.trim().isEmpty) return;
    subscription.name = name.trim();
    _save();
    _changed();
  }

  void setColor(String id, String color) {
    final subscription = _find(id);
    if (subscription == null) return;
    subscription.color = color;
    _save();
    _changed();
  }

  CalendarSubscription? _find(String id) {
    for (final s in _subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The app is back in the foreground (a phone suspends timers in the
  /// background): look for news unless that just happened.
  void resumed({Duration staleAfter = const Duration(minutes: 5)}) {
    final last = _lastRefresh;
    if (_subscriptions.isEmpty) return;
    if (last != null && _clock().difference(last) < staleAfter) return;
    unawaited(refresh());
  }

  /// Downloads every calendar again. Calls made while one is running join it.
  Future<void> refresh() {
    if (_subscriptions.isEmpty || _disposed) return Future.value();
    return _refreshing ??= _refreshAll().whenComplete(() {
      _refreshing = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _refreshAll() async {
    _lastRefresh = _clock();
    if (!_disposed) notifyListeners();
    await Future.wait([for (final s in List.of(_subscriptions)) _refreshOne(s)]);
    _save();
    _changed();
  }

  Future<void> _refreshOne(CalendarSubscription subscription) async {
    final String? address;
    try {
      address = await secrets.read(_secretKey(subscription.id));
    } on Object catch (error) {
      subscription.error = 'Could not read the address from the keyring: $error';
      return;
    }
    if (address == null) {
      subscription.error = 'The address is missing from the keyring. Remove this calendar and add it again.';
      return;
    }
    try {
      // Ask only for changes when there is a copy to fall back on.
      final have = _feeds.containsKey(subscription.id);
      final download = await _download(
        Uri.parse(address),
        etag: have ? subscription.etag : null,
        modified: have ? subscription.modified : null,
      );
      if (download.text != null) {
        final feed = await _parse(download.text!);
        if (!_subscriptions.contains(subscription)) return; // removed meanwhile
        _feeds[subscription.id] = feed;
        subscription.events = feed.eventCount;
        subscription.etag = download.etag;
        subscription.modified = download.modified;
        await cache.write(subscription.id, download.text!);
      }
      subscription.fetched = _clock();
      subscription.error = null;
    } on _FetchFailure catch (error) {
      subscription.error = error.message;
    } on FormatException {
      subscription.error = 'The address no longer answers with a calendar.';
    }
  }

  Future<_Download> _download(Uri url, {String? etag, String? modified}) async {
    try {
      final request = await _client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'text/calendar, text/plain;q=0.8, */*;q=0.5');
      if (etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      if (modified != null) request.headers.set(HttpHeaders.ifModifiedSinceHeader, modified);
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      if (status == 304) {
        await response.drain<void>().timeout(timeout);
        return const _Download(null, null, null);
      }
      if (status == 401 || status == 403 || status == 404 || status == 410) {
        await response.drain<void>().timeout(timeout);
        throw _FetchFailure(
            'The calendar address was not accepted ($status). It may have been '
            'reset; copy it again from the calendar\'s settings.');
      }
      if (status != 200) {
        await response.drain<void>().timeout(timeout);
        throw _FetchFailure('The calendar server answered with an error ($status).');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > _maxBytes) {
          throw const _FetchFailure('The calendar is too large to read.');
        }
      }
      return _Download(
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
        response.headers.value(HttpHeaders.etagHeader),
        response.headers.value(HttpHeaders.lastModifiedHeader),
      );
    } on _FetchFailure {
      rethrow;
    } on TimeoutException {
      throw const _FetchFailure('The calendar server did not answer in time.');
    } on SocketException {
      throw const _FetchFailure('Could not reach the calendar server. Are you online?');
    } on HandshakeException {
      throw const _FetchFailure('The connection to the calendar server is not trusted.');
    } on TlsException {
      throw const _FetchFailure('The connection to the calendar server could not be secured.');
    } on HttpException catch (error) {
      throw _FetchFailure('Connection problem: ${error.message}.');
    } on StateError {
      // Android refuses plain http outright.
      throw const _FetchFailure('This device only connects over https.');
    }
  }

  /// The events of every calendar on the days [first]..[last], by day. Days
  /// without events are absent.
  Map<Day, List<CalendarEvent>> eventsBetween(Day first, Day last) {
    final known = _ranges[(first, last)];
    if (known != null) return known;
    final byDay = <Day, List<CalendarEvent>>{};
    for (final subscription in _subscriptions) {
      final feed = _feeds[subscription.id];
      if (feed == null) continue;
      for (final occurrence in feed.occurrencesBetween(first, last)) {
        (byDay[occurrence.day] ??= []).add(CalendarEvent(occurrence, subscription));
      }
    }
    for (final events in byDay.values) {
      events.sort(_compare);
    }
    // Rebuilds ask for the same few ranges again and again.
    if (_ranges.length > 12) _ranges.clear();
    return _ranges[(first, last)] = byDay;
  }

  /// All-day events first, then by start time, then by title.
  static int _compare(CalendarEvent a, CalendarEvent b) {
    final x = a.occurrence, y = b.occurrence;
    final timedX = x.allDay || x.continues ? 0 : 1;
    final timedY = y.allDay || y.continues ? 0 : 1;
    if (timedX != timedY) return timedX - timedY;
    if (timedX == 1) {
      final byStart = x.start!.compareTo(y.start!);
      if (byStart != 0) return byStart;
    }
    return x.title.toLowerCase().compareTo(y.title.toLowerCase());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_ownsClient) _client.close(force: true);
    super.dispose();
  }
}

class _Download {
  const _Download(this.text, this.etag, this.modified);

  /// Null when the server said nothing changed.
  final String? text;
  final String? etag;
  final String? modified;
}

class _FetchFailure implements Exception {
  const _FetchFailure(this.message);
  final String message;
}
