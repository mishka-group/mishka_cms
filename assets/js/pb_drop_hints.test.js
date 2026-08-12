import { afterEach, beforeEach, describe, expect, it } from "vitest";
import hooks from "./admin_hooks";

// THE SERVER'S VERDICT HAS TO ARRIVE SOMEWHERE.
//
// `EditorSession.drop_hints/2` computes, once per drag, which parents will take the node being
// dragged, and both `BuilderLive` and `CanvasLive` push it as `pb:drop-hints`. The client reads it
// out of `window.__pbDropHints` — in the canvas to decide where the blue line may point, and in the
// layers rail to decide which rows may be dropped INTO.
//
// Nothing listened for it. Every assignment in the bundle set it to `null`, so the drag ran on the
// optimistic fallback for its whole life: the line offered parents the server was about to refuse,
// the drop was then relocated somewhere else, and the rail offered "inside" for a `<span>` a
// `<section>` cannot enter. Two comments in the hooks referred to a listener "above" and "below"
// that did not exist.
//
// The two hooks are not interchangeable. A drag that starts INSIDE the canvas is answered by
// `CanvasLive`, whose push lands in the frame; a palette card or a layers row starts in the PARENT
// document and is answered by `BuilderLive`, whose push lands there — and has to be handed on to
// every frame, because the frame is where the pointer will arrive.
function context(el) {
  const handlers = {};

  return {
    el,
    handlers,
    pushEvent: () => {},
    handleEvent: (name, fn) => (handlers[name] = fn),
  };
}

// TORN DOWN, OR THE NEXT TEST INHERITS THE LISTENERS. `PbShortcuts` binds on `window`, so a mount
// left standing answers every later message as well — which is how "the frame said the drag ended"
// counted five hand-offs for one message.
let mounted = [];

function mount(hook, el) {
  const ctx = context(el);
  ctx.hook = hook;
  hook.mounted.call(ctx);
  mounted.push(ctx);
  return ctx;
}

afterEach(() => {
  window.dispatchEvent(new Event("dragend"));
  for (const ctx of mounted) ctx.hook.destroyed?.call(ctx);
  mounted = [];
});

const transfer = () => ({ effectAllowed: "", setData: () => {} });

// A drag the chrome asked `drag_start` about: a palette card picked up in this document.
function paletteDrag() {
  const card = document.createElement("div");
  card.dataset.template = '<input name="phone" />';
  document.body.appendChild(card);
  mount(hooks.PbPaletteItem, card).onDragStart({ dataTransfer: transfer() });
}

// The same, from a row of the layers rail.
function layersDrag() {
  const rail = document.createElement("div");
  const row = document.createElement("div");
  row.dataset.layerRow = "nfield000";
  rail.appendChild(row);
  document.body.appendChild(rail);
  mount(hooks.PbLayers, rail).onDragStart({ target: row, dataTransfer: transfer() });
}

// A drag that began inside the frame, as the canvas's `dragstart` leaves it.
const canvasDrag = (ctx) => (ctx.dragging = "nfield000");

describe("pb:drop-hints", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    window.__pbDropHints = null;
  });

  it("reaches the canvas, which is where the line is drawn", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);

    const ctx = mount(hooks.PbCanvas, el);

    expect(ctx.handlers["pb:drop-hints"]).toBeTypeOf("function");

    canvasDrag(ctx);
    ctx.handlers["pb:drop-hints"]({ accepts: { nabc: true, ndef: false } });

    expect(window.__pbDropHints).toEqual({ nabc: true, ndef: false });
  });

  it("reaches the chrome, which is where the layers rail reads it", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);

    const ctx = mount(hooks.PbShortcuts, el);

    expect(ctx.handlers["pb:drop-hints"]).toBeTypeOf("function");

    paletteDrag();
    ctx.handlers["pb:drop-hints"]({ accepts: { nabc: true } });

    expect(window.__pbDropHints).toEqual({ nabc: true });
  });

  // A PALETTE CARD'S DRAG BEGINS IN THE PARENT DOCUMENT, so the frame never sees its `dragstart` and
  // never asks for anything. The chrome's answer is the only one it will get.
  it("and is handed on to every canvas frame", () => {
    const el = document.createElement("div");
    const frame = document.createElement("iframe");
    frame.setAttribute("src", "/admin/dashboard/runtime/builder-canvas/tok");
    el.appendChild(frame);
    document.body.appendChild(el);

    const ctx = mount(hooks.PbShortcuts, el);
    paletteDrag();
    ctx.handlers["pb:drop-hints"]({ accepts: { nabc: false } });

    expect(frame.contentWindow.__pbDropHints).toEqual({ nabc: false });
  });

  it("and an empty verdict is still a verdict, not an absence", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);

    const ctx = mount(hooks.PbCanvas, el);
    canvasDrag(ctx);
    ctx.handlers["pb:drop-hints"]({ accepts: {} });

    expect(window.__pbDropHints).toEqual({});
  });
});

