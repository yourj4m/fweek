import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fweek/sync/google_drive.dart';
import 'package:fweek/sync/secrets.dart';
import 'package:fweek/sync/storage.dart';
import 'package:fweek/sync/sync_service.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

import 'harness.dart';

/// Settings → Sync with Google Drive: the choice of place, connecting a
/// Google account through the browser, and what the section then shows.
void main() {
  setUpAll(loadFonts);

  final drive = MemoryStorage();
  late List<String> opened;
  late Completer<GoogleAccount> signedIn;

  SyncService service(MemorySecretStore secrets) => SyncService(
        seededStore(),
        secrets,
        storageFor: (config, secret) => drive,
        revokeGoogleAccess: (_) async {},
        googleSignIn: ({required open, cancel}) async {
          await open('https://accounts.google.com/o/oauth2/v2/auth?test');
          cancel?.then((_) {
            if (!signedIn.isCompleted) {
              signedIn.completeError(
                  const GoogleSignInException('cancelled', cancelled: true));
            }
          });
          return signedIn.future;
        },
      );

  // Made inside each test: a widget test runs in a time of its own, and a
  // completer made outside it would finish where the test never looks.
  void fresh() {
    opened = [];
    signedIn = Completer();
  }

  desktopTest('Google Drive is offered beside Nextcloud and connects through the browser',
      (tester) async {
    fresh();
    final secrets = MemorySecretStore();
    final sync = service(secrets);
    await pumpApp(tester, sync.store, sync: sync, opener: recordingOpener(opened));
    await openSettings(tester, 'Sync');
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Nextcloud'), findsOneWidget);
    expect(find.text('Connect Google account'), findsOneWidget);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/settings_sync_google.png'));

    // Nextcloud's form is a tap away.
    await tester.tap(find.text('Nextcloud'));
    await tester.pumpAndSettle();
    expect(find.text('App password'), findsOneWidget);
    await tester.tap(find.text('Google Drive'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect Google account'));
    await tester.pumpAndSettle();
    expect(opened.single, startsWith('https://accounts.google.com/'));
    expect(find.text('Waiting for Google…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    signedIn.complete(const GoogleAccount(email: 'ada@example.org', refreshToken: 'refresh-1'));
    await tester.pumpAndSettle();
    expect(find.text('ada@example.org on Google Drive'), findsOneWidget);
    expect(find.text('Synced just now.'), findsOneWidget);
    expect(find.textContaining('Delete hidden app data'), findsOneWidget);
    expect(secrets.values['google-refresh-token'], 'refresh-1');
    expect(drive.files, isNotEmpty);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_sync_google_on.png'));

    // The list of sections says where the planner syncs.
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(sync.configured, isFalse);
    expect(secrets.values, isEmpty);
    expect(find.text('Connect Google account'), findsOneWidget);
    sync.dispose();
  });

  desktopTest('waiting for the browser can be cancelled', (tester) async {
    fresh();
    final sync = service(MemorySecretStore());
    await pumpApp(tester, sync.store, sync: sync, opener: recordingOpener(opened));
    await openSettings(tester, 'Sync');
    await tester.tap(find.text('Connect Google account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Google account'), findsOneWidget);
    expect(sync.configured, isFalse);
    sync.dispose();
  });

  phoneTest('on a phone the section names the connected account', (tester) async {
    fresh();
    final sync = service(MemorySecretStore());
    await pumpApp(tester, sync.store,
        sync: sync, opener: recordingOpener(opened), size: const Size(411, 914));
    await openSettings(tester, 'Sync');
    await tester.tap(find.text('Connect Google account'));
    await tester.pumpAndSettle();
    signedIn.complete(const GoogleAccount(email: 'ada@example.org', refreshToken: 'r'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('All settings'));
    await tester.pumpAndSettle();
    expect(find.text('Google Drive: ada@example.org'), findsOneWidget);
    // Its timers end with it, before the test does.
    sync.dispose();
  });
}
