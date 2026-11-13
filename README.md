# WeekToDo

A minimal weekly planner for Linux (Wayland) and Android. Your week as ruled
columns, a Someday area for undated tasks, and nothing else in the way.

Local-first: everything is stored on your machine and the app works offline.
Optionally it keeps your devices in step through a folder in your own
Nextcloud, with no other server involved.

This is a personal project. It shares its name with, but is unrelated to, the
open-source WeekToDo planner at weektodo.me; it would need a different name
before being published.

## Status

Test builds for Linux and Android, from the same code. What works:

- **Week view**: five weekday columns plus a stacked weekend, ten ruled rows
  that grow with your tasks; a single-column layout below 1024 px.
- **Tasks**: click an empty row and type, Enter for the next one. Click a task
  to open it. Check to complete. Drag between days and lists, or hold a task
  at the window edge to carry it to another week.
- **Task card**: title, notes, subtasks (with section titles, stars and one
  level of indent), highlight colour including your own hex colours, time,
  date, repeat (presets and a custom editor), reminder, move, copy, delete.
- **Repeating tasks**: completing, moving or deleting one occurrence leaves
  the rest of the series alone; text and colour edits apply to the series.
- **Someday lists**: any number of named lists below the week.
- **Month view**, **search** with colour filters, seven **themes** including
  dark and follow-the-system.
- **Settings**: week start, 12/24-hour time, move unfinished tasks to today,
  sort or hide completed tasks.
- **Sync** through Nextcloud (Settings → Sync): on start, every five minutes,
  a few seconds after you stop editing, and on request.
