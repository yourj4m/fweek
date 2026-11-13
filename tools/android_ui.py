"""Drive the app on the Android emulator through adb: real touches, real
keyboard input, screenshots, and the accessibility tree to find things by
their label instead of by coordinates.

Used by tools/android-smoke.py; run inside the dev container (tools/dev) so
adb is on PATH.
"""

import re
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = "io.github.yourj4m.weektodo"
ACTIVITY = f"{PACKAGE}/.MainActivity"


def adb(*args, check=True, binary=False, timeout=60):
    result = subprocess.run(["adb", *args], capture_output=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout if binary else result.stdout.decode(errors="replace")


def shell(command, **kwargs):
    return adb("shell", command, **kwargs)


def screen_size():
    width, height = re.search(r"(\d+)x(\d+)", shell("wm size")).groups()
    return int(width), int(height)


def density():
    """Physical pixels per logical pixel."""
    return int(re.search(r"(\d+)\s*$", shell("wm density").strip()).group(1)) / 160


def shot(path):
    data = adb("exec-out", "screencap", "-p", binary=True)
    with open(path, "wb") as out:
        out.write(data)
    return path


def tap(x, y, pause=0.6):
    shell(f"input tap {int(x)} {int(y)}")
    time.sleep(pause)


def swipe(x1, y1, x2, y2, ms=250, pause=0.8):
    shell(f"input swipe {int(x1)} {int(y1)} {int(x2)} {int(y2)} {int(ms)}")
    time.sleep(pause)


def long_press(x, y, ms=900, pause=0.5):
    swipe(x, y, x, y, ms, pause)


def drag(x1, y1, x2, y2, hold=0.9, steps=12, step_ms=40, release=True):
    """Press and hold, then move in steps: what a finger does to drag a task.

    With release=False the finger stays down; finish with finger_up().
    """
    shell(f"input motionevent DOWN {int(x1)} {int(y1)}")
    time.sleep(hold)
    for i in range(1, steps + 1):
        x = x1 + (x2 - x1) * i / steps
        y = y1 + (y2 - y1) * i / steps
        shell(f"input motionevent MOVE {int(x)} {int(y)}")
        time.sleep(step_ms / 1000)
    if release:
        finger_up(x2, y2)


def finger_move(x, y):
    shell(f"input motionevent MOVE {int(x)} {int(y)}")


def finger_up(x, y, pause=0.8):
    shell(f"input motionevent UP {int(x)} {int(y)}")
    time.sleep(pause)


def type_text(text, pause=0.5):
    """Types through the input method, as the on-screen keyboard would."""
    for chunk in re.findall(r" |[^ ]+", text):
        if chunk == " ":
            shell("input keyevent KEYCODE_SPACE")
        else:
            shell("input text " + _quote(chunk))
    time.sleep(pause)


def _quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def key(name, pause=0.5):
    shell(f"input keyevent KEYCODE_{name}")
    time.sleep(pause)


def back(pause=0.6):
    key("BACK", pause)


class Node:
    def __init__(self, element):
        self.label = element.get("content-desc") or ""
        self.text = element.get("text") or ""
        self.cls = element.get("class") or ""
        self.clickable = element.get("clickable") == "true"
        self.focused = element.get("focused") == "true"
        left, top, right, bottom = map(int, re.findall(r"\d+", element.get("bounds")))
        self.left, self.top, self.right, self.bottom = left, top, right, bottom

    @property
    def centre(self):
        return (self.left + self.right) // 2, (self.top + self.bottom) // 2

    @property
    def width(self):
        return self.right - self.left

    @property
    def height(self):
        return self.bottom - self.top

    def __repr__(self):
        name = self.label or self.text
        return f"<{name!r} {self.left},{self.top} {self.width}x{self.height}>"


def nodes(retries=4):
    """The app's accessibility nodes, top to bottom."""
    for attempt in range(retries):
        raw = shell("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml", check=False)
        start = raw.find("<?xml")
        if start >= 0:
            try:
                root = ET.fromstring(raw[start:])
            except ET.ParseError:
                root = None
            if root is not None:
                found = [Node(e) for e in root.iter("node") if e.get("package") == PACKAGE]
                # The first dump after a start can arrive before Flutter has
                # built its accessibility tree: a lone root node.
                if len(found) > 2 or attempt == retries - 1:
                    return sorted(found, key=lambda n: (n.top, n.left))
        time.sleep(0.7)
    return []


def find(pattern, among=None, exact=False):
    """Nodes whose label or text matches."""
    among = nodes() if among is None else among
    out = []
    for node in among:
        for value in (node.label, node.text):
            if (value == pattern) if exact else re.search(pattern, value):
                out.append(node)
                break
    return out


def one(pattern, among=None, exact=False, last=False):
    found = find(pattern, among, exact)
    if not found:
        raise LookupError(f"nothing on screen matches {pattern!r}")
    # The smallest match is the widget itself rather than a container whose
    # merged label merely includes it.
    smallest = min(n.width * n.height for n in found)
    found = [n for n in found if n.width * n.height == smallest]
    return found[-1] if last else found[0]


def tap_on(pattern, **kwargs):
    node = one(pattern, **kwargs)
    tap(*node.centre)
    return node


def launch(clear=False):
    if clear:
        shell(f"pm clear {PACKAGE}", check=False)
    shell(f"am start -W -n {ACTIVITY}")
    time.sleep(2.5)


def stop():
    shell(f"am force-stop {PACKAGE}")
    time.sleep(0.5)


def keyboard_shown():
    return "mInputShown=true" in shell("dumpsys input_method", check=False)


def logcat_errors():
    """Lines Flutter or the runtime logged as errors since the log was cleared."""
    log = adb("logcat", "-d", "-s", "flutter:*", "AndroidRuntime:E", "-v", "brief", check=False)
    return [
        line for line in log.splitlines()
        if re.search(r"EXCEPTION|Unhandled|FATAL|Another exception|RenderFlex overflowed|E/flutter", line)
    ]


def clear_logcat():
    adb("logcat", "-c", check=False)
