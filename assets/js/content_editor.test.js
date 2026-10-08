import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";

import { mount } from "./content_editor.js";
import config, {
  COMPONENT_MIME,
  EVENT,
  contentFrom,
  controllerOf,
  dropComponent,
  markerParagraph,
} from "../vendor/editor_extensions.js";

// THE CONTENT EDITOR AS THE ADMIN RUNS IT: Chelekom's engine, mounted on the markup the Admin
// adapter draws, with the CMS's extensions, asking a server that answers the way
// `ContentComponentPicker` does. The marker is the server's to read and write; what these pin is
// that the browser carries it untouched — in, as a block, and out, as a paragraph of its own.

const MARKER = '[[component callout title="Heads up"]]Read <b>this</b>[[/component]]';

function settle(ms = 20) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function fixture(stored) {
  document.body.innerHTML = `
    <div id="ed" data-part="root">
      <div data-part="toolbar">
        <button type="button" data-editor-command="bold">B</button>
        <button type="button" data-editor-command="h4">H4</button>
      </div>
      <textarea id="ed-value" data-part="value" name="form[content]" hidden></textarea>
      <div id="ed-surface" data-part="surface" data-root-id="ed" data-value-id="ed-value"
           data-format="html" data-debounce="5" data-components="#ed-components"
           data-placeholder="Write here" data-label-id="ed-label"
           data-label-edit="Settings" data-label-remove="Remove"></div>
      <div id="ed-components">
        <button type="button" id="card-callout" data-component-card="callout" data-configurable="true">callout</button>
        <button type="button" id="card-badge" data-component-card="badge" data-configurable="false">badge</button>
        <div data-content-editor-settings="callout">
          <input data-content-editor-attr="title" value="Read me" />
          <select data-content-editor-attr="tone"><option value="warn" selected>warn</option></select>
          <textarea data-content-editor-inner>Inner <i>text</i></textarea>
          <button type="button" id="apply" data-content-editor-apply="callout">Apply</button>
        </div>
      </div>
    </div>`;

  const mirror = document.getElementById("ed-value");
  const surface = document.getElementById("ed-surface");

  mirror.value = stored;
  surface.setAttribute("data-value", stored);

  return { mirror, surface, root: document.getElementById("ed") };
}

// A hook whose pushes are answered by `answers[event]`, a value or a function of the payload.
function hookFor(el, answers = {}) {
  const handlers = {};

  return {
    el,
    pushes: [],
    pushEventTo(target, event, payload, reply) {
      this.pushes.push({ target, event, payload });
      const answer = answers[event];
      const value = typeof answer === "function" ? answer(payload) : answer;
      if (reply) Promise.resolve().then(() => reply(value || {}));
    },
    handleEvent(event, callback) {
      handlers[event] = callback;
      return event;
    },
    removeHandleEvent(ref) {
      delete handlers[ref];
    },
    emit(event, payload) {
      if (handlers[event]) handlers[event](payload);
    },
  };
}

async function open(stored, answers) {
  const { mirror, surface, root } = fixture(stored);
  const hook = hookFor(surface, answers);
  const handle = mount(hook);

  await settle();

  return { mirror, surface, root, hook, handle, editor: handle.engine.editor };
}

function components(editor) {
  const found = [];

  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "mishkaComponent") found.push({ pos, ...node.attrs });
  });

  return found;
}

let opened = [];

// jsdom lays nothing out, and ProseMirror measures a range to scroll the cursor into view.
beforeAll(() => {
  const none = { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 };

  Range.prototype.getClientRects = () => [];
  Range.prototype.getBoundingClientRect = () => none;
});

beforeEach(() => {
  window.prompt = vi.fn();
  opened = [];
});

afterEach(() => {
  for (const handle of opened) handle.destroyed();
  document.body.innerHTML = "";
});

async function editorFor(stored, answers) {
  const context = await open(stored, answers);
  opened.push(context.handle);
  return context;
}

describe("the stored shape", () => {
  test("a block writes its marker as the only thing in a paragraph, untouched", () => {
    const editor = new Editor({
      element: document.createElement("div"),
      extensions: [StarterKit.configure(config.starterKit), ...config.extensions],
      content: contentFrom([{ type: "component", name: "callout", marker: MARKER }]),
    });

    expect(editor.getHTML()).toBe(`<p>${MARKER}</p>`);
    editor.destroy();
  });

  test("and markup inside the marker is written as markup, not as escaped text", () => {
    expect(markerParagraph(MARKER).outerHTML).toBe(`<p>${MARKER}</p>`);
  });

  test("the server's segments become the document, its HTML as it is", () => {
    const html = contentFrom([
      { type: "html", html: "<p>Intro</p>" },
      { type: "component", name: "callout", marker: 'a "quoted" <b>marker</b> & more' },
    ]);

    expect(html).toBe(
      '<p>Intro</p><div data-mishka-component="" data-name="callout" data-marker="a &quot;quoted&quot; &lt;b&gt;marker&lt;/b&gt; &amp; more"></div>',
    );
  });
});

