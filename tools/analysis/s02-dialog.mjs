// Task dialog: open each control in turn and capture what it shows.
// The dialog is expected to be open already (s01 leaves it open); if not,
// it is opened by clicking the demo task.

const DIALOG = ".dialog";

export default async (h) => {
  const { page } = h;

  const ensureOpen = async () => {
    if (await h.sel(DIALOG)) return;
    await h.clickText("Mark me complete");
    await page.sleep(700);
  };
  const controls = async () =>
    (await h.list(`${DIALOG} button, ${DIALOG} [role=button]`)).map(
      (b) => `${b.aria ?? b.text ?? "?"} @${b.rect.join(",")} .${b.cls.split(" ")[1] ?? b.cls}`,
    );
  // Everything that floats above the page and is not the dialog itself.
  const floating = () =>
    page.evaluate(`(() => {
      const out = [];
      for (const el of document.querySelectorAll("body *")) {
        const cs = getComputedStyle(el);
        const z = parseInt(cs.zIndex, 10);
        if (!(z >= 1000) || cs.display === "none") continue;
        const r = el.getBoundingClientRect();
        if (r.width < 20 || r.height < 20) continue;
        out.push({
          cls: (typeof el.className === "string" ? el.className : "").split(" ").slice(0, 3).join(" "),
          z, rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
          text: (el.innerText || "").trim().replace(/\\s+/g, " ").slice(0, 400),
        });
      }
      return out;
    })()`);

  await ensureOpen();
  await h.snap("dialog-open");
  h.log("dialog controls:", JSON.stringify(await controls(), null, 1));

  const footer = (await h.list(`${DIALOG} button`)).filter((b) => b.rect[1] > 380);
  h.log("footer buttons:", JSON.stringify(footer));

  const probe = async (label, x, y) => {
    await ensureOpen();
    await page.click(x, y);
    await page.sleep(900);
    await h.snap(`dialog-${label}`);
    h.log(`--- ${label}: floating layers`, JSON.stringify(await floating(), null, 1).slice(0, 2600));
    await page.press("Escape");
    await page.sleep(500);
  };

  // Footer toolbar, left to right.
  const names = ["subtasks", "repeat", "color", "reminder", "more"];
  for (let i = 0; i < footer.length && i < names.length; i++) {
    const [x, y, w, hh] = footer[i].rect;
    await probe(names[i], x + w / 2, y + hh / 2);
  }

  // Header: date, time, expand.
  await ensureOpen();
  const date = await h.sel(`${DIALOG} button[class*=headerButton]`, 0);
  if (date) await probe("date", date.x, date.y);
  const time = await h.at("Time");
  if (time) await probe("time", time.x, time.y);
  await ensureOpen();
  const expand = await h.at("Expand");
  if (expand) {
    await page.click(expand.x, expand.y);
    await page.sleep(900);
    await h.snap("dialog-expanded");
    h.log("expanded controls:", JSON.stringify(await controls(), null, 1));
  }
};
