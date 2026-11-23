#!/usr/bin/env python3
"""Checks of the newer features on the Android emulator, with real touches.

    tools/android-emulator.sh start
    tools/dev python3 tools/android-features.py <output-dir> [--apk FILE] [--events]

On a fresh planner: the editing bar above the keyboard while a task is
typed, a time set from it, the menu on a long press, a place found through
the place search and handed to the map app, the Tasks page (a new list, a
task typed into it and planned for a day), and the form for a new event
(typed above the keyboard, all day or with times, over several days).

With --events the app must be a build made with FWEEK_PERF (see
tools/android-perf.py), which starts with a calendar of test events: then
events as rows, an event over several days as a bar, hiding an event and
undoing it, and hiding the whole calendar from the menu are checked too,
without clearing the planner first.

The place search check asks the public search server one question.
"""

import argparse
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


def fields():
    return [n for n in ui.nodes() if n.cls.endswith("EditText")]


def hold(x, y, seconds=0.9):
    """A long press that is let go without moving."""
    ui.shell(f"input motionevent DOWN {int(x)} {int(y)}")
    time.sleep(seconds)
    ui.shell(f"input motionevent UP {int(x)} {int(y)}")
    time.sleep(1.0)


def keyboard_top(height):
    ime = re.search(r"type=ime frame=\[\d+,(\d+)\]", ui.shell("dumpsys window", check=False))
    return int(ime.group(1)) if ime else height


def started_geo():
    """Whether Android was asked to show a geo: address since the log was cleared."""
    log = ui.adb("logcat", "-d", "-v", "brief", check=False)
    return bool(re.search(r"START u0 \{act=android\.intent\.action\.VIEW dat=geo:", log))


