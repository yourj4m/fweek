# fweek

A minimal weekly planner for Windows, Linux (Wayland) and Android. Your
week as ruled columns, a page of lists for what has no day yet, and nothing
else in the way.

Local-first: everything is stored on your machine and the app works offline.
Optionally it keeps your devices in step through your own Google Drive or
your own Nextcloud, with no other server involved.

**Download** the latest version from the
[release page](https://github.com/yourj4m/fweek/releases): a setup program
for Windows, a `.tar.gz` for Linux (unpack, then `./install.sh`), an APK for
Android. Website, privacy policy and terms:
https://yourj4m.github.io/planner-oauth-site/

## Quickstart 
For Android
```sh
tools/setup-dev.sh                 # once, if not done for Linux already
tools/setup-android.sh             # once: JDK + Android SDK, into the container and .tools/
tools/android-build.sh             # signed APK for a 64-bit ARM phone
tools/android-build.sh --install   # ... and install it over USB
```

For Linux
```sh
tools/setup-dev.sh                         # once: build container + Flutter SDK
tools/desktop-build.sh                     # build
build/linux/x64/release/bundle/fweek    # run
tools/install-local.sh                     # optional: add to the application menu
```

For Windows (on a Windows machine with Flutter and Visual Studio's C++
tools; GitHub Actions does this for every push)
```sh
flutter build windows --release            # build/windows/x64/runner/Release/fweek.exe
iscc windows\installer\fweek.iss            # optional: the installer, into dist\
```

Releases: pushing a tag such as `v1.2.0` makes `.github/workflows/build.yml`
build all three and publish them on the release page. Google Drive sync in
those builds, and the signed APK, need repository secrets: see
[docs/google-setup.md](docs/google-setup.md).

## Status

Builds for Windows, Linux and Android, from the same code. What works:

- **Week view**: the five weekdays side by side across the window, and
  Saturday and Sunday in a row of their own under them, half the width
  each, with three empty lines under the fuller of the two. The weekdays
  get as many ruled rows as reach the bottom of the window (more when a
  day holds more), so that the week fills a maximized window without
  scrolling; a single-column layout below 1024 px.
- **Tasks and events**: an item is a task, with a circle to tick it off, or
  an event, with none: an event is marked by a bar at its left and turns
  faint once it is over. New items are tasks unless Settings → General → "New
  items are" says events; while typing one, Ctrl+E or the mark at the end of the
  line makes it the other, and so does "Turn into an event / a task" in any
  item's menu. What a calendar brings is an event until you turn it into a
  task.
- **Time order**: within a day, items with a time keep to time order among
  themselves, while items without a time stay where you put them. A 9:00
  event a calendar brings in, or an import adds, goes above your 15:00 one,
  next to it rather than at the top or the end; an item dragged above an
  earlier one goes back after it. A calendar's events stand above the day's
  tasks as long as no item of yours there has a time.
- **New event**: the calendar-with-a-plus button in the header (or N, or
  the menu) opens a form for an event with all it can have: title, start
  and end day, all day or a start and an end time, repeat, reminder,
  colour, place and notes. Nothing is added until "Add event" (or Enter in
  the title); Escape and Cancel drop it; a click beside the form keeps what
  has a title, as a card keeps what was typed into it. A message says it
  was added, with Undo, or with the way to its day when that is not on
  show.
- **Events over several days**: an event of your own can end on a later
  day than it starts (the form's "Ends", or in its card: the date, then
  "Ends on another day…"). It lies as a bar across its days, in the band
  under the day headings the calendars' events use; in the month it keeps
  one line through each week; on a phone each of its days has the bar,
  with which day of how many it is. With times it starts at its start time
  on the first day and ends at its end time on the last. Moved or copied,
  it stays as long. Its menu (right-click, long press) moves and deletes
  it; it is not dragged.
- **Tasks**: click an empty row and type, Enter for the next one. Click a task
  to open it. Check to complete. Drag between days and lists, or hold a task
  at the window edge to carry it to another week. Right-click (on a phone:
  long press and let go) for a menu: move, time, colour, note, place,
  duplicate, delete. Deleting offers Undo for a few seconds.
- **Task card**: along the top the day, the time (from start to end, when
  it has an end) and, for what a calendar brought, the calendar; then the
  title, notes with clickable links, a place, subtasks (with section titles,
  stars and one level of indent); below, highlight colour including your own
  hex colours, repeat (presets and a custom editor), reminder, move, copy,
  delete. A click beside the card, Escape or the back gesture closes it. The
  end time shows in the card only; the week shows when things start.
- **Links**: a web address pasted into a task does not stand there in
  full: it reads as its site and the start of its path, underlined, with a
  small button that opens it. A click on the row opens the task as always;
  in the card the address is a link, and it is there in full while the
  title is edited.
- **Rows** show what a task carries, quietly: its time, a mark for a note,
  subtasks done of total, and the place on a second, smaller line.
- **Places**: type one freely, or pick from suggestions while typing; a
  click opens it in your map program. See [Places](#places).
- **Repeating tasks**: completing, moving or deleting one occurrence leaves
  the rest of the series alone; text and colour edits apply to the series.
- **Three views, named in the header**: Week, Month and Tasks stand side
  by side there, the one on show marked; a click leads to each (keys: M for
  the month, L for the tasks and back). The buttons keep their places from
  view to view. On a phone the bar at the bottom does this.
- **Tasks page**: any number of named lists, on a page of their own beside
  the planner ("Tasks" in the header, or L; on a phone the bar at the
  bottom). Every list is a column while the window has
  room for all of them; in a narrower window their names stand at the left
  and one list is open; on a phone the names are tabs, and a swipe turns to
  the next list. There is always a way to start a new list, which then
  waits for its name where it stands; a list's menu renames, moves and
  deletes it. A task ticked today stays in its row, struck through, for
  the rest of the day, so that the list keeps a running record of what was
  done; from the next day on it is folded away under the list ("3 done"),
  where done tasks can be looked at and cleared.
- **From a list into the week**: "Plan for" in a task's menu gives it a
  day, as does its card; or drag it onto "Week" in the header (a tab of
  the phone's bar) and hold it there: the page turns, and the task is dropped
  on a day. It then shows on that day and stays in its list too, marked
  with the day; ticked in one place it is ticked in the other. Settings → Tasks →
  "A task from a list, given a day" has it leave its list instead. A task
  of the week is put into a list, or taken out, at the top of its card.
- **Lists beside the week**: in a wide window (1240 px and up) the lists
  also open as a panel at the right of the week, to drag tasks straight
  onto days, and from a day back into a list. A plain panel icon in the
  window's top right corner opens it, and the panel's own button, in that
  same corner, shuts it, so two clicks on one spot open and shut it (P
  does both).
  That icon only shows the lists beside the week; "Tasks" is the page.
  The line between the week and the panel is dragged to make the panel
  wider or narrower (a double click gives it its first width again); each
  device keeps its own width.
- **Hints**: on the desktop, a button that is only an icon says what it
  does when the pointer rests on it.
- **Deadlines**: a task can have a day by which it is to be done, apart
  from the day it is planned for (the flag in its card, or "Deadline" in
  its menu). Its row carries a flag, red once the day has passed, and in
  the week the day it is due has a flag in its heading that lists what is
  due then.
- **Month view**; **search** over tasks and calendar events, with colour
  filters; twelve **themes**: light ones, dark ones, and five semi-dark ones
  in deep, muted colours (Wine, Plum, Forest, Midnight, Cocoa).
- **Today** is marked by a thin bar under its heading that fills over the
  day, from midnight to midnight. The day's timed items are on it: a dot
  where one starts, a pill from start to end for one with an end, in the
  item's colour; where two overlap, their colours are checkered.
- **Left unticked**: a task moved to today because it was not ticked the
  day before shows a green check and a red cross. Green: it was done that
  day; it goes back exactly where it stood, ticked. Red: it is still to do
  and stays on today.
- **Settings** (Ctrl+, or the menu), in sections: General (week start,
  12/24-hour time, what new items are, place suggestions), Appearance
  (themes), Tasks (move unfinished tasks to today, sort or hide completed
  tasks, lists, reminders), Calendars, Sync, Data (backup, export, restore,
  copies on the device) and Advanced. On a desktop the sections are listed
  at the left of the card and the chosen one is shown beside them; on a
  phone, or in a narrow window, the card opens on the list of sections and
  a tap opens one (back, or the arrow, returns to the list). The settings
  open again on the section last looked at, and a failed sync's message
  leads straight to the section that can put it right.
- **Sync** through Google Drive or Nextcloud (Settings → Sync): on start, every five minutes,
  a few seconds after you stop editing, and on request.
- **Sync everything**: the button with the two arrows in the header (or S;
  on a phone, scroll to the top of the page and pull it down) does at once
  what otherwise happens at its own times: it syncs with the Nextcloud
  folder, reads every calendar again, and keeps a copy of the planner on
  the device. A message says what was done or what failed; the button
  turns red while the last sync with Nextcloud stands failed.
- **Copies on the device**: that copy is one file a day in `backups/`
  beside the planner (the fourteen latest are kept), the same file
  Settings → Data → Backup saves. Settings → Data says how many there are,
  and "Restore a copy" brings one back. They guard against a slip of one's own, not against losing the
  device.
- **Calendars**: subscribe to a calendar's iCal address (for example Google
  Calendar's "secret address") and its events appear in your week: move
  them, recolour them, edit their notes, hide them, or turn one into a task
  to tick off. Events over several days lie in a band under the day
  headings. Your changes sync between your devices; the calendar itself is
  never changed. See
  [Calendars](#calendars).
- **Birthdays**: Google Calendar gives out no address for its Birthdays
  calendar. Export your contacts instead (contacts.google.com → Export, as
  vCard or as Google CSV) and read that file in Settings → Calendars →
  Birthdays, or drop it on the desktop window: the birthdays and other
  yearly dates of your contacts become a calendar of their own, kept on
  that device. See [Birthdays](#birthdays).
- **Calendar files**: drop an `.ics` file (an invitation, an export) anywhere
  on the desktop window, or pick one in Settings → Calendars on any device,
  and its events are added to the planner as events of your own, which
  sync like everything else. A card lists what was added; each entry leads
  to its day and opens it, and Undo takes them out again. The same file
  again brings them up to date instead of doubling them. An event that
  repeats becomes one repeating item where the planner can say its rule;
  otherwise its dates of the coming year are taken in one by one. An event
  over several days comes in as one event that runs over them.
- **Export** to CSV, iCalendar and plain text; **backup and restore** as JSON.
- **Trackpad**: two fingers swiped sideways turn to the next or previous
  week (or month).
- **Shortcuts**: ← → previous/next (on the Tasks page: the next list,
  where one shows at a time), T today, M month view, L tasks page and
  back, P the lists beside the week, N new event, S sync everything,
  Ctrl+F search, Ctrl+, settings, Esc close. Tab and the arrow keys reach every button and
  row; on a row, Enter opens, Space completes, Delete deletes and the menu
  key (or Shift+F10) opens its menu.
- Text that is not a button can be selected and copied: details in cards,
  calendar descriptions, the settings' explanations.

- **Android** (13 and newer): the single-column layout with larger rows, a
  bar at the bottom for the week and the tasks, a swipe to turn the week (or
  to the next list), a pull down from the top of the page to sync
  everything, a long press to pick a task up (let go for its menu, move on
  to drag it), reminders that fire while the app is closed.
  While you type a task, a bar above the keyboard gives it a time (wheels
  for hours and minutes), a place, a note or a colour. See
  [Android](#android).

Not there yet:

- On Linux, reminders are delivered only while the app is running.
- On Android: no home-screen widget, no sync while the app is closed.
- Notes are plain text (links in them are recognised).
- Reordering subtasks by drag, selecting several tasks at once, print. Undo
  exists for deleting and hiding, not for every edit.
- Writing changes back to a calendar, or sending tasks to one: what you
  change about an event stays in the planner.
- A map inside the app: places open in your map program instead.
- Attachments and sharing are out of scope for now.
- English only.

## Run it

```sh
tools/setup-dev.sh                         # once: build container + Flutter SDK
tools/desktop-build.sh                     # build
build/linux/x64/release/bundle/fweek    # run
tools/install-local.sh                     # optional: add to the application menu
```

`tools/setup-dev.sh` needs Fedora's `toolbox` and installs nothing on the host:
the compiler and GTK headers live in a container, and the Flutter SDK is
downloaded into `.tools/`. The built app runs directly on the host and needs
only GTK 3.

Your planner is stored in `~/.local/share/io.github.yourj4m.weektodo/planner.db`.
Set `FWEEK_DATA_DIR=/some/folder` to try the app against a different,
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
use in `~/.config/fweek/` (a key made under the app's earlier name stays in
`~/.config/weektodo/` and is found there). Android only updates an app with a
build signed by the same key, so keep that folder.

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
  Use sync, or Settings → Data → Backup, to move your data.
- **Touch**: tap an empty line to type (the first button of the bar above
  the keyboard switches between task and event); tap a task to open it, its
  circle to complete it; tap beside an open card to close it; press and hold
  a task to drag it, to the screen edge to carry
  it to another week, or onto the other tab of the bar at the bottom to
  carry it from a list to the week or back; swipe sideways to turn the
  week; tap the title to return to today, and again for the month; going
  back from the tasks leads to the week.

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
off (`FWEEK_EMULATOR_GPU`, `FWEEK_EMULATOR_ARGS` override that). If it
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

    fweek/changes/<device id>-<sequence number>.json

A file is a batch of that device's changes and is never modified, so two
devices cannot overwrite each other, and a sync that is interrupted is simply
finished by the next one. A device that has piled up many files merges them
into one. Nothing is encrypted beyond the connection itself: anyone who can
read the folder can read the planner.

#### Google Drive

Settings → Sync → **Google Drive** → *Connect Google account* opens Google's
own sign-in page in the browser; after the account is chosen and access
allowed, Google sends the browser back to a one-time address on this device
(`http://127.0.0.1:<port>`, with PKCE), and the app takes it from there. It
asks for the account's address and for its own hidden folder in that
account's Drive (`drive.appdata`) only: it cannot see the user's files, and
the files it keeps there are invisible in Drive. Sync then works exactly as
with Nextcloud, with the same files, named by their whole path in that
folder. The long-lived token is kept in the keyring (Windows: encrypted with
the Windows login; Android: the Keystore), never in the planner.
Disconnecting withdraws the app's access at Google and leaves the files
(Drive → Settings → Manage apps → fweek → Delete hidden app data removes
them).

Only builds made with a Google sign-in client offer it; how to register one,
and the pages the consent screen links to, is in
[docs/google-setup.md](docs/google-setup.md). To try it without Google,
`tools/google-smoke.sh` runs the real app against a stand-in
(`test/sync/fake_google.dart`).

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
events in the week and month with the day's tasks, marked with a bar in the
calendar's colour.

For Google Calendar the address is under Settings → the calendar → Integrate
calendar → "Secret address in iCal format". Any calendar that offers an
`.ics` or `webcal://` address works the same way.

An event is handled like an item of your own: open it, give it a colour,
another time or end, a place, subtasks or a reminder, drag it to another
day, hide it. Its note is what the calendar says about it (the event's
description); click it to edit it, and from then on the note is yours.
Being an event it has nothing to tick; "Turn into a task" in its menu gives
it the circle, and that too is a change of yours that syncs. It stands above
the day's tasks, in time order, until you drag it somewhere: then it keeps
that place among them, between or under tasks, on its day or another. An
event over several days is a bar in a band under the day headings, across
its days.
The menu (☰ → Calendars) shows or hides a whole calendar with one click,
and brings hidden events back.

What happens to such changes:

- **The calendar is never changed.** The address is read-only; the planner
  keeps your changes itself, field by field, and lays them over the
  calendar's version. Whatever you did not change keeps following the
  calendar: if a meeting you annotated is retitled or moved there, the new
  title and day show, with your note. "Edited · Reset" in the card drops
  your changes.
- **Your changes sync; the calendar does not.** What you arrange — each
  calendar's name, colour and whether it is shown, and your changes to
  single events, where they stand in their day included — is part of your
  planner and syncs through Nextcloud like tasks do. The calendar's address and its events never enter the Nextcloud
  folder, a backup or an export, and neither does anything about an event
  you left as it is. In synced data a calendar is named by a fingerprint
  (SHA-256) of its address and an event by a fingerprint of its identifier,
  so not even those are written out
  (`test/calendar/calendar_service_test.dart` and
  `event_overrides_test.dart` check all of this).
- Add the address on each device that should show the calendar. A device
  that has not been given it lists the calendar under "On your other
  devices" and shows none of its events; once the address is added, the
  name, colour and your changes are already there.
- The address works like a password: whoever has it can read the calendar.
  It is kept with the passwords (system keyring, Android keystore), not in
  the planner database, and only https addresses are accepted.
- The planner reads the address itself: when it starts, every 15 minutes
  while it is open, when you return to it on a phone, and on request. The
  last copy is kept on the device, so events also show offline.
- Repeating events, exceptions to them, all-day and multi-day events and
  time zones (from the definitions the calendar itself ships) are
  understood; `lib/calendar/ics.dart` lists what is not.

How a change finds its event again (`lib/calendar/identity.dart`): an event
that happens once is known by its identifier, so your changes follow it when
the calendar moves it; one occurrence of a repeating event is known by its
original start, so they stay with that occurrence whatever happens to the
others, including when the calendar itself moves it. Two things calendars do
are allowed for: Google gives the later part of a series changed with "this
and following events" a new identifier (the old one plus `_R<date>`), which
is treated as the same series; and a calendar that issues new identifiers
with every download (some published Outlook calendars do) is noticed, and
its events are then told apart by title and start instead. A change whose
event has gone from the calendar is kept, in case it comes back.

### Birthdays

Google Calendar's own "Birthdays" calendar cannot be subscribed to. It has
no "Integrate calendar" section and so no iCal address; since 2024 the
birthdays are special events of the main calendar, which Google hands out
through its own sign-in (its API, CalDAV) but leaves out of the main
calendar's iCal address. What other programs do is read the contacts,
where the birthdays come from, and so does this one.

- In Google Contacts choose Export, as **vCard** or as **Google CSV**.
  Any address book that writes vCard files will do as well.
- Read the file in Settings → Calendars → Birthdays, or drop it on the
  desktop window. Every birthday, and every other date a contact carries
  (an anniversary), becomes an all-day event that comes round each year, in
  a calendar named Birthdays: "Ada Lovelace's birthday", with "Born 10
  December 1990" as its note when the contact says the year. Someone born
  on 29 February is on the last day of February in other years.
- It is a calendar like the subscribed ones: a colour, hidden and shown
  from the menu, renamed, removed, and its single dates can be moved,
  annotated, hidden or turned into tasks.
- **The file stays on the device.** Nothing of it is uploaded: the dates
  are kept where the calendars' downloads are kept. As for any calendar,
  what syncs is the calendar's name, colour and visibility and what you
  change about single dates, under fingerprints
  (`test/calendar/contacts_test.dart` checks that no name and no date of
  birth leaves). So read the file on each device that should show the
  birthdays; a device that has not lists the calendar under "On your other
  devices".
- When your contacts change, export again and read the new file: it fills
  the one calendar anew, and a date keeps what you changed about it. On a
  desktop the place of the file is remembered: save the new export over
  the old one and the next sync reads it.

Other ways there are, none built in: a Google Apps Script of your own
that copies the birthdays into an ordinary calendar every night, which
then has a secret address to subscribe to; and Google Calendar's Settings →
Import & export → Export, whose archive is reported to hold the birthdays
as an `.ics` file of its own, which can be dropped on the window like any
calendar file (its events then become events of your own).

### Places

A task or an event can have a place: any text. While you type, places
matching it are suggested; picking one also records where it is, so that the
arrow beside the place opens exactly there in your map program (on Android
whichever app shows `geo:` addresses, on Linux a registered map program or
OpenStreetMap in the browser). The planner draws no map itself.

- Suggestions come from OpenStreetMap's data through a
  [Photon](https://photon.komoot.io) server. **What you type into a place
  field is sent to that server**, after a short pause in typing and from
  three letters on; nothing else is (no account, no position unless a place
  was picked before, in which case nearby results come first). OpenStreetMap's
  own search (Nominatim) is not used: its usage policy forbids searching on
  every keystroke.
- Settings → General → Places switches suggestions off (a place is then kept exactly
  as typed) or points them at another Photon server, over https only. The
  public server is free to use within reason; it asks for fair use.
- Links in notes and in calendar descriptions open in your browser or mail
  program. Only web, mail and phone links are opened, never files.

### Updates

Installing a newer build keeps the planner, the sync connection and the
subscribed calendars; nothing has to be entered again.

- **Linux**: `tools/install-local.sh` replaces only the program in
  `~/.local/opt/fweek`. The planner (`~/.local/share/io.github.yourj4m.weektodo`)
  and the passwords in the keyring are not touched.
- **Android**: install the new APK over the old one. This works as long as
  it is signed with the same key (`~/.config/fweek/` or `~/.config/weektodo/`, see
  [Android](#android)); `tools/android-build.sh` numbers builds by commit
  count, so a later build is always an update.

The planner's file is brought up to date when a newer build first opens it
(new tables and columns are added; nothing is rewritten), and devices on
different versions keep syncing: an older build stores what it does not
understand yet and applies it once it is updated. A build older than the
file refuses to open it rather than damage it, so update all devices before
relying on what is new.

Before a file is brought up to date, a copy of it as it was is kept beside
it (`planner.db.v5` for a file of the fifth version). To go back to the
earlier build, close the app, put that copy in the place of `planner.db`
(and delete `planner.db-wal` and `planner.db-shm`), and start the earlier
build; what was changed since the update is then missing on that device
until it syncs.

Both are tested by setting a device up with an earlier build and continuing
with the current one: `tools/dev env FWEEK_OLD_BIN=/path/to/old/fweek
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

### Performance

The phone the app is tuned for is old (a Pixel 4a). What keeps it smooth
there, and what tests guard (`test/golden/features_test.dart`, "what is
redrawn"):

- A widget is rebuilt only by what it shows. The data, the visible week, the
  sync status and the calendars each have their own scope
  (`lib/app_state.dart`), so turning the page, a sync run or a calendar
  download does not rebuild the week's rows.
- Dragging a task redraws the row that follows the finger and, when the
  target changes, the two lists concerned; not the page, and not on every
  move (`lib/ui/drag.dart`).
- The week is the same widget object while the keyboard slides in, so it is
  left alone during that animation.
- The neighbouring weeks are built ahead of a swipe, and scrolling moves a
  finished picture rather than redrawing the page for every frame.
- Nothing is drawn through an extra layer that need not be: done tasks are
  dimmed by their colours, and menus are not blurred on phones (that phone's
  graphics chip runs the OpenGL path, where both are costly).

To measure: build with `--profile --dart-define=FWEEK_PERF=true` and run
`tools/android-perf.py` on the emulator; it plays the same interactions on
the same test planner (some 500 tasks, a calendar of 50 events) every time
and prints frame timings per interaction. Runs differ, so measure each build
twice, alternating, and compare the merged results
(`--compare before1.json,before2.json after1.json,after2.json`). On the
phone itself, Settings → Advanced → "Show frame timing" draws the timing
graphs over the app.

What that gave for this round of work, against the build before it with the
same log added (15 November 2026; the app's own work per frame, in
milliseconds, for frames drawn while a finger was down or the page was still
moving; a frame has 16.7 ms in all):

| | before | after |
|---|---|---|
| Swiping through 16 weeks: frames over 16 ms | 31 of 1427 | 3 of 1548 |
| – slowest 1 % of frames from | 21.8 | 3.8 |
| Scrolling a week: typical frame | 2.6 | 0.4 |
| – slowest frame | 11.7 | 2.7 |
| Dragging a task: typical frame | 6.1 | 0.5 |
| – slowest frame | 13.8 | 5.7 |

These are from the emulator, which runs on the computer's processor and
graphics card: they compare one build with another and say nothing about
how fast the phone is. Nothing here has been measured on a Pixel 4a yet.

What was left as it is, and shows in the numbers:

- Building a week's page takes about 30 ms on the emulator. It now happens
  once per neighbouring week after a swipe has come to rest (the "resting
  long builds" of the tool) instead of in the middle of it; the very first
  swipe after starting can still catch one.
- An edit (a task completed or dropped) rebuilds the visible week from the
  planner's data: one longer frame after the finger has lifted.
- The database is written on the interface's thread, a few milliseconds per
  edit; fine for single edits, noticeable only for something like restoring
  a large backup.
- The month view sizes its rows by measuring their content, which is the
  costly way; it has not been a problem at this size.
- Opening a card, the menu and the keyboard are animations with no finger on
  the screen; the tool lists them under "resting" and no long frames showed
  there.

## Design

The interface started from the layout and behaviour of the Tweek weekly
planner, measured from its public web app and recorded in
`docs/design-spec.md`, and has since gone its own way where that served
better: the highlight colours are calmer, calendar events are editable and
those over several days lie in a band, and there are semi-dark themes. This
is an independent implementation: no code, styles, fonts, icons, images or
text from Tweek are included, and fweek is not affiliated with or endorsed
by Tweek.


This is a personal project and is shared as
it is. It was called WeekToDo for a while (no relation to the planner at
weektodo.me), and a few names that nobody reads still say so: the app id
`io.github.yourj4m.weektodo` and the format tags inside backup and sync
files. Changing those would cut an installed copy off from its planner and
its connection, so they stay.

## Licence

GPL-3.0-or-later; see `LICENSE`.

Bundled third-party work: the Inter typeface (SIL Open Font License 1.1, see
`assets/fonts/Inter-LICENSE.txt`) and Lucide icons (ISC licence).
