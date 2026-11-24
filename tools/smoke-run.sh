#!/usr/bin/env bash
# End-to-end check of the built app as a native Wayland client.
#
#   tools/dev tools/smoke-run.sh <output-dir>
#
# Starts a headless sway compositor with two outputs at different scales (an
# unscaled monitor beside a 125 % one, the arrangement that exposed the
# quarter-window bug), launches the release build, and drives it with real
# pointer and keyboard events: typing tasks, opening the task card, dragging
# to another day, shortcuts, moving the window between the two outputs, and a
# restart. Screenshots go to <output-dir>; the script fails if the app does
# not fill its window, typed text does not arrive, or data does not persist.
#
# Uses a throwaway data folder, so the real planner is never touched.
set -uo pipefail
# A crash during a test run must not reach the desktop's crash reporter: the
# container shares the host's kernel, so the report would pop up there. With
# a core limit of one byte the kernel skips the core handler altogether.
prlimit --core=1:1 --pid $$ 2>/dev/null || ulimit -c 0
out="${1:?output directory}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/build/linux/x64/release/bundle/fweek"
app_id="io.github.yourj4m.weektodo"
[ -x "$bin" ] || { echo "No release build; run: tools/desktop-build.sh" >&2; exit 1; }
mkdir -p "$out"
: >"$out/app.log"

export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
data="$(mktemp -d)"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

cat > "$XDG_RUNTIME_DIR/sway.conf" <<'CFG'
output HEADLESS-1 mode 1440x900 scale 1 position 0 0
default_border none
focus_follows_mouse no
# The window files are dragged out of (tools/drag-source.c) floats in a
# corner, so that the app keeps the whole screen.
for_window [app_id="fweek-drag-source"] floating enable, resize set 200 120, move position 1200 20
CFG
unset DISPLAY WAYLAND_DISPLAY
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
sway -c "$XDG_RUNTIME_DIR/sway.conf" >"$out/sway.log" 2>&1 &
compositor=$!
app=""
input=""
trap 'exec 3>&-; kill $app $input $compositor 2>/dev/null; rm -rf "$data" "$XDG_RUNTIME_DIR"' EXIT
for _ in $(seq 1 40); do
  socket="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)"
  [ -n "$socket" ] && break
  sleep 0.25
done
[ -n "${socket:-}" ] || { echo "sway did not start"; tail -5 "$out/sway.log"; exit 1; }
export WAYLAND_DISPLAY="$(basename "$socket")" GDK_BACKEND=wayland LIBGL_ALWAYS_SOFTWARE=1
export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)"
export FWEEK_DATA_DIR="$data"

# A second output at 125 %, to the right; the app opens on the unscaled one.
swaymsg create_output >/dev/null
swaymsg output HEADLESS-2 mode 1800x1125 scale 1.25 position 1440 0 >/dev/null
swaymsg focus output HEADLESS-1 >/dev/null
sleep 0.5

