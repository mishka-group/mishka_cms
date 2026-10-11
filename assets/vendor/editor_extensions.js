// Editor configuration — the CMS's own, in the file Mishka Chelekom's headless `editor` engine
// (`editor.js` beside it, copied unchanged) imports as its extensions. Everything the CMS adds to
// the engine is here: the component block and its code view, the palette's click and drop, a marker
// typed into the text becoming a block, the block handle, the toolbar commands the engine has no
// entry for, and the questions an editor asks the server.
//
// The engine builds every editor from this one module, so what belongs to one editor is read off
// its surface's data-* and kept on that editor's `ContentController`:
//
//   data-root-id     the editor's root, where its toolbar, palette and settings are
//   data-value-id    the hidden textarea the form submits
//   data-components  the server half — `ContentComponentPicker` — every question is pushed to
//   data-label-*     the words this file shows, already in the reader's language
//
// A component's settings are a drawer the server draws at the side of the page, outside the editor;
// it writes each change back as `applied`, which the block being edited takes. What a component
// holds is also moved on its block, by the grip each part shows under the pointer, and a card
// dropped on a component that takes others goes in among them.
//
// THE SERVER IS THE ONLY READER AND WRITER OF THE MARKER. A component block holds its marker as an
// opaque string the server wrote; this file never reads one apart or puts one together.

import { Extension, Node, getHTMLFromFragment } from "@tiptap/core";
import { Fragment } from "@tiptap/pm/model";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import Image from "@tiptap/extension-image";

export const COMPONENT_MIME = "application/x-mishka-component";
export const BLOCK_MIME = "application/x-mishka-block";
export const EVENT = "mishka:content_editor";

// How long the text rests before a marker typed into it is read.
export const TYPED_WAIT = 600;

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

// A marker holding block markup — a paragraph or a list inside a component — cannot sit in a
// paragraph, which would be taken apart around it, so it is written outside any element, as the
// server also reads a block.
//
// THE EDITOR WRITES EACH NODE AS ONE ELEMENT, and threw on the loose nodes such a marker parses to:
// a banner or a timeline holding a heading stopped every write of the content, and the post was
// saved without them. So the marker is held in a `mishka-marker` element, which the HTML the editor
// writes loses (`unwrapped/1`).
const BLOCK_MARKUP = /<(p|div|h[1-6]|ul|ol|li|dl|blockquote|pre|table|section|article|figure|hr|header|footer|aside|nav)[\s>/]/i;
const HOLDER = /<\/?mishka-marker>/g;

export function markerDOM(marker) {
  if (!BLOCK_MARKUP.test(marker || "")) return markerParagraph(marker);

  inert = inert || document.implementation.createHTMLDocument("");

  const holder = inert.createElement("mishka-marker");
  holder.innerHTML = marker;

  return holder;
}

export function unwrapped(html) {
  return html.replace(HOLDER, "");
}

