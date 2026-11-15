import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/day.dart';
import '../data/models.dart';
import '../data/planner_store.dart';
import '../sync/secrets.dart';
import '../text/links.dart';
import 'ics.dart';
import 'identity.dart';

/// A calendar the planner shows events from: any calendar that hands out an
/// iCalendar address, such as Google Calendar's "secret address in iCal
/// format".
class CalendarSubscription {
  CalendarSubscription({
    required this.id,
    required this.name,
    required this.color,
    this.key = '',
    this.fetched,
    this.etag,
    this.modified,
  });

  /// Names the subscription on this device (its cached feed, its address in
  /// the keyring).
  final String id;

  /// Names the calendar in synced data: a fingerprint of its address, the
  /// same on every device that subscribes to it. See `identity.dart`.
  String key;

  String name;

  /// Key of a task highlight colour that marks this calendar's events.
  String color;

  /// Whether the calendar's events are kept out of the planner for now.
  bool hidden = false;

  /// Whether this calendar's events are named by what they say rather than
  /// by their identifiers, which turned out not to be stable.
  bool contentIds = false;

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
        'key': key,
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
    final key = json['key'];
    final fetched = json['fetched'], etag = json['etag'], modified = json['modified'];
    return CalendarSubscription(
      id: id,
      name: name,
      color: color,
      key: key is String ? key : '',
      fetched: fetched is String ? DateTime.tryParse(fetched) : null,
      etag: etag is String ? etag : null,
      modified: modified is String ? modified : null,
    );
  }
}

/// The imported events of a range of days, as the planner shows them: each
/// one a [Task] whose [Task.event] says where it comes from.
class RangeEvents {
  const RangeEvents(this.byDay, this.spans, this.hidden);

  static const empty = RangeEvents({}, [], 0);

  /// Events within one day, on the day they are shown, in display order.
  final Map<Day, List<Task>> byDay;

  /// Events over several days that touch the range, each once: by first
  /// day, longer ones first.
  final List<Task> spans;

  /// How many events in the range the user has hidden one by one.
  final int hidden;

  List<Task> on(Day day) => byDay[day] ?? const [];

  /// The several-day events that cover [day].
  Iterable<Task> spansOn(Day day) =>
      spans.where((t) => t.date! <= day && t.event!.lastDay >= day);

  bool get isEmpty => byDay.isEmpty && spans.isEmpty;
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

/// Reads subscribed calendars and hands their events to the planner, with
/// whatever the user changed about them laid on top.
///
/// Three kinds of data, kept apart on purpose:
///
///  * The address of a private calendar works like a password: whoever has
///    it can read the calendar. It is kept with the passwords (system
///    keyring, Android keystore), never in the planner database and never
///    synced; each device is given the address itself.
///  * The events are the calendar's. They are downloaded and cached on each
///    device and never written to the sync folder either.
///  * What the user arranges — a calendar's name, colour and visibility, and
///    for single events a colour, a note, another day, hidden — is the
///    planner's own data. It lives in the planner database ([PlannerStore])
///    under fingerprints of the calendar and the event, and syncs like tasks
///    do. A download never touches it, and it never changes a download: an
///    event is shown as its calendar has it, except for the fields the user
///    changed.
class CalendarService extends ChangeNotifier {
  CalendarService(
    this.store,
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
    store.eventResolver = eventTask;
    _seenOverlay = store.overlayRevision;
    store.addListener(_onStore);
  }

  final PlannerStore store;
  final SecretStore secrets;
  final CalendarCache cache;
  final HttpClient _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final Future<IcsCalendar> Function(String text) _parse;

  PlannerDatabase get db => store.db;

  /// Time between automatic refreshes while the app is open.
  final Duration interval;
  final Duration timeout;

  static const _metaKey = 'local.calendars';
  static const _maxBytes = 32 * 1024 * 1024;

  /// Colours handed to new calendars in turn.
  static const _colors = ['blue', 'green', 'orange', 'lilac', 'cyan', 'red'];

  final List<CalendarSubscription> _subscriptions = [];
  final Map<String, IcsCalendar> _feeds = {};

  final Map<(Day, Day, bool), RangeEvents> _ranges = {};

  /// Whether events the user hid one by one are shown for the moment
  /// (dimmed, so they can be found and brought back).
  bool get showHidden => _showHidden;
  bool _showHidden = false;
  set showHidden(bool value) {
    if (value == _showHidden) return;
    _showHidden = value;
    if (!_disposed) notifyListeners();
  }


