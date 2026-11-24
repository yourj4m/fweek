#!/usr/bin/env bash
# End-to-end check of syncing through Google Drive in the built app, against
# a stand-in for Google on this machine (test/sync/fake_google.dart), with
# real pointer and keyboard events on a headless Wayland compositor:
#
#   1. device A connects a Google account from Settings -> Sync: the app
#      opens the sign-in address in "the browser" (here a stand-in that
#      follows Google's redirect back to the app, as a browser does once the
#      user has allowed access), takes the code and syncs; a task added on A
#      reaches the account's hidden app folder
#   2. device B connects the same account and receives A's task
#   3. device A, started again, is still connected (its access is in the
#      keyring) and syncs; then disconnects, which withdraws the access
#
# The test build carries the stand-in's client:
#
#   tools/dev flutter build linux --release \
#     --dart-define=FWEEK_GOOGLE_CLIENT_ID=test-client.apps.googleusercontent.com \
#     --dart-define=FWEEK_GOOGLE_CLIENT_SECRET=test-secret
#   cp -r build/linux/x64/release/bundle <somewhere>
#   tools/dev tools/google-smoke.sh <output-dir> <somewhere>/fweek
#
# (then build the real release again with tools/desktop-build.sh).
set -uo pipefail
# A crash during a test run must not reach the desktop's crash reporter: the
# container shares the host's kernel, so the report would pop up there. With
# a core limit of one byte the kernel skips the core handler altogether.
prlimit --core=1:1 --pid $$ 2>/dev/null || ulimit -c 0
if [ "${FWEEK_PRIVATE_BUS:-}" != 1 ]; then
  export FWEEK_PRIVATE_BUS=1
  exec dbus-run-session -- "$0" "$@"
fi

out="${1:?output directory}"; bin="${2:?test build of fweek (see above)}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="io.github.yourj4m.weektodo"
[ -x "$bin" ] || { echo "No test build at $bin" >&2; exit 1; }
mkdir -p "$out"
: >"$out/app.log"

export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
export HOME="$(mktemp -d)"   # the throwaway keyring lives here
data_a="$(mktemp -d)"; data_b="$(mktemp -d)"; fakebin="$(mktemp -d)"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# A keyring that exists only for this run.
eval "$(printf 'smoke-test' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
sleep 0.5

cat > "$XDG_RUNTIME_DIR/sway.conf" <<'CFG'
output HEADLESS-1 mode 1440x1900 scale 1 position 0 0
default_border none
focus_follows_mouse no
CFG
unset DISPLAY WAYLAND_DISPLAY
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
sway -c "$XDG_RUNTIME_DIR/sway.conf" >"$out/sway.log" 2>&1 &
compositor=$!
app=""; input=""
trap 'exec 3>&-; kill $app $input $compositor $google 2>/dev/null; pkill -u "$(id -u)" -f "gnome-keyring-daemon --unlock" 2>/dev/null; rm -rf "$data_a" "$data_b" "$fakebin" "$XDG_RUNTIME_DIR" "$HOME"' EXIT
for _ in $(seq 1 40); do
  socket="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)"
  [ -n "$socket" ] && break
  sleep 0.25
done
[ -n "${socket:-}" ] || { echo "sway did not start"; tail -5 "$out/sway.log"; exit 1; }
export WAYLAND_DISPLAY="$(basename "$socket")" GDK_BACKEND=wayland LIBGL_ALWAYS_SOFTWARE=1
export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)"