def planner(out, shot, width, height):
    ui.launch(clear=True)
    time.sleep(2)
    today = ui.find("Today", exact=True)
    check(bool(today), "the planner starts")

    # --- the editing bar
    row = min((f for f in fields() if f.top > today[0].bottom), key=lambda f: f.top)
    ui.tap(*row.centre, pause=1.8)
    bar = ui.find("Time", exact=True)
    top = keyboard_top(height)
    focused = [f for f in fields() if f.focused]
    check(bool(bar) and bool(ui.find("Place", exact=True)) and bool(ui.find("Colour", exact=True)),
          "typing a task brings up the editing bar: time, place, note, colour")
    check(bool(bar) and bar[0].bottom <= top, "the bar sits above the keyboard")
    check(bool(bar) and bool(focused) and focused[0].bottom <= bar[0].top,
          "the line being typed in sits above the bar")
    shot("f01-editing-bar")

    ui.tap(*bar[0].centre, pause=1.0)
    check(bool(ui.find("Hours", exact=True)) and bool(ui.find("Minutes", exact=True)),
          "Time opens wheels for hours and minutes, in place")
    check(ui.keyboard_shown(), "and the keyboard stays")
    shot("f02-time-wheels")
    ui.tap_on("Set", exact=True)
    time.sleep(0.6)
    ui.type_text("Dentist check")
    ui.key("ENTER")
    ui.type_text("Plain task")
    ui.key("ENTER")
    # The bar's first button: what is typed next is an event.
    switch = ui.find(r"^A task; tap to make it an event")
    if check(bool(switch), "the bar has a switch between task and event"):
        ui.tap(*switch[0].centre, pause=0.8)
        ui.type_text("Team lunch")
        ui.key("ENTER")
    ui.back(pause=1.2)
    timed = ui.find(r"\d{1,2}:00 Dentist check")
    check(bool(timed), "the task typed next carries the time set in the bar")
    check(bool(ui.find("Plain task")) and not ui.find(r"\d{1,2}:00 Plain task"),
          "and the task after it does not")
    lunch = ui.find("Team lunch")
    check(bool(lunch) and "Mark as" not in lunch[0].label
          and "Mark as" in ui.one("Plain task").label,
          "what was typed as an event has no circle to tick; the tasks have")
    shot("f03-tasks")

    # --- the menu
    task = ui.one("Dentist check")
    hold(task.left + 200, task.centre[1])
    check(bool(ui.find("Duplicate", exact=True)), "a long press that is let go opens the task's menu")
    shot("f04-menu")
    ui.tap_on("Mark as done", exact=True)
    time.sleep(0.8)
    check("Mark as not done" in ui.one("Dentist check").label, "the menu completes the task")

    # --- a place, through the search, to the map app
    task = ui.one("Plain task")
    hold(task.left + 200, task.centre[1])
    ui.tap_on("Add a place", exact=True)
    time.sleep(1.5)
    ui.type_text("Brandenburger Tor")
    time.sleep(4)
    found = [n for n in ui.nodes() if "Berlin" in n.label and "Brandenburger Tor" in n.label]
    shot("f05-place-search")
    if check(bool(found), "the place search suggests places while typing"):
        ui.tap(*found[0].centre, pause=1.5)
    else:
        print("note: no suggestions (no network in the emulator?); the typed text is kept")
    # Picking a suggestion ends typing and puts the keyboard away; without
    # one it is still up, and Back closes it (a second Back would close the
    # sheet).
    if ui.keyboard_shown():
        ui.back(pause=1.0)
    arrow = ui.find(r"^Open .* in the map app$")
    check(bool(arrow), "a task with a place offers to open it in the map app")
    if arrow:
        ui.clear_logcat()
        ui.tap(*arrow[0].centre, pause=2.5)
        check(started_geo(), "the place is handed to Android as a geo: address")
        shot("f06-map")
        ui.launch()
        time.sleep(1.5)
    if ui.find("Add subtask"):
        ui.back(pause=0.8)  # closes the sheet
    check(bool(ui.find("Brandenburger Tor")), "the place shows under the task in the week")

    # --- the Tasks page: the bar at the bottom, a new list, a task planned
    # for a day from there
    tab = ui.find("Tasks", exact=True)
    if not check(bool(tab), "a bar at the bottom leads to the Tasks page"):
        return
    check(tab[0].bottom <= height and tab[0].top > height * 0.8,
          "the bar is at the bottom of the screen")
    ui.tap(*tab[0].centre, pause=1.5)
    check(bool(ui.find(r"^To do, \d+ to do, open$")), "which opens with the first list")
    plus = ui.find("New list", exact=True)
    if check(bool(plus), "after the names of the lists a button makes a new one"):
        ui.tap(*plus[0].centre, pause=1.5)
        ui.type_text("Films")
        ui.key("ENTER", 1.2)
        # Back puts the keyboard away; with none up it would leave the page.
        if ui.keyboard_shown():
            ui.back(pause=0.8)
        check(bool(ui.find("Films, 0 to do, open", exact=True)),
              "the list it creates is named in a card and opens")
        shot("f07-list")
        # The first line of the open list.
        lines = fields()
        if check(bool(lines), "the open list has a line to type on"):
            ui.tap(*lines[0].centre, pause=1.8)
            check(not ui.find("Time", exact=True) and bool(ui.find("Place", exact=True)),
                  "the bar over the keyboard offers no time there: a list's task has no day")
            ui.type_text("Stalker")
            ui.key("ENTER")
            ui.back(pause=1.2)
            film = ui.find("Stalker")
            if check(bool(film), "what is typed there is a task of the list"):
                hold(film[0].left + 200, film[0].centre[1])
                plan = ui.find("Plan for")
                if check(bool(plan), "a long press on it offers to plan it for a day"):
                    ui.tap(*plan[0].centre, pause=1.0)
                    ui.tap_on("Tomorrow", exact=True)
                    time.sleep(1.0)
                    check(any("Tomorrow" in n.label or "Tomorrow" in n.text for n in ui.nodes()),
                          "planned, it stays in its list, marked with the day")
                    shot("f08-planned")
    # Going back leads to the week, not out of the app.
    ui.back(pause=1.2)
    check(bool(ui.find("Go to today")), "going back from the tasks leads to the week")
    # Tomorrow may be on the next week's page; the task is in the planner
    # either way, which the Tasks page has shown.
    shot("f09-week")

    # --- a new event: the header's button opens a sheet with all an event
    # can have; over several days it is a bar on each of its days
    plus = ui.find("New event", exact=True)
    if not check(bool(plus), "the header has a button for a new event"):
        return
    ui.tap(*plus[0].centre, pause=2.0)
    check(bool(ui.find("Add event", exact=True)), "which opens the form")
    ui.type_text("Dinner out")
    time.sleep(0.6)
    top = keyboard_top(height)
    typed = [n for n in fields() if "Dinner out" in n.text]
    check(bool(typed) and typed[0].bottom <= top,
          "the title is typed above the keyboard")
    shot("f10-form-typing")
    # The keyboard's key puts the keyboard away and leaves the form open.
    ui.key("ENTER", 1.2)
    if ui.keyboard_shown():
        ui.back(pause=0.8)
    check(bool(ui.find("Add event", exact=True)) and not ui.find("Event added"),
          "the keyboard's key leaves the form open, with nothing added yet")
    whole = ui.find("All day", exact=True)
    if check(bool(whole), "the form says the event is all day"):
        ui.tap(*whole[0].centre, pause=1.0)
        check(bool(ui.find(r"^Start time, ")) and bool(ui.find(r"^End time, ")),
              "switched off, it has a start and an end")
        ui.tap(*ui.find("All day", exact=True)[0].centre, pause=1.0)
    last = ui.find(r"^End day, ")
    if check(bool(last), "it has an end day"):
        ui.tap(*last[0].centre, pause=1.5)
        ui.tap_on("Next month", exact=True)
        time.sleep(0.8)
        ui.tap_on("15", exact=True)
        time.sleep(1.2)
        check(bool(ui.find(r"^End day, \w+, 15 ")), "which is picked in a month")
    shot("f11-form")
    add = ui.find("Add event", exact=True)
    if check(bool(add) and add[0].bottom <= height, "the button that adds it is on the screen"):
        ui.tap(*add[0].centre, pause=1.5)
        said = [n.label or n.text for n in ui.nodes()]
        check(any("Event added" in t or t.startswith("Added on") for t in said),
              "the event is added, and a message says so")
        check(any(t.startswith("Event over several days: Dinner out") for t in said),
              "over several days it is a bar on its days")
        shot("f12-added")