# A persistent virtual pointer and keyboard (see tools/wl-input.py), created
# before the app starts so the seat's capabilities never change under it.
bindings="$XDG_RUNTIME_DIR/bindings"
python3 -m pywayland.scanner -i /usr/share/wayland/wayland.xml \
  "$root"/tools/wayland-protocols/*.xml -o "$bindings/protocols" >/dev/null
mkfifo "$XDG_RUNTIME_DIR/input"
python3 "$root/tools/wl-input.py" --protocols "$bindings" --extent 2880 900 \
  <"$XDG_RUNTIME_DIR/input" >"$out/input.log" 2>&1 &
input=$!
exec 3>"$XDG_RUNTIME_DIR/input"
for _ in $(seq 1 40); do grep -q ready "$out/input.log" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$out/input.log" || { echo "input helper failed:"; cat "$out/input.log"; exit 1; }
send() { echo "$*" >&3; }

start_app() {
  "$bin" >>"$out/app.log" 2>&1 &
  app=$!
  for _ in $(seq 1 60); do
    swaymsg -t get_tree | grep -q "\"app_id\": \"$app_id\"" && break
    sleep 0.25
  done
  sleep 2
}
at() { send "move $1 $2"; sleep 0.08; }
press() { send press; sleep 0.05; }
release() { send release; sleep 0.05; }
click() { send "click $1 $2"; sleep 0.5; }
# Typing takes about 20 ms a character in the helper; wait for it to finish.
type_text() { send "type $1"; sleep "$(awk -v n="${#1}" 'BEGIN { print 0.4 + 0.03 * n }')"; }
key() { send "key $1"; sleep 0.35; }
shot() { grim -o "${2:-HEADLESS-1}" "$out/$1.png" && echo "shot  $1"; }
stored() { strings "$data"/planner.db* 2>/dev/null | grep -c -- "$1"; }

# The drawn content must reach the right-hand edge of the window. With the
# quarter-window bug it stops at half the width.
assert_fills() {
  local file="$out/$1.png" width trimmed x right
  width="$(magick "$file" -format '%w' info:)"
  read -r trimmed x < <(magick "$file" -fuzz 3% -trim -format '%w %X' info: | tr -d '+')
  right=$((x + trimmed))
  if [ $((right * 100)) -ge $((width * 90)) ]; then
    pass "$1 fills its window (content reaches $right of $width px)"
  else
    fail "$1 does not fill its window (content ends at $right of $width px)"
  fi
}

# Waits until a region of the screen differs from an earlier screenshot, up
# to about four seconds. Used to see that the task card really opened.
#   wait_for_change <earlier-shot> <new-shot> <WxH+X+Y> <what>
wait_for_change() {
  local changed=0
  for _ in $(seq 1 16); do
    grim -o HEADLESS-1 "$out/$2.png"
    changed="$(magick compare -metric AE -fuzz 3% \
      \( "$out/$1.png" -crop "$3" +repage \) \( "$out/$2.png" -crop "$3" +repage \) \
      null: 2>&1 | awk '{ print int($1) }')"
    [ "${changed:-0}" -gt 5000 ] && { pass "$4"; echo "shot  $2"; return; }
    sleep 0.25
  done
  fail "$4 (only ${changed:-0} px changed)"
}

# The icons: a release build carries only those the code uses, cut out of
# the icon font at build time. A font older than the code is one that was
# kept from an earlier build and lacks what the code has come to use since
# (tools/desktop-build.sh builds without that risk).
icons="$(find "$(dirname "$bin")/data/flutter_assets" -name 'Lucide*.ttf' | head -1)"
newest="$(find "$root/lib" -name '*.dart' -newer "$icons" 2>/dev/null | head -1)"
if [ -n "$icons" ] && [ -z "$newest" ]; then
  pass "the build's icon font is as new as the code"
else
  fail "the build's icon font is older than the code (${newest#"$root"/}): build with tools/desktop-build.sh"
fi

start_app
shot 01-start
assert_fills 01-start

# Type two tasks into Monday's first row (rows are 42 px, the first from 154).
click 130 175
type_text "Typed on Wayland"; key Return
type_text "Second task"; key Return
shot 02-typed
key Escape
[ "$(stored 'Typed on Wayland')" -ge 1 ] && pass "typed text was stored" || fail "typed text was not stored"

# Open the first task and add a note.
click 100 175
wait_for_change 02-typed 03-card 500x370+470+90 "the task card opened"
click 620 285
type_text "A note typed in the card."; sleep 0.6
key Escape; sleep 0.4
[ "$(stored 'A note typed in the card')" -ge 1 ] && pass "note was stored" || fail "note was not stored"

# Drag the second task from Monday to Wednesday.
at 70 217; press; sleep 0.1
for x in 90 150 250 400 560 700; do at "$x" 300; done
shot 04-dragging
release; sleep 0.6
shot 05-dropped
wednesday="$(date -d "$(date +%F) -$(( $(date +%u) - 1 )) days +2 days" +%F)"
field() {
  python3 - "$data/planner.db" "$1" "$2" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute(
    f"select {sys.argv[3]} from tasks where title = ? and deleted = 0", (sys.argv[2],)).fetchone()
print("" if row is None or row[0] is None else row[0])
PY
}
[ "$(field 'Second task' date)" = "$wednesday" ] \
  && pass "a task dragged to another day is on that day" \
  || fail "the dragged task is on '$(field 'Second task' date)', not on $wednesday"

# Keyboard: next week, back to today, month view.
key Right
shot 06-next-week
type_text t; type_text m
shot 07-month
type_text m

# Trackpad: two fingers swiped to the left turn to the next week, to the
# right back again. A task typed into the first column after the first
# swipe must be on next week's Monday.
at 700 450
send "swipe -320"; sleep 1.2
shot 07b-swiped
click 130 175
type_text "Typed after a swipe"; key Return; key Escape
sleep 0.4
next_monday="$(date -d "$(date +%F) -$(( $(date +%u) - 1 )) days +7 days" +%F)"
swiped_to="$(python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    "select date from tasks where title = 'Typed after a swipe'").fetchone()
print(row[0] if row else "")
PY
)"
[ "$swiped_to" = "$next_monday" ] \
  && pass "a two-finger swipe on the trackpad turns to the next week" \
  || fail "after a trackpad swipe a task landed on '${swiped_to:-nowhere}', not on $next_monday"
at 700 450
send "swipe 320"; sleep 1.2

# A new event from the keyboard: N, a title, Enter. It is on today, all day,
# and an event.
shot 07j-before-form
type_text n
wait_for_change 07j-before-form 07k-form 500x400+470+100 "N opens the form for a new event"
type_text "Smoke event"; key Return; sleep 0.8
today="$(date +%F)"
[ "$(field 'Smoke event' date)" = "$today" ] && [ "$(field 'Smoke event' kind)" = "event" ] \
  && [ -z "$(field 'Smoke event' time)" ] \
  && pass "a new event typed into the form is on today, all day" \
  || fail "the new event is on '$(field 'Smoke event' date)', kind '$(field 'Smoke event' kind)'"

# From the header's button, over several days: its end day is picked in the
# month after (the form is 512 wide, centred; the month opens under the end
# day, its arrow for the next month at +261,+26, the days from +27,+89 in
# steps of 39 by 38).
click 1166 48; sleep 0.8
type_text "Smoke trip"
click 666 264; sleep 0.7
shot 07l-end-day
click 857 313; sleep 0.5
click 740 452; sleep 0.6
shot 07m-several-days
click 884 587; sleep 0.9
shot 07n-added
trip_first="$(field 'Smoke trip' date)"; trip_last="$(field 'Smoke trip' end_date)"
[ "$trip_first" = "$today" ] && [[ "$trip_last" > "$trip_first" ]] \
  && pass "an event over several days is added from the header's button ($trip_first to $trip_last)" \
  || fail "the event over several days runs from '$trip_first' to '$trip_last'"

# The header names its views: a click on Tasks, and on Week back again.
shot 07o-week
click 1100 48
wait_for_change 07o-week 07p-tasks 1400x240+10+14 "the header's Tasks leads to the Tasks page"
click 952 48; sleep 0.8

# The header's sync button: with nothing connected it still keeps a copy of
# the planner beside it, one file for the day.
click 1212 48; sleep 1.5
shot 07q-synced
copy="$data/backups/planner-$(date +%F).json"
[ -s "$copy" ] && grep -q '"Smoke trip"' "$copy" \
  && pass "the sync button keeps a copy of the planner on this device" \
  || fail "no copy of the planner at $copy after the sync button"

# The settings (Ctrl+,): their sections are listed at the card's left. A
# click on "Tasks" shows that section; a switch there reaches the planner's
# file. (Turned on and off again, so that the rest of the run is as before.)
shot 07r-week
send "ctrl ,"
wait_for_change 07r-week 07s-settings 840x680+300+100 "Ctrl+, opens the settings"
click 392 262
wait_for_change 07s-settings 07t-settings-tasks 600x480+520+150 "a section of the settings opens from their list"
sorted_before="$(stored 'sort_done_down')"
click 1106 289; sleep 0.6
[ "$(stored 'sort_done_down')" -gt "$sorted_before" ] \
  && pass "a switch in the settings is stored" \
  || fail "the switch in the settings did not reach the planner's file"
click 1106 289; sleep 0.6
key Escape; sleep 0.8

# The Tasks page (L): a list is started in the blank column and named
# where it stands; a task typed into it is in that list and has no day.
type_text l; sleep 0.8
shot 07e-tasks
click 500 126
type_text "Films"; key Return
click 500 174
type_text "Stalker"; key Return; key Escape
sleep 0.4
shot 07f-list
films="$(python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    "select id from lists where title = 'Films' and deleted = 0").fetchone()
print(row[0] if row else "")
PY
)"
[ -n "$films" ] && [ "$(field Stalker list_id)" = "$films" ] && [ -z "$(field Stalker date)" ] \
  && pass "a list is made on the Tasks page and takes a task without a day" \
  || fail "the task typed into a new list is in list '$(field Stalker list_id)' (Films is '$films'), on '$(field Stalker date)'"

# Dragged onto the header's "Week" and held there, the task is taken to the
# week; dropped on Wednesday it is planned for that day and still in its
# list.
at 440 174; press; sleep 0.1
for p in "470 170" "700 140" "900 100" "940 60" "952 48"; do at $p; done
sleep 1.3
shot 07g-carried
for p in "1200 200" "900 300" "740 320" "700 330"; do at $p; done
sleep 0.4
release; sleep 0.8
shot 07h-planned
[ "$(field Stalker date)" = "$wednesday" ] && [ "$(field Stalker list_id)" = "$films" ] \
  && pass "held on the header's Week, a task is carried to the week and planned for a day" \
  || fail "the carried task is on '$(field Stalker date)' (wanted $wednesday), in list '$(field Stalker list_id)'"

# The lists button keeps to the window's top right corner: a click there
# opens the lists, a second click on the same spot shuts them.
panel_setting() {
  python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    "select value from meta where key = 'local.list_panel'").fetchone()
print(row[0] if row else "")
PY
}
click 1396 48; sleep 0.8
opened="$(panel_setting)"
click 1396 48; sleep 0.8
[ "$opened" = "true" ] && [ "$(panel_setting)" = "false" ] \
  && pass "the lists button opens and shuts the lists from the same spot" \
  || fail "two clicks on the lists button's corner gave '$opened', then '$(panel_setting)'"

# The lists beside the week (P), and away again.
type_text p; sleep 0.8
shot 07i-panel
panel="$(python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    "select value from meta where key = 'local.list_panel'").fetchone()
print(row[0] if row else "")
PY
)"
[ "$panel" = "true" ] && pass "P opens the lists beside the week" || fail "the lists panel did not open ('$panel')"

# A new list made in the panel is named where it stands: what is typed
# next is its name, without a click on anything.
click 1212 396; sleep 0.8
type_text "Books"; key Return; sleep 0.5
shot 07r-panel-list
books="$(python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(
    "select count(*) from lists where title = 'Books' and deleted = 0").fetchone()[0])
PY
)"
[ "$books" = "1" ] && pass "a list made in the panel takes its name at once" \
  || fail "after 'New list' in the panel and typing, $books lists are called Books"

# The line between the week and the panel, dragged 100 px to the left:
# the panel is that much wider, and the width is kept.
at 1136 450; press; sleep 0.1
for x in 1120 1090 1060 1036; do at "$x" 450; done
sleep 0.2
release; sleep 0.6
shot 07s-panel-wide
width="$(python3 - "$data/planner.db" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
    "select value from meta where key = 'local.panel_width'").fetchone()
print(row[0] if row else "")
PY
)"
awk -v w="${width:-0}" 'BEGIN { exit !(w >= 372 && w <= 388) }' \
  && pass "the panel's edge is dragged to make it wider ($width px)" \
  || fail "after dragging the panel's edge 100 px its width is '${width}', not about 380"
type_text p; sleep 0.5

# A calendar file dragged out of another program's window and dropped on
# the planner: its event must be in the planner afterwards, and the card
# that says so must show.
if gcc $(pkg-config --cflags gtk+-3.0) "$root/tools/drag-source.c" \
    -o "$XDG_RUNTIME_DIR/drag-source" $(pkg-config --libs gtk+-3.0) 2>"$out/drag-source.log"; then
  drop_day="$(date -d "+2 days" +%Y%m%d)"
  printf '%s\r\n' 'BEGIN:VCALENDAR' 'VERSION:2.0' 'BEGIN:VEVENT' 'UID:dropped@smoke' \
    'SUMMARY:Dropped from a file' "DTSTART;VALUE=DATE:$drop_day" 'END:VEVENT' 'END:VCALENDAR' \
    > "$XDG_RUNTIME_DIR/dropped.ics"
  "$XDG_RUNTIME_DIR/drag-source" "$XDG_RUNTIME_DIR/dropped.ics" >>"$out/drag-source.log" 2>&1 &
  source_window=$!
  sleep 1.5
  shot 07c-before-drop
  at 1300 80; press; sleep 0.2
  for x in 1280 1240 1180 1100 1000 900 800 720 700; do at "$x" 420; done
  sleep 0.4
  release; sleep 1.5
  shot 07d-dropped
  kill "$source_window" 2>/dev/null
  [ "$(stored 'Dropped from a file')" -ge 1 ] \
    && pass "a calendar file dragged from another window and dropped on the planner is added" \
    || fail "the dropped calendar file's event is not in the planner"
  key Escape; sleep 0.4
  swaymsg "[app_id=\"$app_id\"] focus" >/dev/null; sleep 0.3

  # A contacts file dropped the same way: its birthday (today's, to be in
  # sight) is in a calendar of its own, kept beside the planner and not
  # in it.
  printf '%s\r\n' 'BEGIN:VCARD' 'VERSION:3.0' 'FN:Smoke Contact' "BDAY:1990$(date +%m%d)" \
    'END:VCARD' > "$XDG_RUNTIME_DIR/contacts.vcf"
  "$XDG_RUNTIME_DIR/drag-source" "$XDG_RUNTIME_DIR/contacts.vcf" >>"$out/drag-source.log" 2>&1 &
  source_window=$!
  sleep 1.5
  at 1300 80; press; sleep 0.2
  for x in 1280 1240 1180 1100 1000 900 800 720 700; do at "$x" 420; done
  sleep 0.4
  release; sleep 1.5
  shot 07t-birthdays
  kill "$source_window" 2>/dev/null
  if grep -qs "Smoke Contact's birthday" "$data"/calendars/* \
      && [ "$(stored 'Smoke Contact')" -eq 0 ]; then
    pass "a contacts file dropped on the planner becomes the Birthdays calendar, outside the planner's own data"
  else
    fail "the dropped contacts file: calendar copy $(grep -ls "Smoke Contact" "$data"/calendars/* | wc -l), in the planner $(stored 'Smoke Contact')"
  fi
  swaymsg "[app_id=\"$app_id\"] focus" >/dev/null; sleep 0.3
else
  echo "note: no compiler for the drag source; dropping a file was not tried"
fi

# Move the window to the 125 % output and back; it must fill both.
swaymsg "[app_id=\"$app_id\"] move container to output HEADLESS-2" >/dev/null; sleep 2
shot 08-on-125-percent HEADLESS-2
assert_fills 08-on-125-percent
swaymsg "[app_id=\"$app_id\"] move container to output HEADLESS-1" >/dev/null; sleep 2
shot 09-back-on-100-percent
assert_fills 09-back-on-100-percent

# Restart: the tasks must still be there.
kill "$app"; wait "$app" 2>/dev/null
start_app
shot 10-restarted
assert_fills 10-restarted
[ "$(stored 'Second task')" -ge 1 ] && pass "tasks survive a restart" || fail "tasks lost on restart"

pattern='EXCEPTION|Unhandled|Unsupported operation|FATAL'
errors="$(grep -c -E "$pattern" "$out/app.log" || true)"
if [ "$errors" -eq 0 ]; then
  pass "no errors in the app log"
else
  fail "$errors error lines in the app log"
  grep -E "$pattern" "$out/app.log" | head -5
fi
# Not a failure: on a busy machine the software-rendered first frame can miss
# GTK's deadline while the window settles on its scale. Whether the picture
# ends up the right size is what assert_fills checks.
slow="$(grep -c 'Timed out waiting' "$out/app.log" || true)"
[ "$slow" -eq 0 ] || echo "note: $slow late frame(s) while the window was resizing"

echo
[ "$failures" -eq 0 ] && echo "smoke run passed" || echo "smoke run FAILED ($failures)"
exit "$failures"
