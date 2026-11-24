import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/data/database.dart';
import 'package:fweek/data/day.dart';
import 'package:fweek/data/models.dart';
import 'package:fweek/data/planner_store.dart';
import 'package:fweek/sync/google_drive.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_service.dart';

import 'fake_google.dart';

/// Google Drive as a place to sync: signing in, the app's hidden folder as
/// storage, and the sync service on top, all against a stand-in for Google
/// on this machine (see fake_google.dart).
void main() {
  const client = GoogleClient(id: FakeGoogle.clientId, secret: FakeGoogle.clientSecret);
  late FakeGoogle google;
  late GoogleEndpoints at;

  setUp(() async {
    google = await FakeGoogle.start();
    at = GoogleEndpoints.at(google.base);
  });
  tearDown(() => google.close());

  Future<GoogleAccount> signIn(String email) {
    google.nextAccount = email;
    return signInWithGoogle(client: client, open: fakeBrowser, endpoints: at);
  }

  DriveStorage storageOf(GoogleAccount account) {
    final storage = DriveStorage(client: client, refreshToken: account.refreshToken, endpoints: at);
    addTearDown(storage.close);
    return storage;
  }

  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  group('signing in', () {
    test('asks Google for the account and the app\'s own Drive folder, nothing more', () async {
      final account = await signIn('ada@example.org');
      expect(account.email, 'ada@example.org');
      expect(account.refreshToken, isNotEmpty);
      expect(account.access, isNotNull);
      expect(google.askedScopes, unorderedEquals(
          ['openid', 'email', 'https://www.googleapis.com/auth/drive.appdata']));
      final asked = google.requests.firstWhere((r) => r.contains('/o/oauth2/v2/auth'));
      final query = Uri.parse(asked.split(' ').last).queryParameters;
      // A one-time secret only this sign-in knows, and a way back to this
      // device only.
      expect(query['code_challenge_method'], 'S256');
      expect(query['code_challenge'], isNotEmpty);
      expect(query['state'], isNotEmpty);
      expect(Uri.parse(query['redirect_uri']!).host, '127.0.0.1');
      expect(query['access_type'], 'offline');
    });

    test('declined on Google\'s page: no account, and a message', () async {
      google.decline = true;
      await expectLater(
        signIn('ada@example.org'),
        throwsA(isA<GoogleSignInException>()
            .having((e) => e.message, 'message', contains('declined'))),
      );
    });

    test('the Drive permission unticked on Google\'s page: said what to tick', () async {
      google.untickDrive = true;
      await expectLater(
        signIn('ada@example.org'),
        throwsA(isA<GoogleSignInException>()
            .having((e) => e.message, 'message', contains('tick'))),
      );
    });

    test('can be cancelled while waiting for the browser', () async {
      final cancel = Completer<void>();
      final signing = signInWithGoogle(
        client: client,
        endpoints: at,
        // A browser that never comes back.
        open: (address) async => true,
        cancel: cancel.future,
      );
      cancel.complete();
      await expectLater(
        signing,
        throwsA(isA<GoogleSignInException>().having((e) => e.cancelled, 'cancelled', isTrue)),
      );
    });
  });

  group('the app\'s Drive folder as storage', () {
    test('writes, lists, reads, replaces and removes files, over several pages', () async {
      final drive = storageOf(await signIn('ada@example.org'));
      await drive.createDir('fweek/changes');
      for (var i = 1; i <= 7; i++) {
        await drive.write('fweek/changes/aaaaaaaa-0000000$i.json', bytes('change $i'));
      }
      await drive.write('fweek/other/x.json', bytes('elsewhere'));
      expect(await drive.list('fweek/changes'), [
        for (var i = 1; i <= 7; i++) 'aaaaaaaa-0000000$i.json',
      ]);
      expect(utf8.decode((await drive.read('fweek/changes/aaaaaaaa-00000003.json'))!), 'change 3');
      expect(await drive.read('fweek/changes/missing.json'), isNull);
      expect(await drive.list('nothing/here'), isEmpty);

      // Never two files of one name: a second write is refused unless it
      // is to replace the first.
      await expectLater(
        drive.write('fweek/changes/aaaaaaaa-00000001.json', bytes('again')),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.exists)),
      );
      await drive.write('fweek/changes/aaaaaaaa-00000001.json', bytes('replaced'), overwrite: true);
      expect(utf8.decode((await drive.read('fweek/changes/aaaaaaaa-00000001.json'))!), 'replaced');
      expect(google.filesOf('ada@example.org').where((n) => n.endsWith('-00000001.json')), hasLength(1));

      await drive.delete('fweek/changes/aaaaaaaa-00000002.json');
      await drive.delete('fweek/changes/never-there.json');
      expect(await drive.list('fweek/changes'), isNot(contains('aaaaaaaa-00000002.json')));
      expect(await drive.read('fweek/changes/aaaaaaaa-00000002.json'), isNull);
    });

    test('each Google account has a folder of its own', () async {
      final ada = storageOf(await signIn('ada@example.org'));
      final bob = storageOf(await signIn('bob@example.org'));
      await ada.write('fweek/changes/aaaaaaaa-00000001.json', bytes('ada\'s'));
      expect(await bob.list('fweek/changes'), isEmpty);
      expect(await bob.read('fweek/changes/aaaaaaaa-00000001.json'), isNull);
      expect(google.filesOf('bob@example.org'), isEmpty);
      expect(google.filesOf('ada@example.org'), ['fweek/changes/aaaaaaaa-00000001.json']);
    });

    test('an expired access token is renewed without anyone noticing', () async {
      final drive = storageOf(await signIn('ada@example.org'));
      await drive.write('fweek/a.json', bytes('1'));
      google.expireAccess();
      expect(utf8.decode((await drive.read('fweek/a.json'))!), '1');
    });

    test('access withdrawn in the Google account: a clear message, no retrying', () async {
      final account = await signIn('ada@example.org');
      final drive = storageOf(account);
      await drive.write('fweek/a.json', bytes('1'));
      google.revokeAll('ada@example.org');
      await expectLater(
        drive.list('fweek'),
        throwsA(isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.unauthorized)
            .having((e) => e.message, 'message', contains('Connect again'))),
      );
    });

    test('Google failing or out of reach is an error, never data lost', () async {
      final drive = storageOf(await signIn('ada@example.org'));
      google.failNext = (request) => request.method == 'POST' && request.uri.path.contains('upload');
      await expectLater(
        drive.write('fweek/a.json', bytes('1')),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.server)),
      );
      await drive.write('fweek/a.json', bytes('1'));
      expect(utf8.decode((await drive.read('fweek/a.json'))!), '1');

      await google.close();
      await expectLater(
        drive.list('fweek'),
        throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.offline)),
      );
    });
  });

  group('syncing through Google Drive', () {
    final today = Day(2026, 11, 13);

    PlannerStore newStore() {
      final db = PlannerDatabase.inMemory();
      addTearDown(db.close);
      return PlannerStore(db, today: () => today)..setSetting(Settings.rollover, false);
    }

    SyncService newService(PlannerStore store, MemorySecretStore secrets, {List<String>? revoked}) {
      final service = SyncService(
        store,
        secrets,
        google: client,
        googleEndpoints: at,
        revokeGoogleAccess: (token) async {
          revoked?.add(token);
          await revokeGoogle(token, endpoints: at);
        },
        afterEdit: const Duration(days: 1),
        interval: const Duration(days: 1),
      );
      addTearDown(service.dispose);
      return service;
    }

    test('two devices of one account share the planner; a second account is apart', () async {
      final laptop = newStore(), phone = newStore(), friend = newStore();
      laptop.addTask(DaySlot(today), 'Written on the laptop');
      final laptopSync = newService(laptop, MemorySecretStore());
      expect(await laptopSync.connectGoogle(await signIn('ada@example.org')), isNull);
      expect(laptopSync.config!.isGoogle, isTrue);
      expect(laptopSync.config!.user, 'ada@example.org');

      // A new phone: connecting is restoring.
      final phoneSync = newService(phone, MemorySecretStore());
      expect(await phoneSync.connectGoogle(await signIn('ada@example.org')), isNull);
      expect(phone.allTasks.map((t) => t.title), contains('Written on the laptop'));

      // Both edit; neither overwrites the other.
      phone.addTask(DaySlot(today), 'Added on the phone');
      laptop.addTask(DaySlot(today), 'Added on the laptop meanwhile');
      await phoneSync.syncNow();
      await laptopSync.syncNow();
      await phoneSync.syncNow();
      for (final store in [laptop, phone]) {
        expect(store.allTasks.map((t) => t.title),
            containsAll(['Added on the phone', 'Added on the laptop meanwhile']));
      }

      // Someone else's account holds none of it.
      final friendSync = newService(friend, MemorySecretStore());
      expect(await friendSync.connectGoogle(await signIn('bob@example.org')), isNull);
      expect(friend.allTasks.map((t) => t.title), isNot(contains('Written on the laptop')));
    });

    test('the connection survives a restart; its token is in the keyring, not the planner',
        () async {
      final store = newStore();
      final secrets = MemorySecretStore();
      final account = await signIn('ada@example.org');
      final first = newService(store, secrets);
      expect(await first.connectGoogle(account), isNull);
      expect(secrets.values.values, contains(account.refreshToken));
      expect(store.db.meta('sync.config'), isNot(contains(account.refreshToken)));
      expect(store.db.meta('sync.config'), isNot(contains('server')),
          reason: 'an earlier build then sees no connection rather than a broken one');

      final again = newService(store, secrets);
      await again.load();
      await again.syncNow();
      expect(again.state, SyncState.idle);
      expect(again.config!.user, 'ada@example.org');
    });

    test('a failed upload leaves the planner as it was and goes up next time', () async {
      final store = newStore();
      final service = newService(store, MemorySecretStore());
      expect(await service.connectGoogle(await signIn('ada@example.org')), isNull);
      store.addTask(DaySlot(today), 'Kept although the upload failed');
      google.failNext = (request) => request.method == 'POST' && request.uri.path.contains('upload');
      await service.syncNow();
      expect(service.state, SyncState.error);
      expect(store.allTasks.map((t) => t.title), contains('Kept although the upload failed'));
      await service.syncNow();
      expect(service.state, SyncState.idle);
      expect(google.filesOf('ada@example.org'), hasLength(2));
    });

    test('disconnecting withdraws the access and leaves the files in Drive', () async {
      final store = newStore();
      final secrets = MemorySecretStore();
      final revoked = <String>[];
      final service = newService(store, secrets, revoked: revoked);
      final account = await signIn('ada@example.org');
      expect(await service.connectGoogle(account), isNull);
      await service.disconnect();
      expect(revoked, [account.refreshToken]);
      expect(google.hasRefreshToken(account.refreshToken), isFalse);
      expect(secrets.values, isEmpty);
      expect(service.configured, isFalse);
      expect(google.filesOf('ada@example.org'), isNotEmpty);

      // Connecting again finds them.
      final other = newStore();
      final again = newService(other, MemorySecretStore());
      store.addTask(DaySlot(today), 'Not synced after disconnecting');
      expect(await again.connectGoogle(await signIn('ada@example.org')), isNull);
      expect(other.allTasks.map((t) => t.title), isNot(contains('Not synced after disconnecting')));
    });

    test('a build without Google sign-in says so instead of failing in silence', () async {
      final store = newStore();
      store.db.setMeta('sync.config', jsonEncode(const SyncConfig.google(account: 'ada@example.org').toJson()));
      final secrets = MemorySecretStore()..values['google-refresh-token'] = 'refresh-x';
      final service = SyncService(store, secrets, google: null);
      addTearDown(service.dispose);
      // No client given and none in this build (tests are built without).
      expect(service.google, isNull);
      await service.load();
      expect(service.state, SyncState.error);
      expect(service.message, contains('cannot sign in to Google'));
    });

    test('a Nextcloud connection saved by an earlier build still reads as one', () {
      final config = SyncConfig.fromJson(
          {'server': 'cloud.example.com', 'user': 'jo', 'folder': 'WeekToDo'})!;
      expect(config.isGoogle, isFalse);
      expect(config.target, startsWith('https://cloud.example.com/'));
      final google = SyncConfig.fromJson(const SyncConfig.google(account: 'a@b.c').toJson())!;
      expect((google.isGoogle, google.user, google.folder), (true, 'a@b.c', 'fweek'));
    });
  });
}