def pull_to_sync(shot, width, height):
    """On a phone the page, at its top, is pulled down to sync everything."""
    ui.launch()
    time.sleep(1.5)
    if ui.keyboard_shown():
        ui.back(pause=0.8)
    week = ui.find("Week", exact=True)
    if week:
        ui.tap(*week[0].centre, pause=1.2)
    check(not ui.find("Sync everything"),
          "the phone's header has no sync button: there the page is pulled")
    # Pulls from the middle of the page: while the page is not at its top
    # they scroll it there, and the one that starts at the top syncs. The
    # message stays for six seconds; one look at the screen takes two.
    x = width // 2
    said = []
    for _ in range(4):
        ui.swipe(x, int(height * 0.38), x, int(height * 0.82), ms=350, pause=1.2)
        said = ui.find("kept on this device")
        if said:
            break
    shot("f13-pulled")
    check(bool(said), "pulled down from its top, the page syncs: a copy of the planner is kept")


def settings(shot, width, height):
    """The settings are a list of sections; a tap opens one, and the back
    button leads to the list again before it leaves the settings."""
    ui.launch()
    time.sleep(1.5)
    if ui.keyboard_shown():
        ui.back(pause=0.8)
    ui.tap_on("Menu", exact=True)
    time.sleep(0.8)
    ui.tap_on("Settings", exact=True)
    time.sleep(1.5)
    names = ("General", "Appearance", "Tasks", "Calendars", "Sync", "Data", "Advanced")
    listed = [name for name in names if ui.find(f"{name} settings", exact=True)]
    shot("f14-settings")
    check(len(listed) == len(names),
          "the settings open on the list of their sections" + ("" if len(listed) == len(names) else f": {listed}"))
    check(not ui.find("Sort completed tasks down"), "which shows none of them yet")

    ui.tap_on("Tasks settings", exact=True)
    time.sleep(1.2)
    shot("f15-settings-tasks")
    check(bool(ui.find("Sort completed tasks down")) and bool(ui.find("All settings", exact=True)),
          "a tap opens a section, with an arrow back to the list")
    check(bool(ui.find("whether or not the app is open")),
          "the Tasks section says how reminders reach a phone")
    ui.back(pause=1.2)
    check(bool(ui.find("Sync settings", exact=True)) and not ui.find("Sort completed tasks down"),
          "the back button leads from a section to the list")

    ui.tap_on("Calendars settings", exact=True)
    time.sleep(1.2)
    shot("f16-settings-calendars")
    check(bool(ui.find("Add calendar", exact=True)), "another section opens from the list")
    arrow = ui.find("All settings", exact=True)
    if arrow:
        ui.tap(*arrow[0].centre, pause=1.2)
    check(bool(ui.find("Data settings", exact=True)) and not ui.find("Add calendar", exact=True),
          "the arrow leads back to the list as well")
    ui.back(pause=1.2)
    check(not ui.find("Data settings", exact=True) and bool(ui.find("Menu", exact=True)),
          "and the back button leaves the settings from the list")


