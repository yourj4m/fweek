// Run an interaction scenario against the throwaway browser and capture the
// resulting states (element tree + screenshot per named step).
//
//   node scenario.mjs <port> <outDir> <scenario.mjs> [WxH]
//
// A scenario module default-exports `async (h) => { ... }` where `h` offers:
//   h.page            the raw CDP helpers from cdp-lib.mjs
//   h.at(text)        centre of the first visible element whose own text matches
//   h.sel(css, n)     centre + rect of the n-th visible element matching a selector
//   h.clickText(text) / h.hoverText(text)
//   h.snap(label)     write <outDir>/<label>.json and .png
//   h.list(css)       text/aria/rect of visible elements matching a selector
//   h.log(...)        console.log

import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { connect } from "./cdp-lib.mjs";
import { WALK } from "./walk-snippet.mjs";

const [port, outDir, scenarioPath, size = "1440x900"] = process.argv.slice(2);
const page = await connect(Number(port));
const [w, hgt] = size.split("x").map(Number);
await page.setViewport(w, hgt, 1, false);
await page.sleep(500);

const VISIBLE = `const vis = (el) => {
  const r = el.getBoundingClientRect();
  const s = getComputedStyle(el);
  return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none";
};`;

const h = {
  page,
  log: (...a) => console.log(...a),
  at: (text, nth = 0) =>
    page.evaluate(`(() => { ${VISIBLE}
      const want = ${JSON.stringify(text)};
      const hits = [...document.querySelectorAll("body *")].filter((el) => {
        if (!vis(el)) return false;
        const own = [...el.childNodes].filter((c) => c.nodeType === 3).map((c) => c.nodeValue).join("").trim();
        return own === want || el.getAttribute("aria-label") === want;
      });
      const el = hits[${nth}];
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2, rect: [r.x, r.y, r.width, r.height], n: hits.length };
    })()`),
  sel: (css, nth = 0) =>
    page.evaluate(`(() => { ${VISIBLE}
      const hits = [...document.querySelectorAll(${JSON.stringify(css)})].filter(vis);
      const el = hits[${nth}];
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2, rect: [r.x, r.y, r.width, r.height], n: hits.length };
    })()`),
  list: (css) =>
    page.evaluate(`(() => { ${VISIBLE}
      return [...document.querySelectorAll(${JSON.stringify(css)})].filter(vis).map((el) => {
        const r = el.getBoundingClientRect();
        return {
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || "").trim().replace(/\\s+/g, " ").slice(0, 60),
          aria: el.getAttribute("aria-label") || undefined,
          title: el.getAttribute("title") || undefined,
          cls: (typeof el.className === "string" ? el.className : "").split(" ").slice(0, 3).join(" "),
          rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
        };
      });
    })()`),
  clickText: async (text, nth = 0) => {
    const p = await h.at(text, nth);
    if (!p) throw new Error(`no element with text ${text}`);
    await page.click(p.x, p.y);
    await page.sleep(500);
    return p;
  },
  hoverText: async (text, nth = 0) => {
    const p = await h.at(text, nth);
    if (!p) throw new Error(`no element with text ${text}`);
    await page.move(p.x, p.y);
    await page.sleep(400);
    return p;
  },
  snap: async (label) => {
    const data = await page.evaluate(WALK);
    await writeFile(`${outDir}/${label}.json`, JSON.stringify(data));
    await page.screenshot(`${outDir}/${label}.png`);
    console.log(`snap ${label}`);
  },
};

const mod = await import(pathToFileURL(resolve(scenarioPath)).href);
try {
  await mod.default(h);
} finally {
  page.close();
}
