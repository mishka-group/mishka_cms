import { beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// THE SELECTED ROW HAS TO BE BROUGHT INTO VIEW, AND TWICE NOW IT WAS NOT.
//
// `BuilderLive.expand_selected/2` pushes `pb:reveal-layer` on every selection. For a long time
// nothing listened, so the rail marked the row and stayed where it was — the same shape of bug as
// `pb:drop-hints` next door, and the hook's own comment described the behaviour as if it existed.
//
// The first listener then used `scrollIntoView`, which is wrong twice over and in ways a browser
// shows and a shim hides: it walks UP and moves every scrollport on the way, not just the rail, and
// its smooth mode is an animation the next LiveView patch cancels — and a patch is guaranteed here,
// because selecting is what rewrote the rail. Then it assumed the hook's own element is the one that
// scrolls, and setting `scrollTop` on a box that does not scroll does nothing at all, silently.
//
// So the geometry is asserted here rather than in a browser. jsdom does no layout, which is the
// point: every box is stated, and the handler's arithmetic is what is under test.
function context(el) {
  const handlers = {};

  return {
    el,
    handlers,
    pushEvent: () => {},
    handleEvent: (name, fn) => (handlers[name] = fn),
  };
}

function box(el, { top, height }) {
  el.getBoundingClientRect = () => ({
    top,
    bottom: top + height,
    height,
    left: 0,
    right: 0,
    width: 0,
  });
}

function scrollport(el, { top = 0, client = 400, scroll = 900 } = {}) {
  el.style.overflowY = "auto";
  Object.defineProperty(el, "clientHeight", { value: client, configurable: true });
  Object.defineProperty(el, "scrollHeight", { value: scroll, configurable: true });
  el.scrollTop = top;
  el.scrollTo = vi.fn(({ top: to }) => {
    el.scrollTop = to;
  });
  return el;
}

// `overflowY` is read through `getComputedStyle`, which jsdom answers from inline styles.
function build({ railScrolls }) {
  document.body.innerHTML = `
    <div id="outer"><div id="pb-layers"><div data-layer-row="target"></div></div></div>
  `;

  const outer = document.getElementById("outer");
  const rail = document.getElementById("pb-layers");
  const row = rail.querySelector('[data-layer-row="target"]');

  // Whichever box carries the overflow is the one that must move.
  const scroller = railScrolls ? scrollport(rail) : scrollport(outer);
  if (railScrolls) Object.defineProperty(outer, "scrollHeight", { value: 0, configurable: true });
  else Object.defineProperty(rail, "scrollHeight", { value: 0, configurable: true });

  box(scroller, { top: 0, height: 400 });

  return { rail, row, scroller };
}

function reveal(rail, row) {
  const ctx = context(rail);
  hooks.PbLayers.mounted.call(ctx);
  expect(ctx.handlers["pb:reveal-layer"]).toBeTypeOf("function");
  ctx.handlers["pb:reveal-layer"]({ id: "target" });
  return ctx;
}

describe("pb:reveal-layer", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    // The handler waits a frame for the patch that opened the branch to land.
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    vi.stubGlobal("matchMedia", () => ({ matches: false }));
    // jsdom ships no `CSS` object; the hook uses `CSS.escape` to build the row selector.
    vi.stubGlobal("CSS", { escape: (value) => value });
  });

  it("is listened for at all", () => {
    const { rail, row } = build({ railScrolls: true });
    box(row, { top: 700, height: 24 });
    expect(() => reveal(rail, row)).not.toThrow();
  });

  it("scrolls down to a row below the fold", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    box(row, { top: 700, height: 24 });

    reveal(rail, row);

    // 0 + (700 - 0) - (400 - 24) / 2 = 512
    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 512, behavior: "smooth" });
  });

  it("scrolls up to a row above the fold", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    scroller.scrollTop = 600;
    box(row, { top: -200, height: 24 });

    reveal(rail, row);

    // 600 + (-200 - 0) - 188 = 212
    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 212, behavior: "smooth" });
  });

  it("never scrolls past the top", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    box(row, { top: -500, height: 24 });

    reveal(rail, row);

    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" });
  });

  it("leaves a row that is already in view alone", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    box(row, { top: 100, height: 24 });

    reveal(rail, row);

    expect(scroller.scrollTo).not.toHaveBeenCalled();
  });

  // THE ONE THE BROWSER FOUND. The hook sits on the rail, but which box carries the overflow depends
  // on the panel's height and the layout above it. Assuming the hook's own element scrolls made the
  // handler a no-op wherever it does not.
  it("moves the ancestor that actually scrolls, not the hook's own element", () => {
    const { rail, row, scroller } = build({ railScrolls: false });
    box(row, { top: 700, height: 24 });

    reveal(rail, row);

    expect(scroller.id).toBe("outer");
    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 512, behavior: "smooth" });
  });

  it("does not animate when the tab is hidden — a stalled loop scrolls nothing", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    box(row, { top: 700, height: 24 });
    Object.defineProperty(document, "hidden", { value: true, configurable: true });

    reveal(rail, row);

    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 512, behavior: "auto" });
    Object.defineProperty(document, "hidden", { value: false, configurable: true });
  });

  it("ignores a reveal with no id", () => {
    const { rail, row, scroller } = build({ railScrolls: true });
    box(row, { top: 700, height: 24 });

    const ctx = context(rail);
    hooks.PbLayers.mounted.call(ctx);
    ctx.handlers["pb:reveal-layer"]({});

    expect(scroller.scrollTo).not.toHaveBeenCalled();
  });
});
