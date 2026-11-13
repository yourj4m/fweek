"""Query the element-tree dumps written by 03-measure.mjs.

Run with `python3 -I digest.py <command> <file.json> [...]` (the dumps are
third-party page data, so the interpreter is started in isolated mode).

Commands
  layout  <files...>          one line per file: grid columns, row counts, type sizes
  find    <file> <substr>     nodes whose class or text contains <substr>, with styles
  node    <file> <index>      full record of one node (no children)
  outline <file> <index> [d]  outline of the subtree under node <index>
"""

import json
import sys

KEY_STYLE = (
    "display position fontSize fontWeight lineHeight letterSpacing color "
    "backgroundColor opacity textDecorationLine borderBottomWidth borderBottomColor "
    "borderBottomStyle borderTopWidth borderTopColor borderRadius paddingTop paddingRight "
    "paddingBottom paddingLeft marginTop marginRight marginBottom marginLeft gap "
    "gridTemplateColumns flexDirection justifyContent alignItems boxShadow "
    "backgroundImage backgroundSize transition cursor height width minHeight maxWidth zIndex"
).split()

BORING = {
    "opacity": "1", "textDecorationLine": "none", "borderBottomWidth": "0px",
    "borderTopWidth": "0px", "borderRadius": "0px", "paddingTop": "0px",
    "paddingRight": "0px", "paddingBottom": "0px", "paddingLeft": "0px",
    "marginTop": "0px", "marginRight": "0px", "marginBottom": "0px",
    "marginLeft": "0px", "gap": "normal", "gridTemplateColumns": "none",
    "boxShadow": "none", "backgroundImage": "none", "backgroundColor": "rgba(0, 0, 0, 0)",
    "letterSpacing": "normal", "position": "static", "cursor": "auto",
    "minHeight": "auto", "maxWidth": "none", "zIndex": "auto",
    "transition": "all", "backgroundSize": "auto", "justifyContent": "normal",
    "alignItems": "normal", "flexDirection": "row", "borderBottomStyle": "none",
}


def walk(node, parent=None, depth=0):
    yield node, parent, depth
    for child in node["children"]:
        yield from walk(child, node, depth + 1)


def compact_style(node):
    out = {}
    s = node["style"]
    for k in KEY_STYLE:
        v = s.get(k)
        if v is None or BORING.get(k) == v:
            continue
        if k in ("borderBottomColor", "borderBottomStyle") and s.get("borderBottomWidth") == "0px":
            continue
        if k == "borderTopColor" and s.get("borderTopWidth") == "0px":
            continue
        if k == "transition" and v.startswith("all 0s"):
            continue
        out[k] = v
    return out


def label(node):
    cls = ".".join(node["cls"].split()[:3])
    return f"{node['tag']}.{cls}" if cls else node["tag"]


def show(node):
    x, y, w, h = node["rect"]
    print(f"#{node['i']} {label(node)} [{x:g},{y:g} {w:g}x{h:g}]"
          + (f" text={node['text']!r}" if node.get("text") else "")
          + (f" aria={node['aria']!r}" if node.get("aria") else ""))
    for k, v in compact_style(node).items():
        print(f"     {k}: {v}")
    for pseudo in ("before", "after"):
        if node.get(pseudo):
            print(f"     ::{pseudo} {node[pseudo]}")


def cmd_layout(files):
    for path in files:
        data = json.load(open(path))
        vw, vh, _ = data["viewport"]
        nodes = list(walk(data["tree"]))
        grids = [n for n, _, _ in nodes
                 if n["style"]["display"] == "grid" and n["rect"][2] > 200]
        heading = next((n for n, _, _ in nodes if "_headingText_" in n["cls"]), None)
        month = next((n for n, _, _ in nodes if "_month_" in n["cls"]), None)
        bodies = [n for n, _, _ in nodes if "_body_" in n["cls"]]
        headers = [n for n, _, _ in nodes if "_header_" in n["cls"]]
        print(f"== {path.split('/')[-1]}  viewport {vw}x{vh}  scroll {data['scroll']}  html.{data['htmlClass']}")
        if heading:
            s = heading["style"]
            print(f"   title {s['fontSize']}/{s['lineHeight']} at {heading['rect'][:2]}")
        if month:
            s = month["style"]
            print(f"   day header {s['fontSize']}/{s['lineHeight']}  first at {month['rect'][:2]}")
        for g in grids:
            cols = g["style"]["gridTemplateColumns"].split()
            print(f"   grid {label(g)} [{g['rect'][0]:g},{g['rect'][1]:g} {g['rect'][2]:g}x{g['rect'][3]:g}]"
                  f" cols={len(cols)} ({cols[0] if cols else ''}) gap={g['style']['gap']}")
        print("   day headers (x,y,w,h): " + " ".join(
            f"({h['rect'][0]:g},{h['rect'][1]:g},{h['rect'][2]:g},{h['rect'][3]:g})" for h in headers[:9]))
        print("   body heights: " + " ".join(f"{b['rect'][3]:g}" for b in bodies))


def cmd_find(path, needle):
    data = json.load(open(path))
    hits = 0
    for node, _, _ in walk(data["tree"]):
        if needle in node["cls"] or needle in (node.get("text") or "") or needle in (node.get("aria") or ""):
            show(node)
            hits += 1
            if hits >= 12:
                print("... (more)")
                break


def cmd_node(path, index):
    data = json.load(open(path))
    for node, parent, _ in walk(data["tree"]):
        if node["i"] == int(index):
            if parent:
                print(f"parent: #{parent['i']} {label(parent)}")
            show(node)
            print("children:", [f"#{c['i']} {label(c)}" for c in node["children"]])


def cmd_outline(path, index, depth="6"):
    data = json.load(open(path))
    root = next(n for n, _, _ in walk(data["tree"]) if n["i"] == int(index))
    for node, _, d in walk(root):
        if d > int(depth) or node["rect"][2] <= 0 or node["rect"][3] <= 0:
            continue
        x, y, w, h = node["rect"]
        s = node["style"]
        extra = ""
        if node.get("text"):
            extra += f" {node['text'][:30]!r} {s['fontSize']}/{s['lineHeight']} w{s['fontWeight']} {s['color']}"
        if s["backgroundColor"] != "rgba(0, 0, 0, 0)":
            extra += f" bg={s['backgroundColor']}"
        if s["borderRadius"] != "0px":
            extra += f" r={s['borderRadius']}"
        print(f"{'  ' * d}#{node['i']} {label(node)} [{x:g},{y:g} {w:g}x{h:g}]{extra}")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"layout": lambda: cmd_layout(args), "find": lambda: cmd_find(*args),
     "node": lambda: cmd_node(*args), "outline": lambda: cmd_outline(*args)}[command]()
