// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// A DOCUMENT SWAP IS NOT A NAVIGATION.
//
// `FrameLoader` hides its spinner on the iframe's own `load`, which fires exactly once. Opening a
// draft, reverting a version or dropping back to the live page replaces the whole document inside a
// frame that never navigates — no `load`, no spinner, and the author looked at the OLD page,
// unchanged, for as long as the new one took to render. Reported as "the page stuck until it loads".
//
// The two ends are tested here because they are the two ways it can go wrong: raised and never taken
// down (the editor covered), or taken down by the wrong patch (raised for a frame and useless).

// The markup `Panels.frame_busy/1` renders. `awaiting` is the first-load shape: already covering,
// with the label the server wrote into it.
function frame(id, { awaiting = false, label = "Loading the canvas…" } = {}) {
  const iframe = document.createElement("iframe");
  iframe.id = id;
  document.body.appendChild(iframe);

  const overlay = document.createElement("div");
  overlay.id = `${id}-busy`;
  overlay.dataset.role = "pb-frame-busy";
  overlay.dataset.frame = id;
  overlay.dataset.settleOnLoad = String(awaiting);
  overlay.hidden = !awaiting;
  overlay.innerHTML =
    '<span data-role="pb-busy-detail" hidden>' +
    `<span data-role="pb-busy-label">${label}</span>` +
    '<span data-role="pb-busy-elapsed"></span></span>';
  document.body.appendChild(overlay);
  return overlay;
}

const detailOf = (o) => o.querySelector("[data-role='pb-busy-detail']");
const labelOf = (o) => o.querySelector("[data-role='pb-busy-label']").textContent;
const elapsedOf = (o) => o.querySelector("[data-role='pb-busy-elapsed']").textContent;

function context(el) {
  const handlers = {};
  return {
    el,
    handlers,
    pushEvent: () => {},
    handleEvent: (name, fn) => (handlers[name] = fn),
  };
}

function busy(ctx, payload) {
  ctx.handlers["pb:frame-busy"](payload);
}

describe("the canvas busy overlay", () => {
  let ctx;

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
    ctx = context(document.createElement("main"));
    hooks.PbFrameBusy.mounted.call(ctx);
  });

  afterEach(() => {
    hooks.PbFrameBusy.destroyed.call(ctx);
    vi.useRealTimers();
  });

  it("covers every frame at once, because one swap changes all of them", () => {
    const one = frame("pb-frame-360");
    const two = frame("pb-frame-1180");

    busy(ctx, { label: "Opening “Tuesday”…", revision: 7 });

    expect(one.hidden).toBe(false);
    expect(two.hidden).toBe(false);
    expect(labelOf(one)).toBe("Opening “Tuesday”…");
  });

  it("counts the seconds, so a slow swap reads as progress rather than a freeze", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening…", revision: 3 });

    expect(elapsedOf(overlay)).toBe("0.0s");

    vi.advanceTimersByTime(1400);

    expect(elapsedOf(overlay)).toBe("1.4s");
  });

  it("is taken down when the canvas reports it has painted the document asked for", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening…", revision: 9 });

    window.dispatchEvent(
      new MessageEvent("message", {
        data: { pb: true, kind: "painted", revision: "9" },
        source: window.parent,
      }),
    );

    expect(overlay.hidden).toBe(true);
  });

  // The editor's OWN re-render is what carried the request, and the frame answers that first. Taking
  // the overlay down on it would raise the spinner for a frame and then uncover the old document —
  // exactly the state this exists to hide.
  it("ignores a report from the document that was already on screen", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening…", revision: 9 });

    window.dispatchEvent(
      new MessageEvent("message", {
        data: { pb: true, kind: "painted", revision: "8" },
        source: window.parent,
      }),
    );

    expect(overlay.hidden).toBe(false);
  });

  // A lost signal must not leave the editor covered for good.
  it("comes down on its own if the frame never reports back", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening…", revision: 2 });

    vi.advanceTimersByTime(15000);

    expect(overlay.hidden).toBe(true);
  });
  // A LOAD THAT FINISHES QUICKLY MUST NOT FLASH A SENTENCE at somebody with no time to read it. The
  // spinner is up from the first frame; the words wait half a second to see whether they are needed.
  it("holds the label and clock back until the wait is worth explaining", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening…", revision: 3 });

    expect(overlay.hidden).toBe(false);
    expect(detailOf(overlay).hidden).toBe(true);

    vi.advanceTimersByTime(520);

    expect(detailOf(overlay).hidden).toBe(false);
  });

  // NO PERCENTAGE TO REPORT, so the honest escalation is to say more as more time passes. A swap
  // only ever reaches the first two stages: it gives up at fifteen seconds and shows the document
  // that is still underneath. The later wording belongs to the first load, which cannot give up.
  it("says more the longer it waits", () => {
    const overlay = frame("pb-frame-desktop");
    busy(ctx, { label: "Opening “Tuesday”…", revision: 1 });

    vi.advanceTimersByTime(600);
    expect(labelOf(overlay)).toBe("Opening “Tuesday”…");

    vi.advanceTimersByTime(6000);
    expect(labelOf(overlay)).toMatch(/large one/);
  });
});

