import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";

import { mount } from "./content_editor.js";
import config, {
  BLOCK_MIME,
  COMPONENT_MIME,
  EVENT,
  TYPED_WAIT,
  besideOf,
  codeAsText,
  contentFrom,
  controllerOf,
  dropComponent,
  markerDOM,
  markerParagraph,
  partsOf,
  single,
  unpin,
  unwrapped,
  whole,
} from "../vendor/editor_extensions.js";

// THE CONTENT EDITOR AS THE ADMIN RUNS IT: Chelekom's engine, mounted on the markup the Admin
// adapter draws, with the CMS's extensions, asking a server that answers the way
// `ContentComponentPicker` does. The marker is the server's to read and write; what these pin is
// that the browser carries it untouched — in, as a block, and out, as a paragraph of its own.

const MARKER = '[[component callout title="Heads up"]]Read <b>this</b>[[/component]]';

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
           data-label-edit="Settings" data-label-remove="Remove" data-label-code="Code"
           data-label-code-error="Not one component"></div>
      <button type="button" id="ed-components-toggle">Components</button>
      <div id="ed-components">
        <div data-role="content-editor-panel" id="ed-panel">
          <button type="button" id="card-callout" data-component-card="callout" data-configurable="true">callout</button>
          <button type="button" id="card-badge" data-component-card="badge" data-configurable="false">badge</button>
          <button type="button" id="block-card" data-block-card="card">Card</button>
        </div>
      </div>
    </div>
    <p id="elsewhere">Elsewhere</p>`;

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

// jsdom lays nothing out, and ProseMirror measures a range to scroll the cursor into view — and
// asks what is under a card dragged over the text, for its drop line.
beforeAll(() => {
  const none = { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 };

  Range.prototype.getClientRects = () => [];
  Range.prototype.getBoundingClientRect = () => none;
  document.elementFromPoint = () => null;
});

beforeEach(() => {
  vi.useFakeTimers({ toFake: CLOCK });
  window.prompt = vi.fn();
  opened = [];
});

afterEach(() => {
  for (const handle of opened) handle.destroyed();
  document.body.innerHTML = "";
  vi.useRealTimers();
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

  test("shows the preview the server pushes for a block, in a shadow root", async () => {
    const { hook, surface } = await editorFor(`<p>${MARKER}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: MARKER }] },
    });

    const preview = surface.querySelector("[data-role='content-component-preview']");
    expect(preview.hasAttribute("data-empty")).toBe(true);

    hook.emit(EVENT, { id: "ed", previews: [{ marker: MARKER, preview: "<aside>drawn</aside>" }] });

    expect(drawnIn(preview)).toBe("<aside>drawn</aside>");
    expect(preview.innerHTML).toBe("");
    expect(preview.hasAttribute("data-empty")).toBe(false);
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

    expect(drawnIn(surface.querySelector("[data-role='content-component-preview']"))).toBe("");
  });

  test("draws every preview with the stylesheet the server names, as soon as it names it", async () => {
    const { hook, surface } = await editorFor(`<p>${MARKER}</p>`, {
      segments: {
        segments: [{ type: "component", name: "callout", marker: MARKER }],
        styles: "/assets/css/content-editor-1/aaa",
      },
    });

    const link = () =>
      surface
        .querySelector("[data-role='content-component-preview']")
        .shadowRoot.querySelector("link[rel=stylesheet]");

    expect(link().getAttribute("href")).toBe("/assets/css/content-editor-1/aaa");

    hook.emit(EVENT, { id: "ed", styles: "/assets/css/content-editor-1/bbb" });
    expect(link().getAttribute("href")).toBe("/assets/css/content-editor-1/bbb");

    hook.emit(EVENT, { id: "other", styles: "/assets/css/content-editor-2/ccc" });
    expect(link().getAttribute("href")).toBe("/assets/css/content-editor-1/bbb");
  });
});

