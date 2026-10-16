// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import hooks from "./admin_hooks";

// THE MENU IS IN THE CHROME AND THE POINTER WAS IN THE FRAME.
//
// A right-click on the canvas is posted up from the frame's own document carrying the point it
// happened at, and the chrome adds the frame's box to move that point into its own coordinates.
// But the frame is CSS-zoomed: it keeps its real breakpoint width and is PAINTED smaller — the
// all-breakpoints view opens at 30%, the single frame runs 40%–200%. So the point being added is
// in a different scale from the box it is added to, and at 30% a click near the right of a 1180px
// canvas asked for a menu ~800px past the pointer, which `open`'s flip then pinned to a viewport
// edge. Nothing else in the editor compensated for the frame scale.
//
// The zoom is MEASURED here rather than read back out of a style: the painted width over the
// viewport the frame's own document reports, which is the space the point came in.

const FRAME_WIDTH = 1180; // the desktop breakpoint — the width the canvas document is laid out at
const MENU = { width: 216, height: 300 };

const mounted = [];

function box({ left, top, width, height }) {
  return { left, top, width, height, right: left + width, bottom: top + height, x: left, y: top };
}

// jsdom lays nothing out, so every box and every viewport this hook reads is stated outright.
function measure(el, prop, value) {
  Object.defineProperty(el, prop, { configurable: true, value });
}

function menu({ viewport = [0, 0] } = {}) {
  document.body.innerHTML = `
    <div id="pb-ctx" data-target="[data-layer-row]" data-key="layerRow" hidden>
      <button data-action="delete">Delete</button>
    </div>
    <iframe id="pb-frame-desktop"></iframe>`;

  measure(document.documentElement, "clientWidth", viewport[0]);
  measure(document.documentElement, "clientHeight", viewport[1]);

  const el = document.getElementById("pb-ctx");
  el.getBoundingClientRect = () => box({ left: 0, top: 0, ...MENU });

  const ctx = {
    el,
    pushed: [],
    pushEvent(name, payload) {
      this.pushed.push([name, payload]);
    },
    handleEvent: () => {},
  };

  hooks.PbContextMenu.mounted.call(ctx);
  mounted.push(ctx);
  return ctx;
}

// The frame as the browser reports it: `getBoundingClientRect` is what is painted, and the frame's
// own `innerWidth` is the viewport its document is laid out in. Their ratio is the zoom.
function paint(frame, { left, top, width, layout = FRAME_WIDTH }) {
  frame.getBoundingClientRect = () => box({ left, top, width, height: (820 * width) / layout });
  measure(frame.contentWindow, "innerWidth", layout);
}

function rightClick(frame, { x, y, id = "n1", hidden = false }) {
  window.dispatchEvent(
    new MessageEvent("message", {
      data: { pb: true, kind: "context", id, x, y, hidden },
      source: frame.contentWindow,
    }),
  );
}

// ONE ENTRY, TWO WORDS: the menu is marked with whether the node it opened on is hidden from
// visitors, so its Hide entry can read Show.
describe("the menu knows whether the node it opened on is hidden from visitors", () => {
  afterEach(() => {
    while (mounted.length) hooks.PbContextMenu.destroyed.call(mounted.pop());
  });

  it("from the canvas, as the frame says", () => {
    const ctx = menu();
    const frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 0, top: 0, width: FRAME_WIDTH });

    rightClick(frame, { x: 10, y: 10, hidden: true });
    expect(ctx.el.dataset.hidden).toBe("true");

    rightClick(frame, { x: 10, y: 10, hidden: false });
    expect(ctx.el.dataset.hidden).toBe("false");
  });

  it("from a layers row, as the row says", () => {
    const ctx = menu();
    const row = document.createElement("div");
    row.dataset.layerRow = "n7";
    row.dataset.pbHidden = "true";
    document.body.appendChild(row);

    row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, clientX: 5, clientY: 5 }));
    expect(ctx.el.dataset.hidden).toBe("true");

    delete row.dataset.pbHidden;
    row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, clientX: 5, clientY: 5 }));
    expect(ctx.el.dataset.hidden).toBe("false");
  });
});

describe("the canvas right-click menu opens at the pointer", () => {
  let frame;
  let ctx;

  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    while (mounted.length) hooks.PbContextMenu.destroyed.call(mounted.pop());
  });

  it("adds the frame's origin when the frame is painted at its real size", () => {
    ctx = menu();
    frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 100, top: 50, width: FRAME_WIDTH });

    rightClick(frame, { x: 200, y: 100 });

    expect(ctx.el.hidden).toBe(false);
    expect([ctx.el.style.left, ctx.el.style.top]).toEqual(["300px", "150px"]);
  });

  // THE REPORTED DEFECT. 1180px of canvas painted 354px wide is the all-breakpoints view at its
  // default 30%; unscaled, this click asked for 1200px and landed nowhere near the pointer.
  it("scales the frame's own point by the zoom it is painted at", () => {
    ctx = menu();
    frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 100, top: 50, width: 354 });

    rightClick(frame, { x: 1100, y: 600 });

    expect([ctx.el.style.left, ctx.el.style.top]).toEqual(["430px", "230px"]);
  });

  // The symptom as it was reported: the menu appeared pinned to a corner. `open` flips a menu that
  // would overhang, so an over-large x did not merely miss the pointer — it jumped to the far side.
  it("is not flipped across the viewport by a point it never reached", () => {
    ctx = menu({ viewport: [1400, 900] });
    frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 100, top: 50, width: 354 });

    rightClick(frame, { x: 1100, y: 600 });

    // Unscaled this was 100 + 1100 = 1200, which overhangs 1400 and flipped to 984.
    expect(ctx.el.style.left).toBe("430px");
  });

  it("zooms above 100% too", () => {
    ctx = menu();
    frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 0, top: 0, width: FRAME_WIDTH * 2 });

    rightClick(frame, { x: 300, y: 200 });

    expect([ctx.el.style.left, ctx.el.style.top]).toEqual(["600px", "400px"]);
  });

  // A frame nobody has painted yet reports a box of zeroes, and zero over a width is not a scale.
  // The point on its own is at least close; a NaN is a menu with no position at all.
  it("leaves an unpainted frame unscaled rather than NaN", () => {
    ctx = menu();
    frame = document.getElementById("pb-frame-desktop");

    rightClick(frame, { x: 1100, y: 600 });

    expect([ctx.el.style.left, ctx.el.style.top]).toEqual(["1100px", "600px"]);
  });

  it("carries the node the click was on, and acts on that one", () => {
    ctx = menu();
    frame = document.getElementById("pb-frame-desktop");
    paint(frame, { left: 100, top: 50, width: 354 });

    rightClick(frame, { x: 1100, y: 600, id: "deep-node" });
    ctx.el.querySelector("[data-action]").dispatchEvent(new MouseEvent("click", { bubbles: true }));

    expect(ctx.pushed).toEqual([["ctx", { action: "delete", node_id: "deep-node" }]]);
    expect(ctx.el.hidden).toBe(true);
  });

  it("ignores a message from a window that is not one of its frames", () => {
    ctx = menu();

    rightClick({ contentWindow: {} }, { x: 10, y: 10 });

    expect(ctx.el.hidden).toBe(true);
  });
});
