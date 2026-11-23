import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A date that comes round every year for one of the user's contacts: a
/// birthday, or another date the contact carries (an anniversary).
class ContactDate {
  const ContactDate({
    required this.name,
    required this.month,
    required this.day,
    this.year,
    this.label,
  });

  final String name;
  final int month;
  final int day;

  /// The year it first happened; null when the contact does not say.
  final int? year;

  /// What the date is, when it is not a birthday: "Anniversary", or the
  /// name the user gave it.
  final String? label;

  bool get isBirthday => label == null;

  /// How the planner shows it.
  String get title {
    final what = label;
    if (what == null) return "$name's birthday";
    if (what.toLowerCase() == 'anniversary') return "$name's anniversary";
    return '$name: $what';
  }

  @override
  String toString() =>
      '$title ${year ?? '----'}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// The dates of the contacts in a file exported from an address book.
///
/// Two kinds of file are read, the two that Google Contacts exports (and
/// that most address books can write):
///
///  - vCard (`.vcf`): `BDAY`, with or without a year, and the other dates
///    of a contact (`ANNIVERSARY`, or Apple's and Google's labelled
///    `X-ABDATE`);
///  - Google CSV: the `Birthday` column and the `Event N` columns.
class ContactsFile {
  const ContactsFile(this.dates, {required this.contacts, required this.unread});

  /// Every date found, birthdays and others.
  final List<ContactDate> dates;

  /// How many contacts the file holds, with or without a date.
  final int contacts;

  /// Dates that were there but could not be understood.
  final int unread;

  /// Reads [text]. Throws a [FormatException] with a message for the user
  /// when it is neither kind of file.
  static ContactsFile parse(String text) {
    if (text.startsWith('﻿')) text = text.substring(1);
    if (RegExp(r'^\s*BEGIN:VCARD', caseSensitive: false, multiLine: true).hasMatch(text)) {
      return _vcards(text);
    }
    final rows = _csvRows(text);
    if (rows.isNotEmpty && rows.first.any((cell) => cell.trim().toLowerCase() == 'birthday')) {
      return _csv(rows);
    }
    throw const FormatException(
      'This is not a contacts file. Export your contacts as vCard (.vcf) or as '
      'Google CSV and choose that file.',
    );
  }

  // ------------------------------------------------------------------ dates

  static final _noYear = RegExp(r'^--(\d\d)-?(\d\d)$');
  static final _full = RegExp(r'^(\d{4})-?(\d\d)-?(\d\d)$');
  static const _lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  static bool _leap(int year) => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

  /// A date as contacts files write it: `1990-05-17`, `19900517`, or
  /// without a year `--05-17`, `--0517`. Address books that cannot leave
  /// the year out write an impossible one (1604 is Apple's), which
  /// [omitYear] may name; such a year counts as none.
  static ({int? year, int month, int day})? _date(String value, {int? omitYear}) {
    var text = value.trim();
    final time = text.indexOf('T');
    if (time > 0) text = text.substring(0, time);
    int? year;
    final int month, day;
    final bare = _noYear.firstMatch(text);
    if (bare != null) {
      month = int.parse(bare[1]!);
      day = int.parse(bare[2]!);
    } else {
      final full = _full.firstMatch(text);
      if (full == null) return null;
      year = int.parse(full[1]!);
      month = int.parse(full[2]!);
      day = int.parse(full[3]!);
      if (year == omitYear || year < 1800) year = null;
    }
    if (month < 1 || month > 12 || day < 1 || day > _lengths[month - 1]) return null;
    // A 29 February in a year that had none: the day stands, the year is
    // not to be trusted.
    if (month == 2 && day == 29 && year != null && !_leap(year)) year = null;
    return (year: year, month: month, day: day);
  }

  // ----------------------------------------------------------------- vCard

  static String _unescape(String value) => value.replaceAllMapped(
        RegExp(r'\\([\\,;nN])'),
        (m) => m[1] == 'n' || m[1] == 'N' ? ' ' : m[1]!,
      );