  /// Fingerprints worked out so far, by calendar, identifier and occurrence.
  final Map<String, String> _keys = {};

  /// Per subscription: its once-only events by fingerprint.
  final Map<String, Map<String, EventOccurrence>> _standalone = {};

  /// Where an event handed out earlier was found: its subscription and
  /// first day. Lets [eventTask] find it again after a download.
  final Map<String, (String, Day)> _hints = {};

  Timer? _timer;
  Future<void>? _refreshing;
  DateTime? _lastRefresh;
  int _seenOverlay = -1;
  bool _loaded = false;
  bool _disposed = false;

  /// Subscribed calendars in the order the user gave them.
  List<CalendarSubscription> get subscriptions => List.unmodifiable(_subscriptions);

  bool get refreshing => _refreshing != null;

  /// Tells of a download starting or ending, and of what it reports per
  /// calendar (when it was read, why it failed). Kept apart from the
  /// service's own notifications, which mean that events changed: the week
  /// follows those, and has no reason to be drawn again because a download
  /// that found nothing new came and went.
  Listenable get status => _status;
  final _status = _Status();

  /// Calendars known from the user's other devices that this one has no
  /// address for, and so cannot show.
  List<CalendarRow> get elsewhere {
    final here = {for (final s in _subscriptions) s.key};
    return [
      for (final row in store.calendarRows)
        if (!here.contains(row.id)) row,
    ];
  }

  static String _secretKey(String id) => 'calendar-address-$id';

  /// Reading a feed of any size takes long enough to drop frames on a
  /// phone; only small ones are read where the interface runs.
  static Future<IcsCalendar> _parseOffThread(String text) => text.length < 32 * 1024
      ? Future.sync(() => IcsCalendar.parse(text))
      : Isolate.run(() => IcsCalendar.parse(text));

  void _changed() {
    _ranges.clear();
    if (!_disposed) notifyListeners();
  }

  void _feedChanged(String id) {
    _standalone.remove(id);
    if (_keys.length > 20000) _keys.clear();
  }

  void _save() => db.setMeta(
        _metaKey,
        _subscriptions.isEmpty ? null : jsonEncode([for (final s in _subscriptions) s.toJson()]),
      );

  // ------------------------------------------------------- the shared list

  /// The store changed: pick up names, colours and visibility that were
  /// edited here or arrived from another device.
  void _onStore() {
    if (store.overlayRevision == _seenOverlay) return;
    _seenOverlay = store.overlayRevision;
    _applyRows();
    _changed();
  }