describe("opening highlighted code", () => {
  // As the old site highlighted it, and as posts imported from it are stored: a line break is a
  // token of its own.
  const HIGHLIGHTED =
    '<pre class="highlight"><code class="language-elixir">' +
    '<span class="c1"># Export the set</span><span class="w">\n</span>' +
    '<span class="n">mix</span><span class="w"> </span><span class="n">export</span>' +
    '<span class="w">\n  </span><span class="ss">:ok</span><span class="w">\n\n</span>' +
    '<span class="c1"># And again</span></code></pre>';

  const LINES = "# Export the set\nmix export\n  :ok\n\n# And again";

  function codeBlocks(editor) {
    const found = [];

    editor.state.doc.descendants((node) => {
      if (node.type.name === "codeBlock") found.push({ text: node.textContent, ...node.attrs });
    });

    return found;
  }

  test("keeps every line and its language", async () => {
    const { editor } = await editorFor(`<p>Run it:</p>${HIGHLIGHTED}`, {
      segments: { segments: [{ type: "html", html: `<p>Run it:</p>${HIGHLIGHTED}` }] },
    });

    expect(codeBlocks(editor)).toEqual([{ text: LINES, language: "elixir", dir: "ltr" }]);
  });

  test("and so does the content the server split around a component", async () => {
    const stored = `${HIGHLIGHTED}<p>${MARKER}</p>`;

    const { editor } = await editorFor(stored, {
      segments: {
        segments: [
          { type: "html", html: HIGHLIGHTED },
          { type: "component", name: "callout", marker: MARKER },
        ],
      },
    });

    expect(components(editor)).toHaveLength(1);
    expect(codeBlocks(editor)).toEqual([{ text: LINES, language: "elixir", dir: "ltr" }]);
  });

  test("a line break written as <br> is a line break", async () => {
    const stored = '<pre><code class="language-js">let a = 1;<br>let b = 2;</code></pre>';
    const { editor } = await editorFor(stored, {
      segments: { segments: [{ type: "html", html: stored }] },
    });

    expect(codeBlocks(editor)).toEqual([{ text: "let a = 1;\nlet b = 2;", language: "js", dir: "ltr" }]);
  });

  test("content with no highlighted code is handed over as it is", () => {
    const html = "<p>Intro</p><pre><code class=\"language-sql\">select 1;\nselect 2;</code></pre>";
    expect(codeAsText(html)).toBe(html);
  });
});

describe("a closed modal", () => {
  test("lets the previews go of the site's stylesheet, and gives it back when shown", async () => {
    const { root, surface } = await editorFor(`<p>${MARKER}</p>`, {
      segments: {
        segments: [{ type: "component", name: "callout", marker: MARKER }],
        styles: "/assets/css/content-editor-1/aaa",
      },
    });

    // The editor inside a modal, as the admin draws it.
    const modal = document.createElement("div");
    root.before(modal);
    modal.append(root);
    controllerOf(surface).watch();

    const link = () =>
      surface
        .querySelector("[data-role='content-component-preview']")
        .shadowRoot.querySelector("link[rel=stylesheet]");

    root.getClientRects = () => [];
    modal.style.display = "none";
    await settle();
    expect(link().hasAttribute("href")).toBe(false);

    root.getClientRects = () => [{ width: 1, height: 1 }];
    modal.style.display = "";
    await settle();
    expect(link().getAttribute("href")).toBe("/assets/css/content-editor-1/aaa");
  });
});