export function escapeAttribute(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// The document the server's segments describe: its HTML as it is — its code blocks as their text,
// `codeAsText/1` — and each component as the element the block parses from.
export function contentFrom(segments) {
  return (segments || [])
    .map((segment) =>
      segment.type === "component"
        ? `<div data-mishka-component="" data-name="${escapeAttribute(segment.name)}" data-marker="${escapeAttribute(segment.marker)}"></div>`
        : codeAsText(segment.html || ""),
    )
    .join("");
}

// HIGHLIGHTED CODE KEEPS ITS LINES. Tiptap takes every text node that is a line break alone — `\n`,
// or `\n` and two spaces — out of the HTML it is handed, before it reads it; and a block the old
// site highlighted holds just that between its tokens, `<span class="w">\n</span>`, so
// `# Export the set` and `mix export` on the next line opened as `# Export the setmix export`, and
// were saved so. A code block holds plain text in the editor anyway: each is handed over as its text,
// with a `<br>` in it as a line break, and the server highlights it again when it is saved.
export function codeAsText(html) {
  if (typeof html !== "string" || !/<pre[\s>]/i.test(html)) return html;

  inert = inert || document.implementation.createHTMLDocument("");

  const holder = inert.createElement("div");
  holder.innerHTML = html;

  let marked = false;

  for (const pre of holder.querySelectorAll("pre")) {
    const code = Array.from(pre.children).find((child) => child.tagName === "CODE") || pre;
    if (!code.firstElementChild) continue;

    for (const br of code.querySelectorAll("br")) br.replaceWith("\n");
    code.textContent = code.textContent;
    marked = true;
  }

  return marked ? holder.innerHTML : html;
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

// What every preview's shadow root starts with, before the site's stylesheet: a picture not chosen
// yet is an empty tinted square.
const PREVIEW_BASE =
  ":host{display:block}img:not([src]){min-width:4rem;min-height:4rem;border-radius:8px;background:#ecebf7}";

let base = null;

function previewBase() {
  if (base === null && typeof CSSStyleSheet === "function" && "replaceSync" in CSSStyleSheet.prototype) {
    base = new CSSStyleSheet();
    base.replaceSync(PREVIEW_BASE);
  }

  return base;
}

// The shadow root a preview is drawn in: the site's stylesheet, linked once it is known, then the
// drawn component.
export function previewRoot(host) {
  const root = host.attachShadow({ mode: "open" });
  const sheet = document.createElement("link");
  const drawn = document.createElement("div");

  sheet.rel = "stylesheet";
  drawn.dataset.role = "content-component-drawn";

  const shared = previewBase();
  if (shared && "adoptedStyleSheets" in root) root.adoptedStyleSheets = [shared];

  root.append(sheet, drawn);

  return { sheet, drawn };
}

const ICONS = {
  edit: `<svg ${SVG}><path d="m5.433 13.917 1.262-3.155A4 4 0 0 1 7.58 9.42l6.92-6.918a2.121 2.121 0 0 1 3 3l-6.92 6.918c-.383.383-.84.685-1.343.886l-3.154 1.262a.5.5 0 0 1-.65-.65Z"/><path d="M3.5 5.75c0-.69.56-1.25 1.25-1.25H10A.75.75 0 0 0 10 3H4.75A2.75 2.75 0 0 0 2 5.75v9.5A2.75 2.75 0 0 0 4.75 18h9.5A2.75 2.75 0 0 0 17 15.25V10a.75.75 0 0 0-1.5 0v5.25c0 .69-.56 1.25-1.25 1.25h-9.5c-.69 0-1.25-.56-1.25-1.25v-9.5Z"/></svg>`,
  remove: `<svg ${SVG}><path fill-rule="evenodd" d="M8.75 1A2.75 2.75 0 0 0 6 3.75v.443c-.795.077-1.584.176-2.365.298a.75.75 0 1 0 .23 1.482l.149-.022.841 10.518A2.75 2.75 0 0 0 7.596 19h4.807a2.75 2.75 0 0 0 2.742-2.53l.841-10.52.149.023a.75.75 0 0 0 .23-1.482A41.03 41.03 0 0 0 14 4.193V3.75A2.75 2.75 0 0 0 11.25 1h-2.5ZM10 4c.84 0 1.673.025 2.5.075V3.75c0-.69-.56-1.25-1.25-1.25h-2.5c-.69 0-1.25.56-1.25 1.25v.325C8.327 4.025 9.16 4 10 4ZM8.58 7.72a.75.75 0 0 0-1.5.06l.3 7.5a.75.75 0 1 0 1.5-.06l-.3-7.5Zm4.34.06a.75.75 0 1 0-1.5-.06l-.3 7.5a.75.75 0 1 0 1.5.06l.3-7.5Z" clip-rule="evenodd"/></svg>`,
  code: `<svg ${SVG}><path fill-rule="evenodd" d="M6.28 5.22a.75.75 0 0 1 0 1.06L2.56 10l3.72 3.72a.75.75 0 0 1-1.06 1.06L.97 10.53a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Zm7.44 0a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L17.44 10l-3.72-3.72a.75.75 0 0 1 0-1.06ZM11.377 2.011a.75.75 0 0 1 .612.867l-2.5 14.5a.75.75 0 0 1-1.478-.255l2.5-14.5a.75.75 0 0 1 .866-.612Z" clip-rule="evenodd"/></svg>`,
  grip: `<svg ${SVG}><circle cx="7" cy="5" r="1.4"/><circle cx="13" cy="5" r="1.4"/><circle cx="7" cy="10" r="1.4"/><circle cx="13" cy="10" r="1.4"/><circle cx="7" cy="15" r="1.4"/><circle cx="13" cy="15" r="1.4"/></svg>`,
};

// ---- the parts a preview draws ----------------------------------------------------------------

const indexOf = (path) => Number(path.slice(path.lastIndexOf("-") + 1));

// The DOM's `Node.DOCUMENT_POSITION_FOLLOWING`; `Node` in this file is Tiptap's.
const FOLLOWING = 4;

// THE PARTS OF A PLACED COMPONENT, AS ITS PREVIEW DRAWS THEM. The server marks them in the preview
// (`ContentComponentPicker`'s `marked/1`): an empty `mishka-part` before each part drawn where the
// component draws what it holds, one ending each run, and one at the start of each slot entry with
// content of its own. This reads each part off the marks and takes the marks out, so the preview is
// drawn as the page draws it. A part is `{path, parent, group, nodes}` — `group` the siblings it
// moves among, a slot's entries apart from the rest — and its box is read off `nodes` when needed.
// Marks the browser moved out of place, as it does around a table, give no parts.
export function partsOf(drawn) {
  const marks = Array.from(drawn.querySelectorAll("mishka-part"));
  const ends = new Map();
  const groups = new Map();

  for (const mark of marks) {
    const { part, end, slot } = mark.dataset;

    if (end !== undefined) {
      if (!ends.has(end)) ends.set(end, mark);
      continue;
    }

    if (!part) continue;

    const parent = part.replace(/-\d+$/, "");
    const group = `${parent}:${slot || ""}`;
    const members = groups.get(group) || [];

    if (!members.some((member) => member.path === part))
      members.push({ path: part, parent, group, slot, mark });

    groups.set(group, members);
  }

  const parts = [];

  for (const members of groups.values()) {
    members.sort((a, b) => indexOf(a.path) - indexOf(b.path));

    const found = members[0].slot ? entries(members) : runs(members, ends.get(members[0].parent));
    if (found) parts.push(...found);
  }

  for (const mark of marks) mark.remove();

  return parts.map(({ path, parent, group, nodes }) => ({ path, parent, group, nodes }));
}

// Parts drawn one after another where the component draws what it holds: each is what lies between
// its mark and the next.
function runs(members, end) {
  const stops = [...members.map((member) => member.mark), end];
  const parent = members[0].mark.parentNode;

  if (!end || stops.some((stop) => stop.parentNode !== parent)) return null;

  const found = [];

  for (let i = 0; i < members.length; i++) {
    const nodes = [];
    let node = members[i].mark.nextSibling;

    for (; node && node !== stops[i + 1]; node = node.nextSibling) nodes.push(node);
    if (!node) return null;

    found.push({ ...members[i], nodes });
  }

  return found;
}

// A slot's entries, drawn wherever the component puts them: each is the element, under the one
// holding all of them, that holds its mark.
function entries(members) {
  if (members.length < 2) return null;

  let common = members[0].mark.parentNode;
  while (common && !members.every(({ mark }) => common.contains(mark))) common = common.parentNode;
  if (!common) return null;

  const boxes = members.map(({ mark }) => {
    let el = mark;
    while (el.parentNode !== common) el = el.parentNode;
    return el;
  });

  const apart = boxes.every(
    (box, i) =>
      box !== members[i].mark &&
      (i === 0 || boxes[i - 1].compareDocumentPosition(box) & FOLLOWING),
  );

  return apart ? members.map((member, i) => ({ ...member, nodes: [boxes[i]] })) : null;
}

// The box a part is drawn in, on the screen; `null` when it draws nothing there.
export function boxOf(part) {
  let box = null;

  for (const node of part.nodes) {
    if (!node.isConnected) continue;

    let rect = null;

    if (node.nodeType === 1) rect = node.getBoundingClientRect();
    else if (node.nodeType === 3 && node.textContent.trim()) {
      const range = node.ownerDocument.createRange();
      range.selectNodeContents(node);
      rect = range.getBoundingClientRect();
    }

    if (!rect || (rect.width === 0 && rect.height === 0)) continue;

    box = box
      ? {
          left: Math.min(box.left, rect.left),
          top: Math.min(box.top, rect.top),
          right: Math.max(box.right, rect.right),
          bottom: Math.max(box.bottom, rect.bottom),
        }
      : { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
  }

  return box;
}

// WHERE A POINT FALLS AMONG PARTS drawn one under another, or side by side: beside the nearest, and
// after it when past its middle — `{part, after, box, across}`, `null` when none is drawn.
export function besideOf(parts, x, y) {
  const drawn = parts.map((part) => ({ part, box: boxOf(part) })).filter(({ box }) => box);
  if (!drawn.length) return null;

  const [a, b] = drawn;
  const across =
    !!b &&
    Math.abs(a.box.top - b.box.top) < Math.min(a.box.bottom - a.box.top, b.box.bottom - b.box.top) / 2 &&
    a.box.left !== b.box.left;
  const backwards = across && b.box.left < a.box.left;

  let nearest = null;

  for (const entry of drawn) {
    const { left, top, right, bottom } = entry.box;
    const dx = Math.max(left - x, 0, x - right);
    const dy = Math.max(top - y, 0, y - bottom);
    const distance = dx * dx + dy * dy;

    if (!nearest || distance < nearest.distance) nearest = { ...entry, distance };
  }

  const { box } = nearest;
  const after = across ? x > (box.left + box.right) / 2 !== backwards : y > (box.top + box.bottom) / 2;

  return { part: nearest.part, after, box, across, backwards };
}

// A COMPONENT PINNED TO THE SCREEN IS DRAWN IN ITS PLACE in the preview: a banner `fixed` to the top
// of the page drew outside its block, which showed nothing, and what was dropped into it was seen
// nowhere.
export function unpin(drawn) {
  for (const el of drawn.querySelectorAll("*"))
    if (getComputedStyle(el).position === "fixed") el.style.position = "relative";
}

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

// The block in the editor: its name, Code, Settings and Remove, and the component drawn as the
// server previews it. The preview is shown and never edited, and `inert` keeps every click and
// binding in it from reaching the page. A double click on the block opens its settings, as
// Settings does — not on its own buttons, nor while its code is open.
//
// WHAT IT HOLDS MOVES ON THE BLOCK: the part under the pointer is outlined and shows a grip, and
// the grip drags it among its siblings — a line shows where it goes — and the server writes the
// new order (`reorder`). A card dragged over a component that takes others shows the same line
// among what it holds.
//
// THE PREVIEW IS DRAWN IN A SHADOW ROOT, with the site's stylesheet the server names (`styles`):
// the admin's own holds none of a kit's colours or variants, and the site's must not restyle the
// admin around it.
//
// CODE SHOWS THE MARKER ITSELF, to change by hand; pressed again, the server reads what was written
// and the block takes it — or, when it is not one component, says so and stays on the code.
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

  const code = iconButton("code", labels.labelCode, ICONS.code);
  const edit = iconButton("edit", labels.labelEdit, ICONS.edit);
  const remove = iconButton("remove", labels.labelRemove, ICONS.remove);
  code.setAttribute("aria-pressed", "false");

  const preview = document.createElement("div");
  preview.dataset.role = "content-component-preview";
  preview.setAttribute("inert", "");
  preview.setAttribute("data-empty", "");

  const { sheet, drawn } = previewRoot(preview);

  const source = document.createElement("textarea");
  source.dataset.role = "content-component-code";
  source.dir = "ltr";
  source.spellcheck = false;
  source.rows = 4;
  source.hidden = true;
  if (labels.labelCode) source.setAttribute("aria-label", labels.labelCode);

  const fault = document.createElement("p");
  fault.dataset.role = "content-component-code-error";
  fault.hidden = true;

  const outline = document.createElement("div");
  outline.dataset.role = "content-part-outline";
  outline.hidden = true;

  const line = document.createElement("div");
  line.dataset.role = "content-part-line";
  line.hidden = true;

  const grip = iconButton("move-part", labels.labelMovePart, ICONS.grip);
  grip.dataset.role = "content-part-grip";
  grip.hidden = true;

  head.append(name, code, edit, remove);
  dom.append(head, preview, source, fault, outline, line, grip);

  sheet.addEventListener("load", () => unpin(drawn));

  let painted = null;
  let parts = [];
  let hovered = null;
  let moving = null;

  // A screen box as a place inside the block.
  const place = (el, box, sized = true) => {
    const frame = dom.getBoundingClientRect();

    el.style.left = `${box.left - frame.left - dom.clientLeft}px`;
    el.style.top = `${box.top - frame.top - dom.clientTop}px`;
    if (!sized) return;

    el.style.width = `${box.right - box.left}px`;
    el.style.height = `${box.bottom - box.top}px`;
  };

  const showLine = ({ box, after, across, backwards }) => {
    const edge = after !== backwards;
    const at = across
      ? { left: edge ? box.right : box.left, right: (edge ? box.right : box.left) + 2, top: box.top, bottom: box.bottom }
      : { left: box.left, right: box.right, top: after ? box.bottom : box.top, bottom: (after ? box.bottom : box.top) + 2 };

    place(line, { ...at, left: at.left - (across ? 1 : 0), top: at.top - (across ? 0 : 1) });
    line.hidden = false;
  };

  const siblings = (part) => parts.filter((other) => other.group === part.group && boxOf(other));
  const depth = (part) => part.path.split("-").length;

  // The part under a point that can move: the innermost, among siblings it can move past.
  const partAt = (x, y) => {
    let found = null;

    for (const part of parts) {
      const box = boxOf(part);
      if (!box || x < box.left || x > box.right || y < box.top || y > box.bottom) continue;
      if (siblings(part).length < 2) continue;
      if (!found || depth(part) > depth(found)) found = part;
    }

    return found;
  };

  const rest = () => {
    hovered = null;
    moving = null;
    outline.hidden = true;
    line.hidden = true;
    grip.hidden = true;
  };

  const hover = (event) => {
    if (moving) return;

    const part = view.coding() ? null : partAt(event.clientX, event.clientY);
    if (part === hovered) return;

    hovered = part;
    outline.hidden = grip.hidden = !part;
    if (!part) return;

    const box = boxOf(part);
    place(outline, box);
    place(grip, { left: box.left + 2, top: box.top + 2 }, false);
  };

  const coding = (on) => {
    source.hidden = !on;
    fault.hidden = true;
    code.setAttribute("aria-pressed", String(on));
    toggle(dom, "data-code", on);
  };

  const view = {
    dom,

    coding() {
      return dom.hasAttribute("data-code");
    },

    code() {
      if (!view.coding()) {
        source.value = node.attrs.marker;
        coding(true);
        source.focus();
        return Promise.resolve(true);
      }

      const written = source.value.trim();
      if (written === node.attrs.marker) {
        coding(false);
        return Promise.resolve(true);
      }

      const controller = controllerOf(surface);
      if (!controller) return Promise.resolve(false);

      return controller.rewrite(getPos(), node.attrs.marker, written).then((done) => {
        if (done) coding(false);
        else {
          fault.textContent = labels.labelCodeError || "";
          fault.hidden = false;
        }

        return done;
      });
    },

    paint() {
      name.textContent = node.attrs.name;

      const controller = controllerOf(surface);
      const html = (controller && controller.previewOf(node.attrs.marker)) || "";
      const styles = controller && controller.shown ? controller.styles : null;

      if (!styles) sheet.removeAttribute("href");
      else if (sheet.getAttribute("href") !== styles) sheet.setAttribute("href", styles);

      if (html === painted) return;
      painted = html;
      drawn.innerHTML = html;
      parts = partsOf(drawn);
      unpin(drawn);
      rest();
      toggle(preview, "data-empty", html === "");
    },

    pos() {
      return getPos();
    },

    // Where a card dropped at a point goes among what this component draws where it draws what it
    // holds — `{beside, after}`, shown as a line — or `{}`, at the end, when it draws none.
    dropAt(x, y) {
      const target = besideOf(
        parts.filter((part) => part.group === "r:"),
        x,
        y,
      );

      if (!target) {
        line.hidden = true;
        return {};
      }

      showLine(target);
      return { beside: target.part.path, after: target.after };
    },

    dropDone() {
      line.hidden = true;
    },

    update(updated) {
      if (updated.type !== node.type) return false;
      node = updated;
      view.paint();
      return true;
    },

    stopEvent(event) {
      return !!(event.target && event.target.closest && event.target.closest("button, textarea"));
    },

    ignoreMutation() {
      return true;
    },

    destroy() {
      const controller = controllerOf(surface);
      if (controller) controller.views.delete(view);
    },
  };

  code.addEventListener("click", (event) => {
    event.preventDefault();
    view.code();
  });

  const settings = (event) => {
    event.preventDefault();
    const controller = controllerOf(surface);
    if (controller) controller.edit(getPos(), node.attrs.marker);
  };

  edit.addEventListener("click", settings);

  dom.addEventListener("dblclick", (event) => {
    if (view.coding() || event.target.closest("button, textarea")) return;
    settings(event);
  });

  dom.addEventListener("pointermove", hover);
  dom.addEventListener("pointerleave", () => {
    if (!moving) rest();
  });

  // The block itself is dragged by the editor; a part's grip is not.
  dom.addEventListener("dragstart", (event) => {
    if (!moving) return;
    event.preventDefault();
    event.stopPropagation();
  });

  grip.addEventListener("mousedown", (event) => event.preventDefault());

  grip.addEventListener("pointerdown", (event) => {
    if (!hovered || event.button !== 0) return;

    if (grip.setPointerCapture) grip.setPointerCapture(event.pointerId);
    moving = { part: hovered, siblings: siblings(hovered), target: null };
  });

  grip.addEventListener("pointermove", (event) => {
    if (!moving) return;

    // Near an edge of the editor the editor scrolls, so a part goes past what it shows.
    const frame = surface.getBoundingClientRect();
    if (event.clientY < frame.top + 32) surface.scrollTop -= 16;
    else if (event.clientY > frame.bottom - 32) surface.scrollTop += 16;

    moving.target = besideOf(moving.siblings, event.clientX, event.clientY);
    if (moving.target) showLine(moving.target);
  });

  grip.addEventListener("pointerup", () => {
    const done = moving;
    rest();
    if (!done || !done.target) return;

    const { part, siblings: all, target } = done;
    const from = all.indexOf(part);
    const to = all.indexOf(target.part);
    const stays = to === from || to === from + (target.after ? -1 : 1);

    const controller = controllerOf(surface);
    if (!stays && controller)
      controller.reorder(getPos(), node.attrs.marker, part.path, target.part.path, target.after);
  });

  grip.addEventListener("pointercancel", rest);

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
    return markerDOM(node.attrs.marker);
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
    this.serial = 0;
    this.scanning = null;
    this.styles = null;
    this.shown = true;
    this.watching = null;
    this.holders = new Set();
    this.dropping = null;
  }

  start() {
    this.onClick = (event) => this.click(event);
    this.onDragStart = (event) => this.dragStart(event);
    this.onOutside = (event) => this.outside(event);
    this.onKey = (event) => this.key(event);
    this.onDragOver = (event) => this.dragOver(event);
    this.onDragLeave = (event) => {
      if (!this.surface.contains(event.relatedTarget)) this.dropEnd();
    };
    this.onDropEnd = () => this.dropEnd();

    this.root.addEventListener("click", this.onClick);
    this.root.addEventListener("dragstart", this.onDragStart);
    this.root.addEventListener("dragend", this.onDropEnd);
    this.surface.addEventListener("dragover", this.onDragOver);
    this.surface.addEventListener("dragleave", this.onDragLeave);
    this.surface.addEventListener("drop", this.onDropEnd);
    document.addEventListener("pointerdown", this.onOutside, true);
    document.addEventListener("keydown", this.onKey);
    this.ref = this.hook.handleEvent(EVENT, (payload) => this.receive(payload));

    controllers.set(this.surface, this);
    this.repaint();
    this.watch();

    return this.load();
  }

  // A CLOSED MODAL HIDES THE EDITOR AND KEEPS IT, so the previews let go of the site's stylesheet
  // while the editor is out of sight, and take it again — from the browser's cache — when it is
  // shown. A modal opens and closes by the `style`, `class` or `hidden` of an element around the
  // editor, so those are watched, and the editor's own box answers whether it is seen.
  watch() {
    if (typeof MutationObserver !== "function") return;

    this.watching = new MutationObserver(() => this.visibility());

    for (let el = this.root.parentElement; el && el !== document.body; el = el.parentElement)
      this.watching.observe(el, { attributes: true, attributeFilter: ["style", "class", "hidden"] });
  }

  visibility() {
    const shown = this.root.getClientRects().length > 0;
    if (shown === this.shown) return;

    this.shown = shown;
    for (const view of this.views) view.paint();
  }

  stop() {
    this.root.removeEventListener("click", this.onClick);
    this.root.removeEventListener("dragstart", this.onDragStart);
    this.root.removeEventListener("dragend", this.onDropEnd);
    this.surface.removeEventListener("dragover", this.onDragOver);
    this.surface.removeEventListener("dragleave", this.onDragLeave);
    this.surface.removeEventListener("drop", this.onDropEnd);
    document.removeEventListener("pointerdown", this.onOutside, true);
    document.removeEventListener("keydown", this.onKey);
    if (this.ref) this.hook.removeHandleEvent(this.ref);
    if (this.watching) this.watching.disconnect();
    clearTimeout(this.scanning);

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

    return this.request("segments", { html }).then(({ segments, styles }) => {
      if (styles) this.restyle(styles);
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
    if (payload.styles) this.restyle(payload.styles);
    if (payload.holders) this.holders = new Set(payload.holders);

    for (const { marker, preview } of payload.previews || []) this.previews.set(marker, preview || "");
    for (const view of this.views) view.paint();

    const current = this.editing && payload.serial === this.editing.serial;

    if (payload.applied && current) this.follow(payload.applied);
    if (payload.done && current) this.editing = null;
  }

  previewOf(marker) {
    return this.previews.get(marker);
  }

  restyle(href) {
    if (this.styles === href) return;

    this.styles = href;
    for (const view of this.views) view.paint();
  }

  panel() {
    return this.root.querySelector("[data-role='content-editor-panel']");
  }

  drawer() {
    const id = this.surface.dataset.rootId;

    for (const drawer of document.querySelectorAll("[data-role='content-editor-drawer']"))
      if (drawer.dataset.editor === id) return drawer;

    return null;
  }

  // A PRESS ANYWHERE ELSE CLOSES what is open: the palette, unless it was its own button that was
  // pressed, which toggles it; and the settings drawer, whose changes are already in the content.
  outside(event) {
    const target = event.target;
    if (!target || !target.closest) return;

    const panel = this.panel();
    const toggle = this.target && document.getElementById(`${this.target.slice(1)}-toggle`);

    if (panel && !panel.contains(target) && !(toggle && toggle.contains(target)))
      this.request("close", {});

    const drawer = this.drawer();
    if (drawer && !drawer.contains(target) && !this.reshaping(target))
      this.request("settings_done", {});
  }

  // A part's grip pressed on the block whose settings are open: they follow what it moves.
  reshaping(target) {
    const grip = target.closest("[data-role='content-part-grip']");
    const view = grip && this.viewOf(grip.closest("[data-role='content-component']"));

    return !!view && !!this.editingAt(view.pos());
  }

  viewOf(dom) {
    for (const view of this.views) if (view.dom === dom) return view;

    return null;
  }

  // The settings open on the block at `pos`, if they are.
  editingAt(pos) {
    const editing = this.editing;
    return editing && this.locate(editing.marker, editing.pos) === pos ? editing : null;
  }

  // A CARD DRAGGED OVER A COMPONENT THAT TAKES OTHERS lights it up, and a line among what it holds
  // shows where the card goes; the editor's own line between blocks is hidden while it does.
  dragOver(event) {
    const types = Array.from((event.dataTransfer && event.dataTransfer.types) || []);
    const card = types.includes(COMPONENT_MIME) || types.includes(BLOCK_MIME);
    const onto = card ? placedUnder(this.editor, this.editor.view, event.target) : null;
    const view = onto && this.holders.has(onto.name) ? this.viewOf(onto.dom) : null;

    if (this.dropping && this.dropping !== view) this.dropEnd();
    if (!view) return;

    this.dropping = view;
    view.dom.setAttribute("data-drop-inside", "");
    this.surface.setAttribute("data-drop-inside", "");
    view.dropAt(event.clientX, event.clientY);
  }

  dropEnd() {
    if (this.dropping) {
      this.dropping.dom.removeAttribute("data-drop-inside");
      this.dropping.dropDone();
    }

    this.dropping = null;
    this.surface.removeAttribute("data-drop-inside");
  }

  // Where a card dropped on the block `onto` goes among what it holds.
  insideAt(onto, event) {
    const view = this.holders.has(onto.name) ? this.viewOf(onto.dom) : null;
    return view ? view.dropAt(event.clientX, event.clientY) : {};
  }

  key(event) {
    if (event.key !== "Escape") return;

    if (this.drawer()) this.request("settings_done", {});
    else if (this.panel()) this.request("close", {});
  }

  click(event) {
    const card = event.target.closest("[data-component-card]");
    if (card) {
      event.preventDefault();
      return this.place(card.dataset.componentCard, null);
    }

    const block = event.target.closest("[data-block-card]");
    if (block) {
      event.preventDefault();
      return this.placeBlock(block.dataset.blockCard, null);
    }

    const tool = event.target.closest("[data-editor-command]");
    const extra = tool && EXTRA[tool.dataset.editorCommand];
    if (extra) {
      event.preventDefault();
      extra(this);
    }
  }

  dragStart(event) {
    const card = event.target.closest && event.target.closest("[data-component-card], [data-block-card]");
    if (!card || !event.dataTransfer) return;

    if (card.dataset.blockCard) event.dataTransfer.setData(BLOCK_MIME, card.dataset.blockCard);
    else event.dataTransfer.setData(COMPONENT_MIME, card.dataset.componentCard);

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

  // A ready-made block, placed and opened: it is there to have its words changed.
  placeBlock(id, at) {
    return this.request("block", { id }).then((reply) => {
      if (!reply.marker) return null;

      const pos = this.insert(reply, at);
      if (pos !== null) this.edit(pos, reply.marker);

      return pos;
    });
  }

  // A component, or a ready-made block (`child` is `{name}` or `{block}`), dropped on a placed one
  // goes inside it — beside the part `inside` names, or at the end — when that one holds content;
  // otherwise it is placed where it fell. With the settings open on that one, they take it.
  nest(pos, marker, child, at, inside = {}) {
    const editing = this.editingAt(pos);
    const payload = { marker, ...child, ...inside };
    if (editing) payload.serial = editing.serial;

    return this.request("nest", payload).then((reply) => {
      if (reply.ok) return pos;
      if (!reply.marker) return child.block ? this.placeBlock(child.block, at) : this.place(child.name, at);

      const found = this.locate(marker, pos);
      if (found === null) return null;

      this.markup(found, reply);
      return found;
    });
  }

  // The part `path` of the block at `pos` moved before — or `after` — its sibling `beside`, as the
  // server writes it. With the settings open on that block, they take it.
  reorder(pos, marker, path, beside, after) {
    const editing = this.editingAt(pos);
    const payload = { marker, path, beside, after };
    if (editing) payload.serial = editing.serial;

    return this.request("reorder", payload).then((reply) => {
      if (!reply.marker) return null;

      const found = this.locate(marker, pos);
      if (found !== null) this.markup(found, reply);

      return found;
    });
  }

  insert({ name, marker }, at) {
    const node = { type: "mishkaComponent", attrs: { name, marker } };
    const near = typeof at === "number" ? at : this.editor.state.selection.from;
    const chain = this.editor.chain().focus();

    (typeof at === "number" ? chain.insertContentAt(at, node) : chain.insertContent(node)).run();

    const pos = this.locate(marker, near);
    if (pos !== null) this.after(pos);

    return pos;
  }

  // THE CURSOR GOES ON THE LINE AFTER A BLOCK JUST PLACED — one is added when none follows — so the
  // next thing written or placed lands below it. Left on the block, it would be selected, and the
  // next block placed would take its place.
  after(pos) {
    const { state, view } = this.editor;
    const node = state.doc.nodeAt(pos);
    if (!node) return;

    const end = pos + node.nodeSize;
    const next = state.doc.nodeAt(end);
    let tr = state.tr;

    if (!next || !next.isTextblock) tr = tr.insert(end, state.schema.nodes.paragraph.create());

    view.dispatch(tr.setSelection(TextSelection.create(tr.doc, end + 1)));
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

  // The block at `pos` takes another marker, without moving the focus — the author may be typing
  // in the settings.
  markup(pos, { name, marker }) {
    const { state, view } = this.editor;
    view.dispatch(state.tr.setNodeMarkup(pos, undefined, { name, marker }));
  }

  edit(pos, marker) {
    this.serial += 1;
    this.editing = { serial: this.serial, pos, marker };

    return this.request("edit", { marker, serial: this.serial });
  }

  // The block being edited, as the settings now write it.
  follow({ name, marker }) {
    const editing = this.editing;
    const pos = this.locate(editing.marker, editing.pos);

    if (pos === null) {
      this.editing = null;
      return;
    }

    this.markup(pos, { name, marker });
    this.editing = { ...editing, pos, marker };
  }

  // What the code view holds, read by the server: one component takes the block's place.
  rewrite(pos, marker, written) {
    return this.request("segments", { html: written }).then(({ segments }) => {
      const one = single(segments);
      if (!one) return false;

      const found = this.locate(marker, typeof pos === "number" ? pos : 0);
      if (found === null) return false;

      this.markup(found, one);
      return true;
    });
  }

  // A MARKER TYPED OR PASTED INTO THE TEXT becomes a block once it is whole and the text has rested:
  // a paragraph holding a marker and nothing else is sent to the server, and when it reads it as one
  // component that paragraph is the block. A marker sharing its line with other text stays text.
  scan() {
    clearTimeout(this.scanning);
    this.scanning = setTimeout(() => this.convert(), TYPED_WAIT);
  }

  convert() {
    if (this.editor.isDestroyed) return Promise.resolve();

    const { doc, schema } = this.editor.state;
    const found = [];

    doc.forEach((node, pos) => {
      if (node.type.name !== "paragraph" || !whole(node.textContent)) return;
      found.push({ pos, node, html: getHTMLFromFragment(Fragment.from(node), schema) });
    });

    return found.reduceRight(
      (done, { pos, node, html }) =>
        done.then(() =>
          this.request("segments", { html }).then(({ segments }) => {
            const one = single(segments);
            if (!one || this.editor.isDestroyed || this.editor.state.doc.nodeAt(pos) !== node) return;

            const block = this.editor.schema.nodes.mishkaComponent.create(one);
            const tr = this.editor.state.tr.replaceWith(pos, pos + node.nodeSize, block);

            this.editor.view.dispatch(tr);
          }),
        ),
      Promise.resolve(),
    );
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

// Text that is one marker from end to end: an opening one, then the closing of a self-closing
// marker or of a component. Whether it reads as one is the server's to say.
export function whole(text) {
  const trimmed = (text || "").trim();

  return (
    trimmed.startsWith("[[component ") &&
    (trimmed.endsWith("/]]") || trimmed.endsWith("[[/component]]"))
  );
}

// The one component segments hold, with nothing but spacing around it — or `null`.
export function single(segments) {
  const parts = segments || [];
  const components = parts.filter((segment) => segment.type === "component");
  const text = parts
    .filter((segment) => segment.type !== "component")
    .map((segment) => (segment.html || "").replace(/<\/?p[^>]*>/gi, "").trim())
    .join("");

  if (components.length !== 1 || text !== "") return null;

  return { name: components[0].name, marker: components[0].marker };
}

// The editable element is the textbox a reader reaches, so it carries the field's label — the id
// the surface names in `data-label-id` — and says it takes more than one line.
export function accessibleName(surface) {
  const label = surface && surface.dataset ? surface.dataset.labelId : null;

  return label
    ? { "aria-labelledby": label, "aria-multiline": "true" }
    : { "aria-multiline": "true" };
}

// A palette card dropped into the text is placed where it fell — or, dropped on a placed component,
// inside it.
export function dropComponent(editor, view, event) {
  const transfer = event.dataTransfer;
  const types = Array.from((transfer && transfer.types) || []);
  const block = types.includes(BLOCK_MIME);

  if (!block && !types.includes(COMPONENT_MIME)) return false;

  const controller = controllers.get(editor.options.element);
  if (!controller) return false;

  event.preventDefault();

  const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
  const pos = at ? at.pos : null;
  const onto = placedUnder(editor, view, event.target);
  const inside = onto ? controller.insideAt(onto, event) : {};
  const child = block ? { block: transfer.getData(BLOCK_MIME) } : { name: transfer.getData(COMPONENT_MIME) };

  controller.dropEnd();

  if (onto) controller.nest(onto.pos, onto.marker, child, pos, inside);
  else if (block) controller.placeBlock(child.block, pos);
  else controller.place(child.name, pos);

  return true;
}

// The placed component whose block `element` is in.
function placedUnder(editor, view, element) {
  const dom = element && element.closest && element.closest("[data-role='content-component']");
  if (!dom) return null;

  let found = null;

  editor.state.doc.descendants((node, pos) => {
    if (found || node.type.name !== "mishkaComponent") return;
    if (view.nodeDOM(pos) === dom) found = { pos, marker: node.attrs.marker, name: node.attrs.name, dom };
  });

  return found;
}

export const ContentBridge = Extension.create({
  name: "contentBridge",

  // Tiptap's own stylesheet is a `<style>` it adds to the page, which this admin's policy refuses
  // without the page's nonce.
  onBeforeCreate() {
    const nonce = cspNonce();
    if (nonce) this.editor.setOptions({ injectNonce: nonce });

    const content = this.editor.options.content;
    if (typeof content === "string") this.editor.setOptions({ content: codeAsText(content) });
  },

  onCreate() {
    const editor = this.editor;
    const surface = editor.options.element;
    const hook = surface && hooks.get(surface);
    const written = editor.getHTML.bind(editor);

    // What the engine stores and submits is what this writes.
    editor.getHTML = () => unwrapped(written());

    if (hook) new ContentController(this.editor, hook).start();
  },

  onTransaction() {
    repaint(this.editor.options.element);
  },

  onUpdate() {
    const controller = controllers.get(this.editor.options.element);
    if (controller) controller.scan();
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

// ---- the block handle ------------------------------------------------------------------------

// The top-level block beside `y` (a viewport coordinate): the one it is over, else the nearest, as
// `{pos, node, dom}`. `null` for an empty document.
export function blockAt(view, y) {
  const { doc } = view.state;
  let best = null;

  doc.forEach((node, pos) => {
    const dom = view.nodeDOM(pos);
    if (!dom || dom.nodeType !== 1) return;

    const rect = dom.getBoundingClientRect();
    const distance = y < rect.top ? rect.top - y : y >= rect.bottom ? y - rect.bottom : 0;

    if (best === null || distance < best.distance) best = { pos, node, dom, distance };
  });

  return best && { pos: best.pos, node: best.node, dom: best.dom };
}

function within(dom, y) {
  const rect = dom.getBoundingClientRect();
  return dom.isConnected && y >= rect.top && y < rect.bottom;
}

// Moves the top-level block holding the selection one place up (`-1`) or down (`1`), keeping the
// selection on it — Alt+↑ and Alt+↓. `false` when there is nowhere to move it, or the selection
// spans more than one block.
export function moveBlock(view, direction) {
  const { state } = view;
  const { selection, doc } = state;
  const index = selection.$from.index(0);

  const single =
    selection instanceof NodeSelection
      ? selection.$from.depth === 0
      : selection instanceof TextSelection && index === selection.$to.index(0);

  const target = index + direction;
  if (!single || index >= doc.childCount || target < 0 || target >= doc.childCount) return false;

  let start = 0;
  for (let i = 0; i < index; i++) start += doc.child(i).nodeSize;

  const node = doc.child(index);
  const neighbour = doc.child(target);
  const to = direction < 0 ? start - neighbour.nodeSize : start + neighbour.nodeSize;
  const delta = to - start;
  const tr = state.tr.delete(start, start + node.nodeSize).insert(to, node);

  tr.setSelection(
    selection instanceof NodeSelection
      ? NodeSelection.create(tr.doc, selection.from + delta)
      : TextSelection.create(tr.doc, selection.anchor + delta, selection.head + delta),
  );

  view.dispatch(tr.scrollIntoView());
  return true;
}

// THE HANDLE BESIDE THE BLOCK UNDER THE POINTER, which drags that block to another place. It lives
// on the surface, in the gutter its padding leaves, and is placed in the surface's own coordinates,
// so it scrolls with the text inside the surface and inside the modal around it.
//
// Its mousedown goes no further than itself. The engine moves the cursor to the end of the document
// for a mousedown anywhere on the surface outside the text — a click in the padding — and scrolls
// it into view, which is what threw the page down whenever the handle was pressed.
//
// A drag is ProseMirror's own: the block is selected, and `view.dragging` holds it as a move, so
// the drop cursor shows where it will land and the drop takes it out of its old place.
class BlockHandleView {
  constructor(view) {
    this.view = view;
    this.surface = view.dom.parentElement;
    this.block = null;
    this.dragging = null;

    const handle = document.createElement("div");
    handle.dataset.role = "content-drag-handle";
    handle.draggable = true;
    handle.setAttribute("aria-hidden", "true");
    handle.innerHTML = ICONS.grip;
    if (this.surface && this.surface.dataset.labelMove) handle.title = this.surface.dataset.labelMove;

    Object.assign(handle.style, { position: "absolute", display: "none", zIndex: "10" });
    this.handle = handle;

    this.onMove = (event) => this.track(event.clientY);
    this.onLeave = () => this.hide();
    this.onDown = (event) => event.stopPropagation();
    this.onDragStart = (event) => this.start(event);
    this.onDragEnd = () => this.end();

    handle.addEventListener("mousedown", this.onDown);
    handle.addEventListener("dragstart", this.onDragStart);
    handle.addEventListener("dragend", this.onDragEnd);

    if (this.surface) {
      this.surface.appendChild(handle);
      this.surface.addEventListener("mousemove", this.onMove);
      this.surface.addEventListener("mouseleave", this.onLeave);
    }
  }

  track(y) {
    if (this.dragging || !this.view.editable) return;
    if (this.block && within(this.block.dom, y)) return;

    const block = blockAt(this.view, y);
    if (block) this.show(block);
    else this.hide();
  }

  show(block) {
    const { surface, handle } = this;
    const box = surface.getBoundingClientRect();
    const rect = block.dom.getBoundingClientRect();
    const width = handle.offsetWidth || 20;
    const height = handle.offsetHeight || 24;
    const line = parseFloat(getComputedStyle(block.dom).lineHeight) || height;
    const rtl = getComputedStyle(this.view.dom).direction === "rtl";

    const top =
      rect.top - box.top - surface.clientTop + surface.scrollTop + Math.max(0, (line - height) / 2);

    const left = rtl
      ? rect.right - box.left - surface.clientLeft + surface.scrollLeft + 6
      : rect.left - box.left - surface.clientLeft + surface.scrollLeft - width - 6;

    this.block = block;
    Object.assign(handle.style, { display: "", top: `${top}px`, left: `${left}px` });
  }

  hide() {
    if (this.dragging) return;

    this.block = null;
    this.handle.style.display = "none";
  }

  start(event) {
    const { view, block } = this;
    if (!block || !event.dataTransfer) return;

    const { state } = view;
    if (!state.doc.nodeAt(block.pos)) return;

    const selection = NodeSelection.create(state.doc, block.pos);
    const slice = selection.content();

    event.dataTransfer.clearData();
    event.dataTransfer.setData("text/html", unwrapped(getHTMLFromFragment(slice.content, state.schema)));
    event.dataTransfer.setData(
      "text/plain",
      slice.content.textBetween(0, slice.content.size, "\n\n"),
    );
    event.dataTransfer.effectAllowed = "copyMove";
    if (event.dataTransfer.setDragImage) event.dataTransfer.setDragImage(block.dom, 0, 0);

    this.dragging = { slice, move: true, node: selection };
    this.handle.dataset.dragging = "true";

    view.dragging = this.dragging;
    view.dispatch(state.tr.setSelection(selection));
  }

  // A drop clears `view.dragging` itself; a drag dropped nowhere leaves it to be cleared here.
  end() {
    const { view, dragging } = this;

    this.dragging = null;
    this.handle.dataset.dragging = "false";
    if (view.dragging === dragging) view.dragging = null;

    this.hide();
  }

  update(view, previous) {
    this.view = view;

    if (this.dragging) return;
    if (!view.editable || (previous && !previous.doc.eq(view.state.doc))) this.hide();
  }

  destroy() {
    const { surface, handle } = this;

    handle.removeEventListener("mousedown", this.onDown);
    handle.removeEventListener("dragstart", this.onDragStart);
    handle.removeEventListener("dragend", this.onDragEnd);
    handle.remove();

    if (surface) {
      surface.removeEventListener("mousemove", this.onMove);
      surface.removeEventListener("mouseleave", this.onLeave);
    }
  }
}

export const BlockHandle = Extension.create({
  name: "contentBlockHandle",

  addKeyboardShortcuts() {
    return {
      "Alt-ArrowUp": () => moveBlock(this.editor.view, -1),
      "Alt-ArrowDown": () => moveBlock(this.editor.view, 1),
    };
  },

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey("mishkaBlockHandle"),
        view: (view) => new BlockHandleView(view),
      }),
    ];
  },
});

export default {
  extensions: [
    ContentDirection,
    Image.configure({ inline: true }),
    MishkaComponent,
    ContentBridge,
    BlockHandle,
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
