#!/usr/bin/env bash
# Start the built app on a headless X display, drive it with synthetic input
# and save screenshots. Run inside the dev container:
#
#   tools/dev tools/smoke-run.sh <output-dir>
#
# Uses a throwaway data folder, so the real planner is never touched.
set -euo pipefail
out="${1:?output directory}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$out"
data="$(mktemp -d)"
display=":97"

Xvfb "$display" -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
trap 'kill "$app" "${wm:-}" "$xvfb" 2>/dev/null || true; rm -rf "$data"' EXIT
sleep 1

export DISPLAY="$display" GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
# Text input only reaches a GTK window that a window manager has focused.
openbox >/dev/null 2>&1 &
wm=$!
sleep 0.5
export WEEKLEAF_DATA_DIR="$data"
"$root/build/linux/x64/release/bundle/weekleaf" >"$out/app.log" 2>&1 &
app=$!

for _ in $(seq 1 40); do
  win="$(xdotool search --onlyvisible --name Weekleaf 2>/dev/null | head -1 || true)"
  [ -n "$win" ] && break
  sleep 0.5
done
[ -n "${win:-}" ] || { echo "window never appeared"; cat "$out/app.log"; exit 1; }
xdotool windowactivate "$win" windowsize "$win" 1440 900
sleep 1.5
shot() { import -window "$win" "$out/$1.png"; echo "shot $1"; }
at() { xdotool mousemove --window "$win" "$1" "$2"; }
shot 01-empty

# Type two tasks into Monday's first row.
at 130 207; xdotool click 1
sleep 0.4
xdotool type --delay 20 "Typed in the real app"
xdotool key Return
xdotool type --delay 20 "Second task"
xdotool key Return
sleep 0.3
shot 02-typing
xdotool key Escape
sleep 0.3

# Open the first task and type a note.
at 100 207; xdotool click 1
sleep 0.8
shot 03-dialog
at 620 285; xdotool click 1
sleep 0.3
xdotool type --delay 20 "A note typed through X11."
sleep 0.8
xdotool key Escape
sleep 0.5

# Drag the second task to Wednesday.
at 70 249; xdotool mousedown 1
for x in 90 150 250 400 520 560; do at "$x" 300; sleep 0.08; done
shot 04-dragging
xdotool mouseup 1
sleep 0.6
shot 05-dropped

# Next week and back with the keyboard, then month view.
xdotool key Right
sleep 0.4
shot 06-next-week
xdotool key t
xdotool key m
sleep 0.5
shot 07-month

kill "$app"; wait "$app" 2>/dev/null || true
# Reopen: the data must still be there.
"$root/build/linux/x64/release/bundle/weekleaf" >>"$out/app.log" 2>&1 &
app=$!
sleep 4
win="$(xdotool search --onlyvisible --name Weekleaf | head -1)"
xdotool windowactivate "$win" windowsize "$win" 1440 900
sleep 1
xdotool key m
sleep 0.5
shot 08-reopened
echo "--- app log ---"; cat "$out/app.log"
