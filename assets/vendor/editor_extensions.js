// Editor configuration — the CMS's own, in the file Mishka Chelekom's headless `editor` engine
// (`editor.js` beside it, copied unchanged) imports as its extensions. Everything the CMS adds to
// the engine is here: the component block, the palette's click and drop, the drag handle, the
// toolbar commands the engine has no entry for, and the questions an editor asks the server.
//
// The engine builds every editor from this one module, so what belongs to one editor is read off
// its surface's data-* and kept on that editor's `ContentController`:
//
//   data-root-id     the editor's root, where its toolbar, palette and settings are
//   data-value-id    the hidden textarea the form submits
//   data-components  the server half — `ContentComponentPicker` — every question is pushed to
//   data-label-*     the words this file shows, already in the reader's language
//
// THE SERVER IS THE ONLY READER AND WRITER OF THE MARKER. A component block holds its marker as an
// opaque string the server wrote; this file never reads one apart or puts one together.

import { Extension, Node } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import DragHandle from "@tiptap/extension-drag-handle";
import Image from "@tiptap/extension-image";

export const COMPONENT_MIME = "application/x-mishka-component";
export const EVENT = "mishka:content_editor";

const hooks = new WeakMap();
const controllers = new WeakMap();

// The LiveView hook a surface's editor pushes through. `content_editor.js` attaches it before the
// engine mounts, so the editor finds it when it is created.
export function attach(surface, hook) {
  hooks.set(surface, hook);
}

export function detach(surface) {
  hooks.delete(surface);
}

export function controllerOf(surface) {
  return controllers.get(surface);
}

// A patch strips the data-active marks the controller writes; this puts them back.
export function repaint(surface) {
  const controller = controllers.get(surface);
  if (controller) controller.repaint();
}

// ---- the stored shape ----------------------------------------------------------------------

let inert = null;

// A component block as stored: its marker as the only thing in a paragraph — the shape the server
// draws as the component alone. Parsed inside a document of its own, where markup loads and runs
// nothing, because the marker's inner content is HTML.
export function markerParagraph(marker) {
  inert = inert || document.implementation.createHTMLDocument("");

  const paragraph = inert.createElement("p");
  paragraph.innerHTML = marker || "";

  return paragraph;
}

