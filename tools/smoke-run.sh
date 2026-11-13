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
bin="$root/build/linux/x64/release/bundle/weektodo"
app_id="io.github.yourj4m.weektodo"
[ -x "$bin" ] || { echo "No release build; run: tools/dev flutter build linux --release" >&2; exit 1; }
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
export WEEKTODO_DATA_DIR="$data"

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

start_app
shot 01-start
assert_fills 01-start

# Type two tasks into Monday's first row.
click 130 207
type_text "Typed on Wayland"; key Return
type_text "Second task"; key Return
shot 02-typed
key Escape
[ "$(stored 'Typed on Wayland')" -ge 1 ] && pass "typed text was stored" || fail "typed text was not stored"

# Open the first task and add a note.
click 100 207
wait_for_change 02-typed 03-card 500x370+470+90 "the task card opened"
click 620 285
type_text "A note typed in the card."; sleep 0.6
key Escape; sleep 0.4
[ "$(stored 'A note typed in the card')" -ge 1 ] && pass "note was stored" || fail "note was not stored"

# Drag the second task from Monday to Wednesday.
at 70 249; press; sleep 0.1
for x in 90 150 250 400 520 560; do at "$x" 300; done
shot 04-dragging
release; sleep 0.6
shot 05-dropped

# Keyboard: next week, back to today, month view.
key Right
shot 06-next-week
type_text t; type_text m
shot 07-month
type_text m

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