  /// Apple's built-in labels are written `_$!<Anniversary>!$_`.
  static String _label(String value) {
    final builtIn = RegExp(r'^_\$!<(.*)>!\$_$').firstMatch(value.trim());
    return _unescape(builtIn != null ? builtIn[1]! : value).trim();
  }

  static ContactsFile _vcards(String text) {
    // A long line is continued on the next, which then starts with a blank.
    final lines = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      if ((raw.startsWith(' ') || raw.startsWith('\t')) && lines.isNotEmpty) {
        lines[lines.length - 1] += raw.substring(1);
      } else {
        lines.add(raw);
      }
    }

    final dates = <ContactDate>[];
    var contacts = 0, unread = 0;
    String? fn, n, org;
    // (label, value, year standing for none)
    var found = <(String?, String, int?)>[];
    var groupDates = <String, String>{};
    var groupLabels = <String, String>{};
    var inside = false;

    for (final line in lines) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final head = line.substring(0, colon).split(';');
      final value = line.substring(colon + 1);
      var name = head.first.trim().toUpperCase();
      String? group;
      final dot = name.indexOf('.');
      if (dot > 0) {
        group = name.substring(0, dot);
        name = name.substring(dot + 1);
      }
      if (name == 'BEGIN' && value.trim().toUpperCase() == 'VCARD') {
        inside = true;
        fn = n = org = null;
        found = [];
        groupDates = {};
        groupLabels = {};
        continue;
      }
      if (!inside) continue;
      switch (name) {
        case 'FN':
          fn = _unescape(value).trim();
        case 'N':
          // Family; given; additional; prefix; suffix.
          final parts = value.split(RegExp(r'(?<!\\);')).map(_unescape).toList();
          String part(int i) => i < parts.length ? parts[i].trim() : '';
          n = [part(1), part(2), part(0)].where((p) => p.isNotEmpty).join(' ');
        case 'ORG':
          org = _unescape(value.split(RegExp(r'(?<!\\);')).first).trim();
        case 'BDAY':
          int? omit;
          for (final param in head.skip(1)) {
            final match = RegExp(r'^X-APPLE-OMIT-YEAR=(\d+)$', caseSensitive: false)
                .firstMatch(param.trim());
            if (match != null) omit = int.parse(match[1]!);
          }
          found.add((null, value, omit ?? 1604));
        case 'ANNIVERSARY' || 'X-ANNIVERSARY' || 'X-EVOLUTION-ANNIVERSARY':
          found.add(('Anniversary', value, 1604));
        case 'X-ABDATE':
          if (group != null) groupDates[group] = value;
        case 'X-ABLABEL':
          if (group != null) groupLabels[group] = _label(value);
        case 'END':
          inside = false;
          contacts++;
          final who = [fn, n, org].firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
          for (final entry in groupDates.entries) {
            final label = groupLabels[entry.key];
            found.add((label == null || label.isEmpty ? 'Date' : label, entry.value, 1604));
          }
          for (final (label, written, omit) in found) {
            final date = _date(written, omitYear: omit);
            if (date == null || who == null) {
              unread++;
              continue;
            }
            dates.add(ContactDate(
              name: who,
              month: date.month,
              day: date.day,
              year: date.year,
              label: label,
            ));
          }
      }
    }
    return ContactsFile(dates, contacts: contacts, unread: unread);
  }

  // ------------------------------------------------------------------- CSV

  /// The rows of a CSV file: fields in quotes may hold commas, line breaks
  /// and doubled quotes.
  static List<List<String>> _csvRows(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false, any = false;
    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      if (any) rows.add(row);
      row = <String>[];
      any = false;
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        quoted = true;
        any = true;
      } else if (c == ',') {
        endField();
        any = true;
      } else if (c == '\n') {
        endRow();
      } else if (c != '\r') {
        field.write(c);
        any = true;
      }
    }
    if (any || field.isNotEmpty) endRow();
    return rows;
  }

  static ContactsFile _csv(List<List<String>> rows) {
    final header = [for (final cell in rows.first) cell.trim().toLowerCase()];
    int column(String name) => header.indexOf(name);
    String cell(List<String> row, List<String> names) {
      for (final name in names) {
        final at = column(name);
        if (at >= 0 && at < row.length && row[at].trim().isNotEmpty) return row[at].trim();
      }
      return '';
    }

    final dates = <ContactDate>[];
    var contacts = 0, unread = 0;
    for (final row in rows.skip(1)) {
      contacts++;
      var who = cell(row, ['name']);
      if (who.isEmpty) {
        who = [
          cell(row, ['first name', 'given name']),
          cell(row, ['middle name', 'additional name']),
          cell(row, ['last name', 'family name']),
        ].where((p) => p.isNotEmpty).join(' ');
      }
      if (who.isEmpty) {
        who = cell(row, ['organization name', 'organization 1 - name', 'nickname']);
      }
      final found = <(String?, String)>[];
      final birthday = cell(row, ['birthday']);
      if (birthday.isNotEmpty) found.add((null, birthday));
      for (var i = 1; column('event $i - value') >= 0; i++) {
        final value = cell(row, ['event $i - value']);
        if (value.isEmpty) continue;
        // An older export marks the first type of a kind with "* ".
        final label = cell(row, ['event $i - label', 'event $i - type'])
            .replaceFirst(RegExp(r'^\*\s*'), '');
        found.add((label.isEmpty ? 'Date' : label, value));
      }
      for (final (label, written) in found) {
        final date = _date(written, omitYear: 1604);
        if (date == null || who.isEmpty) {
          unread++;
          continue;
        }
        dates.add(ContactDate(
          name: who,
          month: date.month,
          day: date.day,
          year: date.year,
          label: label,
        ));
      }
    }
    return ContactsFile(dates, contacts: contacts, unread: unread);
  }
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December', //
];