// THE RETURN LEG. A drag that starts INSIDE the canvas is answered by `CanvasLive`, whose push lands
// in the frame — and the layers rail, which the pointer is about to cross into, lives in the parent
// document and would never see it. So every canvas-to-rail drag ran on the optimistic fallback: the
// rail offered "inside" for a `<p>` a `<section>` cannot enter, and offered the dragged node's own
// row as a place to drop it, because out here nothing even knew which node was in flight.
describe("what the frame reports upwards", () => {
  const post = (data) => window.dispatchEvent(new MessageEvent("message", { data, source: {} }));

  beforeEach(() => {
    document.body.innerHTML = "";
    window.__pbDropHints = null;
    window.__pbDragNode = null;
  });

  it("which node is in flight, so the rail stops offering it to itself", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    mount(hooks.PbShortcuts, el);

    post({ pb: true, kind: "drag", node_id: "ncanvas01" });

    expect(window.__pbDragNode).toBe("ncanvas01");
    expect(window.__pbDropHints).toBe(null);
  });

  it("the server's verdict, spread to this document and to every other frame", () => {
    const el = document.createElement("div");
    const frame = document.createElement("iframe");
    frame.setAttribute("src", "/admin/dashboard/runtime/builder-canvas/tok");
    el.appendChild(frame);
    document.body.appendChild(el);
    mount(hooks.PbShortcuts, el);

    post({ pb: true, kind: "hints", accepts: { nabc: true, ndef: false } });

    expect(window.__pbDropHints).toEqual({ nabc: true, ndef: false });
    expect(frame.contentWindow.__pbDropHints).toEqual({ nabc: true, ndef: false });
  });

  it("and that it is over, since the dragend itself fires inside the frame", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    mount(hooks.PbShortcuts, el);

    window.__pbDragNode = "ncanvas01";
    window.__pbDropHints = { nabc: true };

    let ended = 0;
    const count = () => (ended += 1);
    window.addEventListener("pb:dragend", count);

    post({ pb: true, kind: "dragend" });
    window.removeEventListener("pb:dragend", count);

    expect(window.__pbDragNode).toBe(null);
    expect(window.__pbDropHints).toBe(null);
    expect(ended).toBe(1);
  });

  it("but nothing at all from a message this editor did not send", () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    mount(hooks.PbShortcuts, el);

    post({ kind: "drag", node_id: "from-somewhere-else" });

    expect(window.__pbDragNode).toBe(null);
  });
});

// A FIELD BEING DRAGGED SAYS WHICH FORM IT JOINS. The server marks every form on the canvas with
// `data-pb-form` (its people name) and the node a drop at a form's end lands in front of with
// `data-pb-send`; `pb:drop-hints` says whether the drag is a field. The caption then adds
// "joins Contact form" or "starts a new form", the line is drawn where the field will land, and the
// forms are outlined for as long as the field is in flight.

function fieldCanvasReset() {
  document.body.innerHTML = "";
  document.documentElement.removeAttribute("data-pb-field-drag");
  window.__pbDropHints = null;
  window.__pbFieldDrag = false;
  if (!window.CSS) window.CSS = {};
  if (!window.CSS.escape) window.CSS.escape = (value) => String(value);
}

const box = (left, top, width, height) => () => ({
  left,
  top,
  width,
  height,
  right: left + width,
  bottom: top + height,
});

