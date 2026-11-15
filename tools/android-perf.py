#!/usr/bin/env python3
"""Frame timings of the Android app on the emulator, for comparing builds.

    tools/dev flutter build apk --profile --target-platform android-x64 \\
        --dart-define=WEEKTODO_PERF=true
    tools/android-emulator.sh start
    tools/dev python3 tools/android-perf.py <result.json> --apk build/app/outputs/flutter-apk/app-profile.apk

A build made with WEEKTODO_PERF fills an empty planner with the same few
hundred tasks and a calendar every time, and logs how long each frame took
(see lib/perf_log.dart). This script plays a fixed set of interactions with
real touches and summarises those timings per interaction.

The emulator draws with the computer's graphics card, so the "raster"
numbers say little about a phone. The "build" numbers are the app's own
work per frame; a phone's processor is several times slower than a
desktop's, so read them as relative: before against after.

Compare two results with:  tools/android-perf.py --compare before.json after.json
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import android_ui as ui  # noqa: E402

BUDGET_MS = 1000 / 60


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def frames_logged():
    """Per-frame (build, raster) milliseconds logged since the log was cleared."""
    log = ui.adb("logcat", "-d", "-s", "flutter:*", "-v", "raw", check=False)
    build, raster = [], []
    for match in re.finditer(r"PERF b=([\d,]+) r=([\d,]+)", log):
        build += [int(v) / 1000 for v in match.group(1).split(",")]
        raster += [int(v) / 1000 for v in match.group(2).split(",")]
    return build, raster


def measure(name, action, results):
    ui.clear_logcat()
    time.sleep(0.4)
    action()
    time.sleep(1.8)  # the app logs about once a second
    build, raster = frames_logged()
    total = [b + r for b, r in zip(build, raster)]
    results[name] = {
        "frames": len(build),
        "build_p50": round(percentile(build, 0.5), 2),
        "build_p90": round(percentile(build, 0.9), 2),
        "build_p99": round(percentile(build, 0.99), 2),
        "build_max": round(max(build, default=0), 2),
        "build_sum": round(sum(build), 1),
        "raster_p50": round(percentile(raster, 0.5), 2),
        "raster_p90": round(percentile(raster, 0.9), 2),
        "raster_max": round(max(raster, default=0), 2),
        "build_over_8ms": sum(1 for b in build if b > BUDGET_MS / 2),
        "build_over_16ms": sum(1 for b in build if b > BUDGET_MS),
        "frame_over_16ms": sum(1 for t in total if t > BUDGET_MS),
    }
    r = results[name]
    print(f"{name:14s} frames {r['frames']:4d}  build p50 {r['build_p50']:6.2f} p90 {r['build_p90']:6.2f} "
          f"max {r['build_max']:7.2f} sum {r['build_sum']:8.1f} ms  slow builds {r['build_over_16ms']:3d}  "
          f"slow frames {r['frame_over_16ms']:3d}")


def compare(before_path, after_path):
    with open(before_path) as f:
        before = json.load(f)
    with open(after_path) as f:
        after = json.load(f)
    keys = ["frames", "build_p50", "build_p90", "build_max", "build_sum", "build_over_16ms", "frame_over_16ms"]
    print(f"{'':14s} " + " ".join(f"{k:>24s}" for k in keys))
    for name in before:
        if name not in after:
            continue
        cells = [f"{before[name][k]:>10} -> {after[name][k]:<10}" for k in keys]
        print(f"{name:14s} " + " ".join(f"{c:>24s}" for c in cells))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", nargs="?")
    parser.add_argument("--apk")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = parser.parse_args()
    if args.compare:
        compare(*args.compare)
        return 0
    if not args.out:
        parser.error("give a file for the result")

    if args.apk:
        # A profile build is signed differently from a release build.
        ui.adb("uninstall", ui.PACKAGE, check=False)
        ui.adb("install", args.apk, timeout=240)
    ui.shell("settings put secure show_ime_with_hard_keyboard 1")
    ui.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", check=False)
    width, height = ui.screen_size()
    ui.launch(clear=True)
    # The first start writes the test planner.
    for _ in range(40):
        time.sleep(1.5)
        if ui.find("Today", exact=True):
            break
    else:
        print("the app did not come up", file=sys.stderr)
        return 1
    time.sleep(2)

    # Where things are, read once: asking for the accessibility tree makes
    # the app build it, which must not happen inside a measurement.
    today = ui.find("Today", exact=True)[0]
    rows = [n for n in ui.nodes() if n.cls.endswith("EditText") and n.top > today.bottom]
    add_row = min(rows, key=lambda n: n.top)
    tasks = [n for n in ui.nodes()
             if re.search(r" \d+$", n.label) and "Mark as" not in n.label and n.height < 200
             and height * 0.25 < n.top < height * 0.6]
    task = tasks[0] if tasks else None
    menu = ui.find("Menu", exact=True)
    time.sleep(1.5)

    results = {}
    mid = height * 0.55

    def swipe_weeks():
        for _ in range(8):
            ui.swipe(width * 0.85, mid, width * 0.15, mid, 180, pause=0.7)
        for _ in range(8):
            ui.swipe(width * 0.15, mid, width * 0.85, mid, 180, pause=0.7)

    def scroll():
        for _ in range(6):
            ui.swipe(width * 0.5, height * 0.75, width * 0.5, height * 0.3, 200, pause=0.5)
        for _ in range(6):
            ui.swipe(width * 0.5, height * 0.3, width * 0.5, height * 0.75, 200, pause=0.5)

    def keyboard():
        ui.tap(*add_row.centre, pause=1.5)
        for text in ("Perf one", "Perf two", "Perf three"):
            ui.type_text(text, pause=0.2)
            ui.key("ENTER", 0.4)
        ui.back(pause=1.2)

    def drag():
        x, y = task.left + 200, task.centre[1]
        ui.drag(x, y, x, y + height * 0.25, hold=0.9, steps=30, step_ms=25)

    def sheet():
        for _ in range(4):
            ui.tap(task.left + 200, task.centre[1], pause=0.9)
            ui.back(pause=0.8)

    def open_menu():
        for _ in range(4):
            ui.tap(*menu[0].centre, pause=0.7)
            ui.back(pause=0.6)

    measure("swipe weeks", swipe_weeks, results)
    measure("scroll", scroll, results)
    if task:
        measure("task sheet", sheet, results)
        measure("drag", drag, results)
    if menu:
        measure("menu", open_menu, results)
    measure("keyboard", keyboard, results)

    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
