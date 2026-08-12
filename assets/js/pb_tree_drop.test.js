import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// DROPPING INTO THE TREE.
//
// The layers rail is one of three surfaces a drag can cross, and it was the only one that took
// nothing from the other two: a palette card was refused outright, a node picked up on the canvas
// arrived with no verdict from the server, and the one target that exists to say "inside" was the
// one target no verdict could veto.
//
// Everything here drives the real hook. jsdom has no drag of its own, so the DataTransfer and the
// boxes are stubbed — the first because a real one cannot exist without a real drag, the second
// because every element in jsdom is zero-sized and the rail's geometry is all ratios.

const NODE_MIME = "application/x-pb-node";
const TEMPLATE_MIME = "application/x-pb-template";

function transfer(entries = {}) {
  const data = { ...entries };

  // `types` is LIVE on a real DataTransfer, and it is the whole reason a receiving surface can tell
  // a node drag from a card drag while the values are still sealed.
  return {
    get types() {
      return Object.keys(data);
    },
    effectAllowed: "uninitialized",
    dropEffect: "none",
    setData: (type, value) => (data[type] = value),
    getData: (type) => data[type] || "",
  };
}

function dragEvent(type, target, dataTransfer, point = { clientX: 10, clientY: 10 }) {
  const event = {
    type,
    target,
    dataTransfer,
    defaultPrevented: false,
    preventDefault() {
      event.defaultPrevented = true;
    },
    stopPropagation: () => {},
    relatedTarget: null,
    ...point,
  };

  return event;
}

let mounted = [];

function context(el) {
  const pushed = [];
  const replies = [];

  return {
    el,
    pushed,
    replies,
    pushEvent: (name, payload, onReply) => {
      pushed.push([name, payload]);
      if (onReply) replies.push(onReply);
    },
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

// A rail of two container rows and one that cannot hold children, plus the end-of-page target.
// Rows are 20px tall so the bands are whole numbers: 0-5 before, 5-15 inside, 15-20 after.
function rail() {
  const el = document.createElement("div");
  document.body.appendChild(el);

  const box = (top) => () => ({ top, bottom: top + 20, height: 20, left: 0, right: 200, width: 200 });
  const made = {};

  const add = (id, { parentId = "root", index = 0, kind = "tag", top, holds = true, open }) => {
    const row = document.createElement("div");
    row.dataset.layerRow = id;
    row.dataset.parentId = parentId;
    row.dataset.index = String(index);
    if (holds) row.dataset.container = "true";
    if (open !== undefined) row.dataset.open = open;
    row.dataset.kind = kind;
    row.getBoundingClientRect = box(top);
    el.appendChild(row);
    made[id] = row;
  };

  add("nmain0000", { index: 0, top: 0, open: "true" });
  add("nfoot0000", { index: 1, top: 20, open: "false" });
  add("ntext0000", { index: 2, top: 40, kind: "text", holds: false });

  const tail = document.createElement("div");
  tail.dataset.role = "pb-root-drop";
  tail.dataset.parentId = "root";
  tail.getBoundingClientRect = box(60);
  el.appendChild(tail);

  // The rail is the scrollport, and jsdom gives it no box of its own.
  el.getBoundingClientRect = () => ({ top: 0, bottom: 100, height: 100, left: 0, right: 200, width: 200 });

  return { el, tail, ...made };
}

const shown = (el) => el.dataset.show === "true";
const offers = (el) => el.dataset.can === "true";

beforeEach(() => {
  document.body.innerHTML = "";
  window.__pbDropHints = null;
  window.__pbDragNode = null;
  if (!window.CSS) window.CSS = {};
  if (!window.CSS.escape) window.CSS.escape = (value) => String(value);
});

afterEach(() => {
  for (const ctx of mounted) ctx.hook.destroyed?.call(ctx);
  mounted = [];
  window.__pbDropHints = null;
  window.__pbDragNode = null;
});

describe("a palette card dragged onto the layers rail", () => {
  // The rail required the node marker for a drag to count at all, so it never cancelled a
  // `dragover` for a card — and per HTML no `drop` is dispatched when the last `dragover` stood.
  // Nothing was highlighted, nothing happened, and there was not even a refusal to report.
  it("is accepted, where it used to be refused outright", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [TEMPLATE_MIME]: "<figure></figure>", "text/plain": "<figure></figure>" });

    const over = dragEvent("dragover", bar.nmain0000, dt, { clientX: 10, clientY: 10 });
    ctx.onDragOver(over);

    expect(over.defaultPrevented).toBe(true);
    expect(bar.nmain0000.dataset.drop).toBe("inside");
  });

  // A source that allows only "copy" and a target that answers "move" resolve to `none`, which
  // Chrome discards silently. The canvas learned this the hard way; the rail hardcoded "move".
  it("is answered copy, not move", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [TEMPLATE_MIME]: "<figure></figure>" });

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 10 }));

    expect(dt.dropEffect).toBe("copy");
  });

  it("lands as an insert carrying its template, and no node id", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [TEMPLATE_MIME]: "<figure></figure>" });

    ctx.onDrop(dragEvent("drop", bar.nmain0000, dt, { clientY: 10 }));

    const [name, payload] = ctx.pushed.at(-1);
    expect(name).toBe("drop");
    expect(payload.template).toBe("<figure></figure>");
    expect(payload.node_id).toBeUndefined();
    expect(payload.parent_id).toBe("nmain0000");
    expect(payload.index).toBe(9999);
  });

  it("is still refused when the drag carries nothing this editor owns", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    const over = dragEvent("dragover", bar.nmain0000, transfer({ "text/plain": "hello" }));
    ctx.onDragOver(over);
    ctx.onDrop(dragEvent("drop", bar.nmain0000, transfer({ "text/plain": "hello" })));

    expect(over.defaultPrevented).toBe(false);
    expect(ctx.pushed).toHaveLength(0);
  });
});