// A Contact form (card > grid > column, Send in a flex footer) and a loose box under it.
function canvas() {
  const root = document.createElement("div");
  root.id = "pb-canvas-root";
  root.innerHTML =
    `<div data-node-id="nform0000" data-kind="component" data-pb-form="Contact">` +
    `<div data-node-id="ncard0000"><div data-node-id="ngrid0000">` +
    `<div data-node-id="ncol00000"><input data-node-id="nfield000" /></div></div>` +
    `<div data-node-id="nfoot0000" style="display:flex">` +
    `<button data-node-id="nsend0000" data-pb-send="true">Send</button></div></div></div>` +
    `<div data-node-id="nloose000"></div>`;
  document.body.appendChild(root);

  const at = (id, rect) => (root.querySelector(`[data-node-id="${id}"]`).getBoundingClientRect = rect);

  root.getBoundingClientRect = box(0, 0, 400, 500);
  at("nform0000", box(0, 0, 400, 300));
  at("ncard0000", box(0, 0, 400, 300));
  at("ngrid0000", box(0, 0, 400, 200));
  at("ncol00000", box(0, 0, 400, 200));
  at("nfield000", box(0, 0, 400, 40));
  at("nfoot0000", box(0, 200, 400, 100));
  at("nsend0000", box(250, 220, 100, 40));
  at("nloose000", box(0, 300, 400, 200));

  const node = (id) => root.querySelector(`[data-node-id="${id}"]`);
  return { root, node };
}

const accepts = {
  nform0000: true,
  ncard0000: true,
  ngrid0000: true,
  ncol00000: true,
  nfoot0000: true,
  nloose000: true,
  nfield000: false,
  nsend0000: false,
};

function over(ctx, target, point) {
  const dt = {
    types: ["application/x-pb-template"],
    dropEffect: "none",
    getData: () => "",
  };

  ctx.onDragOver({
    type: "dragover",
    target,
    dataTransfer: dt,
    preventDefault: () => {},
    clientX: point.x,
    clientY: point.y,
  });
}

const parts = (ctx) => [...ctx.indicator.firstChild.children];

describe("a field dragged over the canvas", () => {
  beforeEach(fieldCanvasReset);

  it("outlines the forms while the field is in flight, and not after", () => {
    const { root } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    canvasDrag(ctx);

    ctx.handlers["pb:drop-hints"]({ accepts, field: true });
    expect(document.documentElement.getAttribute("data-pb-field-drag")).toBe("true");

    window.dispatchEvent(new Event("pb:dragend"));
    expect(document.documentElement.hasAttribute("data-pb-field-drag")).toBe(false);

    ctx.handlers["pb:drop-hints"]({ accepts, field: false });
    expect(document.documentElement.hasAttribute("data-pb-field-drag")).toBe(false);
  });

  it("says it joins the form, and draws the line in front of its Send", () => {
    const { root, node } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    canvasDrag(ctx);

    ctx.handlers["pb:drop-hints"]({ accepts, field: true });
    over(ctx, node("nform0000"), { x: 200, y: 150 });

    const [base, form] = parts(ctx);

    expect(base.textContent).toBe("inside <div>");
    expect(form.textContent).toBe("· joins Contact form");
    expect(form.style.background).toBe("rgb(124, 58, 237)");
    expect(ctx.indicator.style.transform).toBe("translate3d(250px, 220px, 0)");
    expect(ctx.indicator.style.width).toBe("2px");
  });

  it("says it starts a new form in the line's blue anywhere else", () => {
    const { root, node } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    canvasDrag(ctx);

    ctx.handlers["pb:drop-hints"]({ accepts, field: true });
    over(ctx, node("nloose000"), { x: 200, y: 480 });

    const [base, form] = parts(ctx);

    expect(base.style.display).toBe("none");
    expect(form.textContent).toBe("starts a new form");
    expect(form.style.background).toBe("rgb(58, 108, 244)");
    expect(ctx.indicator.firstChild.style.display).toBe("flex");
  });

  it("keeps amber and today's words for a redirected drop, and adds the form after them", () => {
    const { root, node } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    canvasDrag(ctx);

    ctx.handlers["pb:drop-hints"]({ accepts: { ...accepts, ncol00000: false }, field: true });
    over(ctx, node("nfield000"), { x: 200, y: 35 });

    const [base, form] = parts(ctx);

    expect(base.textContent).toBe("after <div>");
    expect(base.style.background).toBe("rgb(217, 119, 6)");
    expect(form.textContent).toBe("· joins Contact form");
  });

  it("says nothing about forms for anything that is not a field", () => {
    const { root, node } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    canvasDrag(ctx);

    ctx.handlers["pb:drop-hints"]({ accepts, field: false });
    over(ctx, node("nloose000"), { x: 200, y: 480 });

    expect(ctx.indicator.firstChild.style.display).toBe("none");
  });
});

