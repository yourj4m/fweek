"""Print the rules of a minified stylesheet whose selector matches a pattern,
with their @media context, one declaration group per line.

    python3 -I digest_css.py <css-dir-or-file> <regex> [--max N]

Used to read measurements (sizes, colours, timings, state changes) off the
publicly served stylesheets. The CSS itself is reference material only and is
never copied into the application.
"""

import os
import re
import sys


def load(path):
    if os.path.isdir(path):
        return "".join(
            open(os.path.join(path, f), encoding="utf-8", errors="replace").read()
            for f in sorted(os.listdir(path))
            if f.endswith(".css")
        )
    return open(path, encoding="utf-8", errors="replace").read()


def rules(css, context=""):
    """Yield (context, selector, body) for every style rule, descending into
    conditional group rules (@media, @supports, @container, @layer)."""
    i, n = 0, len(css)
    while i < n:
        brace = css.find("{", i)
        if brace < 0:
            return
        prelude = css[i:brace].strip()
        depth, j = 1, brace + 1
        while j < n and depth:
            c = css[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        body = css[brace + 1 : j - 1]
        if prelude.startswith(("@media", "@supports", "@container", "@layer")):
            yield from rules(body, (context + " " + prelude).strip())
        elif prelude.startswith("@"):
            yield context, prelude, body if len(body) < 400 else body[:400] + " …"
        else:
            yield context, prelude, body
        i = j


def main():
    args = sys.argv[1:]
    limit = 400
    if "--max" in args:
        k = args.index("--max")
        limit = int(args[k + 1])
        del args[k : k + 2]
    path, pattern = args
    rx = re.compile(pattern)
    shown = 0
    for context, selector, body in rules(load(path)):
        if not rx.search(selector):
            continue
        body = re.sub(r"\s+", " ", body).strip().rstrip(";")
        head = f"[{context}] " if context else ""
        print(f"{head}{selector} {{ {body.replace(';', '; ')} }}")
        shown += 1
        if shown >= limit:
            print("… (limit reached)")
            break


if __name__ == "__main__":
    main()
