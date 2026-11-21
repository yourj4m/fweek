#!/usr/bin/env python3
"""Frame timings of the Android app on the emulator, for comparing builds.

    tools/dev flutter build apk --profile --target-platform android-x64 \\
        --dart-define=WEEKTODO_PERF=true
    tools/android-emulator.sh start
    tools/dev python3 tools/android-perf.py <result.json> --apk build/app/outputs/flutter-apk/app-profile.apk

A build made with WEEKTODO_PERF fills an empty planner with the same few
hundred tasks and a calendar every time, and logs how long each frame took
and whether the screen was in motion at the time (see lib/perf_log.dart).
This script plays a fixed set of interactions with real touches and
summarises those timings per interaction.

What to read:

  * "moving" numbers are frames drawn while a finger was down or a page or
    list was still scrolling. A frame that takes too long then is a stutter
    one sees.
  * "resting" long frames happen while nothing moves, such as a week being
    prepared after a swipe has ended. They cost a little battery, not
    smoothness.
  * "build" is the app's own work per frame; "raster" is the graphics work.
    The emulator draws with the computer's graphics card and runs on its
    processor, so neither says how fast a phone is: read them as relative,
    one build against another, measured in the same session. Runs differ by
    a good deal from one to the next; measure each build more than once,
    alternating, and compare the merged results:

      tools/android-perf.py --compare before1.json,before2.json after1.json,after2.json
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
    """Per-frame build and raster milliseconds, and whether the screen was
    in motion, logged since the log was cleared."""
    log = ui.adb("logcat", "-d", "-s", "flutter:*", "-v", "raw", check=False)
    build, raster, moving = [], [], []
    for match in re.finditer(r"PERF b=([\d,]+) r=([\d,]+)(?: m=([01]+))?", log):
        b = [int(v) / 1000 for v in match.group(1).split(",")]
        build += b
        raster += [int(v) / 1000 for v in match.group(2).split(",")]
        flags = match.group(3)
        # A build without the motion log counts every frame as moving.
        moving += [c == "1" for c in flags] if flags else [True] * len(b)
    return build, raster, moving


def summarise(raw):
    build, raster, moving = raw["build"], raw["raster"], raw["moving"]
    in_motion = [b for b, m in zip(build, moving) if m]
    at_rest = [b for b, m in zip(build, moving) if not m]
    late = [b + r for b, r, m in zip(build, raster, moving) if m and b + r > BUDGET_MS]
    return {
        "frames": len(build),
        "moving_frames": len(in_motion),
        "moving_build_p50": round(percentile(in_motion, 0.5), 2),
        "moving_build_p90": round(percentile(in_motion, 0.9), 2),
        "moving_build_p99": round(percentile(in_motion, 0.99), 2),
        "moving_build_max": round(max(in_motion, default=0), 2),
        # Half the frame's time is what the app's own work may take if the
        # graphics work is to fit in the other half.
        "moving_build_over_8ms": sum(1 for b in in_motion if b > BUDGET_MS / 2),
        "moving_build_over_16ms": sum(1 for b in in_motion if b > BUDGET_MS),
        "moving_late_frames": len(late),
        "resting_build_over_16ms": sum(1 for b in at_rest if b > BUDGET_MS),
        "build_sum": round(sum(build), 1),
        "raster_p50": round(percentile(raster, 0.5), 2),
        "raster_p90": round(percentile(raster, 0.9), 2),
    }


def measure(name, action, results):
    ui.clear_logcat()
    time.sleep(0.4)
    action()
    time.sleep(1.8)  # the app logs about once a second
    build, raster, moving = frames_logged()
    raw = {"build": build, "raster": raster, "moving": moving}
    results[name] = {**summarise(raw), "raw": raw}
    r = results[name]
    print(f"{name:12s} moving: {r['moving_frames']:4d} frames, build p50 {r['moving_build_p50']:5.2f} "
          f"p90 {r['moving_build_p90']:5.2f} max {r['moving_build_max']:6.2f} ms, "
          f"over 8 ms {r['moving_build_over_8ms']:3d}, over 16 ms {r['moving_build_over_16ms']:3d}"
          f"   resting long builds: {r['resting_build_over_16ms']}")


def merged(paths):
    """The results of several runs as one: their frames put together."""
    out = {}
    for path in paths.split(","):
        with open(path) as f:
            run = json.load(f)
        for name, result in run.items():
            raw = out.setdefault(name, {"build": [], "raster": [], "moving": []})
            for key in raw:
                raw[key] += result["raw"][key]
    return {name: summarise(raw) for name, raw in out.items()}


def compare(before_paths, after_paths):
    before, after = merged(before_paths), merged(after_paths)
    keys = [
        ("moving_frames", "frames"),
        ("moving_build_p50", "build p50"),
        ("moving_build_p90", "build p90"),
        ("moving_build_p99", "build p99"),
        ("moving_build_max", "build max"),
        ("moving_build_over_8ms", "over 8 ms"),
        ("moving_build_over_16ms", "over 16 ms"),
        ("resting_build_over_16ms", "resting long"),
    ]
    print("While the screen is in motion (build time per frame in ms; before -> after)")
    print(f"{'':12s} " + " ".join(f"{label:>18s}" for _, label in keys))
    for name in before:
        if name not in after:
            continue
        cells = [f"{before[name][k]:>7} -> {after[name][k]:<7}" for k, _ in keys]
        print(f"{name:12s} " + " ".join(f"{c:>18s}" for c in cells))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", nargs="?")
    parser.add_argument("--apk")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"),
                        help="result files of each side, comma-separated")
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
    for _ in range(4):
        if rows:
            break
        # A full day late in the week: its line to type on is below the
        # screen. Any line further down will do.
        ui.swipe(width * 0.5, height * 0.7, width * 0.5, height * 0.4, 250, pause=0.8)
        rows = [n for n in ui.nodes() if n.cls.endswith("EditText") and n.top < height * 0.85]
    add_row = min(rows, key=lambda n: n.top)

    def find_task():
        """A task in the upper half of the screen, with room under it for a
        drag that stays above the bar at the bottom."""
        found = [n for n in ui.nodes()
                 if re.search(r" \d+$", n.label.split("\n")[0]) and n.height < 200
                 and height * 0.2 < n.top < height * 0.5]
        return found[0] if found else None

    task = find_task()
    menu = ui.find("Menu", exact=True)
    time.sleep(1.5)

    results = {}
    mid = height * 0.55

    def swipe_weeks():
        for _ in range(8):
            ui.swipe(width * 0.85, mid, width * 0.15, mid, 180, pause=0.9)
        for _ in range(8):
            ui.swipe(width * 0.15, mid, width * 0.85, mid, 180, pause=0.9)

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
    # The page does not always come to rest where it started (late in the
    # week it opens scrolled down to today, and scrolls back to its top):
    # what was a task's place may now be an empty line, and pressing that
    # brings the keyboard up instead of picking anything up. So the task to
    # open and to drag is looked for again, outside any measurement.
    task = find_task()
    time.sleep(1.5)
    if task:
        measure("task sheet", sheet, results)
        measure("drag", drag, results)
    else:
        print("note: no task in the middle of the screen; drag and task sheet were not measured")
    if menu:
        measure("menu", open_menu, results)
    measure("keyboard", keyboard, results)

    with open(args.out, "w") as f:
        json.dump(results, f)
    print(f"written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