- **Calendars**: subscribe to a calendar's iCal address (for example Google
  Calendar's "secret address") and its events appear in your week,
  read-only. See [Calendars](#calendars).
- **Export** to CSV, iCalendar and plain text; **backup and restore** as JSON.
- **Shortcuts**: ← → previous/next, T today, M month view, Ctrl+F search,
  Ctrl+, settings, Esc close.

- **Android** (13 and newer): the single-column layout with larger rows, a
  swipe to turn the week, a long press to pick a task up, reminders that
  fire while the app is closed. See [Android](#android).

Not there yet:

- On Linux, reminders are delivered only while the app is running.
- On Android: no home-screen widget, no sync while the app is closed.
- Notes are plain text.
- Reordering subtasks by drag, selecting several tasks at once, undo, print.
- Changing calendar events or sending tasks to a calendar (calendars are read-only).
- Attachments and sharing are out of scope for now.
- English only.

## Run it

```sh
tools/setup-dev.sh                         # once: build container + Flutter SDK
tools/dev flutter build linux --release    # build
build/linux/x64/release/bundle/weektodo    # run
tools/install-local.sh                     # optional: add to the application menu
```

`tools/setup-dev.sh` needs Fedora's `toolbox` and installs nothing on the host:
the compiler and GTK headers live in a container, and the Flutter SDK is
downloaded into `.tools/`. The built app runs directly on the host and needs
only GTK 3.

Your planner is stored in `~/.local/share/io.github.yourj4m.weektodo/planner.db`.
Set `WEEKTODO_DATA_DIR=/some/folder` to try the app against a different,
throwaway folder.

## Android

```sh
tools/setup-dev.sh                 # once, if not done for Linux already
tools/setup-android.sh             # once: JDK + Android SDK, into the container and .tools/
tools/android-build.sh             # signed APK for a 64-bit ARM phone
tools/android-build.sh --install   # ... and install it over USB
```

The APK lands in `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`;
copying that file to the phone and opening it installs it as well. It is
signed with a key of your own that `tools/android-build.sh` creates on first
use in `~/.config/weektodo/`. Android only updates an app with a build signed
by the same key, so keep that folder.

What to expect on the phone:

- **No Google services** are used; it runs on LineageOS without them.
- **Battery**: nothing runs in the background. Reminders are handed to
  Android's alarm service ahead of time and cost nothing until they fire;
  they also survive a restart of the phone. Sync happens when you open the
  app, when you come back to it, a few seconds after an edit, and as you
  leave it. The price: a change made on another device reaches the phone
  when you next open the app, and a reminder set elsewhere is scheduled
  from that moment on.
- **Permissions**: network (sync), notifications (asked when you set your
  first reminder), exact alarms, start at boot (to set the alarms again).
- **Backups**: the app opts out of system backups and phone-to-phone
  transfer, because the planner file carries the device's identity for sync.
  Use sync, or Settings → Backup, to move your data.
- **Touch**: tap an empty line to type; tap a task to open it, its circle to
  complete it; press and hold a task to drag it, to the screen edge to carry
  it to another week; swipe sideways to turn the week; tap the title to
  return to today, and again for the month.

The stack, and why: the Android app is the desktop app's Flutter code, so
there is one sync engine and one data format to keep right. On top of that
sit about 300 lines of Kotlin (`android/app/src/main/kotlin`) for what
Android does better itself: alarms and notifications, the permission prompt
and the save-file dialog. It targets Android 13+ only, which keeps a single
code path for notifications, alarms and icons.

### Testing on an emulator

```sh
tools/setup-android.sh --emulator          # once: emulator + Android 16 image
tools/android-emulator.sh start            # headless; needs /dev/kvm
tools/android-build.sh --emulator
tools/dev python3 tools/android-smoke.py out/ \
  --apk build/app/outputs/flutter-apk/app-x86_64-release.apk --wait-reminder
tools/android-emulator.sh stop
```

`tools/android-smoke.py` drives the real app with touches and the on-screen
keyboard through adb and checks typing, keyboard and system-bar clearance,
completing, long-press drag, the week swipe, the task sheet, a reminder
reaching the alarm service and firing with the app closed, and data
surviving a restart.

The emulator's renderer is fragile inside the container: the software modes
crash within seconds, so the helper uses the host GPU with Vulkan switched
off (`WEEKTODO_EMULATOR_GPU`, `WEEKTODO_EMULATOR_ARGS` override that). If it
dies, start it again; what was installed on it is gone after a crash.

## Develop

```sh
tools/dev flutter analyze
tools/dev flutter test                     # unit, interaction and render tests
tools/dev flutter test --update-goldens    # after an intended visual change
tools/dev tools/smoke-run.sh /tmp/shots    # drive the real binary on Wayland
```

The smoke run starts a headless Wayland compositor with two outputs, one
unscaled and one at 125 %, and drives the release build with real pointer and
keyboard events. It fails if the app does not fill its window on either
output, typed text does not arrive, the task card does not open, or data does
not survive a restart.

### Flutter version

The Flutter release is pinned in `tools/flutter-version` (3.47.9). Flutter
3.50.0 draws through a new Wayland renderer that fixes its buffer scale when
the window is created. On a desktop that mixes a fractionally scaled output
with unscaled ones, GTK starts the window at scale 2 and then corrects to 1,
and the app ends up drawing into a quarter of its window. 3.47.9 predates
that renderer. Before raising the pin, run the smoke test: it reproduces that
arrangement.

Layout:

| Path | What |
| --- | --- |
| `lib/data/` | Dates, the change-log database, ordering keys, recurrence, the planner store, export |
| `lib/services/` | Reminders and the daily rollover |
| `lib/sync/` | Sync engine, WebDAV client, keyring access, the sync service |
| `lib/theme/` | Colours, type scale and sizes |
| `lib/ui/` | Screens and widgets |
| `test/data/` | Unit tests for the data layer |
| `test/sync/` | Sync tests: engine, WebDAV client, service, live Nextcloud |
| `test/golden/` | Interaction tests and reference renders |
| `docs/design-spec.md` | The measured design this interface follows |
| `tools/analysis/` | Scripts used to take those measurements |

### Sync

Set it up under Settings → Sync with your Nextcloud address, login name and an
*app password* (Nextcloud: Settings → Security → Devices & sessions). The user
name is the login Nextcloud shows next to the new app password: an app
password works only together with that name. The address may also be the
WebDAV address from Nextcloud's Files settings. The
password is kept in the system keyring (KWallet or GNOME Keyring), never in
the planner database. Theme and week/month view stay per device; everything
else syncs.

The login name is not always the name the account's files are filed under:
accounts that come from a directory (LDAP), as at many universities, get a
generated id such as `0f1e2d3c-4b5a-1069-…` — the id in the WebDAV address.
The app logs in with the login name and asks the server for that id (WebDAV
`current-user-principal`), so nobody has to type it.

In the chosen folder each device only ever adds files named after itself:

    WeekToDo/changes/<device id>-<sequence number>.json

A file is a batch of that device's changes and is never modified, so two
devices cannot overwrite each other, and a sync that is interrupted is simply
finished by the next one. A device that has piled up many files merges them
into one. Nothing is encrypted beyond the connection itself: anyone who can
read the folder can read the planner.

Do not copy `planner.db` between devices to move your data; connect the new
device to sync, or use Backup and Restore. Two copies of one database share a
device identity.

To test sync end to end against a real server:

```sh
# unit and protocol tests against a Nextcloud server (skipped when unset);
# NEXTCLOUD_TEST_USER is the login name, and the optional
# NEXTCLOUD_TEST_USER_ID the account's id where it differs (an LDAP account)
NEXTCLOUD_TEST_URL=... NEXTCLOUD_TEST_USER=... NEXTCLOUD_TEST_PASSWORD=... \
  tools/dev flutter test test/sync/nextcloud_live_test.dart
# two app instances syncing through the settings screen
tools/dev tools/sync-smoke.sh /tmp/shots <server-url> <user> <app-password>
```

Both create a clearly named test folder in the account. A throwaway server is
one command: `podman run -d -p 127.0.0.1:8089:80 -e SQLITE_DATABASE=nc
-e NEXTCLOUD_ADMIN_USER=tester -e NEXTCLOUD_ADMIN_PASSWORD=... nextcloud:34-apache`.

### Calendars

Settings → Calendars takes the iCal address of a calendar and shows its
events in the week and month, above the day's tasks, marked with a coloured
bar and without a check circle. Tapping one shows its time, place and notes.
Events cannot be changed here, and tasks are not sent to the calendar.

For Google Calendar the address is under Settings → the calendar → Integrate
calendar → "Secret address in iCal format". Any calendar that offers an
`.ics` or `webcal://` address works the same way.

- The planner reads the address itself: when it starts, every 15 minutes
  while it is open, when you return to it on a phone, and on request. The
  last copy is kept on the device, so events also show offline.
- **Nothing of a calendar is synced.** Its events never become tasks, and
  neither they nor the calendar's name or address enter the Nextcloud folder,
  a backup or an export (`test/calendar/calendar_service_test.dart` checks
  this). Add the address on each device that should show the calendar.
- The address works like a password: whoever has it can read the calendar.
  It is kept with the passwords (system keyring, Android keystore), not in
  the planner database, and only https addresses are accepted.
- Repeating events, exceptions to them, all-day and multi-day events and
  time zones (from the definitions the calendar itself ships) are
  understood; `lib/calendar/ics.dart` lists what is not.

### Updates

Installing a newer build keeps the planner, the sync connection and the
subscribed calendars; nothing has to be entered again.

- **Linux**: `tools/install-local.sh` replaces only the program in
  `~/.local/opt/weektodo`. The planner (`~/.local/share/io.github.yourj4m.weektodo`)
  and the passwords in the keyring are not touched.
- **Android**: install the new APK over the old one. This works as long as
  it is signed with the same key (`~/.config/weektodo/`, see
  [Android](#android)); `tools/android-build.sh` numbers builds by commit
  count, so a later build is always an update.

Both are tested by setting a device up with an earlier build and continuing
with the current one: `WEEKTODO_OLD_BIN=/path/to/old/weektodo tools/dev
tools/sync-smoke.sh ...` on Linux, and `adb install -r` over the older APK on
the emulator. What must stay the same for this to hold: the app id
`io.github.yourj4m.weektodo`, the signing key, and the meaning of the saved
connection (`sync.config`; new fields have to be optional).

### How data is stored

Every edit is recorded as a change to one field of one task, stamped with a
hybrid logical clock. The tables hold the result of applying all changes,
newest stamp winning per field. Two devices that exchange their change logs
therefore end up with the same planner regardless of order, without a server;
that is what sync builds on. Task order uses fractional keys,
so moving one task never rewrites its neighbours.

## Design

The interface follows the layout and behaviour of the Tweek weekly planner,
measured from its public web app and recorded in `docs/design-spec.md`. This
is an independent implementation: no code, styles, fonts, icons, images or
text from Tweek are included, and WeekToDo is not affiliated with or endorsed
by Tweek.

## Licence

GPL-3.0-or-later; see `LICENSE`.

Bundled third-party work: the Inter typeface (SIL Open Font License 1.1, see
`assets/fonts/Inter-LICENSE.txt`) and Lucide icons (ISC licence).
