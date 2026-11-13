# WeekToDo

A minimal weekly planner for Linux, with Android planned. Your week as ruled
columns, a Someday area for undated tasks, and nothing else in the way.

Local-first: everything is stored on your machine and the app works offline.
Sync through your own Nextcloud or Google Drive is the next milestone; the
data layer is already built for it.

"WeekToDo" is a working title.

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
- **Export** to CSV, iCalendar and plain text; **backup and restore** as JSON.
- **Shortcuts**: ← → previous/next, T today, M month view, Ctrl+F search,
  Esc close.

Not there yet:

- Sync, and the Android app.
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
tools/dev tools/smoke-run.sh /tmp/shots    # drive the real binary headlessly
```

Layout:

| Path | What |
| --- | --- |
| `lib/data/` | Dates, the change-log database, ordering keys, recurrence, the planner store, export |
| `lib/services/` | Reminders and the daily rollover |
| `lib/theme/` | Colours, type scale and sizes |
| `lib/ui/` | Screens and widgets |
| `test/data/` | Unit tests for the data layer |
| `test/golden/` | Interaction tests and reference renders |
| `docs/design-spec.md` | The measured design this interface follows |
| `tools/analysis/` | Scripts used to take those measurements |

### How data is stored

Every edit is recorded as a change to one field of one task, stamped with a
hybrid logical clock. The tables hold the result of applying all changes,
newest stamp winning per field. Two devices that exchange their change logs
therefore end up with the same planner regardless of order, without a server;
that is what file-based sync will build on. Task order uses fractional keys,
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