def events(out, shot, width, height):
    # From an empty planner, which the profile build fills with its test
    # tasks and calendar: what an earlier run hid stays hidden otherwise.
    ui.launch(clear=True)
    for _ in range(40):
        time.sleep(1.5)
        if ui.find("Menu", exact=True):
            break
    time.sleep(2)
    # Today heads the page; earlier days of the week are above.
    meeting = []
    for _ in range(6):
        meeting = ui.find(r"Weekly meeting \d")
        if meeting:
            break
        ui.swipe(width * 0.5, height * 0.4, width * 0.5, height * 0.75, 250, pause=0.6)
    if not check(bool(meeting), "calendar events show as rows of their day"):
        return
    shot("e01-events")
    seen = ui.nodes()
    check(not any("Mark as" in n.label for n in seen if "Weekly meeting" in n.label)
          and any("Mark as" in n.label for n in seen),
          "an event has no circle to tick; tasks have")

    row = meeting[0]
    title = re.search(r"Weekly meeting \d", row.label).group(0)
    hold(row.left + 200, row.centre[1])
    check(bool(ui.find("Turn into a task", exact=True)) and bool(ui.find(r"^Hide Calendar"))
          and not ui.find("Mark as done", exact=True),
          "a long press on an event opens its menu, which can turn it into a task")
    shot("e02-event-menu")
    ui.tap_on("Hide", exact=True)
    time.sleep(0.6)
    # One look at the screen for both: the offer to undo goes away after a
    # few seconds, and each look takes a couple.
    seen = ui.nodes()
    check(not any(title in n.label for n in seen), "Hide takes the event out of the week")
    undo = [n for n in seen if n.label == "Undo"]
    if check(bool(undo), "and offers Undo"):
        ui.tap(*undo[0].centre, pause=1.0)
        check(bool(ui.find(title)), "which brings it back")

    row = ui.one(title)
    ui.tap(row.left + 200, row.centre[1], pause=1.5)
    seen = ui.nodes()
    check(any(re.search(r"^Calendar( ·|$)", n.label) for n in seen)
          and any(re.search(r"– \d{1,2}:\d\d", n.label) for n in seen),
          "its card says which calendar it is from, and from when to when")
    check(not any(n.label.startswith("Mark as") for n in seen),
          "and has nothing to tick")
    shot("e03-event-card")
    # A tap above the sheet, on the dimmed page, closes it.
    ui.tap(width * 0.5, height * 0.08, pause=1.0)
    check(not ui.find("Add subtask"), "a tap beside the card closes it")

    # An event over several days: a bar on each of its days.
    bar = []
    for _ in range(8):
        bar = ui.find(r"Trip \d")
        if bar:
            break
        ui.swipe(width * 0.5, height * 0.4, width * 0.5, height * 0.75, 250, pause=0.6)
    if not bar:
        # None this week: the week before or after has one.
        for _ in range(3):
            ui.swipe(width * 0.85, height * 0.55, width * 0.15, height * 0.55, 200, pause=1.2)
            for _ in range(6):
                bar = ui.find(r"Trip \d")
                if bar:
                    break
                ui.swipe(width * 0.5, height * 0.75, width * 0.5, height * 0.4, 250, pause=0.6)
            if bar:
                break
    check(bool(bar), "an event over several days is a bar under its days' headings")
    shot("e04-span")

    # The whole calendar, from the menu.
    ui.tap_on("Menu", exact=True)
    time.sleep(0.8)
    ui.tap_on("Calendars", exact=True)
    time.sleep(0.8)
    shot("e05-calendars")
    ui.tap_on(r"^Hide Calendar")
    time.sleep(1.0)
    ui.back(pause=0.8)
    check(not ui.find(r"Trip \d") and not ui.find(r"Weekly meeting \d") and not ui.find(r"Appointment \d"),
          "the menu hides a whole calendar with one tap")
    ui.tap_on("Menu", exact=True)
    time.sleep(0.8)
    # With a calendar hidden the entry also says how many are shown.
    ui.tap_on(r"^Calendars")
    time.sleep(0.8)
    ui.tap_on(r"^Show Calendar")
    time.sleep(1.0)
    ui.back(pause=0.8)
    check(bool(ui.find(r"Trip \d")) or bool(ui.find(r"Weekly meeting \d")) or bool(ui.find(r"Appointment \d")),
          "and shows it again")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--apk")
    parser.add_argument("--events", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    def shot(name):
        ui.shot(os.path.join(args.out, name + ".png"))

    if args.apk:
        # A profile build is signed and numbered differently from a release
        # build, and Android installs neither over the other.
        if "Success" not in ui.adb("install", "-r", args.apk, timeout=240, check=False):
            ui.adb("uninstall", ui.PACKAGE, check=False)
            ui.adb("install", args.apk, timeout=240)
    ui.shell("settings put secure show_ime_with_hard_keyboard 1")
    ui.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", check=False)
    width, height = ui.screen_size()
    ui.clear_logcat()
    if args.events:
        events(args.out, shot, width, height)
    else:
        planner(args.out, shot, width, height)
        pull_to_sync(shot, width, height)
        settings(shot, width, height)

    errors = ui.logcat_errors()
    check(not errors, "no errors in the device log" + ("" if not errors else ": " + errors[0][:160]))
    print()
    print("feature checks passed" if failures == 0 else f"feature checks FAILED ({failures})")
    return failures


if __name__ == "__main__":
    sys.exit(main())
