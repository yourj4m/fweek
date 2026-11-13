// Add, complete and colour a task; then probe the header title, the week
// number and the Someday list headings.

export default async (h) => {
  const { page } = h;
  const reset = async () => {
    for (let i = 0; i < 3; i++) { await page.press("Escape"); await page.sleep(300); }
  };
  const active = () =>
    page.evaluate(`(() => { const a = document.activeElement; if (!a) return null;
      const r = a.getBoundingClientRect();
      return { tag: a.tagName, cls: (a.className || "").toString().slice(0, 60), ph: a.getAttribute("placeholder"),
               rect: [r.x, r.y, r.width, r.height].map(Math.round), value: a.value }; })()`);
  await reset();

  // 1. Inline add on Monday: first empty row.
  const mon = await h.sel("input[class*=_input_re5rs]", 0);
  await page.click(mon.x, mon.y);
  await page.sleep(500);
  h.log("focused:", JSON.stringify(await active()));
  await h.snap("add-focused");
  await page.typeText("Buy oat milk and a very long task title that should wrap or truncate somewhere");
  await page.sleep(400);
  await h.snap("add-typing");
  await page.press("Enter");
  await page.sleep(900);
  h.log("after enter, focused:", JSON.stringify(await active()));
  await page.typeText("Second task");
  await page.press("Enter");
  await page.sleep(700);
  await page.typeText("9:30 Call dentist");
  await page.press("Enter");
  await page.sleep(700);
  await page.press("Escape");
  await page.sleep(500);
  await h.snap("add-done");

  // 2. Complete the second task via its hover check button.
  const t = await h.hoverText("Second task");
  const check = await page.evaluate(`(() => {
    const row = [...document.querySelectorAll("[class*=_cell_1a36s]")].find((c) => c.innerText.includes("Second task"));
    if (!row) return null;
    const b = [...row.querySelectorAll("button, [role=button], svg, [class*=check]")].map((e) => {
      const r = e.getBoundingClientRect();
      return { tag: e.tagName, cls: (e.className.baseVal ?? e.className ?? "").toString().slice(0, 50), aria: e.getAttribute("aria-label"), x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
    });
    return b;
  })()`);
  h.log("row internals:", JSON.stringify(check));
  const btn = (check || []).find((c) => c.w > 0 && c.w <= 44 && c.x > t.x);
  if (btn) { await page.click(btn.x, btn.y); await page.sleep(800); }
  await page.move(720, 860);
  await page.sleep(400);
  await h.snap("task-completed");

  // 3. Colour the first new task yellow via the dialog palette.
  await h.clickText("9:30 Call dentist").catch(async () => {
    const p = await page.evaluate(`(() => { const e = [...document.querySelectorAll("[class*=_text_1a36s]")].find((c) => c.innerText.includes("Call dentist")); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + 30, y: r.y + r.height / 2 }; })()`);
    if (p) await page.click(p.x, p.y);
  });
  await page.sleep(800);
  const color = await h.at("Color");
  if (color) {
    await page.click(color.x, color.y);
    await page.sleep(700);
    const swatches = await h.list("[class*=_sheet_] button, [class*=_sheet_] [role=button], [class*=_sheet_] [role=radio]");
    h.log("palette items:", JSON.stringify(swatches));
    if (swatches[1]) {
      const [x, y, w, hh] = swatches[1].rect;
      await page.click(x + w / 2, y + hh / 2);
      await page.sleep(700);
    }
    await h.snap("dialog-colored");
  }
  await reset();
  await page.move(720, 860);
  await page.sleep(400);
  await h.snap("task-colored");

  // 4. Header: click the title, then the week number.
  await h.clickText("November 2026").catch(() => {});
  await page.sleep(800);
  await h.snap("header-title-clicked");
  h.log("title click -> sheets:", JSON.stringify(await h.list("[class*=_sheet_], [class*=popover], [role=dialog]")).slice(0, 900));
  await reset();
  await h.hoverText("W46").catch(() => {});
  await page.sleep(900);
  await h.snap("header-week-hover");
  h.log("tooltips:", JSON.stringify(await h.list("[role=tooltip], [class*=tooltip], [class*=Tooltip]")).slice(0, 600));

  // 5. Someday: the unnamed second list heading.
  await reset();
  const headings = await h.list("[class*=_heading_1kkru]");
  h.log("someday headings:", JSON.stringify(headings));
  if (headings[1]) {
    const [x, y, w, hh] = headings[1].rect;
    await page.move(x + 40, y + hh / 2);
    await page.sleep(500);
    await h.snap("someday-heading-hover");
    await page.click(x + 40, y + hh / 2);
    await page.sleep(700);
    h.log("someday heading click -> focused:", JSON.stringify(await active()));
    await h.snap("someday-heading-clicked");
  }
  await reset();
};
