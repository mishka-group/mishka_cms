import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// A DRAG THAT CROSSES SURFACES.
//
// The builder has three of them — the palette, the layers rail, and the canvas in its own iframe —
// and only the surface a drag STARTED on holds the hook state that says what is moving. A row picked
// up in the rail could be reordered in the rail and nowhere else: the canvas answered `dropEffect =
// "copy"` to a source that allowed only `"move"`, which HTML resolves to `none`, so Chrome fired
// `dragleave` and never a `drop` at all; and had the drop fired, `onDrop` had nothing to name the
// node with and returned without pushing anything.
//
// `application/x-pb-node` is what carries it. A dataTransfer's VALUES are sealed until `drop`, but
// its type list is legible the whole way through — which is exactly the split between the two
// questions: "is this a node drag" (answered on every `dragover`) and "which node" (answered once).
//
// The canvas hook binds on the DOCUMENT, so every mount here is torn down or the next test inherits
// its listeners.
function context(el) {
  const pushed = [];

  return {
    el,
    pushed,
    handlers: {},
    pushEvent: (name, payload) => pushed.push([name, payload]),
    handleEvent: (name, fn) => (context.handlers = fn),
  };
}

// The pieces of a DataTransfer these handlers touch. jsdom has no drag support of its own, and a
// real one cannot be built without a real drag.
function transfer(entries = {}) {
  const data = { ...entries };

  // `types` is LIVE on a real DataTransfer — it has to be, since `setData` during `dragstart` is the
  // only way anything gets on there and every later handler reads the list back.
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
  return {
    type,
    target,
    dataTransfer,
    preventDefault: () => {},
    stopPropagation: () => {},
    relatedTarget: null,
    ...point,
  };
}

let mounted = [];

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
});

afterEach(() => {
  for (const ctx of mounted) ctx.hook.destroyed?.call(ctx);
  mounted = [];
});

// A canvas with one node in it, and the geometry `resolveDrop` reads. jsdom gives every element a
// zero-sized box, so the boxes are stubbed on the elements themselves.
function canvas() {
  const el = document.createElement("div");
  el.id = "pb-canvas-root";
  document.body.appendChild(el);

  const node = document.createElement("div");
  node.dataset.nodeId = "nkeepthis";
  node.dataset.kind = "tag";
  el.appendChild(node);

  const box = (top, height) => () => ({
    left: 0,
    right: 300,
    top,
    bottom: top + height,
    width: 300,
    height,
  });

  el.getBoundingClientRect = box(0, 200);
  node.getBoundingClientRect = box(0, 100);

  return { el, node };
}

function rail() {
  const el = document.createElement("div");
  document.body.appendChild(el);

  const row = document.createElement("div");
  row.dataset.layerRow = "nmoveme00";
  row.dataset.parentId = "root";
  row.dataset.index = "0";
  row.dataset.container = "true";
  row.dataset.kind = "tag";
  row.getBoundingClientRect = () => ({ top: 0, bottom: 20, height: 20, left: 0, right: 200, width: 200 });
  el.appendChild(row);

  return { el, row };
}

