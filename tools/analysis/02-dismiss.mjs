// Decline analytics cookies and close the welcome dialog, then report what
// the page looks like. Tries the least committal way to close the dialog
// first (Escape, then a click on the backdrop) before using its button.
//
//   node 02-dismiss.mjs <port> <outDir>

import { connect } from "./cdp-lib.mjs";

const [port, outDir] = process.argv.slice(2);
const page = await connect(Number(port));

const find = (text) =>
  page.evaluate(`(() => {
    const el = [...document.querySelectorAll("button")].find(
      (b) => b.innerText.trim() === ${JSON.stringify(text)} && b.getBoundingClientRect().width > 0,
    );
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()`);

const dialogOpen = () =>
  page.evaluate(`!![...document.querySelectorAll("button")].find(
    (b) => b.innerText.trim() === "Start now" && b.getBoundingClientRect().width > 0)`);

const decline = await find("Decline");
if (decline) {
  await page.click(decline.x, decline.y);
  await page.sleep(600);
}
console.log("cookie banner declined:", !!decline);

const steps = [];
if (await dialogOpen()) {
  await page.press("Escape");
  await page.sleep(700);
  steps.push(["escape", !(await dialogOpen())]);
}
if (await dialogOpen()) {
  await page.click(30, 400); // backdrop, far left of the dialog
  await page.sleep(700);
  steps.push(["backdrop", !(await dialogOpen())]);
}
if (await dialogOpen()) {
  const start = await find("Start now");
  await page.click(start.x, start.y);
  await page.sleep(2500);
  steps.push(["start-now", !(await dialogOpen())]);
}
console.log("dialog close attempts:", JSON.stringify(steps));

const state = await page.evaluate(`({
  url: location.href,
  text: document.body.innerText.replace(/\\s+/g, " ").slice(0, 700),
  localStorageKeys: Object.keys(localStorage),
})`);
console.log(JSON.stringify(state, null, 1));
await page.screenshot(`${outDir}/02-planner-1440.png`);
page.close();
