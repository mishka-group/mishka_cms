import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { NodeSelection } from "@tiptap/pm/state";

import { mount } from "./content_editor.js";
import { blockAt, moveBlock } from "../vendor/editor_extensions.js";

// THE BLOCK HANDLE: the grip beside the top-level block under the pointer, which drags that block to
// another place through ProseMirror's own drag and drop, and Alt+↑/↓ for the same from the
// keyboard. jsdom lays nothing out, so each block is given a box here: 30px tall, one under another,
// 36px in from the surface's edge, the way the surface's gutter leaves them.

const MARKER = "[[component callout /]]";
const ROW = 30;

// Everything the editor schedules — Tiptap's create, the engine's debounce, the frame a focus
// scrolls on, ProseMirror's focus timer — runs on a fake clock that moves only when `settle` moves
// it, so no run depends on how long the machine takes between two of them.
const CLOCK = [
  "setTimeout",
  "clearTimeout",
  "setInterval",
  "clearInterval",
  "requestAnimationFrame",
  "cancelAnimationFrame",
];

function settle(ms = 20) {
  return vi.advanceTimersByTimeAsync(ms);
}

function rect(top, height, left = 36, width = 500) {
  return { top, bottom: top + height, left, right: left + width, width, height, x: left, y: top };
}

function fixture(stored) {
  document.body.innerHTML = `
    <div id="ed" data-part="root">
      <textarea id="ed-value" data-part="value" name="form[content]" hidden></textarea>
      <div id="ed-surface" data-part="surface" data-root-id="ed" data-value-id="ed-value"
           data-format="html" data-debounce="5" data-components="#ed-components"></div>
      <div id="ed-components"></div>
    </div>`;

  const surface = document.getElementById("ed-surface");
  document.getElementById("ed-value").value = stored;
  surface.setAttribute("data-value", stored);

  return surface;
}

function hookFor(el, segments) {
  return {
    el,
    pushEventTo(_target, _event, _payload, reply) {
      if (reply) Promise.resolve().then(() => reply({ segments }));
    },
    handleEvent: (event) => event,
    removeHandleEvent: () => {},
  };
}

// Every top-level block's box, in document order, from the surface's top.
function layOut(editor, surface) {
  surface.getBoundingClientRect = () => rect(0, 600, 0, 600);

  editor.state.doc.forEach((_node, pos, index) => {
    const dom = editor.view.nodeDOM(pos);
    dom.getBoundingClientRect = () => rect(index * ROW, ROW);
  });
}

function blocks(editor) {
  const found = [];
  editor.state.doc.forEach((node) =>
    found.push(node.type.name === "mishkaComponent" ? node.attrs.marker : node.textContent),
  );
  return found;
}

function transfer() {
  const data = {};

  return {
    data,
    types: [],
    files: [],
    setData(type, value) {
      data[type] = value;
      this.types.push(type);
    },
    getData: (type) => data[type] || "",
    clearData() {
      for (const key of Object.keys(data)) delete data[key];
      this.types = [];
    },
    setDragImage: vi.fn(),
  };
}

function hover(surface, y) {
  surface.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: 10, clientY: y }));
}

let opened = [];

async function open(stored, segments = []) {
  const surface = fixture(stored);
  const handle = mount(hookFor(surface, segments));
  opened.push(handle);

  await settle();

  const editor = handle.engine.editor;
  layOut(editor, surface);

  return { surface, editor, grip: surface.querySelector("[data-role='content-drag-handle']") };
}

beforeAll(() => {
  Range.prototype.getClientRects = () => [];
  Range.prototype.getBoundingClientRect = () => rect(0, 0);
});

beforeEach(() => {
  vi.useFakeTimers({ toFake: CLOCK });
  opened = [];
});