describe("a node drag on the rail", () => {
  it("is still answered move", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "ncanvas01" });

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 10 }));

    expect(dt.dropEffect).toBe("move");
  });

  // The self-check compared against `this.dragging`, which only the rail's own dragstart sets. A
  // node picked up on the canvas was therefore offered its own row as a place to drop itself.
  it("does not offer the dragged node's own row, wherever the drag began", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    window.__pbDragNode = "nmain0000";

    const over = dragEvent("dragover", bar.nmain0000, transfer({ [NODE_MIME]: "nmain0000" }));
    ctx.onDragOver(over);

    expect(over.defaultPrevented).toBe(false);
    expect(bar.nmain0000.dataset.drop).toBeUndefined();
  });
});

// NOTHING MOVES WHILE A DRAG IS IN FLIGHT.
//
// The first version of this drew a "drop inside …" strip under the hovered row. Showing one is
// harmless — it moves only what is below its own row — but HIDING the previous one moves the row now
// under the pointer, and the strip was taller than a row. Two failures came out of that: travelling
// down the rail flipped "before footer" into "inside footer" with the pointer standing still, and
// reaching the end-of-page target pulled it out from under the pointer, which is a release that
// fires no `drop` event and reports nothing.
//
// So the answer is written on boxes that already have their size: a chip inside the row for the
// target, an outline on every row that would take this drag for the map.
describe("what the rail says while something is being dragged", () => {
  it("marks the row itself as the container being entered", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    ctx.onDragOver(
      dragEvent("dragover", bar.nmain0000, transfer({ [NODE_MIME]: "nother000" }), { clientY: 10 })
    );

    expect(bar.nmain0000.dataset.drop).toBe("inside");
    expect(bar.nfoot0000.dataset.drop).toBeUndefined();
  });

  // Half the row, not the middle 40%. Twelve pixels of a 31px row is not a target anybody can aim
  // at, and for a component it is twelve pixels above nine hundred of properties and slot ghosts.
  it("gives half the row to inside, and the outer quarters to beside", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nother000" });

    const zoneAt = (y) => {
      ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: y }));
      return bar.nmain0000.dataset.drop;
    };

    expect(zoneAt(2)).toBe("before");
    expect(zoneAt(6)).toBe("inside");
    expect(zoneAt(14)).toBe("inside");
    expect(zoneAt(18)).toBe("after");
  });

  // A row that cannot be entered splits its middle rather than handing all of it to "after".
  it("splits the middle of a row that cannot be entered", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nother000" });

    ctx.onDragOver(dragEvent("dragover", bar.ntext0000, dt, { clientY: 47 }));
    expect(bar.ntext0000.dataset.drop).toBe("before");

    ctx.onDragOver(dragEvent("dragover", bar.ntext0000, dt, { clientY: 53 }));
    expect(bar.ntext0000.dataset.drop).toBe("after");
  });

  // The map: every row this drag could go into, drawn once for the whole gesture. Before it, the
  // only way to find out whether a container would take something was to drop it and read the flash.
  it("outlines every row that would take this drag", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    window.__pbDropHints = { nmain0000: true, nfoot0000: false, ntext0000: false };

    // Pointed at the row that takes nothing, so the map is read on rows the marker is not touching.
    ctx.onDragOver(dragEvent("dragover", bar.ntext0000, transfer({ [NODE_MIME]: "nx" }), { clientY: 47 }));

    expect(offers(bar.nmain0000)).toBe(true);
    expect(offers(bar.nfoot0000)).toBe(false);
    expect(offers(bar.ntext0000)).toBe(false);
  });

  // Until the verdict lands the rail can only answer from `data-container`, which is a question
  // about the target alone. The sweep therefore runs again the moment the server has answered.
  it("re-draws the map when the server's verdict arrives", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nx" });

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 2 }));
    expect(offers(bar.nfoot0000)).toBe(true, "the optimistic guess");

    window.__pbDropHints = { nmain0000: true, nfoot0000: false };
    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 2 }));

    expect(offers(bar.nfoot0000)).toBe(false);
    expect(offers(bar.nmain0000)).toBe(true);
  });

  it("never offers the row being dragged", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer();

    ctx.onDragStart(dragEvent("dragstart", bar.nmain0000, dt));

    expect(offers(bar.nmain0000)).toBe(false);
    expect(offers(bar.nfoot0000)).toBe(true);
  });

  // Two dashed treatments on one row read as two different offers.
  it("takes the outline off the row it is actually pointing at, and puts it back", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nx" });

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 10 }));
    expect(offers(bar.nmain0000)).toBe(false);

    ctx.onDragOver(dragEvent("dragover", bar.nfoot0000, dt, { clientY: 30 }));
    expect(offers(bar.nmain0000)).toBe(true);
    expect(offers(bar.nfoot0000)).toBe(false);
  });

  it("appends, as the canvas does, rather than putting the node first", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    ctx.onDrop(dragEvent("drop", bar.nmain0000, transfer({ [NODE_MIME]: "nx" }), { clientY: 10 }));

    const [, payload] = ctx.pushed.at(-1);
    expect(payload.parent_id).toBe("nmain0000");
    expect(payload.index).toBe(9999);
  });
});