describe("opening stored content", () => {
  test("asks the server to split it, and holds each component standing alone as a block", async () => {
    const stored = `<p>Intro</p><p>${MARKER}</p><p>After</p>`;

    const { hook, editor } = await editorFor(stored, {
      segments: {
        segments: [
          { type: "html", html: "<p>Intro</p>" },
          { type: "component", name: "callout", marker: MARKER },
          { type: "html", html: "<p>After</p>" },
        ],
      },
    });

    expect(hook.pushes[0]).toEqual({
      target: "#ed-components",
      event: "segments",
      payload: { html: stored },
    });

    expect(components(editor)).toEqual([{ pos: 7, name: "callout", marker: MARKER }]);
    expect(editor.getHTML()).toBe(
      `<p dir="auto">Intro</p><p>${MARKER}</p><p dir="auto">After</p>`,
    );
  });

  test("leaves content with no component as the engine opened it", async () => {
    const { editor } = await editorFor("<p>Only text</p>", {
      segments: { segments: [{ type: "html", html: "<p>Only text</p>" }] },
    });

    expect(components(editor)).toEqual([]);
    expect(editor.getHTML()).toBe('<p dir="auto">Only text</p>');
  });

  test("does not mark the record changed by opening it", async () => {
    const stored = `<p>Intro</p><p>${MARKER}</p>`;
    const { mirror } = await editorFor(stored, {
      segments: {
        segments: [
          { type: "html", html: "<p>Intro</p>" },
          { type: "component", name: "callout", marker: MARKER },
        ],
      },
    });

    await settle(30);

    expect(mirror.value).toBe(stored);
  });

  test("shows the preview the server pushes for a block", async () => {
    const { hook, surface } = await editorFor(`<p>${MARKER}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: MARKER }] },
    });

    hook.emit(EVENT, { id: "ed", previews: [{ marker: MARKER, preview: "<aside>drawn</aside>" }] });

    const preview = surface.querySelector("[data-role='content-component-preview']");
    expect(preview.innerHTML).toBe("<aside>drawn</aside>");
    expect(preview.hasAttribute("inert")).toBe(true);
    expect(surface.querySelector("[data-role='content-component-name']").textContent).toBe(
      "callout",
    );
  });

  test("and ignores one pushed for another editor", async () => {
    const { hook, surface } = await editorFor(`<p>${MARKER}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: MARKER }] },
    });

    hook.emit(EVENT, { id: "other", previews: [{ marker: MARKER, preview: "<aside>no</aside>" }] });

    expect(surface.querySelector("[data-role='content-component-preview']").innerHTML).toBe("");
  });
});

describe("the field", () => {
  test("an edit is written into the hidden textarea, with an input event the form hears", async () => {
    const { editor, mirror } = await editorFor("<p>Hi</p>", { segments: { segments: [] } });
    const heard = vi.fn();
    mirror.addEventListener("input", heard);

    editor.commands.setContent("<p>Hello</p>", { emitUpdate: true });
    await settle(30);

    expect(mirror.value).toBe('<p dir="auto">Hello</p>');
    expect(heard).toHaveBeenCalledTimes(1);
    expect(heard.mock.calls[0][0].bubbles).toBe(true);
  });
});

describe("placing a component", () => {
  test("a palette card is built by the server and placed at the cursor", async () => {
    const { root, hook, editor, mirror } = await editorFor("<p>Hi</p>", {
      segments: { segments: [] },
      build: { name: "badge", marker: "[[component badge /]]" },
    });

    editor.commands.setTextSelection(editor.state.doc.content.size - 1);
    root.querySelector("#card-badge").click();
    await settle(30);

    expect(hook.pushes.find((push) => push.event === "build").payload).toEqual({
      name: "badge",
      attrs: {},
      inner: "",
    });
    expect(components(editor).map((block) => block.marker)).toEqual(["[[component badge /]]"]);
    expect(mirror.value).toContain("<p>[[component badge /]]</p>");
    expect(hook.pushes.some((push) => push.event === "edit")).toBe(false);
  });

  test("one that takes settings opens them for the block just placed", async () => {
    const { root, hook } = await editorFor("<p>Hi</p>", {
      segments: { segments: [] },
      build: { name: "callout", marker: "[[component callout /]]" },
    });

    root.querySelector("#card-callout").click();
    await settle(30);

    expect(hook.pushes.find((push) => push.event === "edit").payload).toEqual({
      marker: "[[component callout /]]",
    });
  });

  test("the server's refusal places nothing", async () => {
    const { root, editor } = await editorFor("<p>Hi</p>", {
      segments: { segments: [] },
      build: { error: "not placeable" },
    });

    root.querySelector("#card-badge").click();
    await settle(30);

    expect(components(editor)).toEqual([]);
  });

  test("a card dropped into the text is placed where it fell", async () => {
    const { editor } = await editorFor("<p>One</p><p>Two</p>", {
      segments: { segments: [] },
      build: { name: "badge", marker: "[[component badge /]]" },
    });

    const transfer = {
      types: [COMPONENT_MIME],
      getData: (type) => (type === COMPONENT_MIME ? "badge" : ""),
    };
    const event = { dataTransfer: transfer, clientX: 0, clientY: 0, preventDefault: vi.fn() };
    const view = { posAtCoords: () => ({ pos: 5 }) };

    expect(dropComponent(editor, view, event)).toBe(true);
    await settle(30);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(components(editor)[0].pos).toBe(5);
  });

  test("anything else dropped is left to the editor", async () => {
    const { editor } = await editorFor("<p>One</p>", { segments: { segments: [] } });
    const event = { dataTransfer: { types: ["text/plain"], getData: () => "x" } };

    expect(dropComponent(editor, { posAtCoords: () => null }, event)).toBe(false);
  });

  test("dragging a card carries its name", async () => {
    const { root } = await editorFor("<p>One</p>", { segments: { segments: [] } });
    const data = {};
    const event = new Event("dragstart", { bubbles: true });
    event.dataTransfer = { setData: (type, value) => (data[type] = value) };

    root.querySelector("#card-badge").dispatchEvent(event);

    expect(data[COMPONENT_MIME]).toBe("badge");
  });
});