function drawnIn(preview) {
  return preview.shadowRoot.querySelector("[data-role='content-component-drawn']").innerHTML;
}

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
      serial: 1,
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
  const PLACED = "[[component callout /]]";

  async function editing() {
    const context = await editorFor(`<p>${PLACED}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: PLACED }] },
      edit: { ok: true },
    });

    context.surface.querySelector("[data-action='edit']").click();
    await settle();

    return context;
  }

  test("Settings asks the server to open them, numbering the edit", async () => {
    const { hook } = await editing();

    expect(hook.pushes.find((push) => push.event === "edit").payload).toEqual({
      marker: PLACED,
      serial: 1,
    });
  });

  test("the block being edited takes each marker the settings write, the focus left alone", async () => {
    const { hook, editor, root } = await editing();
    const typing = document.createElement("input");
    root.after(typing);
    typing.focus();

    const first = '[[component callout title="A" /]]';
    const second = '[[component callout title="AB" /]]';

    hook.emit(EVENT, { id: "ed", serial: 1, applied: { name: "callout", marker: first } });
    hook.emit(EVENT, { id: "ed", serial: 1, applied: { name: "callout", marker: second } });

    expect(components(editor).map((block) => block.marker)).toEqual([second]);
    expect(document.activeElement).toBe(typing);
  });

  test("what an earlier edit's settings write, or another editor's, changes nothing", async () => {
    const { hook, editor } = await editing();
    const late = '[[component callout title="late" /]]';

    hook.emit(EVENT, { id: "ed", serial: 0, applied: { name: "callout", marker: late } });
    hook.emit(EVENT, { id: "other", serial: 1, applied: { name: "callout", marker: late } });

    expect(components(editor).map((block) => block.marker)).toEqual([PLACED]);
  });

  test("closed, they write into the block no more", async () => {
    const { hook, editor } = await editing();

    hook.emit(EVENT, { id: "ed", serial: 1, done: true });
    hook.emit(EVENT, {
      id: "ed",
      serial: 1,
      applied: { name: "callout", marker: '[[component callout title="x" /]]' },
    });

    expect(components(editor).map((block) => block.marker)).toEqual([PLACED]);
  });

  test("a double click on the block opens them, as Settings does", async () => {
    const { hook, surface } = await editorFor(`<p>${PLACED}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: PLACED }] },
      edit: { ok: true },
    });

    const block = surface.querySelector("[data-role='content-component']");
    block.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true }));
    await settle();

    expect(hook.pushes.filter((push) => push.event === "edit").map((push) => push.payload)).toEqual(
      [{ marker: PLACED, serial: 1 }],
    );
  });

  test("a double click on its buttons, or on its open code, opens nothing", async () => {
    const { hook, surface } = await editorFor(`<p>${PLACED}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: PLACED }] },
      edit: { ok: true },
    });

    const twice = (el) =>
      el.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true }));

    twice(surface.querySelector("[data-action='remove']"));
    surface.querySelector("[data-action='code']").click();
    await settle();
    twice(surface.querySelector("[data-role='content-component']"));
    await settle();

    expect(hook.pushes.filter((push) => push.event === "edit")).toEqual([]);
  });

  test("Remove takes the block out", async () => {
    const { surface, editor } = await editorFor(`<p>${MARKER}</p>`, {
      segments: { segments: [{ type: "component", name: "callout", marker: MARKER }] },
    });

    surface.querySelector("[data-action='remove']").click();

    expect(components(editor)).toEqual([]);
  });
});

describe("a component as code", () => {
  const PLACED = "[[component callout /]]";
  const WRITTEN = '[[component callout title="By hand" /]]';

  async function coded(answer) {
    const context = await editorFor(`<p>${PLACED}</p>`, {
      segments: (payload) =>
        payload.html === `<p>${PLACED}</p>`
          ? { segments: [{ type: "component", name: "callout", marker: PLACED }] }
          : answer,
    });

    context.surface.querySelector("[data-action='code']").click();
    await settle();

    return { ...context, code: context.surface.querySelector("[data-role='content-component-code']") };
  }

  test("Code shows the block's marker, to change by hand", async () => {
    const { code, surface } = await coded({});

    expect(code.hidden).toBe(false);
    expect(code.value).toBe(PLACED);
    expect(surface.querySelector("[data-action='code']").getAttribute("aria-pressed")).toBe("true");
    expect(surface.querySelector("[data-role='content-component']").hasAttribute("data-code")).toBe(
      true,
    );
  });

  test("pressed again, the server reads what was written and the block takes it", async () => {
    const { code, surface, editor, hook } = await coded({
      segments: [{ type: "component", name: "callout", marker: WRITTEN }],
    });

    code.value = WRITTEN;
    surface.querySelector("[data-action='code']").click();
    await settle();

    expect(hook.pushes.at(-1)).toEqual({
      target: "#ed-components",
      event: "segments",
      payload: { html: WRITTEN },
    });
    expect(components(editor).map((block) => block.marker)).toEqual([WRITTEN]);
    expect(code.hidden).toBe(true);
  });

  test("what is not one component is said so, and the code stays", async () => {
    const { code, surface, editor } = await coded({
      segments: [{ type: "html", html: "[[component callout" }],
    });

    code.value = "[[component callout";
    surface.querySelector("[data-action='code']").click();
    await settle();

    const fault = surface.querySelector("[data-role='content-component-code-error']");
    expect(fault.hidden).toBe(false);
    expect(fault.textContent).toBe("Not one component");
    expect(code.hidden).toBe(false);
    expect(components(editor).map((block) => block.marker)).toEqual([PLACED]);
  });

  test("unchanged, it closes without asking", async () => {
    const { code, surface, hook } = await coded({});
    const asked = hook.pushes.length;

    surface.querySelector("[data-action='code']").click();
    await settle();

    expect(code.hidden).toBe(true);
    expect(hook.pushes.length).toBe(asked);
  });
});

const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

describe("a marker typed into the text", () => {
  const TYPED = '[[component badge size="small" /]]';

  test("whole and standing alone, becomes a block once the text rests", async () => {
    const { editor, hook } = await editorFor("<p>Intro</p>", {
      segments: (payload) =>
        payload.html.includes(TYPED)
          ? { segments: [{ type: "component", name: "badge", marker: TYPED }] }
          : { segments: [] },
    });

    editor.commands.insertContentAt(editor.state.doc.content.size, `<p>${TYPED}</p>`);
    await settle(TYPED_WAIT - 50);
    expect(hook.pushes.filter((push) => push.event === "segments").length).toBe(1);

    await settle(100);

    expect(hook.pushes.at(-1).payload).toEqual({ html: `<p dir="auto">${TYPED}</p>` });
    expect(components(editor).map((block) => block.marker)).toEqual([TYPED]);
    expect(editor.getHTML()).toMatch(new RegExp(`^<p dir="auto">Intro</p><p>${escaped(TYPED)}</p>`));
  });

  test("half written, or sharing its line with text, stays text", async () => {
    const { editor, hook } = await editorFor("<p>Intro</p>", { segments: { segments: [] } });

    editor.commands.insertContentAt(editor.state.doc.content.size, "<p>[[component badge</p>");
    editor.commands.insertContentAt(editor.state.doc.content.size, `<p>See ${TYPED}</p>`);
    await settle(TYPED_WAIT + 50);

    expect(hook.pushes.filter((push) => push.event === "segments").length).toBe(1);
    expect(components(editor)).toEqual([]);
  });

  test("one the server does not read as a component stays text", async () => {
    const { editor } = await editorFor("<p>Intro</p>", {
      segments: { segments: [{ type: "html", html: `<p>${TYPED}</p>` }] },
    });

    editor.commands.insertContentAt(editor.state.doc.content.size, `<p>${TYPED}</p>`);
    await settle(TYPED_WAIT + 50);

    expect(components(editor)).toEqual([]);
  });

  test("whole/1 and single/1 are what decide", () => {
    expect(whole(` ${TYPED} `)).toBe(true);
    expect(whole("[[component a]]x[[/component]]")).toBe(true);
    expect(whole("[[component a]]x")).toBe(false);
    expect(whole(`x ${TYPED}`)).toBe(false);

    expect(single([{ type: "component", name: "a", marker: "m" }])).toEqual({ name: "a", marker: "m" });
    expect(
      single([
        { type: "html", html: "<p> " },
        { type: "component", name: "a", marker: "m" },
        { type: "html", html: "</p>" },
      ]),
    ).toEqual({ name: "a", marker: "m" });
    expect(single([{ type: "html", html: "x" }, { type: "component", name: "a", marker: "m" }])).toBe(
      null,
    );
    expect(single([])).toBe(null);
  });
});

describe("closing what is open", () => {
  test("a press outside the palette closes it; one inside it, or on its button, does not", async () => {
    const { hook } = await editorFor("<p>Hi</p>", { segments: { segments: [] } });
    const closes = () => hook.pushes.filter((push) => push.event === "close").length;

    document.getElementById("card-badge").dispatchEvent(new Event("pointerdown", { bubbles: true }));
    document
      .getElementById("ed-components-toggle")
      .dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(closes()).toBe(0);

    document.getElementById("elsewhere").dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(closes()).toBe(1);
  });

  test("a press outside the settings drawer closes it; one inside it does not", async () => {
    const { hook } = await editorFor("<p>Hi</p>", { segments: { segments: [] } });
    document.getElementById("ed-panel").remove();
    document.body.insertAdjacentHTML(
      "beforeend",
      '<aside data-role="content-editor-drawer" data-editor="ed"><input id="field" /></aside>',
    );
    const done = () => hook.pushes.filter((push) => push.event === "settings_done").length;

    document.getElementById("field").dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(done()).toBe(0);

    document.getElementById("elsewhere").dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(done()).toBe(1);
  });

  test("Escape closes the drawer first, then the palette", async () => {
    const { hook } = await editorFor("<p>Hi</p>", { segments: { segments: [] } });
    const escape = () => document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));

    escape();
    expect(hook.pushes.at(-1).event).toBe("close");

    document.body.insertAdjacentHTML(
      "beforeend",
      '<aside data-role="content-editor-drawer" data-editor="ed"></aside>',
    );
    escape();
    expect(hook.pushes.at(-1).event).toBe("settings_done");
  });
});

describe("ready blocks", () => {
  const BLOCK = "[[component card]][[component card-title /]][[/component]]";

  test("a block is built by the server, placed, and opened to be filled in", async () => {
    const { root, hook, editor } = await editorFor("<p>Hi</p>", {
      segments: { segments: [] },
      block: { name: "card", marker: BLOCK },
      edit: { ok: true },
    });

    root.querySelector("#block-card").click();
    await settle(30);

    expect(hook.pushes.find((push) => push.event === "block").payload).toEqual({ id: "card" });
    expect(components(editor).map((block) => block.marker)).toEqual([BLOCK]);
    expect(hook.pushes.find((push) => push.event === "edit").payload.marker).toBe(BLOCK);
  });

  test("two placed one after the other both stay, the second below the first", async () => {
    let n = 0;
    const { root, editor } = await editorFor("<p>Hi</p>", {
      segments: { segments: [] },
      block: () => ({ name: "card", marker: `[[component card n="${(n += 1)}" /]]` }),
      edit: { ok: true },
    });

    root.querySelector("#block-card").click();
    await settle(30);
    root.querySelector("#block-card").click();
    await settle(30);

    expect(components(editor).map((block) => block.marker)).toEqual([
      '[[component card n="1" /]]',
      '[[component card n="2" /]]',
    ]);
    expect(editor.state.selection.empty).toBe(true);
  });

  test("dragging a block carries its id, and dropping it places it where it fell", async () => {
    const { root, editor } = await editorFor("<p>One</p><p>Two</p>", {
      segments: { segments: [] },
      block: { name: "card", marker: BLOCK },
      edit: { ok: true },
    });

    const data = {};
    const start = new Event("dragstart", { bubbles: true });
    start.dataTransfer = { setData: (type, value) => (data[type] = value) };
    root.querySelector("#block-card").dispatchEvent(start);
    expect(data[BLOCK_MIME]).toBe("card");

    const event = {
      dataTransfer: { types: [BLOCK_MIME], getData: (type) => data[type] || "" },
      clientX: 0,
      clientY: 0,
      preventDefault: vi.fn(),
    };

    expect(dropComponent(editor, { posAtCoords: () => ({ pos: 5 }) }, event)).toBe(true);
    await settle(30);

    expect(components(editor)[0]).toEqual({ pos: 5, name: "card", marker: BLOCK });
  });

  test("a marker holding block markup is written outside any paragraph", () => {
    const marker = "[[component card]]<p>Inside</p>[[/component]]";
    const holder = document.createElement("div");
    holder.append(markerDOM(marker));

    expect(unwrapped(holder.innerHTML)).toBe(marker);
    expect(markerDOM("[[component a /]]").outerHTML).toBe("<p>[[component a /]]</p>");
  });

  test("content holding such a marker is still written, and reaches the form", async () => {
    const marker = '[[component banner]]<div class="row"><h3>Hi</h3></div>[[/component]]';
    const { editor, mirror } = await editorFor(`${marker}<p>After</p>`, {
      segments: { segments: [{ type: "component", name: "banner", marker }, { type: "html", html: "<p>After</p>" }] },
    });

    expect(editor.getHTML()).toBe(`${marker}<p dir="auto">After</p>`);

    editor.commands.insertContentAt(editor.state.doc.content.size, "<p>More</p>");
    await settle(30);

    expect(mirror.value).toBe(`${marker}<p dir="auto">After</p><p dir="auto">More</p>`);
  });
});

describe("a component dropped on a placed one", () => {
  const ROW = "[[component row]][[/component]]";
  const NESTED = "[[component row]][[component badge /]][[/component]]";

  async function dropped(answers) {
    const context = await editorFor(`<p>${ROW}</p>`, {
      segments: { segments: [{ type: "component", name: "row", marker: ROW }] },
      ...answers,
    });

    const block = context.surface.querySelector("[data-role='content-component-preview']");
    const event = {
      dataTransfer: { types: [COMPONENT_MIME], getData: () => "badge" },
      target: block,
      clientX: 0,
      clientY: 0,
      preventDefault: vi.fn(),
    };

    // jsdom lays nothing out, so the drop lands nowhere in particular; the block it is over is the
    // one whose element the event came from.
    const view = {
      posAtCoords: () => null,
      nodeDOM: (pos) => context.editor.view.nodeDOM(pos),
    };

    dropComponent(context.editor, view, event);
    await settle(30);

    return context;
  }

  test("goes inside it, as the server writes it", async () => {
    const { hook, editor } = await dropped({ nest: { name: "row", marker: NESTED } });

    expect(hook.pushes.find((push) => push.event === "nest").payload).toEqual({
      marker: ROW,
      name: "badge",
    });
    expect(components(editor).map((block) => block.marker)).toEqual([NESTED]);
  });

  test("is placed beside it when it holds nothing", async () => {
    const { hook, editor } = await dropped({
      nest: { error: "holds nothing" },
      build: { name: "badge", marker: "[[component badge /]]" },
    });

    expect(hook.pushes.some((push) => push.event === "build")).toBe(true);
    expect(components(editor).map((block) => block.marker)).toContain("[[component badge /]]");
  });
});

// WHAT A COMPONENT HOLDS, ON ITS BLOCK: the server marks each part in the preview, and the block
// finds the parts by the marks, takes the marks out, and moves a part by its grip — or shows where a
// card dropped on it goes.
describe("what a component holds, on its block", () => {
  const LIST = "[[component list]][[component item /]][[component item /]][[component item /]][[/component]]";
  const MOVED = "[[component list]][[component item /]][[component item /]][[component item /]][[/component]] ";
  const MARKED =
    '<ul class="probe-list"><mishka-part data-part="r-0"></mishka-part><li id="i0">A</li>' +
    '<mishka-part data-part="r-1"></mishka-part><li id="i1">B</li>' +
    '<mishka-part data-part="r-2"></mishka-part><li id="i2">C</li><mishka-part data-end="r"></mishka-part></ul>';

  // jsdom lays nothing out: each item gets a row of its own, 20px high, 30px apart.
  function rows(drawn) {
    ["i0", "i1", "i2"].forEach((id, i) => {
      const top = i * 30;
      drawn.querySelector(`#${id}`).getBoundingClientRect = () => ({
        left: 0, right: 100, top, bottom: top + 20, width: 100, height: 20,
      });
    });
  }

  async function placed(answers = {}) {
    const context = await editorFor(`<p>${LIST}</p>`, {
      segments: { segments: [{ type: "component", name: "list", marker: LIST }] },
      reorder: { name: "list", marker: MOVED },
      ...answers,
    });

    context.hook.emit(EVENT, { id: "ed", previews: [{ marker: LIST, preview: MARKED }] });

    const block = context.surface.querySelector("[data-role='content-component']");
    const drawn = block
      .querySelector("[data-role='content-component-preview']")
      .shadowRoot.querySelector("[data-role='content-component-drawn']");

    rows(drawn);

    return { ...context, block, drawn };
  }

  const point = (el, type, x, y) =>
    el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 }));

  const pushed = (hook, event) => hook.pushes.filter((push) => push.event === event).map((push) => push.payload);

  test("the marks are taken out, and the preview is drawn as the page draws it", async () => {
    const { drawn } = await placed();

    expect(drawn.querySelector("mishka-part")).toBe(null);
    expect(drawn.querySelector("ul").innerHTML).toBe('<li id="i0">A</li><li id="i1">B</li><li id="i2">C</li>');
  });

  test("the part under the pointer shows a grip that drags it among its siblings", async () => {
    const { block, hook, editor } = await placed();
    const grip = block.querySelector("[data-role='content-part-grip']");
    const line = block.querySelector("[data-role='content-part-line']");

    point(block, "pointermove", 50, 70);
    expect(grip.hidden).toBe(false);
    expect(block.querySelector("[data-role='content-part-outline']").hidden).toBe(false);

    point(grip, "pointerdown", 50, 70);
    point(grip, "pointermove", 50, 2);
    expect(line.hidden).toBe(false);

    point(grip, "pointerup", 50, 2);
    await settle();

    expect(pushed(hook, "reorder")).toEqual([{ marker: LIST, path: "r-2", beside: "r-0", after: false }]);
    expect(components(editor).map((found) => found.marker)).toEqual([MOVED]);
    expect(grip.hidden).toBe(true);
    expect(line.hidden).toBe(true);
  });

  test("a part dropped where it already is sends nothing", async () => {
    const { block, hook } = await placed();
    const grip = block.querySelector("[data-role='content-part-grip']");

    point(block, "pointermove", 50, 40);
    point(grip, "pointerdown", 50, 40);
    point(grip, "pointermove", 50, 18);
    point(grip, "pointerup", 50, 18);
    await settle();

    expect(pushed(hook, "reorder")).toEqual([]);
  });

  test("a grip pressed on the block whose settings are open leaves them open", async () => {
    const { block, hook, surface } = await placed({ edit: { ok: true } });
    const drawer = document.createElement("aside");
    drawer.dataset.role = "content-editor-drawer";
    drawer.dataset.editor = "ed";
    document.body.append(drawer);

    surface.querySelector("[data-action='edit']").click();
    await settle();

    point(block, "pointermove", 50, 40);
    point(block.querySelector("[data-role='content-part-grip']"), "pointerdown", 50, 40);
    expect(pushed(hook, "settings_done")).toEqual([]);

    point(document.getElementById("elsewhere"), "pointerdown", 0, 0);
    expect(pushed(hook, "settings_done")).toEqual([{}]);
  });

  test("a card dragged over a component that takes others lights it up, and goes in where shown", async () => {
    const { block, hook, editor, surface } = await placed({ nest: { name: "list", marker: MOVED } });
    hook.emit(EVENT, { id: "ed", holders: ["list"] });

    const over = new Event("dragover", { bubbles: true, cancelable: true });
    Object.assign(over, { dataTransfer: { types: [COMPONENT_MIME] }, clientX: 50, clientY: 38 });
    block.dispatchEvent(over);

    expect(block.hasAttribute("data-drop-inside")).toBe(true);
    expect(surface.hasAttribute("data-drop-inside")).toBe(true);
    expect(block.querySelector("[data-role='content-part-line']").hidden).toBe(false);

    const view = { posAtCoords: () => null, nodeDOM: (pos) => editor.view.nodeDOM(pos) };
    const drop = {
      dataTransfer: { types: [COMPONENT_MIME], getData: () => "item" },
      target: block,
      clientX: 50,
      clientY: 38,
      preventDefault: vi.fn(),
    };

    dropComponent(editor, view, drop);
    await settle(30);

    expect(pushed(hook, "nest")).toEqual([{ marker: LIST, name: "item", beside: "r-1", after: false }]);
    expect(block.hasAttribute("data-drop-inside")).toBe(false);
    expect(surface.hasAttribute("data-drop-inside")).toBe(false);
    expect(components(editor).map((found) => found.marker)).toEqual([MOVED]);
  });

  test("a component that takes nothing is not lit up", async () => {
    const { block, hook } = await placed();
    hook.emit(EVENT, { id: "ed", holders: ["other"] });

    const over = new Event("dragover", { bubbles: true, cancelable: true });
    Object.assign(over, { dataTransfer: { types: [COMPONENT_MIME] }, clientX: 50, clientY: 38 });
    block.dispatchEvent(over);

    expect(block.hasAttribute("data-drop-inside")).toBe(false);
  });

  test("a ready block dropped on a placed component goes inside it too", async () => {
    const { block, hook, editor } = await placed({ nest: { name: "list", marker: MOVED } });
    const view = { posAtCoords: () => null, nodeDOM: (pos) => editor.view.nodeDOM(pos) };

    dropComponent(editor, view, {
      dataTransfer: { types: [BLOCK_MIME], getData: (type) => (type === BLOCK_MIME ? "card" : "") },
      target: block,
      clientX: 0,
      clientY: 0,
      preventDefault: vi.fn(),
    });
    await settle(30);

    expect(pushed(hook, "nest")).toEqual([{ marker: LIST, block: "card" }]);
    expect(components(editor).map((found) => found.marker)).toEqual([MOVED]);
  });

  test("a slot's entries are the elements holding their marks; marks out of place give nothing", () => {
    const drawn = document.createElement("div");
    drawn.innerHTML =
      '<div class="tabs"><button><mishka-part data-part="r-0" data-slot="tab"></mishka-part>One</button>' +
      '<button><mishka-part data-part="r-1" data-slot="tab"></mishka-part>Two</button></div>' +
      '<div><mishka-part data-part="r-2"></mishka-part>Moved</div><div><mishka-part data-end="r"></mishka-part></div>';

    const parts = partsOf(drawn);

    expect(parts.map((part) => [part.path, part.group, part.nodes.map((node) => node.textContent)])).toEqual([
      ["r-0", "r:tab", ["One"]],
      ["r-1", "r:tab", ["Two"]],
    ]);
    expect(drawn.querySelector("mishka-part")).toBe(null);
  });

  test("where a point falls among parts side by side, or one under another", () => {
    const box = (left, top) => {
      const el = document.createElement("div");
      document.body.append(el);
      el.getBoundingClientRect = () => ({ left, top, right: left + 20, bottom: top + 20, width: 20, height: 20 });
      return { path: `r-${left}-${top}`, nodes: [el] };
    };

    const side = [box(0, 0), box(30, 0), box(60, 0)];
    expect(besideOf(side, 38, 10)).toMatchObject({ part: side[1], after: false, across: true });
    expect(besideOf(side, 48, 10)).toMatchObject({ part: side[1], after: true });

    const under = [box(0, 0), box(0, 30)];
    expect(besideOf(under, 10, 44)).toMatchObject({ part: under[1], after: true, across: false });
    expect(besideOf([], 0, 0)).toBe(null);
  });

  test("a component pinned to the screen is drawn in its place", () => {
    const drawn = document.createElement("div");
    drawn.innerHTML = '<div id="pinned" style="position: fixed; top: 0"></div><p id="still">x</p>';
    document.body.append(drawn);

    unpin(drawn);

    expect(drawn.querySelector("#pinned").style.position).toBe("relative");
    expect(drawn.querySelector("#still").style.position).toBe("");
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
