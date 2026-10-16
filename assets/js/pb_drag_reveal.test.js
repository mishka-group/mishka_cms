// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import hooks from "./admin_hooks";

// OPENING THE EMPTY CONTAINERS MUST NOT MOVE WHAT THE POINTER IS AIMED AT.
//
// An empty container has no height, so for the length of a drag every one of them is given a 34px
// floor and a dashed edge — otherwise a fresh 0px column is unreachable. But that changes the height
// of the document, so everything below the first opened box slides down mid-gesture: an author
// aiming below a table watched blocks appear above it and the table walk away from the cursor.
//
// The floors stay. The compensation is a scroll by exactly the distance the anchor moved, so the
// document grows and the thing being aimed at stays put.

let mounted = [];
let scrolled = 0;

function context(el) {
  const pushed = [];
  return {
    el,
    pushed,
    pushEvent: (name, payload) => pushed.push([name, payload]),
    handleEvent: () => {},
  };
}

function mount(hook, el) {
  const ctx = context(el);
  ctx.hook = hook;
  hook.mounted.call(ctx);
  mounted.push(ctx);
  return ctx;
}

beforeEach(() => {
  document.body.innerHTML = "";
  window.__pbDropHints = null;
  if (!window.CSS) window.CSS = {};
  if (!window.CSS.escape) window.CSS.escape = (value) => String(value);
  scrolled = 0;

  // jsdom leaves `document.scrollingElement` null, and the production code reads it to scroll the
  // canvas — so the document under test has to have one, with a scrollTop that records what it was
  // asked to do.
  const scroller = document.documentElement;

  Object.defineProperty(scroller, "scrollTop", {
    configurable: true,
    get: () => scrolled,
    set: (value) => {
      scrolled = value;
    },
  });

  Object.defineProperty(document, "scrollingElement", {
    configurable: true,
    get: () => scroller,
  });
});

afterEach(() => {
  for (const ctx of mounted) ctx.hook.destroyed?.call(ctx);
  mounted = [];
});

// An empty box above, and the node the pointer is over below it. The empty one grows when the
// reveal opens it, which in a real document pushes the lower one down by the same amount.
function canvasWithEmptyAbove({ grows = 34 } = {}) {
  const el = document.createElement("div");
  el.id = "pb-canvas-root";
  document.body.appendChild(el);

  const empty = document.createElement("div");
  empty.dataset.nodeId = "empty";
  empty.dataset.kind = "tag";
  empty.setAttribute("data-pb-nest", "");
  el.appendChild(empty);

  const target = document.createElement("div");
  target.dataset.nodeId = "target";
  target.dataset.kind = "tag";
  el.appendChild(target);

  // The reveal is what sets `min-height`, so the stubbed geometry reads the real style rather than a
  // flag — that way the test cannot pass unless the production code actually opened the box.
  const isOpen = () => empty.style.minHeight === "34px";

  empty.getBoundingClientRect = () => ({
    top: 0,
    bottom: isOpen() ? grows : 0,
    left: 0,
    right: 100,
    width: 100,
    height: isOpen() ? grows : 0,
  });

  // The target sits below, so it moves down by exactly what the empty one gained.
  target.getBoundingClientRect = () => {
    const top = isOpen() ? grows : 0;
    return { top, bottom: top + 50, left: 0, right: 100, width: 100, height: 50 };
  };

  return { el, empty, target };
}

// What crosses into the frame is a palette card unless the test says otherwise: its marker is the
// only part of a dataTransfer legible while the drag is still moving, and the reveal is gated on it.
function dragEvent(target, types = ["application/x-pb-template"]) {
  return {
    target,
    clientX: 10,
    clientY: 60,
    dataTransfer: {
      types,
      effectAllowed: "",
      dropEffect: "",
      setData: () => {},
      getData: () => "",
      setDragImage: () => {},
    },
    preventDefault: () => {},
    stopPropagation: () => {},
  };
}

