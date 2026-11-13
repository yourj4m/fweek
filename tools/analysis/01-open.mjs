// Open the public planner page in the throwaway browser and report what is
// clickable, so later steps can dismiss the cookie banner and welcome dialog.
//
//   node 01-open.mjs <port> <outDir>

import { connect } from "./cdp-lib.mjs";

const [port, outDir] = process.argv.slice(2);
const page = await connect(Number(port));

await page.setViewport(1440, 900, 1);
await page.navigate("https://tweek.so/", 6000);

const info = await page.evaluate(`(() => {
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none";
  };
  const buttons = [...document.querySelectorAll("button, a, [role=button]")]
    .filter(vis)
    .map((el) => {
      const r = el.getBoundingClientRect();
      return {
        tag: el.tagName.toLowerCase(),
        text: (el.innerText || el.getAttribute("aria-label") || "").trim().slice(0, 40),
        cls: (el.className && el.className.toString().slice(0, 60)) || "",
        x: Math.round(r.x + r.width / 2),
        y: Math.round(r.y + r.height / 2),
        w: Math.round(r.width),
        h: Math.round(r.height),
      };
    });
  return {
    url: location.href,
    title: document.title,
    viewport: [innerWidth, innerHeight],
    rootId: document.body.firstElementChild?.id,
    buttons,
  };
})()`);

console.log(JSON.stringify(info, null, 1));
await page.screenshot(`${outDir}/01-open-1440.png`);
page.close();