afterEach(() => {
  for (const handle of opened) handle.destroyed();
  document.body.innerHTML = "";
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("the handle", () => {
  test("lives on the surface, beside the text, hidden until the pointer is over a block", async () => {
    const { surface, editor, grip } = await open("<p>One</p><p>Two</p>");

    expect(grip.parentElement).toBe(surface);
    expect(editor.view.dom.contains(grip)).toBe(false);
    expect(grip.draggable).toBe(true);
    expect(grip.style.display).toBe("none");

    hover(surface, ROW + 5);

    expect(grip.style.display).toBe("");
    expect(parseFloat(grip.style.left)).toBeLessThan(36);
    expect(parseFloat(grip.style.top)).toBe(ROW);
  });

  test("is placed in the surface's own coordinates, so it scrolls with the text", async () => {
    const { surface, grip } = await open("<p>One</p><p>Two</p>");

    Object.defineProperty(surface, "scrollTop", { value: 120, configurable: true });
    hover(surface, ROW + 5);

    expect(parseFloat(grip.style.top)).toBe(ROW + 120);
  });

  test("finds the block beside the pointer, a component block too", async () => {
    const { editor } = await open(`<p>One</p><p>${MARKER}</p><p>Three</p>`, [
      { type: "html", html: "<p>One</p>" },
      { type: "component", name: "callout", marker: MARKER },
      { type: "html", html: "<p>Three</p>" },
    ]);

    layOut(editor, editor.view.dom.parentElement);

    expect(blockAt(editor.view, ROW + 2).node.type.name).toBe("mishkaComponent");
    expect(blockAt(editor.view, 2).node.textContent).toBe("One");
    expect(blockAt(editor.view, 999).node.textContent).toBe("Three");
  });

  test("a press on it moves neither the cursor, the scroll nor the focus", async () => {
    const { surface, editor, grip } = await open("<p>One</p><p>Two</p>");
    const transactions = vi.fn();
    const writes = vi.fn();
    const before = editor.state.selection;

    editor.on("transaction", transactions);
    Element.prototype.scrollIntoView = vi.fn();
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    Object.defineProperty(surface, "scrollTop", { get: () => 0, set: writes, configurable: true });

    hover(surface, 5);
    grip.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, clientX: 10, clientY: 5 }));
    await settle(50);

    expect(transactions).not.toHaveBeenCalled();
    expect(editor.state.selection.eq(before)).toBe(true);
    expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled();
    expect(writes).not.toHaveBeenCalled();
    expect(focus).not.toHaveBeenCalled();

    delete Element.prototype.scrollIntoView;
  });

  // WHAT THREW THE PAGE DOWN. The engine answers a mousedown on the surface outside the text with
  // `focus("end")`, which on the next frame scrolls the end of the document into view — through the
  // surface and the modal. The handle sits on the surface, outside the text.
  test("while a press in the surface's padding still takes the cursor to the end, and scrolls there", async () => {
    const { surface, editor } = await open("<p>One</p><p>Two</p>");
    const scrolled = vi.fn();

    editor.on("transaction", ({ transaction }) => scrolled(transaction.scrolledIntoView));
    surface.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    await settle(50);

    expect(editor.state.selection.from).toBe(editor.state.doc.content.size - 1);
    expect(scrolled).toHaveBeenCalledWith(true);
  });
});