describe("opening the empty containers during a drag", () => {
  it("scrolls by however far the aimed-at node moved", () => {
    const { el, target } = canvasWithEmptyAbove({ grows: 34 });
    const ctx = mount(hooks.PbCanvas, el);

    expect(scrolled).toBe(0);

    ctx.onDragEnter(dragEvent(target));

    expect(
      scrolled,
      "the document grew and nothing compensated, so the table walked away from the cursor",
    ).toBe(34);
  });

  it("leaves the scroll alone when nothing moved", () => {
    const { el, target } = canvasWithEmptyAbove({ grows: 0 });
    const ctx = mount(hooks.PbCanvas, el);

    ctx.onDragEnter(dragEvent(target));

    expect(scrolled).toBe(0);
  });

  // A FILE DRAGGED IN FROM FINDER, or a selection out of another tab, has no source node in either
  // of this editor's documents — so the browser fires `dragend` nowhere we listen, and the end of it
  // can never be broadcast into the frame. Anything it opened would stand for the rest of the
  // session. It is not opened.
  it("is not opened by a drag carrying nothing this editor owns", () => {
    const { el, empty, target } = canvasWithEmptyAbove();
    const ctx = mount(hooks.PbCanvas, el);

    ctx.onDragEnter(dragEvent(target, ["Files"]));

    expect(empty.style.minHeight, "a file from outside the browser inflated the layout").toBe("");
    expect(empty.style.outline).toBe("");
    expect(scrolled).toBe(0);
  });
});

// AND THEY HAVE TO CLOSE AGAIN, however the gesture ended.
//
// `dragend` fires on the SOURCE, so a palette card picked up in the chrome and released back over
// the palette is never reported to the frame it crossed. Every empty container on the page kept its
// 34px floor, its dashed edge and its tint for the rest of the session — and the false heights then
// moved where the next drop landed. The chrome broadcasts the end into every frame instead.
describe("closing the empty containers again", () => {
  it("restores every inline style when the drag ends outside the frame", () => {
    const { el, empty, target } = canvasWithEmptyAbove();
    const ctx = mount(hooks.PbCanvas, el);

    ctx.onDragEnter(dragEvent(target));
    expect(empty.style.minHeight).toBe("34px");

    window.dispatchEvent(new Event("pb:dragend"));

    expect(empty.style.minHeight, "the floor outlived the drag that asked for it").toBe("");
    expect(empty.style.outline).toBe("");
    expect(empty.style.outlineOffset).toBe("");
    expect(empty.style.background).toBe("");
  });

  // A box left standing open measures the floor it was given, so the re-scan that begins the next
  // drag read it as content, skipped it, and dropped the entry holding its real styles — after
  // which nothing could ever put it back.
  it("still restores a box a previous gesture left open", () => {
    const { el, empty, target } = canvasWithEmptyAbove();
    const ctx = mount(hooks.PbCanvas, el);

    ctx.onDragEnter(dragEvent(target));
    ctx.onDragStart(dragEvent(target));

    window.dispatchEvent(new Event("pb:dragend"));

    expect(empty.style.minHeight, "the second drag forgot the box the first one opened").toBe("");
    expect(empty.style.outline).toBe("");
  });

  it("and the chrome tells every canvas frame when a drag it owns ends", () => {
    const el = document.createElement("div");
    const frame = document.createElement("iframe");
    frame.setAttribute("src", "/admin/dashboard/runtime/builder-canvas/tok");
    el.appendChild(frame);
    document.body.appendChild(el);

    mount(hooks.PbShortcuts, el);

    const ends = [];
    frame.contentWindow.addEventListener("pb:dragend", () => ends.push("frame"));

    // A palette card released back over the palette: `dragend` fires out here and nowhere else.
    window.dispatchEvent(new Event("dragend"));

    expect(ends, "the frame was never told the gesture was over").toEqual(["frame"]);
    expect(window.__pbDropHints).toBe(null);
    expect(window.__pbDragNode).toBe(null);
  });
});