describe("a row dragged out of the layers rail", () => {
  it("puts its node id on the dataTransfer, where another surface can read it", () => {
    const { el, row } = rail();
    const ctx = mount(hooks.PbLayers, el);
    const dt = transfer();

    ctx.onDragStart(dragEvent("dragstart", row, dt));

    expect(dt.effectAllowed).toBe("move");
    expect(dt.types).toContain("application/x-pb-node");
    expect(dt.getData("application/x-pb-node")).toBe("nmoveme00");
  });

  // BLOCKER ONE. The effect has to match what the source allowed or the browser cancels the gesture
  // outright — no `drop` event is ever fired, so nothing below this can be reached.
  it("is answered 'move' by the canvas, not 'copy'", () => {
    const { el, node } = canvas();
    const ctx = mount(hooks.PbCanvas, el);
    const dt = transfer({ "application/x-pb-node": "nmoveme00", "text/plain": "nmoveme00" });

    const event = dragEvent("dragover", node, dt, { clientX: 150, clientY: 90 });
    ctx.onDragOver(event);

    expect(dt.dropEffect).toBe("move");
  });

  // A palette card allows "copy" and carries a template. Answering IT "move" is the same refusal in
  // mirror image, and is what the ternary this replaces was there to avoid.
  it("does not disturb a palette card, which is a copy", () => {
    const { el, node } = canvas();
    const ctx = mount(hooks.PbCanvas, el);
    const dt = transfer({ "application/x-pb-template": "<p>hi</p>" });

    ctx.onDragOver(dragEvent("dragover", node, dt, { clientX: 150, clientY: 90 }));

    expect(dt.dropEffect).toBe("copy");
  });

  // BLOCKER TWO. `this.dragging` belongs to the canvas's own hook and is null for a drag that began
  // in the rail, so the drop used to fall through to `return` and push nothing at all.
  it("lands on the canvas as a move of that node", () => {
    const { el, node } = canvas();
    const ctx = mount(hooks.PbCanvas, el);
    const dt = transfer({ "application/x-pb-node": "nmoveme00", "text/plain": "nmoveme00" });

    ctx.onDrop(dragEvent("drop", node, dt, { clientX: 150, clientY: 90 }));

    const [name, payload] = ctx.pushed.at(-1);
    expect(name).toBe("drop");
    expect(payload.node_id).toBe("nmoveme00");
    // What it was beside, so the server can count in the tree rather than trusting the screen.
    expect(payload.anchor_id).toBe("nkeepthis");
    expect(payload.anchor_before).toBe(false);
  });
});

// PREVIEW TAKES NO DROP. The canvas answers no edit there, so a drag carried over it must be
// refused where the author can see it — no landing line — rather than drawn a place to land and
// then silently dropped. Refused by cancelling with "none", not by ignoring: an uncancelled drag of
// a file or a link from outside is the browser's to open, and that navigates away from the document.
describe("a drag over the canvas in preview", () => {
  // What a real browser hands `dragenter`/`dragover`: an effect already derived from what the
  // source allowed.
  const carried = (entries) => {
    const dt = transfer(entries);
    dt.effectAllowed = "copy";
    dt.dropEffect = "copy";
    return dt;
  };

  it.each([
    ["a palette card", { "application/x-pb-template": "<p>hi</p>" }],
    ["a file from outside the page", { Files: "" }],
    ["a link from outside the page", { "text/uri-list": "https://example.com/" }],
  ])("of %s is taken and refused, with no landing line", (_what, entries) => {
    const { el, node } = canvas();
    el.dataset.preview = "true";
    const ctx = mount(hooks.PbCanvas, el);
    const dt = carried(entries);
    const cancelled = [];

    const event = (type) => ({
      ...dragEvent(type, node, dt, { clientX: 150, clientY: 90 }),
      preventDefault: () => cancelled.push(type),
    });

    ctx.onDragEnter(event("dragenter"));
    ctx.onDragOver(event("dragover"));

    expect(cancelled).toEqual(["dragenter", "dragover"]);
    expect(dt.dropEffect).toBe("none");
    expect(ctx.indicator.style.display).toBe("none");
  });
});

describe("a node dragged off the canvas onto the rail", () => {
  it("is accepted there too, by the same marker", () => {
    const { el, row } = rail();
    const ctx = mount(hooks.PbLayers, el);
    const dt = transfer({ "application/x-pb-node": "ncanvas01", "text/plain": "ncanvas01" });

    ctx.onDrop(dragEvent("drop", row, dt, { clientX: 10, clientY: 2 }));

    const [name, payload] = ctx.pushed.at(-1);
    expect(name).toBe("drop");
    expect(payload.node_id).toBe("ncanvas01");
  });

  it("is still refused when the drag is carrying nothing this editor owns", () => {
    const { el, row } = rail();
    const ctx = mount(hooks.PbLayers, el);

    ctx.onDrop(dragEvent("drop", row, transfer({ "text/plain": "hello" }), { clientY: 2 }));

    expect(ctx.pushed).toHaveLength(0);
  });
});

