// Page-side snippet: returns the visible element tree with geometry and
// design-relevant computed styles. Shared by 03-measure.mjs and scenario.mjs.
export const WALK = `(() => {
  const PROPS = [
    "display", "position", "fontFamily", "fontSize", "fontWeight", "lineHeight",
    "letterSpacing", "color", "backgroundColor", "opacity", "textDecorationLine",
    "borderTopWidth", "borderTopColor", "borderBottomWidth", "borderBottomColor",
    "borderBottomStyle", "borderRadius", "paddingTop", "paddingRight",
    "paddingBottom", "paddingLeft", "marginTop", "marginRight", "marginBottom",
    "marginLeft", "gap", "columnGap", "rowGap", "gridTemplateColumns",
    "gridTemplateRows", "flexDirection", "justifyContent", "alignItems",
    "boxShadow", "backgroundImage", "backgroundSize", "transition", "cursor",
    "overflowY", "textOverflow", "whiteSpace", "zIndex", "minHeight", "height",
    "width", "maxWidth",
  ];
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "LINK", "META", "HEAD"]);
  let n = 0;
  const walk = (el, depth) => {
    if (SKIP.has(el.tagName)) return null;
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden") return null;
    const style = {};
    for (const p of PROPS) style[p] = cs[p];
    const before = getComputedStyle(el, "::before");
    const after = getComputedStyle(el, "::after");
    const pseudo = (p) =>
      p.content && p.content !== "none" && p.content !== "normal"
        ? {
            content: p.content.slice(0, 30), height: p.height, width: p.width,
            backgroundColor: p.backgroundColor, borderBottomWidth: p.borderBottomWidth,
            borderBottomColor: p.borderBottomColor, position: p.position,
            fontFamily: p.fontFamily, fontSize: p.fontSize, color: p.color,
          }
        : undefined;
    const own = [...el.childNodes]
      .filter((c) => c.nodeType === 3)
      .map((c) => c.nodeValue.trim())
      .join(" ")
      .trim();
    const node = {
      i: n++,
      tag: el.tagName.toLowerCase(),
      cls: typeof el.className === "string" ? el.className : "",
      id: el.id || undefined,
      role: el.getAttribute("role") || undefined,
      aria: el.getAttribute("aria-label") || undefined,
      text: own ? own.slice(0, 80) : undefined,
      rect: [r.x, r.y, r.width, r.height].map((v) => Math.round(v * 100) / 100),
      style,
      before: pseudo(before),
      after: pseudo(after),
      children: [],
    };
    for (const c of el.children) {
      const k = walk(c, depth + 1);
      if (k) node.children.push(k);
    }
    return node;
  };
  return {
    viewport: [innerWidth, innerHeight, devicePixelRatio],
    scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
    htmlClass: document.documentElement.className,
    bodyClass: document.body.className,
    bodyStyle: (() => {
      const cs = getComputedStyle(document.body);
      return { backgroundColor: cs.backgroundColor, fontFamily: cs.fontFamily, color: cs.color };
    })(),
    tree: walk(document.body, 0),
  };
})()`;
