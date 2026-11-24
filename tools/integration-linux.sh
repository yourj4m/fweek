#!/usr/bin/env bash
# Runs the integration tests (integration_test/) against the real Linux app,
# in a headless Wayland session with a throwaway keyring, inside the build
# container:
#
#   tools/dev tools/integration-linux.sh
#
# The same tests run on Windows in the build service (.github/workflows).
set -uo pipefail
prlimit --core=1:1 --pid $$ 2>/dev/null || ulimit -c 0
if [ "${FWEEK_PRIVATE_BUS:-}" != 1 ]; then
  export FWEEK_PRIVATE_BUS=1
  exec dbus-run-session -- "$0" "$@"
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
export HOME="$(mktemp -d)"   # the throwaway keyring and app data live here
eval "$(printf 'integration' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
cat > "$XDG_RUNTIME_DIR/sway.conf" <<'CFG'
output HEADLESS-1 mode 1440x900 scale 1
default_border none
CFG
unset DISPLAY WAYLAND_DISPLAY
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  sway -c "$XDG_RUNTIME_DIR/sway.conf" >"$XDG_RUNTIME_DIR/sway.log" 2>&1 &
compositor=$!
trap 'kill $compositor 2>/dev/null; pkill -u "$(id -u)" -f "gnome-keyring-daemon --unlock" 2>/dev/null; rm -rf "$XDG_RUNTIME_DIR" "$HOME"' EXIT
for _ in $(seq 1 40); do
  socket="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)"
  [ -n "$socket" ] && break
  sleep 0.25
done
[ -n "${socket:-}" ] || { echo "sway did not start"; exit 1; }
export WAYLAND_DISPLAY="$(basename "$socket")" GDK_BACKEND=wayland LIBGL_ALWAYS_SOFTWARE=1
cd "$root" && flutter test integration_test -d linux "$@"
