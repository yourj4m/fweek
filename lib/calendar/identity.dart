import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Short fingerprints that name calendars and their events in synced data.
///
/// What the user changes about an imported event (its colour, a note, the
/// day it was moved to) is synced between devices; the calendar's address
/// and the events themselves are not. A fingerprint lets two devices agree
/// on which calendar or event a change belongs to without either the
/// address or the event's identifier ever being written to the sync folder.
String _fingerprint(String text, int hexLength) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, hexLength);

/// Names a calendar by its address. The address of a private calendar is a
/// long random secret, so it cannot be worked out from this.
String calendarKey(Uri address) {
  // Spelling differences that lead to the same feed give the same key.
  final normal = address.replace(
    scheme: address.scheme.toLowerCase(),
    host: address.host.toLowerCase(),
    fragment: null,
  );
  return _fingerprint('calendar\n${normal.toString().replaceFirst(RegExp(r'#$'), '')}', 20);
}

/// A key for a calendar whose address this device does not have (anymore).
String localCalendarKey(String localId) => _fingerprint('local\n$localId', 20);

final _splitSuffix = RegExp(r'_R\d{8}(?:T\d{6}Z?)?(?=@|$)');

/// The identifier of the series an event belongs to. Google Calendar gives
/// the later part of a series changed with "this and following events" a
/// new identifier: the old one with `_R<date>` added. Without the suffix
/// both parts name the same series, so changes made here to its later
/// occurrences survive such a split.
String seriesUid(String uid) => uid.replaceFirst(_splitSuffix, '');

/// Names one occurrence of one event of one calendar.
///
/// [instance] is empty for an event that happens once; for an occurrence of
/// a repeating event it is the occurrence's original start (see
/// `EventOccurrence.instance`), so the name follows a single event when its
/// calendar moves it, and stays with one occurrence of a series whatever is
/// done to the others.
String eventKey(String calendar, String uid, String instance) =>
    _fingerprint('event\n$calendar\n${seriesUid(uid)}\n$instance', 24);

/// Names an event by what it says, for calendars whose identifiers are not
/// stable (some services issue new ones with every download): the same
/// title at the same start is the same event.
String contentEventKey(String calendar, String title, String start) =>
    _fingerprint('content\n$calendar\n${title.trim().toLowerCase()}\n$start', 24);