// ONE HANDLE, TWO BEHAVIOURS. The element toolbar's grip is the control that says "move this", and
// it put only `text/plain` on the dataTransfer — so inside the canvas it worked (the hook has its
// own `this.dragging` to answer with) and everywhere else it was invisible. The rail saw a drag
// carrying nothing it owned, never cancelled a `dragover`, and the browser fired no `drop` at all.
describe("a move started from the canvas toolbar's grip", () => {
  it("carries the same marker the node itself does", () => {
    const { el } = canvas();
    const ctx = mount(hooks.PbCanvas, el);
    ctx.selectedId = "ngripped0";

    const grip = document.createElement("span");
    grip.id = "pb-el-grip";
    document.body.appendChild(grip);

    const dt = transfer();
    ctx.onGripDrag(dragEvent("dragstart", grip, dt));

    expect([...dt.types]).toContain("application/x-pb-node");
    expect(dt.getData("application/x-pb-node")).toBe("ngripped0");
    expect(dt.effectAllowed).toBe("move");
  });

  it("and is therefore accepted by the rail, which reads that marker", () => {
    const { el, row } = rail();
    const ctx = mount(hooks.PbLayers, el);
    const dt = transfer({ "application/x-pb-node": "ngripped0", "text/plain": "ngripped0" });

    ctx.onDrop(dragEvent("drop", row, dt, { clientX: 10, clientY: 2 }));

    const [name, payload] = ctx.pushed.at(-1);
    expect(name).toBe("drop");
    expect(payload.node_id).toBe("ngripped0");
  });
});

describe("dropping INSIDE a row of the layers rail", () => {
  // The canvas has always appended, and `Tree`'s own `clamp/2` reads any index past the end that
  // way. The rail sent 0, so a field dropped onto a form wrapper went in front of the fields that
  // were already there — the same "it always comes before" the anchor fixes on the canvas.
  it("appends, as the canvas does, rather than putting the node first", () => {
    const { el, row } = rail();
    const ctx = mount(hooks.PbLayers, el);
    const dt = transfer({ "application/x-pb-node": "ncanvas01" });

    // The middle band of a row is "inside"; 10 of 20px is dead centre.
    ctx.onDrop(dragEvent("drop", row, dt, { clientX: 10, clientY: 10 }));

    const [, payload] = ctx.pushed.at(-1);
    expect(payload.parent_id).toBe("nmoveme00");
    expect(payload.index).toBeGreaterThan(0);
  });
});

// A GESTURE THAT ENDS ON ANOTHER SURFACE still ended. `dragend` fires on the SOURCE, so a card
// released back over the palette is reported to the chrome and never to the frame it crossed —
// which is why the chrome broadcasts the end into every frame. The frame then has to put back
// everything it changed for the length of the drag, the boxes it measured included: those were
// measured against a layout with every empty container opened, and a patch between two gestures
// moves whatever survives it.
describe("a drag that ends off the canvas", () => {
  it("leaves the canvas nothing it measured during it", () => {
    const { el, node } = canvas();
    const ctx = mount(hooks.PbCanvas, el);
    const dt = transfer({ "application/x-pb-node": "nmoveme00", "text/plain": "nmoveme00" });

    ctx.onDragOver(dragEvent("dragover", node, dt, { clientX: 150, clientY: 90 }));

    window.dispatchEvent(new Event("pb:dragend"));

    // Patched between the gestures: the node is now a hundred pixels further down the page.
    node.getBoundingClientRect = () => ({
      left: 0,
      right: 300,
      top: 100,
      bottom: 200,
      width: 300,
      height: 100,
    });

    ctx.onDrop(dragEvent("drop", node, dt, { clientX: 150, clientY: 110 }));

    const [, payload] = ctx.pushed.at(-1);
    expect(payload.anchor_before, "the drop landed by where the node used to be").toBe(true);
  });
});
