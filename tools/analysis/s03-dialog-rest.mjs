// Task dialog controls that s02 missed, each probed from a clean state so a
// premium upsell modal cannot derail the next step.

export default async (h) => {
  const { page } = h;

  const reset = async () => {
    for (let i = 0; i < 3; i++) {
      await page.press("Escape");
      await page.sleep(350);
    }
    // Click neutral whitespace to drop any focused row input.
    await page.click(720, 860);
    await page.sleep(300);
    await h.clickText("Mark me complete");
    await page.sleep(800);
    if (!(await h.sel(".dialog"))) throw new Error("dialog did not open");
  };

  const layers = () =>
    page.evaluate(`(() => {
      const out = [];
      for (const el of document.querySelectorAll("body *")) {
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        if (cs.display === "none" || r.width < 20 || r.height < 20) continue;
        const z = parseInt(cs.zIndex, 10);
        const floats = z >= 1001 || /menu|popover|sheet|tooltip|modal/i.test(typeof el.className === "string" ? el.className : "");
        if (!floats) continue;
        out.push({
          cls: (typeof el.className === "string" ? el.className : "").split(" ").slice(0, 3).join(" "),
          z: cs.zIndex, rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
          text: (el.innerText || "").trim().replace(/\\s+/g, " | ").slice(0, 500),
        });
      }
      return out.slice(0, 12);
    })()`);

  for (const name of ["More", "Repeat", "Time", "Expand"]) {
    await reset();
    const p = await h.at(name);
    if (!p) { h.log(`no control ${name}`); continue; }
    await page.click(p.x, p.y);
    await page.sleep(1000);
    await h.snap(`dialog2-${name.toLowerCase()}`);
    h.log(`--- ${name}`, JSON.stringify(await layers(), null, 1).slice(0, 3000));
    h.log(`    buttons`, JSON.stringify((await h.list("[role=menuitem], [role=option], .dialog button, [class*=sheet] button, [class*=menu] button")).map((b) => `${b.aria ?? b.text}@${b.rect.join(",")}`)).slice(0, 1500));
  }
  await reset();
  await page.press("Escape");
};
