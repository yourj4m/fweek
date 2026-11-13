// Drag and drop visuals on desktop, then the phone-width layout: planner,
// task sheet, and colour palette.

export default async (h) => {
  const { page } = h;
  const reset = async () => {
    for (let i = 0; i < 3; i++) { await page.press("Escape"); await page.sleep(300); }
  };
  await reset();
  await page.setViewport(1440, 900, 1, false);
  await page.sleep(600);

  // Desktop drag: "Tap and edit" (Saturday) -> Tuesday, second row.
  const src = await h.at("Tap and edit");
  const dst = await h.sel("input[class*=_input_re5rs]", 1); // Tuesday's empty row
  h.log("drag from", JSON.stringify(src.rect), "to", JSON.stringify(dst.rect));
  const d1 = await page.drag(src.x, src.y, src.x - 120, src.y + 60, 8, 200);
  await h.snap("drag-start");
  h.log("drag overlay:", JSON.stringify(await page.evaluate(`(() => {
    const out = [];
    for (const el of document.querySelectorAll("body *")) {
      const cs = getComputedStyle(el);
      if (cs.position !== "fixed" || cs.display === "none") continue;
      const r = el.getBoundingClientRect();
      if (r.width < 30 || r.height < 10 || r.width > 600) continue;
      out.push({ cls: (el.className || "").toString().slice(0, 70), rect: [r.x, r.y, r.width, r.height].map(Math.round),
        transform: cs.transform, boxShadow: cs.boxShadow, opacity: cs.opacity, bg: cs.backgroundColor, radius: cs.borderRadius,
        cursor: cs.cursor, transition: cs.transition.slice(0, 80), text: (el.innerText || "").slice(0, 30) });
    }
    return out;
  })()`), null, 1));
  // Continue the same drag to the target without releasing in between.
  for (let i = 1; i <= 14; i++) {
    const t = i / 14;
    await page.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", button: "left", buttons: 1,
      x: src.x - 120 + (dst.x - (src.x - 120)) * t,
      y: src.y + 60 + (dst.y + 42 - (src.y + 60)) * t,
    });
    await page.sleep(30);
  }
  await page.sleep(500);
  await h.snap("drag-over-target");
  // Towards the left screen edge: the "previous week" ear.
  for (let i = 1; i <= 10; i++) {
    await page.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", button: "left", buttons: 1, x: dst.x + (8 - dst.x) * (i / 10), y: 450,
    });
    await page.sleep(30);
  }
  await page.sleep(400);
  await h.snap("drag-at-edge");
  // Back to the target and drop.
  for (let i = 1; i <= 10; i++) {
    await page.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", button: "left", buttons: 1, x: 8 + (dst.x - 8) * (i / 10), y: 450 + (dst.y - 450) * (i / 10),
    });
    await page.sleep(30);
  }
  await page.sleep(300);
  await page.send("Input.dispatchMouseEvent", { type: "mouseReleased", button: "left", buttons: 0, x: dst.x, y: dst.y, clickCount: 1 });
  await page.sleep(900);
  await h.snap("drag-dropped");

  // Phone width.
  await page.setViewport(390, 844, 2, true);
  await page.sleep(1200);
  await h.snap("m-planner");
  await page.evaluate(`window.scrollTo(0, document.documentElement.scrollHeight)`);
  await page.sleep(600);
  await h.snap("m-planner-bottom");
  await page.evaluate(`window.scrollTo(0, 0)`);
  await page.sleep(400);
  const t = await h.at("Buy oat milk and a very long task title that should wrap or truncate somewhere")
    ?? (await page.evaluate(`(() => { const e = [...document.querySelectorAll("[class*=_text_1a36s]")].find((c) => c.innerText.includes("Buy oat")); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + 40, y: r.y + r.height / 2 }; })()`));
  if (t) {
    await page.click(t.x, t.y);
    await page.sleep(1100);
    await h.snap("m-task-sheet");
    const color = await h.at("Color");
    if (color) { await page.click(color.x, color.y); await page.sleep(800); await h.snap("m-task-color"); }
  }
  await reset();
  await page.setViewport(1440, 900, 1, false);
  await page.sleep(600);
};