describe("the end of the page", () => {
  it("is offered for the length of a gesture the rail can take", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, transfer({ [NODE_MIME]: "nx" })));

    expect(shown(bar.tail)).toBe(true);
  });

  // IT IS THE ONLY BOX HERE WHOSE SIZE CHANGES, and it is last, so it can only push the rail's own
  // bottom padding down. Entering it must not disturb anything above it — the earlier version closed
  // the open strip on the way in, which moved the target itself out from under the pointer and made
  // the release fire no `drop` event at all.
  it("does not disturb anything above it on the way in", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nx" });

    ctx.onDragOver(dragEvent("dragover", bar.nfoot0000, dt, { clientY: 30 }));

    const over = dragEvent("dragover", bar.tail, dt, { clientY: 65 });
    ctx.onDragOver(over);

    expect(over.defaultPrevented).toBe(true);
    expect(bar.tail.dataset.drop).toBe("inside");

    // The map is still whole and no row is still claiming to be the target — and neither of those
    // is a box being shown or hidden, so the tail has not moved.
    expect(offers(bar.nmain0000)).toBe(true);
    expect(offers(bar.nfoot0000)).toBe(true);
    expect(bar.nfoot0000.dataset.drop).toBeUndefined();
  });

  it("takes a drop as a new last root", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [TEMPLATE_MIME]: "<figure></figure>" });

    ctx.onDragOver(dragEvent("dragover", bar.tail, dt, { clientY: 85 }));
    expect(bar.tail.dataset.drop).toBe("inside");

    ctx.onDrop(dragEvent("drop", bar.tail, dt, { clientY: 85 }));

    const [, payload] = ctx.pushed.at(-1);
    expect(payload.parent_id).toBe("root");
    expect(payload.index).toBe(9999);
    expect(payload.template).toBe("<figure></figure>");
  });
});