  /// Brings the subscriptions in line with their shared entries, creating
  /// an entry for any that has none.
  void _applyRows() {
    var changed = false;
    for (final subscription in _subscriptions) {
      if (subscription.key.isEmpty) continue;
      final row = store.calendarRow(subscription.key);
      if (row == null || row.deleted) {
        // Removed on another device, but still wanted on this one.
        store.setCalendar(
          subscription.key,
          name: subscription.name,
          color: subscription.color,
          hidden: subscription.hidden,
          deleted: false,
        );
        continue;
      }
      if (row.name.isNotEmpty && row.name != subscription.name) {
        subscription.name = row.name;
        changed = true;
      }
      if (row.color != null && row.color != subscription.color) {
        subscription.color = row.color!;
        changed = true;
      }
      subscription.hidden = row.hidden;
      subscription.contentIds = row.ids == 'content';
    }
    final order = {for (final row in store.calendarRows) row.id: row.position};
    _subscriptions.sort((a, b) {
      final byPosition = (order[a.key] ?? '').compareTo(order[b.key] ?? '');
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });
    _seenOverlay = store.overlayRevision;
    // Name and colour are kept on the device too, for a start without them.
    if (changed) _save();
  }

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
    var named = false;
    for (final subscription in List.of(_subscriptions)) {
      if (subscription.key.isEmpty) {
        // Saved by a version that knew calendars by their place on this
        // device only: name it by its address now.
        String? address;
        try {
          address = await secrets.read(_secretKey(subscription.id));
        } on Object {
          address = null;
        }
        final uri = address == null ? null : Uri.tryParse(address);
        subscription.key =
            uri == null ? localCalendarKey(subscription.id) : calendarKey(uri);
        named = true;
      }
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
    if (_disposed) return;
    if (named) _save();
    _applyRows();
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
    final key = calendarKey(url);
    if (_subscriptions.any((s) => s.key == key)) {
      return 'This calendar is already in the list.';
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
    // Another device may have added this calendar before: then it already
    // has a name, a colour and a place in the list.
    final row = store.calendarRow(key);
    final known = row != null && !row.deleted ? row : null;
    final typed = name.trim();
    final title = typed.isNotEmpty
        ? typed
        : known != null && known.name.isNotEmpty
            ? known.name
            : (feed.name ?? '').trim();
    final subscription = CalendarSubscription(
      id: id,
      key: key,
      name: title.isNotEmpty ? title : 'Calendar',
      color: known?.color ?? _colors[_subscriptions.length % _colors.length],
      fetched: _clock(),
      etag: download.etag,
      modified: download.modified,
    )
      ..events = feed.eventCount
      ..hidden = known?.hidden ?? false;
    _subscriptions.add(subscription);
    _feeds[id] = feed;
    await cache.write(id, download.text!);
    _save();
    store.setCalendar(
      key,
      name: subscription.name,
      color: subscription.color,
      deleted: false,
    );
    _applyRows();
    _schedule();
    _changed();
    return null;
  }

  /// Forgets a calendar on this device: its address, its events and its
  /// place in the list. What was changed about its events is kept, in case
  /// the calendar is added again or is still shown on another device.
  Future<void> remove(String id) async {
    final subscription = _find(id);
    _subscriptions.removeWhere((s) => s.id == id);
    _feeds.remove(id);
    _feedChanged(id);
    _save();
    _schedule();
    if (subscription != null && subscription.key.isNotEmpty) {
      // Another device still showing it puts its entry back.
      store.setCalendar(subscription.key, deleted: true);
    }
    _changed();
    await cache.remove(id);
    try {
      await secrets.delete(_secretKey(id));
    } on Object {
      // The keyring is unavailable; the entry is of no use without the list.
    }
  }

  /// Drops a calendar known only from another device from the list.
  void forget(String key) => store.setCalendar(key, deleted: true);

  void rename(String id, String name) {
    final subscription = _find(id);
    if (subscription == null || name.trim().isEmpty) return;
    subscription.name = name.trim();
    _save();
    store.setCalendar(subscription.key, name: subscription.name);
    _changed();
  }

  void setColor(String id, String color) {
    final subscription = _find(id);
    if (subscription == null) return;
    subscription.color = color;
    _save();
    store.setCalendar(subscription.key, color: color);
    _changed();
  }

  /// Keeps a whole calendar out of the planner, or lets it back in.
  void setHidden(String id, bool hidden) {
    final subscription = _find(id);
    if (subscription == null) return;
    subscription.hidden = hidden;
    store.setCalendar(subscription.key, hidden: hidden);
    _changed();
  }

  /// Moves a calendar one place up ([by] = −1) or down (+1) in the list.
  void move(String id, int by) {
    final subscription = _find(id);
    if (subscription == null) return;
    store.moveCalendar(subscription.key, by);
    _applyRows();
    _changed();
  }

  CalendarSubscription? _find(String id) {
    for (final s in _subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The subscription showing the calendar with this shared [key].
  CalendarSubscription? byKey(String key) {
    for (final s in _subscriptions) {
      if (s.key == key) return s;
    }
    return null;
  }

  // ------------------------------------------------------------ downloads

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
    final running = _refreshing ??= _refreshAll().whenComplete(() {
      _refreshing = null;
      if (!_disposed) _status.changed();
    });
    _status.changed();
    return running;
  }

  Future<void> _refreshAll() async {
    _lastRefresh = _clock();
    final before = [for (final s in _subscriptions) _feeds[s.id]];
    await Future.wait([for (final s in List.of(_subscriptions)) _refreshOne(s)]);
    if (_disposed) return;
    _save();
    // Nothing new: the week on screen stays as it is.
    final after = [for (final s in _subscriptions) _feeds[s.id]];
    if (!listEquals(before, after)) _changed();
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
      final previous = _feeds[subscription.id];
      final download = await _download(
        Uri.parse(address),
        etag: previous != null ? subscription.etag : null,
        modified: previous != null ? subscription.modified : null,
      );
      if (download.text != null) {
        final feed = await _parse(download.text!);
        if (_disposed || !_subscriptions.contains(subscription)) return; // removed meanwhile
        if (previous != null && !subscription.contentIds && renamedEverything(previous, feed)) {
          // This calendar hands out new identifiers with every download;
          // from now on its events are told apart by what they say.
          subscription.contentIds = true;
          store.setCalendar(subscription.key, ids: () => 'content');
        }
        _feeds[subscription.id] = feed;
        _feedChanged(subscription.id);
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

  /// Whether [next] holds about as many events as [previous] but hardly one
  /// of its identifiers: the mark of a service that makes them up anew for
  /// every download.
  @visibleForTesting
  static bool renamedEverything(IcsCalendar previous, IcsCalendar next) {
    final before = previous.uids, after = next.uids;
    if (before.length < 5 || after.length < 5) return false;
    if ((after.length - before.length).abs() > before.length / 2) return false;
    final kept = before.where(after.contains).length;
    return kept * 10 < before.length;
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

  // --------------------------------------------------------------- events

  /// The fingerprint under which changes to [occurrence] are kept.
  String _keyOf(CalendarSubscription subscription, EventOccurrence occurrence) {
    if (subscription.contentIds) {
      final start = occurrence.allDay
          ? 'D${occurrence.firstDay.iso}'
          : 'T${occurrence.start!.toUtc().toIso8601String()}';
      return contentEventKey(subscription.key, occurrence.title, start);
    }
    final name = '${subscription.key}\n${occurrence.uid}\n${occurrence.instance}';
    return _keys[name] ??=
        eventKey(subscription.key, occurrence.uid, occurrence.instance);
  }

  /// The event [occurrence] as the planner shows it: the calendar's version
  /// with the user's changes on top.
  Task _task(
    CalendarSubscription subscription,
    EventOccurrence occurrence,
    String key,
    EventOverride? override,
  ) {
    final moved = override?.date;
    final shift = moved == null ? 0 : moved.difference(occurrence.firstDay);
    final ownTime = occurrence.allDay
        ? null
        : occurrence.start!.hour * 60 + occurrence.start!.minute;
    final time = switch (override?.time) {
      null => ownTime,
      EventOverride.noTime => null,
      final minutes => minutes,
    };
    _hints[key] = (subscription.id, occurrence.firstDay);
    if (_hints.length > 6000) _hints.remove(_hints.keys.first);
    return Task(
      id: '${Task.eventPrefix}$key',
      date: occurrence.firstDay.addDays(shift),
      title: override?.title ?? occurrence.title.trim(),
      note: override?.note ?? '',
      color: override?.color,
      time: time,
      done: override?.done ?? false,
      doneAt: override?.doneAt,
      subtasks: override?.subtasks ?? const [],
      reminder: override?.reminder,
      location: override?.location ?? occurrence.location.trim(),
      geo: override?.geo,
      event: EventSource(
        key: key,
        calendar: subscription.key,
        calendarName: subscription.name,
        calendarColor: subscription.color,
        title: occurrence.title.trim(),
        location: occurrence.location.trim(),
        description: plainFromHtml(occurrence.description).trim(),
        allDay: occurrence.allDay,
        start: occurrence.start,
        end: occurrence.end,
        originalDay: occurrence.firstDay,
        lastDay: occurrence.lastDay.addDays(shift),
        repeats: occurrence.recurring,
        edited: override?.edits ?? false,
        hidden: override?.hidden ?? false,
      ),
    );
  }

  /// Finds the occurrence named [key] in a feed: among the events that
  /// happen once, wherever they are now, or among the occurrences around
  /// [near], where it was last seen.
  EventOccurrence? _locate(
    CalendarSubscription subscription,
    IcsCalendar feed,
    String key,
    Day? near,
  ) {
    final once = _standalone[subscription.id] ??= {
      for (final occurrence in feed.standalone) _keyOf(subscription, occurrence): occurrence,
    };
    final found = once[key];
    if (found != null || near == null) return found;
    // Two days either way: another device may have seen it in another zone.
    for (final occurrence in feed.occurrencesBetween(near.addDays(-2), near.addDays(2))) {
      if (!occurrence.continues && _keyOf(subscription, occurrence) == key) {
        return occurrence;
      }
    }
    return null;
  }

  /// The imported event behind an id starting [Task.eventPrefix], with the
  /// user's changes applied; null if no calendar on this device has it.
  /// Hidden events and those of hidden calendars are found too.
  Task? eventTask(String id) {
    if (!Task.isEventId(id)) return null;
    final key = id.substring(Task.eventPrefix.length);
    final override = store.eventOverride(key);
    final hint = _hints[key];
    for (final subscription in _subscriptions) {
      if (hint != null && hint.$1 != subscription.id) continue;
      if (hint == null && override?.calendar != null && override!.calendar != subscription.key) {
        continue;
      }
      final feed = _feeds[subscription.id];
      if (feed == null) continue;
      final occurrence = _locate(subscription, feed, key, hint?.$2 ?? override?.origin);
      if (occurrence != null) return _task(subscription, occurrence, key, override);
    }
    return null;
  }

  /// The events of every shown calendar on the days [first]..[last]. While
  /// [showHidden] is on (or asked for here), events the user hid one by one
  /// are included, marked as hidden; those of hidden calendars never are.
  RangeEvents eventsBetween(Day first, Day last, {bool? showHidden}) {
    showHidden ??= _showHidden;
    if (_subscriptions.isEmpty) return RangeEvents.empty;
    if (store.overlayRevision != _seenOverlay) {
      _seenOverlay = store.overlayRevision;
      _applyRows();
      _ranges.clear();
    }
    final known = _ranges[(first, last, showHidden)];
    if (known != null) return known;

    final byDay = <Day, List<Task>>{};
    final spans = <Task>[];
    final placed = <String>{};
    var hidden = 0;

    void place(Task task) {
      final source = task.event!;
      if (task.date! > last || source.lastDay < first) return;
      // Two events of one name (a sloppy feed) would be one row twice.
      if (!placed.add(task.id)) return;
      if (source.hidden) {
        hidden++;
        if (!showHidden!) return;
      }
      if (task.spansDays) {
        spans.add(task);
      } else {
        (byDay[task.date!] ??= []).add(task);
      }
    }

    for (final subscription in _subscriptions) {
      if (subscription.hidden) continue;
      final feed = _feeds[subscription.id];
      if (feed == null) continue;
      for (final occurrence in feed.occurrencesBetween(first, last)) {
        // An event over several days comes once per day; take the first.
        final leading = occurrence.firstDay < first ? first : occurrence.firstDay;
        if (occurrence.day != leading) continue;
        final key = _keyOf(subscription, occurrence);
        final override = store.eventOverride(key);
        // One moved by the user is placed below, wherever it went.
        if (override?.date != null) continue;
        place(_task(subscription, occurrence, key, override));
      }
      for (final override in store.eventOverrides) {
        if (override.date == null || override.calendar != subscription.key) continue;
        final occurrence = _locate(subscription, feed, override.id, override.origin);
        if (occurrence != null) {
          place(_task(subscription, occurrence, override.id, override));
        }
      }
    }
    for (final events in byDay.values) {
      events.sort(_compare);
    }
    spans.sort((a, b) {
      final byStart = a.date!.compareTo(b.date!);
      if (byStart != 0) return byStart;
      final byLength = b.event!.lastDay.compareTo(a.event!.lastDay);
      return byLength != 0 ? byLength : _compare(a, b);
    });
    // Rebuilds ask for the same few ranges again and again.
    if (_ranges.length > 16) _ranges.clear();
    return _ranges[(first, last, showHidden)] = RangeEvents(byDay, spans, hidden);
  }

  /// Events without a time first, then by start time, then by title.
  static int _compare(Task a, Task b) {
    final timedA = a.time == null ? 0 : 1, timedB = b.time == null ? 0 : 1;
    if (timedA != timedB) return timedA - timedB;
    if (a.time != null && a.time != b.time) return a.time! - b.time!;
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
  }

  /// Events of shown calendars between [from] and [to] whose title, place,
  /// description or note contains [query], soonest first.
  List<Task> search(String query, {required Day from, required Day to, int limit = 40}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final range = eventsBetween(from, to);
    final all = [...range.spans, for (final events in range.byDay.values) ...events];
    bool matches(Task t) =>
        t.title.toLowerCase().contains(needle) ||
        t.location.toLowerCase().contains(needle) ||
        t.note.toLowerCase().contains(needle) ||
        t.event!.description.toLowerCase().contains(needle);
    final found = all.where(matches).toList()
      ..sort((a, b) {
        final byDay = a.date!.compareTo(b.date!);
        return byDay != 0 ? byDay : _compare(a, b);
      });
    return found.length > limit ? found.sublist(0, limit) : found;
  }

  /// Imported events that carry a reminder set here, of calendars this
  /// device shows.
  List<Task> get eventsWithReminders => [
        for (final override in store.eventsWithReminders)
          if (eventTask('${Task.eventPrefix}${override.id}') case final task?
              when byKey(task.event!.calendar)?.hidden == false)
            task,
      ];

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _status.dispose();
    store.removeListener(_onStore);
    if (store.eventResolver == eventTask) store.eventResolver = null;
    if (_ownsClient) _client.close(force: true);
    super.dispose();
  }
}

class _Status extends ChangeNotifier {
  void changed() => notifyListeners();
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
