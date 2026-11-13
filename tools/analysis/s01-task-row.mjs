// Task row: resting anatomy, hover state, and what a click does.
export default async (h) => {
  await h.snap("row-rest");

  const t = await h.hoverText("Mark me complete");
  h.log("task rect", JSON.stringify(t.rect));
  await h.snap("row-hover");

  // What appears inside the hovered row?
  h.log("buttons while hovering:", JSON.stringify(await h.list("button, [role=button]")));

  // Click the task text.
  await h.page.click(t.x, t.y);
  await h.page.sleep(900);
  await h.snap("row-clicked");
  h.log("after click, dialogs:", JSON.stringify(await h.list("[role=dialog], dialog, [aria-modal=true]")));
  h.log("after click, buttons:", JSON.stringify(await h.list("button, [role=button]")));
  h.log("after click, inputs:", JSON.stringify(await h.list("input, textarea, [contenteditable=true]")));
  h.log("active element:", await h.page.evaluate(
    `(() => { const a = document.activeElement; return a ? a.tagName + "." + a.className + " ce=" + a.isContentEditable : null; })()`));
};
