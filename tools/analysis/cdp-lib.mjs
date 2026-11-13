// Minimal Chrome DevTools Protocol client for driving a local, throwaway
// browser during design analysis. No dependencies: uses Node's built-in
// fetch and WebSocket (Node >= 22).
//
// rea observes passively; this file performs the interactions (navigate,
// click, type, resize) so that there is something to observe.

import { writeFile } from "node:fs/promises";

export async function listTargets(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  return (await res.json()).filter((t) => t.type === "page");
}

export async function connect(port, targetId) {
  const targets = await listTargets(port);
  const target = targetId
    ? targets.find((t) => t.id === targetId)
    : targets[0];
  if (!target) throw new Error(`no page target (wanted ${targetId ?? "any"})`);

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  const listeners = new Set();
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id !== undefined && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(`${msg.error.message} (${msg.error.code})`));
      else resolve(msg.result);
    } else if (msg.method) {
      for (const fn of listeners) fn(msg);
    }
  });

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Evaluate an expression (or an async function body via `(async()=>{...})()`)
  // and return its JSON-serialisable value.
  const evaluate = async (expression) => {
    const out = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (out.exceptionDetails) {
      const d = out.exceptionDetails;
      throw new Error(
        `page exception: ${d.exception?.description ?? d.text}`,
      );
    }
    return out.result.value;
  };

  const setViewport = (width, height, deviceScaleFactor = 1, mobile = false) =>
    send("Emulation.setDeviceMetricsOverride", {
      width,
      height,
      deviceScaleFactor,
      mobile,
    });

  const mouse = (type, x, y, extra = {}) =>
    send("Input.dispatchMouseEvent", {
      type,
      x,
      y,
      button: "left",
      buttons: type === "mouseReleased" ? 0 : 1,
      clickCount: 1,
      ...extra,
    });

  const move = (x, y) =>
    send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, buttons: 0 });

  const click = async (x, y) => {
    await move(x, y);
    await mouse("mousePressed", x, y);
    await mouse("mouseReleased", x, y);
  };

  // Press-move-release with intermediate steps, for pointer-based drag and drop.
  const drag = async (x0, y0, x1, y1, steps = 12, holdMs = 150) => {
    await move(x0, y0);
    await mouse("mousePressed", x0, y0);
    await sleep(holdMs);
    for (let i = 1; i <= steps; i++) {
      const t = i / steps;
      await send("Input.dispatchMouseEvent", {
        type: "mouseMoved",
        x: x0 + (x1 - x0) * t,
        y: y0 + (y1 - y0) * t,
        button: "left",
        buttons: 1,
      });
      await sleep(25);
    }
    await sleep(holdMs);
    return { release: () => mouse("mouseReleased", x1, y1) };
  };

  const typeText = (text) => send("Input.insertText", { text });

  const KEYS = {
    Enter: { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" },
    Escape: { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 },
    Tab: { key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 },
    Backspace: { key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 },
    ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37 },
    ArrowRight: { key: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39 },
    ArrowUp: { key: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38 },
    ArrowDown: { key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40 },
  };
  const press = async (name, modifiers = 0) => {
    const k = KEYS[name] ?? {
      key: name,
      code: `Key${name.toUpperCase()}`,
      windowsVirtualKeyCode: name.toUpperCase().charCodeAt(0),
      text: modifiers ? undefined : name,
    };
    await send("Input.dispatchKeyEvent", { type: "keyDown", modifiers, ...k });
    await send("Input.dispatchKeyEvent", { type: "keyUp", modifiers, ...k });
  };

  const screenshot = async (path, { fullPage = false } = {}) => {
    const { data } = await send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: fullPage,
    });
    await writeFile(path, Buffer.from(data, "base64"));
    return path;
  };

  const navigate = async (url, settleMs = 2500) => {
    await send("Page.enable");
    await send("Page.navigate", { url });
    await sleep(settleMs);
  };

  return {
    target,
    send,
    evaluate,
    setViewport,
    click,
    move,
    drag,
    typeText,
    press,
    screenshot,
    navigate,
    sleep,
    on: (fn) => listeners.add(fn),
    close: () => ws.close(),
  };
}