String _two(int n) => n.toString().padLeft(2, '0');

String _escape(String text) => text
    .replaceAll('\\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\n', r'\n');

/// The dates of contacts as a calendar in iCalendar form, which the planner
/// reads like any calendar it subscribes to: every date an all-day event
/// that comes round each year.
///
/// The same contact's date gets the same identifier whenever the file is
/// read, also when the date itself was corrected, so that what the user
/// changed about it in the planner stays with it.
String birthdaysCalendar(List<ContactDate> dates, {String name = 'Birthdays'}) {
  final sorted = [...dates]..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      final byLabel = (a.label ?? '').compareTo(b.label ?? '');
      if (byLabel != 0) return byLabel;
      return (a.month * 100 + a.day).compareTo(b.month * 100 + b.day);
    });
  final seen = <String, int>{};
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//fweek//Contacts//EN',
    'X-WR-CALNAME:${_escape(name)}',
  ];
  for (final date in sorted) {
    final who = '${date.name.toLowerCase()}\n${(date.label ?? '').toLowerCase()}';
    final nth = seen.update(who, (n) => n + 1, ifAbsent: () => 0);
    final id = sha256.convert(utf8.encode('$who\n$nth')).toString().substring(0, 24);
    // Occurrences before this century are of no use to a planner, and a
    // rule that starts later is quicker to follow; the year itself is told
    // in the description.
    final year = date.year;
    final start = year != null && year > 2000 ? year : 2000;
    final leapDay = date.month == 2 && date.day == 29;
    final said = '${date.day} ${_months[date.month - 1]}';
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:$id@contacts.fweek',
      'DTSTART;VALUE=DATE:$start${_two(date.month)}${_two(date.day)}',
      // Born on a 29 February: the last day of February in other years.
      leapDay ? 'RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1' : 'RRULE:FREQ=YEARLY',
      'SUMMARY:${_escape(date.title)}',
      if (year != null)
        'DESCRIPTION:${_escape(date.isBirthday ? 'Born $said $year' : '$said $year')}',
      'TRANSP:TRANSPARENT',
      'END:VEVENT',
    ]);
  }
  lines.addAll(['END:VCALENDAR', '']);
  return lines.join('\r\n');
}