describe("a component's settings", () => {
  test("Apply sends what they hold, and the block being edited takes the server's marker", async () => {
    const placed = "[[component callout /]]";
    const built = '[[component callout title="Read me" tone="warn"]]Inner <i>text</i>[[/component]]';

    const { root, hook, editor, surface } = await editorFor(`<p>${placed}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: placed }] },
      edit: { ok: true },
      build: { name: "callout", marker: built },
    });

    surface.querySelector("[data-action='edit']").click();
    root.querySelector("#apply").click();
    await settle(30);

    expect(hook.pushes.find((push) => push.event === "edit").payload).toEqual({ marker: placed });
    expect(hook.pushes.find((push) => push.event === "build").payload).toEqual({
      name: "callout",
      attrs: { title: "Read me", tone: "warn" },
      inner: "Inner <i>text</i>",
    });
    expect(components(editor).map((block) => block.marker)).toEqual([built]);
  });

  test("Remove takes the block out", async () => {
    const { surface, editor } = await editorFor(`<p>${MARKER}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: MARKER }] },
    });

    surface.querySelector("[data-action='remove']").click();

    expect(components(editor)).toEqual([]);
  });
});

describe("the toolbar", () => {
  test("H4 is a command the CMS adds, and it marks itself active", async () => {
    const { root, editor } = await editorFor("<p>Title</p>", { segments: { segments: [] } });

    editor.commands.setTextSelection(2);
    root.querySelector("[data-editor-command='h4']").click();

    expect(editor.getHTML()).toMatch(/^<h4 dir="auto">Title<\/h4>/);
    expect(root.querySelector("[data-editor-command='h4']").hasAttribute("data-active")).toBe(true);
  });

  test("Link asks for the address, and an empty answer takes the link away", async () => {
    const { root, editor } = await editorFor("<p>Site</p>", { segments: { segments: [] } });

    editor.commands.setTextSelection({ from: 1, to: 5 });
    window.prompt.mockReturnValueOnce("https://mishka.tools");
    root.querySelector("[data-editor-command='bold']").insertAdjacentHTML(
      "afterend",
      '<button type="button" data-editor-command="link">L</button>',
    );
    root.querySelector("[data-editor-command='link']").click();

    expect(editor.getHTML()).toBe('<p dir="auto"><a href="https://mishka.tools">Site</a></p>');

    window.prompt.mockReturnValueOnce("");
    root.querySelector("[data-editor-command='link']").click();

    expect(editor.getHTML()).toBe('<p dir="auto">Site</p>');
  });
});

describe("what a reader is told", () => {
  test("the editable element is the textbox, named by the field's label", async () => {
    const { surface } = await editorFor("<p>Hi</p>", { segments: { segments: [] } });
    const textbox = surface.querySelector(".ProseMirror");

    expect(textbox.getAttribute("role")).toBe("textbox");
    expect(textbox.getAttribute("aria-labelledby")).toBe("ed-label");
    expect(textbox.getAttribute("aria-multiline")).toBe("true");
  });

  test("an empty editor shows the placeholder, through the engine's data-placeholder", async () => {
    const { surface, root, editor } = await editorFor("", { segments: { segments: [] } });

    expect(surface.querySelector(".ProseMirror").getAttribute("data-placeholder")).toBe(
      "Write here",
    );
    expect(root.hasAttribute("data-empty")).toBe(true);

    editor.commands.setContent("<p>Typed</p>", { emitUpdate: true });

    expect(root.hasAttribute("data-empty")).toBe(false);
  });
});

describe("one module, many editors", () => {
  test("each editor asks its own server half and keeps its own controller", async () => {
    const first = await editorFor("<p>A</p>", { segments: { segments: [] } });

    expect(controllerOf(first.surface)).toBeDefined();
    expect(controllerOf(document.createElement("div"))).toBeUndefined();
  });
});
