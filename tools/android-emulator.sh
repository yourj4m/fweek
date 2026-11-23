#!/usr/bin/env bash
# Start or stop the headless Android emulator used for testing.
#
#   tools/android-emulator.sh start    boot (or reuse) the "fweek" device and wait until it is ready
#   tools/android-emulator.sh stop     shut it down
#   tools/android-emulator.sh status
#
# The device is created by tools/setup-android.sh --emulator. It runs without
# a window; look at it with tools/dev adb exec-out screencap -p > shot.png.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev="$root/tools/dev"
log="$root/.tools/android-user/emulator.log"

running() { "$dev" adb devices 2>/dev/null | grep -q '^emulator-[0-9]*[[:space:]]*device$'; }

case "${1:-}" in
  start)
    if ! running; then
      mkdir -p "$(dirname "$log")"
      # setsid: the emulator must outlive this script and its terminal.
      # prlimit: should the emulator crash, keep that off the desktop's crash
      # reporter (the container shares the host's kernel).
      # -gpu host: render with this machine's graphics driver. The software
      # modes do not survive here: SwiftShader segfaults a few seconds into
      # the boot, and ANGLE-on-SwiftShader dies when the app starts drawing.
      setsid prlimit --core=1:1 -- "$dev" emulator -avd fweek -no-window \
        -no-audio -no-boot-anim -no-snapshot -no-metrics \
        -gpu "${FWEEK_EMULATOR_GPU:-host}" ${FWEEK_EMULATOR_ARGS:--feature -Vulkan} \
        -memory 3072 -cores 2 \
        >"$log" 2>&1 < /dev/null &
    fi
    "$dev" adb wait-for-device
    for _ in $(seq 1 180); do
      [ "$("$dev" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
      sleep 2
    done
    [ "$("$dev" adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || { echo "the emulator did not finish booting; see $log" >&2; exit 1; }
    # Steady state for scripted input: no animations, screen stays on.
    for key in window_animation_scale transition_animation_scale animator_duration_scale; do
      "$dev" adb shell settings put global "$key" 0
    done
    "$dev" adb shell svc power stayon true
    "$dev" adb shell input keyevent KEYCODE_WAKEUP
    "$dev" adb shell wm dismiss-keyguard
    echo "emulator ready: Android $("$dev" adb shell getprop ro.build.version.release | tr -d '\r')"
    ;;
  stop)
    running && "$dev" adb emu kill >/dev/null 2>&1 || true
    ;;
  status)
    running && echo running || echo stopped
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2
    ;;
esac
