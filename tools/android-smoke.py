#!/usr/bin/env python3
"""End-to-end check of the Android app on the emulator, with real touches.

    tools/android-emulator.sh start
    tools/dev python3 tools/android-smoke.py <output-dir> [--apk FILE] [--wait-reminder]

Starts from an empty planner (the app's data on the emulator is cleared) and
checks what only a real device shows: typing with the on-screen keyboard,
the list staying clear of keyboard and system bars, completing a task,
dragging one to another day by long press, turning the week with a swipe,
the task sheet, a reminder reaching Android's alarm service, and data
surviving a restart. Screenshots go to <output-dir>.

With --wait-reminder it also closes the app and waits (about two minutes)
for the reminder's notification to appear.
"""

import argparse
import datetime
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import android_ui as ui  # noqa: E402

failures = 0


def check(ok, what):
    global failures
    print(("ok:   " if ok else "FAIL: ") + what)
    if not ok:
        failures += 1
    return ok


def system_dump():
    """The whole screen's accessibility tree, system dialogs included."""
    return ui.shell("uiautomator dump /sdcard/sys.xml >/dev/null 2>&1; cat /sdcard/sys.xml", check=False)


def tap_system(resource_or_text):
    match = re.search(
        r'(?:text|resource-id)="[^"]*%s[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % resource_or_text,
        system_dump(),
    )
    if not match:
        return False
    x1, y1, x2, y2 = map(int, match.groups())
    ui.tap((x1 + x2) // 2, (y1 + y2) // 2, pause=1.5)
    return True


def fields():
    return [n for n in ui.nodes() if n.cls.endswith("EditText")]


def task(title):
    return ui.one(re.escape(title))


def open_sheet(title):
    node = task(title)
    ui.tap(node.left + 200, node.centre[1], pause=1.2)


def reminder_alarms():
    out = ui.shell(
        'dumpsys alarm | grep -A2 "tag=.walarm.:%s.REMINDER" | grep origWhen' % ui.PACKAGE, check=False
    )
    return re.findall(r"origWhen=(\S+ \S+)", out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--apk")
    parser.add_argument("--wait-reminder", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    def shot(name):
        ui.shot(os.path.join(args.out, name + ".png"))

    if args.apk:
        # A profile build is signed and numbered differently from a release
        # build, and Android installs neither over the other.
        if "Success" not in ui.adb("install", "-r", args.apk, timeout=180, check=False):
            ui.adb("uninstall", ui.PACKAGE, check=False)
            ui.adb("install", args.apk, timeout=180)
    # The emulator types through a "hardware" keyboard; show the on-screen
    # one anyway, since staying clear of it is part of what is checked.
    ui.shell("settings put secure show_ime_with_hard_keyboard 1")
    ui.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", check=False)
    width, height = ui.screen_size()
    ui.clear_logcat()
    ui.launch(clear=True)
    time.sleep(2)

    # --- first screen
    header = ui.find("Go to today")
    check(bool(header), "the planner starts and shows its header")
    today = ui.find("Today", exact=True)
    check(bool(today), "the week opens with today in view")
    shot("01-start")

    # --- typing tasks into today
    row = min((f for f in fields() if f.top > today[0].bottom), key=lambda f: f.top)
    ui.tap(*row.centre, pause=1.5)
    check(ui.keyboard_shown(), "tapping an empty line brings up the keyboard")
    ui.type_text("Buy oat milk")
    ui.key("ENTER")
    ui.type_text("Call the dentist")
    ui.key("ENTER")
    ui.back(pause=1.2)
    check(not any(f.focused for f in fields()), "putting the keyboard away ends typing")
    check(bool(ui.find("Buy oat milk")) and bool(ui.find("Call the dentist")), "both typed tasks are listed")
    shot("02-two-tasks")

    # --- the last line on the page must end up above the keyboard
    ui.tap(*fields()[-1].centre, pause=2.5)
    ime = re.search(r"type=ime frame=\[\d+,(\d+)\]", ui.shell("dumpsys window", check=False))
    focused = [f for f in fields() if f.focused]
    keyboard_top = int(ime.group(1)) if ime else height
    check(ime is not None and keyboard_top < height * 0.8, "the on-screen keyboard is showing")
    check(bool(focused) and focused[0].bottom <= keyboard_top, "the line being typed in sits above the keyboard")
    shot("03-keyboard")
    ui.type_text("Read that paper")
    ui.key("ENTER")
    ui.back(pause=1.2)
    # Early in the week, typing on the page's last line has scrolled today
    # out of view: back up the page. (The title would not do: on the week
    # of today it opens the month.)
    for _ in range(8):
        if ui.find(re.escape("Call the dentist")):
            break
        ui.swipe(width * 0.5, height * 0.35, width * 0.5, height * 0.8, 250, pause=0.6)

    # --- completing
    dentist = task("Call the dentist")
    ui.tap(dentist.right - 45, dentist.centre[1], pause=0.8)
    check("Mark as not done" in task("Call the dentist").label, "tapping the circle completes a task")

    # --- long-press drag to a neighbouring day
    headers = [n for n in ui.nodes() if re.fullmatch(r"\d{1,2} [A-Z][a-z]{2}", n.label)]
    today_header = min(headers, key=lambda n: abs(n.top - today[0].top))
    later = [n for n in headers if n.top > today_header.top + 10]
    target = later[0] if later else max((n for n in headers if n.top < today_header.top - 10), key=lambda n: n.top)
    milk = task("Buy oat milk")
    drop_y = target.bottom + 80
    ui.drag(milk.left + 200, milk.centre[1], 400, drop_y, hold=0.9, steps=14, release=False)
    time.sleep(0.4)
    shot("04-dragging")
    ui.finger_up(400, drop_y)
    headers = sorted((n for n in ui.nodes() if re.fullmatch(r"\d{1,2} [A-Z][a-z]{2}", n.label)), key=lambda n: n.top)
    moved = task("Buy oat milk")
    home = max((n for n in headers if n.top < moved.top), key=lambda n: n.top, default=None)
    check(home is not None and home.label == target.label,
          f"a long press picks a task up and drops it on another day ({target.label})")
    shot("05-dropped")

    # --- turning the week
    before = ui.one("Go to today").label
    ui.swipe(width * 0.85, height * 0.55, width * 0.15, height * 0.55, 200, pause=1.2)
    after = ui.one("Go to today").label
    check(after != before, "a swipe turns to the next week")
    ui.swipe(width * 0.15, height * 0.55, width * 0.85, height * 0.55, 200, pause=1.2)
    check(ui.one("Go to today").label == before, "and back again")

    # --- the task sheet
    open_sheet("Call the dentist")
    toolbar = ui.find("Add subtask")
    inset = re.search(r"type=navigationBars frame=\[\d+,(\d+)\]", ui.shell("dumpsys window", check=False))
    bar_top = int(inset.group(1)) if inset else height
    check(bool(toolbar) and toolbar[0].bottom <= bar_top, "the task sheet's toolbar clears the navigation bar")
    shot("06-sheet")
    ui.back(pause=0.8)
    check(not ui.find("Add subtask"), "Back closes the sheet")

    # --- a reminder two minutes from now
    open_sheet("Read that paper")
    ui.tap_on("Reminder", exact=True)
    time.sleep(1)
    hour, minute = map(int, ui.shell("date +%H:%M").strip().split(":"))
    due = datetime.datetime(2000, 1, 1, hour, minute) + datetime.timedelta(minutes=2)
    wanted = due.strftime("%H:%M")
    clock = [f for f in fields() if ":" in f.text][0]
    ui.tap(*clock.centre, pause=1.2)
    ui.key("MOVE_END", 0.1)
    for _ in range(6):
        ui.key("DEL", 0.05)
    ui.type_text(wanted)
    ui.tap_on("Set reminder")
    time.sleep(2)
    asked = tap_system("permission_allow_button")
    check(asked, "the first reminder asks for the notification permission")
    alarms = reminder_alarms()
    check(any(a.endswith(wanted + ":00.000") for a in alarms),
          f"the reminder is with Android's alarm service ({', '.join(alarms) or 'none'})")
    ui.back(pause=0.8)

    # --- leaving and returning
    ui.key("HOME", 1.5)
    ui.shell(f"am kill {ui.PACKAGE}", check=False)
    time.sleep(1)

    if args.wait_reminder:
        seen = False
        for _ in range(60):
            out = ui.shell(f'dumpsys notification --noredact | grep -A25 "pkg={ui.PACKAGE}"', check=False)
            if "Read that paper" in out:
                seen = True
                break
            time.sleep(3)
        check(seen, "the reminder's notification appears while the app is closed")
        ui.shell("cmd statusbar expand-notifications")
        time.sleep(1.5)
        shot("07-notification")
        if tap_system("Read that paper"):
            time.sleep(4)
            check(bool(ui.find("Add subtask")), "tapping the notification opens that task")
            ui.back(pause=0.8)
        ui.key("HOME", 1.0)
        ui.shell(f"am kill {ui.PACKAGE}", check=False)

    ui.launch()
    time.sleep(2)
    kept = all(ui.find(re.escape(t)) for t in ("Buy oat milk", "Call the dentist", "Read that paper"))
    check(kept, "tasks are still there after the app was closed")
    shot("08-restarted")

    errors = ui.logcat_errors()
    check(not errors, "no errors in the device log" + ("" if not errors else ": " + errors[0][:160]))

    print()
    print("android smoke run passed" if failures == 0 else f"android smoke run FAILED ({failures})")
    return failures


if __name__ == "__main__":
    sys.exit(main())