describe("the chrome's copy of the verdict for a field", () => {
  beforeEach(fieldCanvasReset);

  it("flags every canvas frame while a field is dragged, and the drag's end clears it", () => {
    const el = document.createElement("div");
    const frame = document.createElement("iframe");
    frame.setAttribute("src", "/admin/dashboard/runtime/builder-canvas/tok");
    el.appendChild(frame);
    document.body.appendChild(el);

    // jsdom loads nothing into the frame, so its document is given the root a canvas has.
    const doc = frame.contentDocument;
    if (!doc.documentElement) doc.appendChild(doc.createElement("html"));

    const ctx = mount(hooks.PbShortcuts, el);
    paletteDrag();
    ctx.handlers["pb:drop-hints"]({ accepts: { nabc: true }, field: true });

    const root = doc.documentElement;
    expect(root.getAttribute("data-pb-field-drag")).toBe("true");
    expect(frame.contentWindow.__pbFieldDrag).toBe(true);

    window.dispatchEvent(new MessageEvent("message", { data: { pb: true, kind: "dragend" }, source: {} }));

    expect(root.hasAttribute("data-pb-field-drag")).toBe(false);
  });
});

// A REPLY THAT LANDS AFTER ITS DRAG ENDED. `drag_start` is answered one round trip later, and a
// drag cancelled with Escape, or a click that barely moved, is over before that. Marked then, every
// form stayed outlined with nothing being dragged, until the next drag cleared it.
describe("a drop-hints reply that lands after its drag ended", () => {
  beforeEach(fieldCanvasReset);

  it("is dropped by the canvas the drag began in", () => {
    const { root, node } = canvas();
    const ctx = mount(hooks.PbCanvas, root);
    const start = { target: node("nfield000"), dataTransfer: transfer(), preventDefault: () => {} };

    ctx.onDragStart(start);
    ctx.handlers["pb:drop-hints"]({ accepts, field: true });
    expect(document.documentElement.getAttribute("data-pb-field-drag")).toBe("true");

    ctx.onDragEnd();
    ctx.handlers["pb:drop-hints"]({ accepts, field: true });

    expect(document.documentElement.hasAttribute("data-pb-field-drag")).toBe(false);
    expect(window.__pbDropHints).toBe(null);
  });

  it("is dropped by the chrome, in every frame, for a palette card and for a layers row", () => {
    for (const start of [paletteDrag, layersDrag]) {
      fieldCanvasReset();
      const el = document.createElement("div");
      const frame = document.createElement("iframe");
      frame.setAttribute("src", "/admin/dashboard/runtime/builder-canvas/tok");
      el.appendChild(frame);
      document.body.appendChild(el);

      const doc = frame.contentDocument;
      if (!doc.documentElement) doc.appendChild(doc.createElement("html"));

      const ctx = mount(hooks.PbShortcuts, el);

      start();
      ctx.handlers["pb:drop-hints"]({ accepts: { nabc: true }, field: true });
      expect(doc.documentElement.getAttribute("data-pb-field-drag")).toBe("true");

      window.dispatchEvent(new Event("dragend"));
      ctx.handlers["pb:drop-hints"]({ accepts: { nabc: true }, field: true });

      expect(doc.documentElement.hasAttribute("data-pb-field-drag")).toBe(false);
      expect(frame.contentWindow.__pbDropHints).toBe(null);
      expect(window.__pbDropHints).toBe(null);

      for (const each of mounted) each.hook.destroyed?.call(each);
      mounted = [];
    }
  });
});
