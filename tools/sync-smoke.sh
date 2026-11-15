#!/usr/bin/env bash
# End-to-end check of sync in the built app, against a real Nextcloud server.
#
#   tools/dev tools/sync-smoke.sh <output-dir> <server-url> <user> <app-password>
#
# Two planners (two data folders, standing in for two devices) are connected
# to the same Nextcloud account through the settings screen, using real
# pointer and keyboard events on a headless Wayland compositor:
#
#   1. device A connects and adds a task
#   2. device B connects and must receive it, then adds one of its own
#   3. device A is started again and must receive B's task on its own, using
#      the password it saved earlier
#
# The app keeps the password in the system keyring. So that this never
# touches a real keyring, the whole run happens inside a private D-Bus
# session with its own throwaway keyring.
#
# Use a test server or a dedicated test account: the run creates a folder
# named "WeekToDo sync test <random>" in the account and leaves it there.
#
# To check that an update keeps the connection, point WEEKTODO_OLD_BIN at the
# executable of an earlier build: device A is then set up with that build and
# restarted (step 3) with the current one, on the same data and keyring.
# tools/dev does not pass variables on, so set them inside the container:
#
#   tools/dev env WEEKTODO_OLD_BIN=$HOME/.local/opt/weektodo/weektodo \
#       WEEKTODO_OLD_FORM=1 tools/sync-smoke.sh <output-dir> ...
#
# WEEKTODO_OLD_FORM names where the earlier build has its sync form (see
# "form" below); leave it out when both builds have it in the same place.
set -uo pipefail
# A crash during a test run must not reach the desktop's crash reporter: the
# container shares the host's kernel, so the report would pop up there. With
# a core limit of one byte the kernel skips the core handler altogether.
prlimit --core=1:1 --pid $$ 2>/dev/null || ulimit -c 0
if [ "${WEEKTODO_PRIVATE_BUS:-}" != 1 ]; then
  export WEEKTODO_PRIVATE_BUS=1
  exec dbus-run-session -- "$0" "$@"
fi

out="${1:?output directory}"; server="${2:?server url}"; user="${3:?user}"; password="${4:?app password}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/build/linux/x64/release/bundle/weektodo"
app_id="io.github.yourj4m.weektodo"
folder="WeekToDo sync test $(printf '%04x' $RANDOM)"
[ -x "$bin" ] || { echo "No release build; run: tools/dev flutter build linux --release" >&2; exit 1; }
mkdir -p "$out"
: >"$out/app.log"

export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
export HOME="$(mktemp -d)"   # the throwaway keyring lives here
data_a="$(mktemp -d)"; data_b="$(mktemp -d)"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# A keyring that exists only for this run.
eval "$(printf 'smoke-test' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
sleep 0.5

cat > "$XDG_RUNTIME_DIR/sway.conf" <<'CFG'
output HEADLESS-1 mode 1440x1400 scale 1 position 0 0
default_border none
focus_follows_mouse no
CFG
unset DISPLAY WAYLAND_DISPLAY
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
sway -c "$XDG_RUNTIME_DIR/sway.conf" >"$out/sway.log" 2>&1 &
compositor=$!
app=""; input=""
trap 'exec 3>&-; kill $app $input $compositor 2>/dev/null; pkill -u "$(id -u)" -f "gnome-keyring-daemon --unlock" 2>/dev/null; rm -rf "$data_a" "$data_b" "$XDG_RUNTIME_DIR" "$HOME"' EXIT
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
python3 "$root/tools/wl-input.py" --protocols "$bindings" --extent 1440 1400 \
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
  WEEKTODO_DATA_DIR="$1" "${2:-$bin}" >>"$out/app.log" 2>&1 &
  app=$!
  for _ in $(seq 1 60); do
    swaymsg -t get_tree | grep -q "\"app_id\": \"$app_id\"" && break
    sleep 0.25
  done
  sleep 2
}
stop_app() { kill "$app"; wait "$app" 2>/dev/null; app=""; sleep 0.5; }

# Where the sync form sits in the settings card of a 1440x1400 window: the
# four fields (server, login name, app password, folder) and the Connect
# button, top to bottom. It moves when the settings above it grow.
#   1: builds up to the calendars release (one row of themes)
#   2: three rows of themes
form() {
  case "$1" in
    1) echo "921 973 1025 1077 1203" ;;
    *) echo "1074 1126 1178 1230 1356" ;;
  esac
}
current_form=2

# Fills in the sync settings and connects.
connect() {  # <data folder> [form]
  read -r y_server y_user y_password y_folder y_connect <<<"$(form "${2:-$current_form}")"
  # The settings card takes a moment to appear with software rendering.
  send "ctrl ,"; sleep 3
  click 780 "$y_server";   type_text "$server"
  click 780 "$y_user";     type_text "$user"
  click 780 "$y_password"; type_text "$password"
  click 780 "$y_folder"
  for _ in $(seq 1 12); do key BackSpace; done
  type_text "$folder"
  click 549 "$y_connect"
  # Wait for the first sync to finish.
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

echo "folder: $folder"
old_bin="${WEEKTODO_OLD_BIN:-$bin}"
[ "$old_bin" = "$bin" ] || echo "device A starts on the earlier build: $old_bin"
start_app "$data_a" "$old_bin"
if [ "$old_bin" = "$bin" ]; then connect "$data_a"; else connect "$data_a" "${WEEKTODO_OLD_FORM:-$current_form}"; fi
shot 01-a-connected
[ "$(stored "$data_a" 'sync.last_ok')" -ge 1 ] && pass "device A connected and synced" || fail "device A did not connect"
add_task "Task from device A" 207
shot 02-a-task
# Edits are uploaded a few seconds after typing stops.
sleep 11
stop_app

start_app "$data_b"
connect "$data_b"
shot 03-b-connected
[ "$(stored "$data_b" 'Task from device A')" -ge 1 ] && pass "device B received A's task" || fail "device B did not receive A's task"
add_task "Reply from device B" 249
shot 04-b-task
sleep 11
stop_app

# Device A again: it must sync by itself, with the password from the keyring.
start_app "$data_a"
for _ in $(seq 1 30); do
  [ "$(stored "$data_a" 'Reply from device B')" -ge 1 ] && break
  sleep 0.5
done
shot 05-a-restarted
what="after a restart"
[ "$old_bin" = "$bin" ] || what="after being updated to the current build"
[ "$(stored "$data_a" 'Reply from device B')" -ge 1 ] && pass "device A received B's task $what, without re-entering the password" || fail "device A did not receive B's task $what"
stop_app

# The secure-storage plugin files its entry under this account name.
if secret-tool search --all account "$app_id.secureStorage" 2>&1 | grep -q "secret = "; then
  pass "the password is in the keyring"
else
  fail "the password is not in the keyring"
fi
if strings "$data_a"/planner.db* "$data_b"/planner.db* | grep -q -F -- "$password"; then
  fail "the password was written to the planner database"
else
  pass "the password is not in the planner database"
fi

pattern='EXCEPTION|Unhandled|Unsupported operation|FATAL'
errors="$(grep -c -E "$pattern" "$out/app.log" || true)"
if [ "$errors" -eq 0 ]; then pass "no errors in the app log"; else fail "$errors error lines in the app log"; grep -E "$pattern" "$out/app.log" | head -5; fi

echo
[ "$failures" -eq 0 ] && echo "sync smoke run passed" || echo "sync smoke run FAILED ($failures)"
exit "$failures"