describe("when the gesture ends", () => {
  // `dragend` fires on the SOURCE. For a palette card that is elsewhere in this document and for a
  // canvas node it is inside the iframe, so a rail-bound listener saw neither and the strips stood
  // open until the next drag.
  it("a dragend anywhere in the document puts the rail back", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, transfer({ [NODE_MIME]: "nx" })));
    expect(shown(bar.tail)).toBe(true);
    expect(offers(bar.nfoot0000)).toBe(true);

    window.dispatchEvent(new Event("dragend"));

    expect(shown(bar.tail)).toBe(false);
    expect(offers(bar.nfoot0000)).toBe(false);
  });

  it("so does the frame's own dragend, relayed as pb:dragend", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, transfer({ [NODE_MIME]: "nx" })));
    window.__pbDragNode = "nx";

    window.dispatchEvent(new Event("pb:dragend"));

    expect(shown(bar.tail)).toBe(false);
    expect(window.__pbDragNode).toBe(null);
  });

  it("and a drop clears everything it opened", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nx" });

    ctx.onDragOver(dragEvent("dragover", bar.nmain0000, dt, { clientY: 10 }));
    ctx.onDrop(dragEvent("drop", bar.nmain0000, dt, { clientY: 10 }));

    expect(bar.nmain0000.dataset.drop).toBeUndefined();
    expect(offers(bar.nfoot0000)).toBe(false);
    expect(shown(bar.tail)).toBe(false);
    expect(window.__pbDropHints).toBe(null);
  });
});