describe("dragging a block", () => {
  test("starts a move of the block beside the pointer, selected whole", async () => {
    const { surface, editor, grip } = await open("<p>One</p><p>Two</p><p>Three</p>");
    const data = transfer();

    hover(surface, ROW + 5);

    const event = new Event("dragstart", { bubbles: true });
    event.dataTransfer = data;
    grip.dispatchEvent(event);

    const { dragging } = editor.view;

    expect(dragging.move).toBe(true);
    expect(dragging.slice.content.childCount).toBe(1);
    expect(dragging.slice.content.firstChild.textContent).toBe("Two");
    expect(dragging.node).toBeInstanceOf(NodeSelection);
    expect(dragging.node.from).toBe(5);
    expect(editor.state.selection.from).toBe(5);
    expect(data.data["text/plain"]).toBe("Two");
    expect(data.data["text/html"]).toContain("Two");
    expect(data.effectAllowed).toBe("copyMove");
    expect(grip.dataset.dragging).toBe("true");
  });

  test("and the drop moves it, not a copy, as one step undo takes back", async () => {
    const { surface, editor, grip } = await open("<p>One</p><p>Two</p><p>Three</p>");
    const data = transfer();

    hover(surface, 5);

    const start = new Event("dragstart", { bubbles: true });
    start.dataTransfer = data;
    grip.dispatchEvent(start);

    const end = editor.state.doc.content.size;
    editor.view.posAtCoords = () => ({ pos: end, inside: -1 });

    const drop = new Event("drop", { bubbles: true, cancelable: true });
    drop.dataTransfer = data;
    drop.clientX = 40;
    drop.clientY = 3 * ROW - 2;
    editor.view.dom.dispatchEvent(drop);

    expect(blocks(editor)).toEqual(["Two", "Three", "One"]);
    expect(editor.view.dragging).toBeNull();

    editor.commands.undo();

    expect(blocks(editor)).toEqual(["One", "Two", "Three"]);
  });

  test("a component block moves the same way, its marker untouched", async () => {
    const { surface, editor, grip } = await open(`<p>One</p><p>${MARKER}</p><p>Three</p>`, [
      { type: "html", html: "<p>One</p>" },
      { type: "component", name: "callout", marker: MARKER },
      { type: "html", html: "<p>Three</p>" },
    ]);

    layOut(editor, surface);
    hover(surface, ROW + 5);

    const data = transfer();
    const start = new Event("dragstart", { bubbles: true });
    start.dataTransfer = data;
    grip.dispatchEvent(start);

    expect(editor.view.dragging.slice.content.firstChild.type.name).toBe("mishkaComponent");

    editor.view.posAtCoords = () => ({ pos: 0, inside: -1 });

    const drop = new Event("drop", { bubbles: true, cancelable: true });
    drop.dataTransfer = data;
    editor.view.dom.dispatchEvent(drop);

    expect(blocks(editor)).toEqual([MARKER, "One", "Three"]);
    expect(editor.getHTML()).toBe(`<p>${MARKER}</p><p dir="auto">One</p><p dir="auto">Three</p>`);
  });

  test("a drag dropped nowhere leaves nothing behind", async () => {
    const { surface, editor, grip } = await open("<p>One</p><p>Two</p>");

    hover(surface, 5);

    const start = new Event("dragstart", { bubbles: true });
    start.dataTransfer = transfer();
    grip.dispatchEvent(start);
    grip.dispatchEvent(new Event("dragend", { bubbles: true }));

    expect(editor.view.dragging).toBeNull();
    expect(grip.dataset.dragging).toBe("false");
    expect(blocks(editor)).toEqual(["One", "Two"]);
  });
});

describe("Alt+↑ and Alt+↓", () => {
  function press(editor, key) {
    editor.view.dom.dispatchEvent(
      new KeyboardEvent("keydown", { key, altKey: true, bubbles: true, cancelable: true }),
    );
  }

  test("move the block holding the cursor, and the cursor with it", async () => {
    const { editor } = await open("<p>One</p><p>Two</p><p>Three</p>");

    editor.commands.setTextSelection(7);
    press(editor, "ArrowUp");

    expect(blocks(editor)).toEqual(["Two", "One", "Three"]);
    expect(editor.state.selection.$from.parent.textContent).toBe("Two");

    press(editor, "ArrowDown");
    press(editor, "ArrowDown");

    expect(blocks(editor)).toEqual(["One", "Three", "Two"]);
    expect(editor.state.selection.$from.parent.textContent).toBe("Two");
  });

  test("move a selected component block", async () => {
    const { editor } = await open(`<p>One</p><p>${MARKER}</p><p>Three</p>`, [
      { type: "html", html: "<p>One</p>" },
      { type: "component", name: "callout", marker: MARKER },
      { type: "html", html: "<p>Three</p>" },
    ]);

    editor.commands.setNodeSelection(5);

    expect(moveBlock(editor.view, -1)).toBe(true);
    expect(blocks(editor)).toEqual([MARKER, "One", "Three"]);
    expect(editor.state.selection).toBeInstanceOf(NodeSelection);
    expect(editor.state.selection.node.type.name).toBe("mishkaComponent");
  });

  test("do nothing past the first or the last block", async () => {
    const { editor } = await open("<p>One</p><p>Two</p>");

    editor.commands.setTextSelection(2);

    expect(moveBlock(editor.view, -1)).toBe(false);
    expect(blocks(editor)).toEqual(["One", "Two"]);
  });
});
