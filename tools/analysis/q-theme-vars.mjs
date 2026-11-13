// Read the theme custom properties the page sets at runtime (they are not in
// the stylesheets) and list the names of every custom property referenced by
// the stylesheets but resolved on the root element.
import { connect } from "./cdp-lib.mjs";
const page = await connect(Number(process.argv[2]));
const out = await page.evaluate(`(() => {
  const holders = [];
  for (const el of [document.documentElement, document.body, ...document.querySelectorAll("[style*='--']")]) {
    const st = el.style; const vars = {};
    for (let i = 0; i < st.length; i++) { const p = st[i]; if (p.startsWith("--")) vars[p] = st.getPropertyValue(p).trim(); }
    if (Object.keys(vars).length) holders.push({ el: el.tagName + "." + (el.className || "").toString().slice(0, 40), vars });
  }
  // Also resolve the names the app's CSS expects.
  const names = ["--primary-text","--primary-accent","--primary-background","--calendar--day-grid-background","--calendar-task--hover-border","--secondary-background","--secondary-text","--task-color","--day-divider-inset"];
  const cs = getComputedStyle(document.querySelector(".App") || document.body);
  const resolved = {}; for (const n of names) resolved[n] = cs.getPropertyValue(n).trim();
  // Constructed / injected style sheets that define custom properties.
  const sheets = [];
  for (const sh of document.styleSheets) {
    let rules; try { rules = sh.cssRules; } catch { continue; }
    for (const r of rules) {
      if (r.style && [...r.style].some((p) => p.startsWith("--primary-") || p.startsWith("--calendar"))) {
        const vars = {}; for (const p of r.style) if (p.startsWith("--")) vars[p] = r.style.getPropertyValue(p).trim();
        sheets.push({ href: (sh.href || "inline").split("/").pop(), selector: r.selectorText, vars });
      }
    }
  }
  return { holders, resolved, sheets };
})()`);
console.log(JSON.stringify(out, null, 1));
page.close();