// THE FIRST LOAD, where the server renders the overlay already covering because there is nothing
// underneath it yet. Nothing pushes it, so the hook has to adopt it — start its clock, arm its
// listeners — or it would sit there with a spinner and no way down.
describe("the first load", () => {
  let ctx;

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
  });

  afterEach(() => {
    if (ctx) hooks.PbFrameBusy.destroyed.call(ctx);
    vi.useRealTimers();
  });

  const mount = () => {
    ctx = context(document.createElement("main"));
    hooks.PbFrameBusy.mounted.call(ctx);
  };

  it("adopts an overlay the server rendered covering, and starts its clock", () => {
    const overlay = frame("pb-frame-desktop", { awaiting: true });
    mount();

    expect(overlay.hidden).toBe(false);
    vi.advanceTimersByTime(1200);
    expect(elapsedOf(overlay)).toBe("1.2s");
  });

  // `load` means the document arrived — on a first load that is the tree, server-rendered into the
  // response, so the reader is looking at the page.
  it("settles when the frame's document arrives", () => {
    const overlay = frame("pb-frame-desktop", { awaiting: true });
    mount();

    document.getElementById("pb-frame-desktop").dispatchEvent(new Event("load"));

    expect(overlay.hidden).toBe(true);
  });

  it("settles just as well when the canvas reports first", () => {
    const overlay = frame("pb-frame-desktop", { awaiting: true });
    mount();

    window.dispatchEvent(
      new MessageEvent("message", {
        data: { pb: true, kind: "painted", revision: "1" },
        source: window.parent,
      }),
    );

    expect(overlay.hidden).toBe(true);
  });

  // THERE IS NOTHING UNDER A FIRST LOAD'S OVERLAY. Pulling it away on a timer would reveal a blank
  // iframe and turn a slow load into what looks like a broken one.
  it("never gives up on its own — it escalates instead", () => {
    const overlay = frame("pb-frame-desktop", { awaiting: true });
    mount();

    vi.advanceTimersByTime(6100);
    expect(labelOf(overlay)).toMatch(/large one/);

    vi.advanceTimersByTime(9000);
    expect(labelOf(overlay)).toMatch(/longer than usual/);

    vi.advanceTimersByTime(25000);
    expect(labelOf(overlay)).toMatch(/very slow/);

    // Still covering after forty seconds. There is nothing underneath but a blank iframe, and
    // uncovering it would turn a slow load into what looks like a broken one.
    expect(overlay.hidden).toBe(false);
    expect(elapsedOf(overlay)).toBe("40.0s");
  });

  it("does nothing when no overlay is covering — an ordinary mount", () => {
    const overlay = frame("pb-frame-desktop");
    mount();

    expect(overlay.hidden).toBe(true);
    vi.advanceTimersByTime(3000);
    expect(elapsedOf(overlay)).toBe("");
  });
});

describe("the canvas announcing what it has painted", () => {
  function canvas(revision) {
    const el = document.createElement("div");
    el.id = "pb-canvas-root";
    el.dataset.revision = String(revision);
    return el;
  }

  it("posts once per document, not once per patch", () => {
    const el = canvas(4);
    const ctx = { el, pushEvent: () => {}, handleEvent: () => {} };
    const posted = [];
    const original = window.parent.postMessage;
    window.parent.postMessage = (message) => posted.push(message);

    hooks.PbCanvas.updated.call(ctx);
    hooks.PbCanvas.updated.call(ctx);
    el.dataset.revision = "5";
    hooks.PbCanvas.updated.call(ctx);

    window.parent.postMessage = original;

    expect(posted.map((m) => m.revision)).toEqual(["4", "5"]);
    expect(posted.every((m) => m.pb === true && m.kind === "painted")).toBe(
      true,
    );
  });
});