bindings="$XDG_RUNTIME_DIR/bindings"
python3 -m pywayland.scanner -i /usr/share/wayland/wayland.xml \
  "$root"/tools/wayland-protocols/*.xml -o "$bindings/protocols" >/dev/null 2>&1
mkfifo "$XDG_RUNTIME_DIR/input"
python3 "$root/tools/wl-input.py" --protocols "$bindings" --extent 1440 1900 \
  <"$XDG_RUNTIME_DIR/input" >"$out/input.log" 2>&1 &
input=$!
exec 3>"$XDG_RUNTIME_DIR/input"
for _ in $(seq 1 40); do grep -q ready "$out/input.log" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$out/input.log" || { echo "input helper failed:"; cat "$out/input.log"; exit 1; }
send() { echo "$*" >&3; }
click() { send "click $1 $2"; sleep 0.5; }
type_text() { send "type $1"; sleep "$(awk -v n="${#1}" 'BEGIN { print 0.4 + 0.035 * n }')"; }
key() { send "key $1"; sleep 0.35; }
shot() { grim -o HEADLESS-1 "$out/$1.png" && echo "shot  $1"; }
stored() { strings "$1"/planner.db* 2>/dev/null | grep -c -- "$2"; }

start_app() {  # <data folder> [executable]
  # Builds from before the rename read WEEKTODO_DATA_DIR: without it an
  # earlier build would open the real planner.
  FWEEK_DATA_DIR="$1" WEEKTODO_DATA_DIR="$1" "${2:-$bin}" >>"$out/app.log" 2>&1 &
  app=$!
  for _ in $(seq 1 60); do
    swaymsg -t get_tree | grep -q "\"app_id\": \"$app_id\"" && break
    sleep 0.25
  done
  sleep 2
}
stop_app() { kill "$app"; wait "$app" 2>/dev/null; app=""; sleep 0.5; }

# The stand-in for Google, and a "browser" that follows its redirect.
port=$((20000 + RANDOM % 20000))
dart run "$root/test/sync/fake_google.dart" "$port" ada@example.org >"$out/google.log" 2>&1 &
google=$!
for _ in $(seq 1 80); do grep -q "fake google on" "$out/google.log" && break; sleep 0.25; done
grep -q "fake google on" "$out/google.log" || { echo "the stand-in for Google did not start"; cat "$out/google.log"; exit 1; }
export FWEEK_GOOGLE_SERVER="http://127.0.0.1:$port"
cat > "$fakebin/xdg-open" <<'SH'
#!/bin/sh
echo "browser: $1" >> "$BROWSER_LOG"
exec curl -sSL -o /dev/null "$1"
SH
chmod +x "$fakebin/xdg-open"
export PATH="$fakebin:$PATH" BROWSER_LOG="$out/browser.log"
files() { curl -s "http://127.0.0.1:$port/_test/files?account=ada@example.org"; }
tokens() { curl -s "http://127.0.0.1:$port/_test/tokens"; }

# Settings -> Sync -> Connect Google account (Google Drive is preselected).
connect() {  # <data folder>
  send "ctrl ,"; sleep 3
  click 392 346; sleep 0.6
  click 669 383
  for _ in $(seq 1 40); do
    [ "$(stored "$1" 'sync.last_ok')" -ge 1 ] && break
    sleep 0.5
  done
  sleep 0.5
}
add_task() {  # <text>: typed into Monday's first free row
  key Escape; sleep 0.4
  click 130 "$2"
  type_text "$1"; key Return; key Escape
}

start_app "$data_a"
connect "$data_a"
shot 01-a-connected
grep -q "accounts\|/o/oauth2/v2/auth" "$out/browser.log" 2>/dev/null \
  && pass "the app sent the browser to the sign-in page" || fail "the browser was not asked to open the sign-in page"
grep -q 'scope=openid+email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.appdata' "$out/browser.log" \
  && pass "it asked for the account and the app's own Drive folder, nothing more" \
  || fail "the sign-in asked for other scopes: $(grep -o 'scope=[^&]*' "$out/browser.log")"
[ "$(stored "$data_a" 'sync.last_ok')" -ge 1 ] && pass "device A connected its Google account and synced" || fail "device A did not connect"
add_task "Task from device A" 207
sleep 11
files | grep -q "fweek/changes/" && pass "A's changes are in the account's hidden app folder" || fail "nothing reached the app folder: $(files)"
stop_app
strings "$data_a"/planner.db* | grep -q "refresh-" && fail "the Google token is in the planner database" \
  || pass "the Google token is not in the planner database"

start_app "$data_b"
connect "$data_b"
shot 02-b-connected
[ "$(stored "$data_b" 'Task from device A')" -ge 1 ] && pass "device B, same account, received A's task" || fail "device B did not receive A's task"
stop_app

start_app "$data_a"
sleep 4
shot 03-a-restarted
before="$(tokens)"
send "ctrl ,"; sleep 3
click 392 346; sleep 0.6
shot 04-a-sync-section
# "Disconnect", beside "Sync now".
click 750 238; sleep 2
shot 05-a-disconnected
[ "$(tokens)" -lt "$before" ] && pass "disconnecting withdrew the app's access at Google ($before -> $(tokens) valid sign-ins)" \
  || fail "disconnecting left the access valid ($before -> $(tokens))"
files | grep -q "fweek/changes/" && pass "the planner's copy stayed in Drive" || fail "the files in Drive went away"
stop_app
grep -iE "error|exception" "$out/app.log" | grep -v "Notifications unavailable" | head -5 > "$out/errors.txt"
[ -s "$out/errors.txt" ] && fail "errors in the app log: $(head -1 "$out/errors.txt")" || pass "no errors in the app log"

echo
[ "$failures" -eq 0 ] && echo "google smoke run passed" || { echo "google smoke run: $failures failed"; exit 1; }
