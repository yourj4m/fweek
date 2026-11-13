// Dump the visible element tree of the current page with geometry and the
// computed styles that define the design (type, colour, borders, spacing,
// layout), at one or more viewport sizes.
//
//   node 03-measure.mjs <port> <outDir> <label> <WxH[@dpr]> [<WxH> ...]
//
// Writes <outDir>/<label>-<W>x<H>.json and .png per size and prints a short
// outline (depth-limited) of the first size.

import { writeFile } from "node:fs/promises";
import { connect } from "./cdp-lib.mjs";
import { WALK } from "./walk-snippet.mjs";

const [port, outDir, label, ...sizes] = process.argv.slice(2);
const page = await connect(Number(port));


const outline = (node, depth, maxDepth, lines) => {
  if (depth > maxDepth) return;
  const [x, y, w, h] = node.rect;
  if (w > 0 && h > 0) {
    const s = node.style;
    const bits = [
      `${"  ".repeat(depth)}${node.tag}.${node.cls.split(" ").slice(0, 2).join(".")}`,
      `[${Math.round(x)},${Math.round(y)} ${Math.round(w)}x${Math.round(h)}]`,
    ];
    if (node.text) bits.push(JSON.stringify(node.text.slice(0, 28)), `${s.fontSize}/${s.lineHeight} w${s.fontWeight}`);
    if (s.display === "grid") bits.push(`grid(${s.gridTemplateColumns.slice(0, 60)}) gap ${s.gap}`);
    if (s.display === "flex") bits.push(`flex-${s.flexDirection} gap ${s.gap}`);
    lines.push(bits.join(" "));
  }
  for (const c of node.children) outline(c, depth + 1, maxDepth, lines);
};

let first = true;
for (const size of sizes) {
  const [wh, dpr = "1"] = size.split("@");
  const [w, h] = wh.split("x").map(Number);
  await page.setViewport(w, h, Number(dpr), false);
  await page.sleep(900);
  const data = await page.evaluate(WALK);
  const base = `${outDir}/${label}-${w}x${h}`;
  await writeFile(`${base}.json`, JSON.stringify(data));
  await page.screenshot(`${base}.png`);
  console.log(`# ${size}: viewport ${data.viewport} scroll ${data.scroll} html.${data.htmlClass} body.${data.bodyClass} bg ${data.bodyStyle.backgroundColor}`);
  if (first) {
    const lines = [];
    outline(data.tree, 0, Number(process.env.OUTLINE_DEPTH ?? 9), lines);
    console.log(lines.join("\n"));
    first = false;
  }
}
page.close();
