import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/calendar/calendar_service.dart';
import 'package:fweek/calendar/contacts.dart';
import 'package:fweek/calendar/ics.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/export.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_engine.dart';

/// A vCard file as Google Contacts exports it (version 3.0): birthdays with
/// and without a year, a labelled other date, a long line folded.
const googleVcf = '''
BEGIN:VCARD\r
VERSION:3.0\r
FN:Ada Lovelace\r
N:Lovelace;Ada;;;\r
EMAIL;TYPE=INTERNET:ada@example.org\r
BDAY:19901210\r
CATEGORIES:myContacts\r
END:VCARD\r
BEGIN:VCARD\r
VERSION:3.0\r
FN:Grace Hopper\r
N:Hopper;Grace;;;\r
BDAY:--1209\r
item1.X-ABDATE:16040613\r
item1.X-ABLabel:_\$!<Anniversary>!\$_\r
NOTE:A note that is long enough to be folded onto a second line by the progra\r
 m that wrote the file\\, with a comma in it\r
END:VCARD\r
BEGIN:VCARD\r
VERSION:3.0\r
FN:Smith\\, John\r
N:Smith;John;;;\r
TEL;TYPE=CELL:+33 6 00 00 00 00\r
END:VCARD\r
''';

void main() {
  List<String> said(ContactsFile file) => [for (final d in file.dates) d.toString()];

  group('a vCard file', () {
    test('as Google Contacts exports it: years, no years, other dates', () {
      final file = ContactsFile.parse(googleVcf);
      expect(file.contacts, 3);
      expect(file.unread, 0);
      expect(said(file), [
        "Ada Lovelace's birthday 1990-12-10",
        "Grace Hopper's birthday -----12-09",
        "Grace Hopper's anniversary -----06-13",
      ]);
    });

    test('the other ways a date and a name are written', () {
      final file = ContactsFile.parse([
        'BEGIN:VCARD', 'VERSION:4.0', 'FN:Iso Dashes', 'BDAY:1985-03-02', 'ANNIVERSARY:20140614', 'END:VCARD',
        // Apple: a year that stands for none, named beside the date.
        'BEGIN:VCARD', 'FN:Apple Omit', 'BDAY;X-APPLE-OMIT-YEAR=1604:1604-07-04', 'END:VCARD',
        'BEGIN:VCARD', 'FN:Dashes Bare', 'BDAY;VALUE=date:--04-01', 'END:VCARD',
        'BEGIN:VCARD', 'FN:With Time', 'BDAY:1970-01-31T00:00:00Z', 'END:VCARD',
        // No FN: the parts of N, given name first; then the organisation.
        'BEGIN:VCARD', 'N:Curie;Marie;Salomea;;', 'BDAY:18671107', 'END:VCARD',
        'BEGIN:VCARD', 'ORG:The Bakery;Front desk', 'BDAY:--1001', 'END:VCARD',
        // A label of the user's own, and lower-case property names.
        'BEGIN:VCARD', 'fn:Own Label', 'item2.x-abdate:2019-09-01', 'item2.x-ablabel:Moved in', 'END:VCARD',
        // 29 February in a year that had none: the day, without the year.
        'BEGIN:VCARD', 'FN:Leap Wrong', 'BDAY:19850229', 'END:VCARD',
        'BEGIN:VCARD', 'FN:Leap Right', 'BDAY:19960229', 'END:VCARD',
        // Not dates; and a date without anybody.
        'BEGIN:VCARD', 'FN:Bad One', 'BDAY:sometime in May', 'END:VCARD',
        'BEGIN:VCARD', 'FN:Bad Two', 'BDAY:19901345', 'END:VCARD',
        'BEGIN:VCARD', 'BDAY:19900101', 'END:VCARD',
      ].join('\n'));
      expect(said(file), [
        "Iso Dashes's birthday 1985-03-02",
        "Iso Dashes's anniversary 2014-06-14",
        "Apple Omit's birthday -----07-04",
        "Dashes Bare's birthday -----04-01",
        "With Time's birthday 1970-01-31",
        "Marie Salomea Curie's birthday 1867-11-07",
        "The Bakery's birthday -----10-01",
        'Own Label: Moved in 2019-09-01',
        "Leap Wrong's birthday -----02-29",
        "Leap Right's birthday 1996-02-29",
      ]);
      expect(file.contacts, 12);
      expect(file.unread, 3);
    });
  });

  group('a Google CSV file', () {
    test('the columns of today: first and last name, Birthday, Event N', () {
      final file = ContactsFile.parse([
        'First Name,Middle Name,Last Name,Nickname,Organization Name,Birthday,Notes,Labels,'
            'E-mail 1 - Label,E-mail 1 - Value,Event 1 - Label,Event 1 - Value',
        'Ada,,Lovelace,,,1990-12-10,"She wrote, among other things,\nthe first program",* myContacts,,ada@example.org,,',
        'Grace,B.,Hopper,,, --12-09,,* myContacts,,,Anniversary,2010-06-13',
        ',,,,The Bakery,--10-01,,,,,,',
        'No,,Date,,,,,,,,,',
        '"Smith, John",,"O""Neil",,,19800105,,,,,,',
      ].join('\r\n'));
      expect(file.contacts, 5);
      expect(said(file), [
        "Ada Lovelace's birthday 1990-12-10",
        "Grace B. Hopper's birthday -----12-09",
        "Grace B. Hopper's anniversary 2010-06-13",
        "The Bakery's birthday -----10-01",
        'Smith, John O"Neil\'s birthday 1980-01-05',
      ]);
    });

    test('the columns of before 2024: Name, Event N - Type', () {
      final file = ContactsFile.parse('﻿${[
        'Name,Given Name,Additional Name,Family Name,Birthday,Event 1 - Type,Event 1 - Value',
        'Ada Lovelace,Ada,,Lovelace,1990-12-10,* Anniversary,2010-01-01',
        ',Grace,,Hopper,--12-09,,',
      ].join('\n')}');
      expect(said(file), [
        "Ada Lovelace's birthday 1990-12-10",
        "Ada Lovelace's anniversary 2010-01-01",
        "Grace Hopper's birthday -----12-09",
      ]);
    });
  });

  test('anything else is turned away with a word on what to export', () {
    for (final text in ['', 'Name,Phone\nAda,123', 'BEGIN:VCALENDAR\nEND:VCALENDAR', '{"a": 1}']) {
      expect(
        () => ContactsFile.parse(text),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('vCard'))),
        reason: text,
      );
    }
  });

  group('the calendar made of the dates', () {
    List<String> on(IcsCalendar calendar, Day first, Day last) => [
          for (final o in calendar.occurrencesBetween(first, last))
            '${o.day.iso} ${o.title}${o.allDay ? '' : ' (timed)'}',
        ]..sort();

    test('every date is an all-day event that comes round each year', () {
      final calendar = IcsCalendar.parse(birthdaysCalendar(ContactsFile.parse(googleVcf).dates));
      expect(calendar.name, 'Birthdays');
      expect(calendar.eventCount, 3);
      expect(on(calendar, Day(2026, 1, 1), Day(2027, 12, 31)), [
        "2026-06-13 Grace Hopper's anniversary",
        "2026-12-09 Grace Hopper's birthday",
        "2026-12-10 Ada Lovelace's birthday",
        "2027-06-13 Grace Hopper's anniversary",
        "2027-12-09 Grace Hopper's birthday",
        "2027-12-10 Ada Lovelace's birthday",
      ]);
      // The year is told in the note; without one there is none.
      final ada = calendar.occurrencesBetween(Day(2026, 12, 10), Day(2026, 12, 10)).single;
      expect(ada.description, 'Born 10 December 1990');
      expect(calendar.occurrencesBetween(Day(2026, 12, 9), Day(2026, 12, 9)).single.description,
          isEmpty);
    });

    test('a 29 February is kept on the last day of February in other years', () {
      final calendar = IcsCalendar.parse(birthdaysCalendar(const [
        ContactDate(name: 'Leap', month: 2, day: 29, year: 1996),
        ContactDate(name: 'Leapless', month: 2, day: 29),
      ]));
      expect(on(calendar, Day(2026, 1, 1), Day(2028, 12, 31)), [
        "2026-02-28 Leap's birthday",
        "2026-02-28 Leapless's birthday",
        "2027-02-28 Leap's birthday",
        "2027-02-28 Leapless's birthday",
        "2028-02-29 Leap's birthday",
        "2028-02-29 Leapless's birthday",
      ]);
    });

    test('nobody born this century has a birthday before being born', () {
      final calendar = IcsCalendar.parse(birthdaysCalendar(const [
        ContactDate(name: 'Kid', month: 3, day: 3, year: 2027),
      ]));
      expect(on(calendar, Day(2026, 1, 1), Day(2028, 12, 31)),
          ["2027-03-03 Kid's birthday", "2028-03-03 Kid's birthday"]);
    });

    test('a date keeps its identifier when it is corrected or the file is reordered', () {
      Set<String> uids(List<ContactDate> dates) => IcsCalendar.parse(birthdaysCalendar(dates)).uids;
      const ada = ContactDate(name: 'Ada Lovelace', month: 12, day: 10, year: 1990);
      const grace = ContactDate(name: 'Grace Hopper', month: 12, day: 9);
      const fixed = ContactDate(name: 'Ada Lovelace', month: 12, day: 11, year: 1815);
      expect(uids([ada, grace]), uids([grace, fixed]));
      // Two people of one name are two events; a birthday and an
      // anniversary of one person too.
      expect(uids([ada, ada, grace]), hasLength(3));
      expect(
          uids([ada, const ContactDate(name: 'Ada Lovelace', month: 12, day: 10, label: 'Anniversary')]),
          hasLength(2));
      // Names with what a calendar file gives a meaning to.
      final odd = IcsCalendar.parse(birthdaysCalendar(const [
        ContactDate(name: r'Smith, John; "Jr" \ co', month: 1, day: 5),
      ]));
      expect(odd.occurrencesBetween(Day(2026, 1, 5), Day(2026, 1, 5)).single.title,
          r'''Smith, John; "Jr" \ co's birthday''');
    });
  });

  group('the Birthdays calendar', () {
    final december = (Day(2026, 12, 1), Day(2026, 12, 31));
    late PlannerDatabase db;
    late PlannerStore store;
    late MemorySecretStore secrets;
    late MemoryCalendarCache cache;
    late Directory folder;
    var now = DateTime(2026, 11, 23, 12);

    CalendarService service() {
      final s = CalendarService(store, secrets, cache, clock: () => now);
      addTearDown(s.dispose);
      return s;
    }

    List<String> titles(CalendarService s) => [
          for (final day in s.eventsBetween(december.$1, december.$2).byDay.entries)
            for (final event in day.value) '${day.key.iso} ${event.title}',
        ]..sort();

    setUp(() {
      db = PlannerDatabase.inMemory();
      store = PlannerStore(db, today: () => Day(2026, 11, 23));
      secrets = MemorySecretStore();
      cache = MemoryCalendarCache();
      folder = Directory.systemTemp.createTempSync('fweek-contacts-');
      now = DateTime(2026, 11, 23, 12);
    });
    tearDown(() {
      db.close();
      folder.deleteSync(recursive: true);
    });

    test('a contacts file makes it; the same or a newer file fills it anew', () async {
      final s = service();
      expect(s.birthdays, isNull);
      expect(await s.setBirthdays(text: googleVcf, file: 'contacts.vcf'), isNull);
      final calendar = s.subscriptions.single;
      expect(s.birthdays, same(calendar));
      expect((calendar.name, calendar.events, calendar.contacts!.file, calendar.key),
          ('Birthdays', 3, 'contacts.vcf', CalendarService.birthdaysKey));
      expect(titles(s), ["2026-12-09 Grace Hopper's birthday", "2026-12-10 Ada Lovelace's birthday"]);
      // They are events like those of any calendar: all day, not ticked.
      final event = s.eventsBetween(december.$1, december.$2).on(Day(2026, 12, 10)).single;
      expect((event.fromCalendar, event.time, event.checkable), (true, null, false));
      expect(event.note, 'Born 10 December 1990');

      // Read again with one more contact: one calendar still, three dates
      // in December.
      final more = googleVcf.replaceFirst(
          'BEGIN:VCARD', 'BEGIN:VCARD\r\nFN:Alan Turing\r\nBDAY:19121223\r\nEND:VCARD\r\nBEGIN:VCARD');
      expect(await s.setBirthdays(text: more, file: 'contacts (1).vcf'), isNull);
      expect(s.subscriptions, hasLength(1));
      expect(s.subscriptions.single.events, 4);
      expect(titles(s), contains("2026-12-23 Alan Turing's birthday"));

      // After a restart they are there without the file.
      final again = service();
      await again.load();
      expect(again.birthdays!.contacts!.file, 'contacts (1).vcf');
      expect(titles(again), hasLength(3));
    });

    test('a file without birthdays, or of another kind, changes nothing and says why', () async {
      final s = service();
      expect(await s.setBirthdays(text: 'BEGIN:VCARD\nFN:Nobody Dated\nEND:VCARD', file: 'a.vcf'),
          'None of the 1 contacts in a.vcf has a birthday.');
      expect(await s.setBirthdays(text: 'hello', file: 'b.txt'), contains('not a contacts file'));
      expect(s.subscriptions, isEmpty);
      await s.setBirthdays(text: googleVcf, file: 'contacts.vcf');
      expect(await s.setBirthdays(text: 'hello', file: 'b.txt'), isNotNull);
      expect(s.subscriptions.single.events, 3);
    });

    test('what the user arranges is shared; the contacts and their dates stay on the device',
        () async {
      store.addTask(DaySlot(Day(2026, 12, 10)), 'Buy a present');
      final s = service();
      await s.setBirthdays(text: googleVcf, file: 'contacts.vcf', path: '/home/me/contacts.vcf');
      s.setColor(s.birthdays!.id, 'green');
      final event = s.eventsBetween(december.$1, december.$2).on(Day(2026, 12, 10)).single;
      store.updateTask(event.id, note: 'Call in the evening');

      final account = MemoryStorage();
      await SyncEngine(store, account, folder: 'fweek').sync();
      final outgoing = [
        for (final bytes in account.files.values) utf8.decode(bytes),
        account.files.keys.join('\n'),
        Export.backup(store),
        Export.csv(store),
        Export.ics(store),
        Export.text(store),
        jsonEncode([for (final c in db.changesSince(null)) c.toJson()]),
      ].join('\n');
      expect(outgoing, contains('Buy a present'));
      expect(outgoing, contains('Call in the evening'));
      for (final private in ['Lovelace', 'Hopper', 'ada@example.org', '1990', 'contacts.vcf', '/home/me']) {
        expect(outgoing, isNot(contains(private)), reason: '"$private" must stay on the device');
      }
      // Nothing is put into the keyring either: there is no address.
      expect(secrets.values, isEmpty);

      // Another device learns that there is such a calendar, how it is
      // named and coloured, and that it has to read a file of its own.
      final otherDb = PlannerDatabase.inMemory();
      addTearDown(otherDb.close);
      final other = PlannerStore(otherDb, today: () => Day(2026, 11, 23));
      await SyncEngine(other, account, folder: 'fweek').sync();
      final there = CalendarService(other, MemorySecretStore(), MemoryCalendarCache());
      addTearDown(there.dispose);
      await there.load();
      expect(there.subscriptions, isEmpty);
      expect([for (final row in there.elsewhere) (row.id, row.name, row.color)],
          [(CalendarService.birthdaysKey, 'Birthdays', 'green')]);
      // Once it has, the calendar takes the shared colour, and the note on
      // Ada's birthday is there.
      await there.setBirthdays(text: googleVcf, file: 'export.vcf');
      expect(there.birthdays!.color, 'green');
      expect(there.elsewhere, isEmpty);
      expect(
          there.eventsBetween(december.$1, december.$2).on(Day(2026, 12, 10)).single.note,
          'Call in the evening');
    });

    test('with the calendars, the file is read again from where it was, if it changed', () async {
      final file = File('${folder.path}/contacts.vcf')
        ..writeAsStringSync(googleVcf)
        ..setLastModifiedSync(DateTime(2026, 11, 23, 9));
      final s = service();
      await s.setBirthdays(text: googleVcf, file: 'contacts.vcf', path: file.path);
      expect(s.birthdays!.events, 3);

      // Unchanged: nothing happens.
      now = now.add(const Duration(hours: 1));
      await s.refresh();
      expect(s.birthdays!.fetched, DateTime(2026, 11, 23, 12));

      // A new export saved over it.
      file.writeAsStringSync(
          '${googleVcf}BEGIN:VCARD\r\nFN:Alan Turing\r\nBDAY:19121223\r\nEND:VCARD\r\n');
      file.setLastModifiedSync(now.add(const Duration(minutes: 5)));
      now = now.add(const Duration(hours: 1));
      await s.refresh();
      expect(s.birthdays!.events, 4);
      expect(s.birthdays!.error, isNull);
      expect(titles(s), contains("2026-12-23 Alan Turing's birthday"));

      // The file turned into something else: the dates stay, and it is said.
      file.writeAsStringSync('not contacts any more');
      file.setLastModifiedSync(now.add(const Duration(minutes: 5)));
      now = now.add(const Duration(hours: 1));
      await s.refresh();
      expect(s.birthdays!.events, 4);
      expect(s.birthdays!.error, contains('not a contacts file'));

      // The file gone: no complaint, the dates stay.
      file.deleteSync();
      await s.refresh();
      expect(titles(s), hasLength(3));

      // Removed like any calendar.
      await s.remove(s.birthdays!.id);
      expect(s.subscriptions, isEmpty);
      expect(titles(s), isEmpty);
      expect(cache.feeds, isEmpty);
    });
  });
}
