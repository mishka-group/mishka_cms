// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// A MENU IN THE CHROME CANNOT SEE A CLICK IN THE CANVAS.
//
// `phx-click-away` walks the chrome's document for open menus and compares each against where the
// press started. A press inside the frame is an event in ANOTHER document, so it never reaches that
// walk: the "..." menu, the preview picker and every other dropdown stayed open while you clicked
// the page behind them, and only a click on the chrome itself would shut them.
//
// Two halves, asserted separately because they live in different documents: the frame says a press
// happened, and the chrome replays it as a real press on the frame element — which IS in its
// document, so LiveView answers it the way it answers any other click on empty chrome.
const live = [];

function canvas(html = '<p data-node-id="p1" data-kind="tag">hi</p>') {
  document.body.innerHTML = `<div id="pb-canvas-root">${html}</div>`;
  const el = document.getElementById("pb-canvas-root");
  el.dataset.preview = "false";

  const ctx = { el, pushed: [], pushEvent() {}, handleEvent: () => {} };
  hooks.PbCanvas.mounted.call(ctx);
  live.push(ctx);
  return ctx;
}

function press(selector) {
  document
    .querySelector(selector)
    .dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
}

describe("a press in the canvas dismisses the chrome's menus", () => {
  let posted;

  beforeEach(() => {
    document.body.innerHTML = "";
    posted = [];
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    vi.stubGlobal("CSS", { escape: (value) => value });
    Element.prototype.scrollIntoView = vi.fn();
    vi.spyOn(window.parent, "postMessage").mockImplementation((message) => posted.push(message));
  });

  afterEach(() => {
    while (live.length) hooks.PbCanvas.destroyed.call(live.pop());
    vi.restoreAllMocks();
  });

  it("posts a dismissal when the canvas is pressed", () => {
    canvas();

    press('[data-node-id="p1"]');

    expect(posted).toContainEqual({ pb: true, kind: "dismiss" });
  });

  // The element toolbar lives in the frame's top layer and a link's press is stopped before it
  // bubbles — both are presses that left a menu open, and both are why this listens in the capture
  // phase on the document rather than on the canvas root.
  it("posts it for a link too, whose press is stopped before it bubbles", () => {
    canvas('<a id="hit" href="/somewhere">go</a>');

    press("#hit");

    expect(posted).toContainEqual({ pb: true, kind: "dismiss" });
  });

  it("stops posting once the hook is torn down", () => {
    canvas();
    hooks.PbCanvas.destroyed.call(live.pop());

    press('[data-node-id="p1"]');

    expect(posted).toEqual([]);
  });

  describe("and the chrome replays it", () => {
    // LiveView answers a click in two steps: click-away for every open menu, then the nearest
    // `phx-click` above the target. The stand-in below is that second step, so "nothing else runs"
    // is asserted against the same lookup LiveView does rather than assumed.
    let answered;
    const chromes = [];
    const answer = (event) => answered.push(event.target.closest("[phx-click]"));

    function chrome() {
      document.body.innerHTML = `
        <div id="pb-shortcuts"></div>
        <div id="pb-canvas-scroll" phx-click="place">
          <iframe id="frame-a"></iframe>
          <iframe id="frame-b"></iframe>
        </div>`;

      const ctx = {
        el: document.getElementById("pb-shortcuts"),
        pushed: [],
        pushEvent(name, payload) {
          this.pushed.push([name, payload]);
        },
        handleEvent: () => {},
      };

      hooks.PbShortcuts.mounted.call(ctx);
      chromes.push(ctx);
      return ctx;
    }

    function dismissFrom(source, data = { pb: true, kind: "dismiss" }) {
      window.dispatchEvent(new MessageEvent("message", { data, source }));
    }

    beforeEach(() => {
      answered = [];
      window.addEventListener("click", answer);
    });

    afterEach(() => {
      window.removeEventListener("click", answer);
      while (chromes.length) hooks.PbShortcuts.destroyed.call(chromes.pop());
    });

    it("presses the chrome's body, mousedown first", () => {
      chrome();
      const seen = [];

      for (const kind of ["mousedown", "click"]) {
        window.addEventListener(kind, (event) => seen.push([kind, event.target, event.bubbles]), {
          once: true,
        });
      }

      dismissFrom(document.getElementById("frame-b").contentWindow);

      // Both, and in this order: LiveView records where a press STARTED on mousedown and only then
      // answers the click with it. A click alone leaves the menus open.
      expect(seen).toEqual([
        ["mousedown", document.body, true],
        ["click", document.body, true],
      ]);
    });

    // THE REPORTED DEFECT. Pressed on the frame element, the replay resolved to the scroll
    // container's `place`, which dropped an armed palette component at the top of the page.
    it("runs no click binding — not the canvas scroll's place", () => {
      chrome();

      dismissFrom(document.getElementById("frame-b").contentWindow);

      expect(answered).toEqual([null]);
    });

    it("ignores a message that did not come from the builder", () => {
      chrome();

      dismissFrom(document.getElementById("frame-b").contentWindow, { kind: "dismiss" });

      expect(answered).toEqual([]);
    });
  });
});