export function escapeAttribute(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// The document the server's segments describe: its HTML as it is, and each component as the
// element the block parses from.
export function contentFrom(segments) {
  return (segments || [])
    .map((segment) =>
      segment.type === "component"
        ? `<div data-mishka-component="" data-name="${escapeAttribute(segment.name)}" data-marker="${escapeAttribute(segment.marker)}"></div>`
        : segment.html || "",
    )
    .join("");
}

function toggle(el, attr, on) {
  if (on) el.setAttribute(attr, "");
  else el.removeAttribute(attr);
}

// Read back off a script the server already marked, as `code_editor.js` does for CodeMirror.
function cspNonce() {
  for (const script of document.scripts) if (script.nonce) return script.nonce;

  return "";
}

const SVG = 'xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" width="16" height="16" aria-hidden="true"';

const ICONS = {
  edit: `<svg ${SVG}><path d="m5.433 13.917 1.262-3.155A4 4 0 0 1 7.58 9.42l6.92-6.918a2.121 2.121 0 0 1 3 3l-6.92 6.918c-.383.383-.84.685-1.343.886l-3.154 1.262a.5.5 0 0 1-.65-.65Z"/><path d="M3.5 5.75c0-.69.56-1.25 1.25-1.25H10A.75.75 0 0 0 10 3H4.75A2.75 2.75 0 0 0 2 5.75v9.5A2.75 2.75 0 0 0 4.75 18h9.5A2.75 2.75 0 0 0 17 15.25V10a.75.75 0 0 0-1.5 0v5.25c0 .69-.56 1.25-1.25 1.25h-9.5c-.69 0-1.25-.56-1.25-1.25v-9.5Z"/></svg>`,
  remove: `<svg ${SVG}><path fill-rule="evenodd" d="M8.75 1A2.75 2.75 0 0 0 6 3.75v.443c-.795.077-1.584.176-2.365.298a.75.75 0 1 0 .23 1.482l.149-.022.841 10.518A2.75 2.75 0 0 0 7.596 19h4.807a2.75 2.75 0 0 0 2.742-2.53l.841-10.52.149.023a.75.75 0 0 0 .23-1.482A41.03 41.03 0 0 0 14 4.193V3.75A2.75 2.75 0 0 0 11.25 1h-2.5ZM10 4c.84 0 1.673.025 2.5.075V3.75c0-.69-.56-1.25-1.25-1.25h-2.5c-.69 0-1.25.56-1.25 1.25v.325C8.327 4.025 9.16 4 10 4ZM8.58 7.72a.75.75 0 0 0-1.5.06l.3 7.5a.75.75 0 1 0 1.5-.06l-.3-7.5Zm4.34.06a.75.75 0 1 0-1.5-.06l-.3 7.5a.75.75 0 1 0 1.5.06l.3-7.5Z" clip-rule="evenodd"/></svg>`,
  grip: `<svg ${SVG}><circle cx="7" cy="5" r="1.4"/><circle cx="13" cy="5" r="1.4"/><circle cx="7" cy="10" r="1.4"/><circle cx="13" cy="10" r="1.4"/><circle cx="7" cy="15" r="1.4"/><circle cx="13" cy="15" r="1.4"/></svg>`,
};

// ---- the component block -------------------------------------------------------------------

function iconButton(action, label, icon) {
  const button = document.createElement("button");

  button.type = "button";
  button.dataset.action = action;
  button.setAttribute("aria-label", label || action);
  button.title = label || action;
  button.innerHTML = icon;

  return button;
}

// The block in the editor: its name, Settings and Remove, and the component drawn as the server
// previews it. The preview is shown and never edited, and `inert` keeps every click and binding in
// it from reaching the page.
function componentView({ node, getPos, editor }) {
  const surface = editor.options.element;
  const labels = surface ? surface.dataset : {};

  const dom = document.createElement("div");
  dom.dataset.role = "content-component";
  dom.contentEditable = "false";

  const head = document.createElement("div");
  head.dataset.role = "content-component-head";

  const name = document.createElement("span");
  name.dataset.role = "content-component-name";
  name.dir = "ltr";

  const edit = iconButton("edit", labels.labelEdit, ICONS.edit);
  const remove = iconButton("remove", labels.labelRemove, ICONS.remove);

  const preview = document.createElement("div");
  preview.dataset.role = "content-component-preview";
  preview.setAttribute("inert", "");

  head.append(name, edit, remove);
  dom.append(head, preview);

  let painted = null;

  const view = {
    dom,

    paint() {
      name.textContent = node.attrs.name;

      const controller = controllerOf(surface);
      const html = (controller && controller.previewOf(node.attrs.marker)) || "";

      if (html === painted) return;
      painted = html;
      preview.innerHTML = html;
    },

    update(updated) {
      if (updated.type !== node.type) return false;
      node = updated;
      view.paint();
      return true;
    },

    stopEvent(event) {
      return !!(event.target && event.target.closest && event.target.closest("button"));
    },

    ignoreMutation() {
      return true;
    },

    destroy() {
      const controller = controllerOf(surface);
      if (controller) controller.views.delete(view);
    },
  };

  edit.addEventListener("click", (event) => {
    event.preventDefault();
    const controller = controllerOf(surface);
    if (controller) controller.edit(getPos(), node.attrs.marker);
  });

  remove.addEventListener("click", (event) => {
    event.preventDefault();
    const pos = getPos();
    if (typeof pos !== "number") return;
    editor.chain().focus().deleteRange({ from: pos, to: pos + node.nodeSize }).run();
  });

  const controller = controllerOf(surface);
  if (controller) controller.views.add(view);

  view.paint();

  return view;
}

export const MishkaComponent = Node.create({
  name: "mishkaComponent",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes() {
    return {
      name: { default: "", rendered: false },
      marker: { default: "", rendered: false },
    };
  },

  parseHTML() {
    return [
      {
        tag: "div[data-mishka-component]",
        getAttrs: (el) => ({
          name: el.getAttribute("data-name") || "",
          marker: el.getAttribute("data-marker") || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    return markerParagraph(node.attrs.marker);
  },

  addNodeView() {
    return (props) => componentView(props);
  },
});

// ---- direction ----------------------------------------------------------------------------

function direction(fallback) {
  return {
    default: fallback,
    parseHTML: (el) => {
      const dir = el.getAttribute("dir");
      return dir === "ltr" || dir === "rtl" || dir === "auto" ? dir : fallback;
    },
    renderHTML: (attributes) => (attributes.dir ? { dir: attributes.dir } : {}),
  };
}

// EACH BLOCK FINDS ITS OWN DIRECTION, so a Persian paragraph beside an English one reads right in
// the editor and on the page — what Tiptap's `textDirection: "auto"` does, which the engine does
// not pass. Code is always left to right.
export const ContentDirection = Extension.create({
  name: "contentDirection",

  addGlobalAttributes() {
    return [
      {
        types: ["paragraph", "heading", "blockquote", "bulletList", "orderedList", "listItem"],
        attributes: { dir: direction("auto") },
      },
      { types: ["codeBlock"], attributes: { dir: direction("ltr") } },
    ];
  },
});

// ---- one editor's questions to the server ---------------------------------------------------

// Toolbar commands the engine's list has no entry for; it leaves their buttons alone.
const EXTRA = {
  h4: (controller) => controller.editor.chain().focus().toggleHeading({ level: 4 }).run(),
  link: (controller) => controller.link(),
};

const EXTRA_ACTIVE = {
  h4: ["heading", { level: 4 }],
  link: ["link"],
};

export class ContentController {
  constructor(editor, hook) {
    this.editor = editor;
    this.hook = hook;
    this.surface = editor.options.element;
    this.root = document.getElementById(this.surface.dataset.rootId) || this.surface.parentElement;
    this.hidden = document.getElementById(this.surface.dataset.valueId);
    this.target = this.surface.dataset.components;
    this.previews = new Map();
    this.views = new Set();
    this.editing = null;
  }

  start() {
    this.onClick = (event) => this.click(event);
    this.onDragStart = (event) => this.dragStart(event);

    this.root.addEventListener("click", this.onClick);
    this.root.addEventListener("dragstart", this.onDragStart);
    this.ref = this.hook.handleEvent(EVENT, (payload) => this.receive(payload));

    controllers.set(this.surface, this);
    this.repaint();

    return this.load();
  }

  stop() {
    this.root.removeEventListener("click", this.onClick);
    this.root.removeEventListener("dragstart", this.onDragStart);
    if (this.ref) this.hook.removeHandleEvent(this.ref);

    controllers.delete(this.surface);
    this.views.clear();
  }

  request(event, payload) {
    if (!this.target) return Promise.resolve({});

    return new Promise((resolve) =>
      this.hook.pushEventTo(this.target, event, payload, (reply) => resolve(reply || {})),
    );
  }

  // The engine opened the stored HTML with each marker as text. The server splits it, and the
  // markers standing alone become blocks — unless the author typed in the meantime, when the text
  // they typed wins and the markers stay text.
  load() {
    const html = this.hidden ? this.hidden.value : this.surface.getAttribute("data-value") || "";
    const before = this.editor.state.doc;

    return this.request("segments", { html }).then(({ segments }) => {
      if (this.editor.isDestroyed || this.editor.state.doc !== before) return;
      if (!(segments || []).some((segment) => segment.type === "component")) return;

      this.editor
        .chain()
        .setMeta("addToHistory", false)
        .setContent(contentFrom(segments), { emitUpdate: false })
        .run();
    });
  }

  receive(payload) {
    if (!payload || payload.id !== this.surface.dataset.rootId) return;

    for (const { marker, preview } of payload.previews || []) this.previews.set(marker, preview || "");
    for (const view of this.views) view.paint();
  }

  previewOf(marker) {
    return this.previews.get(marker);
  }

  click(event) {
    const card = event.target.closest("[data-component-card]");
    if (card) {
      event.preventDefault();
      return this.place(card.dataset.componentCard, null);
    }

    const apply = event.target.closest("[data-content-editor-apply]");
    if (apply) {
      event.preventDefault();
      return this.apply(apply);
    }

    const tool = event.target.closest("[data-editor-command]");
    const extra = tool && EXTRA[tool.dataset.editorCommand];
    if (extra) {
      event.preventDefault();
      extra(this);
    }
  }

  dragStart(event) {
    const card = event.target.closest && event.target.closest("[data-component-card]");
    if (!card || !event.dataTransfer) return;

    event.dataTransfer.setData(COMPONENT_MIME, card.dataset.componentCard);
    event.dataTransfer.effectAllowed = "copy";
  }

  card(name) {
    for (const card of this.root.querySelectorAll("[data-component-card]"))
      if (card.dataset.componentCard === name) return card;

    return null;
  }

  // A component from the palette, placed at `at` or at the cursor; one that takes settings opens
  // them.
  place(name, at) {
    const card = this.card(name);
    const configurable = !!card && card.dataset.configurable === "true";

    return this.request("build", { name, attrs: {}, inner: "" }).then((reply) => {
      if (!reply.marker) return null;

      const pos = this.insert(reply, at);
      if (configurable && pos !== null) this.edit(pos, reply.marker);

      return pos;
    });
  }

  insert({ name, marker }, at) {
    const node = { type: "mishkaComponent", attrs: { name, marker } };
    const near = typeof at === "number" ? at : this.editor.state.selection.from;
    const chain = this.editor.chain().focus();

    (typeof at === "number" ? chain.insertContentAt(at, node) : chain.insertContent(node)).run();

    return this.locate(marker, near);
  }

  // The block holding `marker` nearest to `near`.
  locate(marker, near) {
    let found = null;

    this.editor.state.doc.descendants((node, pos) => {
      if (node.type.name !== "mishkaComponent" || node.attrs.marker !== marker) return;
      if (found === null || Math.abs(pos - near) < Math.abs(found - near)) found = pos;
    });

    return found;
  }

  edit(pos, marker) {
    this.editing = { pos, marker };

    return this.request("edit", { marker });
  }

  // Apply in the settings: what they hold, sent as the component to build. The block being edited
  // takes the answer; with none, it is placed at the cursor.
  apply(button) {
    const settings = button.closest("[data-content-editor-settings]") || this.root;
    const attrs = {};

    for (const input of settings.querySelectorAll("[data-content-editor-attr]"))
      attrs[input.dataset.contentEditorAttr] = input.value;

    const inner = settings.querySelector("[data-content-editor-inner]");
    const name = button.dataset.contentEditorApply;

    return this.request("build", { name, attrs, inner: inner ? inner.value : "" }).then((reply) => {
      if (reply.marker) this.replace(reply);
      return reply;
    });
  }

  replace({ name, marker }) {
    const editing = this.editing;
    this.editing = null;

    const pos = editing ? this.locate(editing.marker, editing.pos) : null;
    if (pos === null) return this.insert({ name, marker }, null);

    this.editor
      .chain()
      .focus()
      .command(({ tr }) => {
        tr.setNodeMarkup(pos, undefined, { name, marker });
        return true;
      })
      .run();

    return pos;
  }

  link() {
    const current = this.editor.getAttributes("link").href || "";
    const href = window.prompt(this.surface.dataset.labelLink || "", current);

    if (href === null) return;

    const chain = this.editor.chain().focus().extendMarkRange("link");

    (href.trim() === "" ? chain.unsetLink() : chain.setLink({ href: href.trim() })).run();
  }

  repaint() {
    if (this.editor.isDestroyed) return;

    for (const button of this.root.querySelectorAll("[data-editor-command]")) {
      const check = EXTRA_ACTIVE[button.dataset.editorCommand];
      if (check) toggle(button, "data-active", this.editor.isActive(...check));
    }
  }
}

// The editable element is the textbox a reader reaches, so it carries the field's label — the id
// the surface names in `data-label-id` — and says it takes more than one line.
export function accessibleName(surface) {
  const label = surface && surface.dataset ? surface.dataset.labelId : null;

  return label
    ? { "aria-labelledby": label, "aria-multiline": "true" }
    : { "aria-multiline": "true" };
}

// A palette card dropped into the text is placed where it fell.
export function dropComponent(editor, view, event) {
  const transfer = event.dataTransfer;
  if (!transfer || !Array.from(transfer.types || []).includes(COMPONENT_MIME)) return false;

  const controller = controllers.get(editor.options.element);
  if (!controller) return false;

  event.preventDefault();

  const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
  controller.place(transfer.getData(COMPONENT_MIME), at ? at.pos : null);

  return true;
}

export const ContentBridge = Extension.create({
  name: "contentBridge",

  // Tiptap's own stylesheet is a `<style>` it adds to the page, which this admin's policy refuses
  // without the page's nonce.
  onBeforeCreate() {
    const nonce = cspNonce();
    if (nonce) this.editor.setOptions({ injectNonce: nonce });
  },

  onCreate() {
    const surface = this.editor.options.element;
    const hook = surface && hooks.get(surface);

    if (hook) new ContentController(this.editor, hook).start();
  },

  onTransaction() {
    repaint(this.editor.options.element);
  },

  onDestroy() {
    const controller = controllers.get(this.editor.options.element);
    if (controller) controller.stop();
  },

  addProseMirrorPlugins() {
    const editor = this.editor;

    return [
      new Plugin({
        key: new PluginKey("mishkaContentPalette"),
        props: {
          handleDrop: (view, event) => dropComponent(editor, view, event),
          attributes: () => accessibleName(editor.options.element),
        },
      }),
    ];
  },
});

const ContentDragHandle = DragHandle.configure({
  render() {
    const element = document.createElement("div");

    element.dataset.role = "content-drag-handle";
    element.setAttribute("aria-hidden", "true");
    element.innerHTML = ICONS.grip;

    return element;
  },
});

export default {
  extensions: [
    ContentDirection,
    Image.configure({ inline: true }),
    MishkaComponent,
    ContentBridge,
    ContentDragHandle,
  ],
  starterKit: {
    link: {
      openOnClick: false,
      autolink: true,
      defaultProtocol: "https",
      HTMLAttributes: { target: null, rel: null },
    },
  },
};