// A ROW OPENS WHEN YOU REST ON IT.
//
// `default_expanded/1` opens the roots and one level below them, so a tree of any depth is mostly
// shut — a `<span>` four levels inside a `<p>` inside a `<div>` has no row to aim at at all, and the
// only way to reach it was to let go of what you were holding, click down to it, and pick it up
// again. A shut branch is not in this document, so opening it is the server's business and this is
// the one hover in the editor that is allowed a round trip; the dwell is what earns it.
describe("a shut branch, met by a drag", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  const hover = (ctx, row, y) =>
    ctx.onDragOver(dragEvent("dragover", row, transfer({ [NODE_MIME]: "nx" }), { clientY: y }));

  it("opens after the pointer has rested on it", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    hover(ctx, bar.nfoot0000, 30);
    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);

    vi.advanceTimersByTime(700);

    expect(ctx.pushed.at(-1)).toEqual(["toggle_expand", { id: "nfoot0000" }]);
  });

  // Crossing a row on the way somewhere else must open nothing, or a drag down a long rail leaves a
  // trail of branches the author never asked for.
  it("does not open one the pointer only crossed", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    hover(ctx, bar.nfoot0000, 30);
    vi.advanceTimersByTime(300);
    hover(ctx, bar.nmain0000, 10);
    vi.advanceTimersByTime(700);

    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);
  });

  it("leaves an open branch alone, since the ask would TOGGLE it shut", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    hover(ctx, bar.nmain0000, 10);
    vi.advanceTimersByTime(700);

    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);
  });

  // And asks again only when the row is still shut: a patch may have opened it in the meantime.
  it("checks again when the dwell is up, not when it started", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    hover(ctx, bar.nfoot0000, 30);
    bar.nfoot0000.dataset.open = "true";
    vi.advanceTimersByTime(700);

    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);
  });

  // `data-can` is written by the hook and is in nothing the server renders, so the very patch that
  // opens the branch takes the map off every row it touches. Trusting our own "already painted" flag
  // left the map gone for the rest of the gesture — and a patch that is NOT a spring (an autosave, a
  // collaborator) does the same thing with nothing at all to notice it.
  it("draws the map again when a patch has wiped it", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const dt = transfer({ [NODE_MIME]: "nx" });

    hover(ctx, bar.nmain0000, 10);
    expect(offers(bar.nfoot0000)).toBe(true);

    // What a LiveView patch does to an attribute the server does not render.
    bar.el.querySelectorAll("[data-can]").forEach((el) => el.removeAttribute("data-can"));

    hover(ctx, bar.nmain0000, 10);

    expect(offers(bar.nfoot0000)).toBe(true);
  });

  it("never opens the row being dragged", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    window.__pbDragNode = "nfoot0000";

    hover(ctx, bar.nfoot0000, 30);
    vi.advanceTimersByTime(700);

    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);
  });

  // The rows that arrive with the branch were rendered after the map was swept, so they carry none
  // of it. Without this the newly reachable rows are the only ones that say nothing.
  // Not on the next pointer move — the patch that opens the branch strips the map, and blinking it
  // off is exactly the moment the author is reading it to decide where to go next.
  it("draws the map over the rows the branch brought with it", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    const frames = [];
    const raf = vi.spyOn(window, "requestAnimationFrame").mockImplementation((fn) => frames.push(fn));

    hover(ctx, bar.nfoot0000, 30);
    vi.advanceTimersByTime(700);

    // What the patch does: the branch arrives, and every row it touched loses the map.
    const arrived = document.createElement("div");
    arrived.dataset.layerRow = "nkid00000";
    arrived.dataset.parentId = "nfoot0000";
    arrived.dataset.index = "0";
    arrived.dataset.container = "true";
    arrived.getBoundingClientRect = () => ({ top: 60, bottom: 80, height: 20, left: 0, right: 200, width: 200 });
    bar.el.appendChild(arrived);
    bar.el.querySelectorAll("[data-can]").forEach((el) => el.removeAttribute("data-can"));

    ctx.replies.forEach((reply) => reply());
    frames.forEach((frame) => frame());
    raf.mockRestore();

    // Back without the pointer having moved at all.
    expect(arrived.dataset.can).toBe("true");
    expect(offers(bar.nmain0000)).toBe(true);
  });

  it("forgets a pending open when the gesture ends", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);

    hover(ctx, bar.nfoot0000, 30);
    window.dispatchEvent(new Event("dragend"));
    vi.advanceTimersByTime(700);

    expect(ctx.pushed.filter(([name]) => name === "toggle_expand")).toHaveLength(0);
  });
});

// AND THE RAIL SCROLLS AT ITS EDGES, which it never did — so a target below the fold could not be
// reached at all, and a branch that has just sprung open is very often below the fold because it
// just pushed itself there.
describe("a drag near the rail's edge", () => {
  it("scrolls the rail towards what is off screen", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    let frame = null;
    const raf = vi.spyOn(window, "requestAnimationFrame").mockImplementation((fn) => (frame = fn) && 1);

    Object.defineProperty(bar.el, "scrollTop", { value: 0, writable: true, configurable: true });
    ctx.onDragOver(dragEvent("dragover", bar.ntext0000, transfer({ [NODE_MIME]: "nx" }), { clientY: 98 }));
    frame();

    expect(bar.el.scrollTop).toBeGreaterThan(0);
    raf.mockRestore();
  });

  it("and stands still in the middle of it", () => {
    const bar = rail();
    const ctx = mount(hooks.PbLayers, bar.el);
    const raf = vi.spyOn(window, "requestAnimationFrame");

    Object.defineProperty(bar.el, "scrollTop", { value: 0, writable: true, configurable: true });
    ctx.onDragOver(dragEvent("dragover", bar.nfoot0000, transfer({ [NODE_MIME]: "nx" }), { clientY: 50 }));

    expect(raf).not.toHaveBeenCalled();
    expect(bar.el.scrollTop).toBe(0);
    raf.mockRestore();
  });
});
