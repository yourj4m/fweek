# WeekToDo

A minimal weekly planner for Linux (Wayland), with Android planned. Your week
as ruled columns, a Someday area for undated tasks, and nothing else in the
way.

Local-first: everything is stored on your machine and the app works offline.
Optionally it keeps your devices in step through a folder in your own
Nextcloud, with no other server involved.

This is a personal project. It shares its name with, but is unrelated to, the
open-source WeekToDo planner at weektodo.me; it would need a different name
before being published.

## Status

First test build for Linux. What works:

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
- **Export** to CSV, iCalendar and plain text; **backup and restore** as JSON.
- **Shortcuts**: ← → previous/next, T today, M month view, Ctrl+F search,
  Ctrl+, settings, Esc close.

Not there yet:

- The Android app.
- Reminders are delivered only while the app is running.
- Notes are plain text.
- Reordering subtasks by drag, selecting several tasks at once, undo, print.
- Attachments, sharing and calendar-provider sync are out of scope for now.
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

Set it up under Settings → Sync with your Nextcloud address, user name and an
*app password* (Nextcloud: Settings → Security → Devices & sessions). The
password is kept in the system keyring (KWallet or GNOME Keyring), never in
the planner database. Theme and week/month view stay per device; everything
else syncs.

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
# unit and protocol tests against a Nextcloud server (skipped when unset)
NEXTCLOUD_TEST_URL=... NEXTCLOUD_TEST_USER=... NEXTCLOUD_TEST_PASSWORD=... \
  tools/dev flutter test test/sync/nextcloud_live_test.dart
# two app instances syncing through the settings screen
tools/dev tools/sync-smoke.sh /tmp/shots <server-url> <user> <app-password>
```

Both create a clearly named test folder in the account. A throwaway server is
one command: `podman run -d -p 127.0.0.1:8089:80 -e SQLITE_DATABASE=nc
-e NEXTCLOUD_ADMIN_USER=tester -e NEXTCLOUD_ADMIN_PASSWORD=... nextcloud:34-apache`.

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
