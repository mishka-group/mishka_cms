// THE HOOKS ONLY THE ADMIN EVER MOUNTS — the page builder, the dashboard's widget grid, the review
// composer's `@` list, the Assets dropzone. No public template names one of these, and the elements
// they attach to exist only under /admin.
//
// They live here rather than in `app.js` so the RUNTIME JAVASCRIPT COMPILER can leave them out. That
// compiler builds each site's bundle with `app.js` as its entry point, so every hook below — and
// `sortablejs` with them — was being shipped to every visitor of every site, to sit unmounted.
//
// `app.js` reaches them through `if (MISHKA_ADMIN)`, which esbuild replaces at build time: true for
// the admin bundle, false for a site's, where the branch and this whole module are then dropped.

import Sortable from "sortablejs";
import {
  axisOf,
  edgeVelocity,
  formCaption,
  formLanding,
  resolveDrop as resolveDropAt,
  indicatorBox,
} from "./pb_drop";
import { mentionAt, withMention } from "./pb_mention";

// WHAT A DRAG IS CARRYING, readable while it is still in flight.
//
// A drag crosses between three surfaces — the palette, the layers rail and the canvas iframe — and
// only the surface it STARTED on holds the hook state that says what is moving. Everything else has
// the dataTransfer, whose values are sealed until `drop` but whose TYPE LIST is legible throughout,
// so the type itself is the message: this gesture is moving an existing node, answer it "move".
//
// `text/plain` cannot carry it. Firefox refuses to start a drag with no payload at all, so every
// source already sets it, and a receiving surface reading it could not tell a node from a template
// from a text selection dragged in off the desktop.
const NODE_MIME = "application/x-pb-node";
const TEMPLATE_MIME = "application/x-pb-template";

// Whether a field is being dragged, on a frame's root element: the canvas outlines its forms while
// it is set.
function markFieldDrag(doc, field) {
  if (!doc || !doc.documentElement) return;
  if (field) doc.documentElement.setAttribute("data-pb-field-drag", "true");
  else doc.documentElement.removeAttribute("data-pb-field-drag");
}

// THE DROPZONE IS THE SUBMIT, in the editor's Assets sheet. That sheet is 620px of overlay beside a
// canvas, and a Create button in it is a second step for something the drop already said: put this
// file in this folder. The form is mounted with `submit={false}` so Gervaz draws no button; this is
// what presses it.
//
// IT WATCHES THE INPUT, NOT THE EVENTS. Listening for `change`/`input` looks obvious and is wrong:
// LiveView stages the file in its OWN listener, and a listener that runs first submits a form that
// has no files yet. That is not a race to lose carefully — the picker path always loses it, because
// a capture listener on this container runs before LiveView's on the document. The file then sits
// staged at 0% forever, which is exactly what it did.
//
// `data-phx-active-refs` is LiveView's own record of what is staged, and `data-phx-preflighted-refs`
// of what it has already begun. A ref in the first and not the second is a file waiting to go, and
// that is true however it arrived — dropped or picked. Submitting moves the ref into preflighted,
// so the next mutation finds nothing waiting: no timer, no debounce, no double upload.
const UploadSubmitsItself = {
  mounted() {
    this.watch();
  },
  updated() {
    // A save replaces the input with a fresh one, and the observer is still on the old node.
    this.watch();
  },
  watch() {
    const input = this.el.querySelector('input[type="file"]');
    if (!input || input === this.input) return;

    this.observer?.disconnect();
    this.input = input;
    this.observer = new MutationObserver(() => this.submitWaiting());
    this.observer.observe(input, {
      attributes: true,
      attributeFilter: ["data-phx-active-refs", "data-phx-preflighted-refs"],
    });

    // A file may already be staged — a reconnect, or one left behind by an earlier failure.
    this.submitWaiting();
  },
  submitWaiting() {
    const refs = (name) =>
      (this.input.getAttribute(name) || "").split(",").filter((ref) => ref !== "");

    const started = refs("data-phx-preflighted-refs");
    const waiting = refs("data-phx-active-refs").filter((ref) => !started.includes(ref));

    if (waiting.length > 0) this.input.form?.requestSubmit();
  },
  destroyed() {
    this.observer?.disconnect();
  },
};

// A THUMBNAIL WHOSE IMAGE MAY NEVER ARRIVE — the media gallery's cards, the Assets sheet's rows, the
// media table's preview cell. Every one of them paints a type glyph BEHIND the <img>, so a file that
// no longer exists on disk only has to get the image out of the way for the glyph to be what you
// see. A loaded image gets a background of its own where the element asks for one, or a transparent
// PNG picks up the tile's tint instead of sitting on paper.
//
// It exists because `onload=`/`onerror=` cannot: an enforced CSP blocks inline event handlers
// outright, and there is no nonce or hash that applies to them — the attribute is the violation.
// A listener bound from the admin bundle is ordinary same-origin script, which the policy allows.
//
// THE `complete` CHECK IS THE PART THE ATTRIBUTES DID NOT NEED. They were parsed before the request
// started, so no event could be missed. A hook mounts after the element is in the document, and a
// cached image is already finished by then — it will never fire `load` again, and without this every
// second visit to the page would show the glyph under an image that is perfectly fine.
const MediaThumb = {
  mounted() {
    this.sync();
  },
  updated() {
    this.sync();
  },
  sync() {
    const img = this.el.querySelector("img");
    if (!img) return;

    if (img !== this.img) {
      this.detach();
      this.img = img;
      this.settled = (event) => this.settle(event.type === "load");
      img.addEventListener("load", this.settled);
      img.addEventListener("error", this.settled);
    }

    // A patch may have swapped the src for another record's, so the verdict on the old one is
    // cleared before the new one is judged.
    img.style.display = "";
    img.style.background = "";
    if (img.complete) this.settle(img.naturalWidth > 0);
  },
  settle(loaded) {
    if (!loaded) {
      this.img.style.display = "none";
      return;
    }

    const background = this.el.dataset.loadedBackground;
    if (background) this.img.style.background = background;
  },
  detach() {
    if (!this.img) return;
    this.img.removeEventListener("load", this.settled);
    this.img.removeEventListener("error", this.settled);
    this.img = null;
  },
  destroyed() {
    this.detach();
  },
};

// TYPING `@` IN A REVIEW NOTE. The split is deliberate: the browser decides WHEN somebody is being
// named — it is the only thing that knows where the caret is — and the server decides WHO can be
// named, because that is a tenancy question and the browser must not be trusted with the answer.
//
// The hook sits on the textarea itself, so the form rebuilding on `defaults` (which replaces the
// element) remounts it rather than leaving a listener on a textarea that is gone.
const MentionBox = {
  mounted() {
    this.at = null;
    this.open = false;
    this.active = 0;
    this.blurTimer = null;

    this.el.addEventListener("input", () => this.probe());
    this.el.addEventListener("click", () => this.probe());

    // THE KEYBOARD IS HOW AN AUTOCOMPLETE IS USED. Without this, Enter typed a newline and left the
    // half-written `@n` sitting in the note — the list was only ever clickable, which is not what
    // anybody expects from a list that appears while they are typing.
    this.el.addEventListener("keydown", (event) => {
      // WHAT IS ON SCREEN DECIDES, not what this instance remembers. The composer rebuilds itself
      // whenever `defaults` change, which remounts this hook with an empty memory while the list the
      // server rendered is still standing — and a list you can see but cannot arrow through is worse
      // than no list. If the rows are there, recover the caret position and carry on.
      if (this.candidates().length === 0) return;

      if (this.at === null) {
        const found = mentionAt(this.el.value, this.el.selectionStart);
        if (!found) return;
        this.at = found.at;
        this.open = true;
      }

      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.step(event.key === "ArrowDown" ? 1 : -1);
      } else if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault();
        this.pick(this.candidates()[this.active]);
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.close();
      }
    });

    this.el.addEventListener("keyup", (event) => {
      if (!["Enter", "Tab", "Escape", "ArrowDown", "ArrowUp"].includes(event.key)) this.probe();
    });

    // The mouse picks through the same path the keyboard does. `mousedown` rather than `click`, with
    // the default prevented, so the caret never leaves the note — a click that blurs first is a
    // click that closes the list it was aimed at.
    this.onMouseDown = (event) => {
      const option = event.target.closest("#pb-mention-list [data-handle]");
      if (!option) return;
      event.preventDefault();
      this.pick(option);
    };

    document.addEventListener("mousedown", this.onMouseDown);
    // A blur closes it, but not before a click on the list has landed — the click IS a blur. The
    // timer is stored and cancelled on focus so a patch that relocates the textarea cannot close the
    // list behind the author's back: LiveView hands focus straight back, and only a real click away
    // leaves it gone.
    this.el.addEventListener("blur", () => {
      this.blurTimer = setTimeout(() => this.close(), 200);
    });
    this.el.addEventListener("focus", () => clearTimeout(this.blurTimer));

  },

  candidates() {
    return Array.from(document.querySelectorAll("#pb-mention-list [data-handle]"));
  },

  // Which row Enter would take, painted where the reader is looking. Painting and remembering are
  // one step on purpose: they drifted apart when only one of them ran, and a highlight that lies
  // about what Enter will do is worse than no highlight.
  step(by) {
    const options = this.candidates();
    if (options.length === 0) return;

    this.active = (this.active + by + options.length) % options.length;
    this.paint(options);
    options[this.active].scrollIntoView({ block: "nearest" });
  },

  paint(options) {
    options.forEach((option, index) =>
      option.setAttribute("data-active", index === this.active ? "true" : "false"),
    );
  },

  pick(option) {
    if (!option) return;
    this.insert(option.dataset.handle);
    this.close();
  },

  probe() {
    const found = mentionAt(this.el.value, this.el.selectionStart);

    if (!found) return this.close();

    this.at = found.at;
    this.open = true;

    // A NEW WORD IS A NEW LIST. The server re-renders it with the first row highlighted, so the
    // hook has to agree — and repaint, because the rows on screen may be the previous answer still.
    this.active = 0;
    this.paint(this.candidates());

    // One search per pause rather than one per keystroke: the list is a query, and holding a key
    // down should not be a query per character.
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.pushEvent("mention_search", { q: found.query }), 120);
  },

  // The one place the list is finished with — writing the name does not close it, or `pick` would
  // have nothing left to tell the server and the list would sit there over the note it just wrote.
  close() {
    clearTimeout(this.timer);
    if (!this.open) return;
    this.open = false;
    this.at = null;
    this.pushEvent("mention_close", {});
  },

  // Only the browser knows where the caret is, so only the browser can put the name where it goes.
  insert(handle) {
    if (this.at === null) return;

    const written = withMention(this.el.value, this.at, this.el.selectionStart, handle);

    this.el.value = written.value;
    this.el.setSelectionRange(written.caret, written.caret);
    this.el.focus();
  },

  destroyed() {
    clearTimeout(this.timer);
    clearTimeout(this.blurTimer);
    document.removeEventListener("mousedown", this.onMouseDown);
  },
};

// Admin dashboard widget grid: drag-to-reorder within the grid, and a shared Sortable group with
// the widget library tray so chips drop in ("add_at") and widgets drag off the board ("hide" via
// the tray's onAdd). Dragging is enabled only while data-customize="true". Touch-friendly: the
// short delayOnTouchOnly hold starts a drag while taps and page scroll keep working.
const DashboardGrid = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      animation: 150,
      handle: "[data-drag-handle]",
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      disabled: this.el.dataset.customize !== "true",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        const index = evt.newIndex;
        evt.item.remove();
        this.pushEvent("add_at", { id, index });
      },
      onEnd: (evt) => {
        if (evt.from !== evt.to || evt.oldIndex === evt.newIndex) return;
        const ids = Array.from(
          this.el.querySelectorAll(":scope > [data-id]"),
        ).map((el) => el.dataset.id);
        this.pushEvent("reorder", { ids });
      },
    });
  },
  updated() {
    this.sorter?.option("disabled", this.el.dataset.customize !== "true");
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// The widget library tray: chips drag onto the grid (handled by the grid's onAdd); a widget card
// dropped HERE is removed from the board ("hide"). Chips also add on plain click/tap.
const DashboardTray = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      sort: false,
      animation: 150,
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        evt.item.remove();
        this.pushEvent("hide", { id });
      },
    });
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// ---------------------------------------------------------------------------------------------
// Page builder. Three hooks, and deliberately only three: everything else in the editor is an
// ordinary LiveView binding, because the document lives on the server. These cover the parts a
// server genuinely cannot do — pointer geometry, key handling, and bridging the canvas iframe.
// ---------------------------------------------------------------------------------------------

// THE EDITOR'S KEYBOARD, in one place because two hooks read it — `PbShortcuts` on the chrome and
// `PbCanvas` inside the frame, which cannot see the chrome's listener at all.
//
// MATCHED ON THE PHYSICAL KEY, NOT ON THE CHARACTER. `event.key` is what the LAYOUT produced: on a
// Persian keyboard ⌘Z arrives as `ز`, on a Russian one as `я`, on Dvorak as `;`. Every shortcut here
// compared against `"z"` and friends, so on any non-Latin layout the whole editor keyboard was dead
// — undo, save, copy, paste, duplicate, the command palette, all of it — with nothing on screen to
// say why. Reported as "I pressed Ctrl+Z and the second block didn't come back"; reverting from the
// history sheet worked, because that is a click.
//
// `event.code` names the key by WHERE IT IS — `KeyZ` is the same key on every layout — so it is the
// answer for the letters. `event.key` stays as the fallback for everything `code` cannot spell the
// same way everywhere, and for browsers that do not send one.
export const PB_KEYS = (event) => {
  const code = event.code || "";

  return {
    letter: /^Key[A-Z]$/.test(code) ? code.slice(3).toLowerCase() : null,
    key: (event.key || "").toLowerCase(),
    code,
  };
};

export const PB_SHORTCUTS = (event) => {
  const mod = event.metaKey || event.ctrlKey;
  const { letter, key, code } = PB_KEYS(event);

  // The physical key when the browser named one, the character otherwise.
  const is = (want) => (letter ? letter === want : key === want);

  if (mod && is("z")) return event.shiftKey ? "redo" : "undo";
  if (mod && is("s")) return "save";
  if (mod && is("c")) return "copy";
  if (mod && is("x")) return "cut";
  if (mod && is("v")) return "paste";
  if (mod && is("d")) return "duplicate";
  // ⇧⌘H, Figma's and Sketch's hide and show; ⌘H alone is the system's on a Mac.
  if (mod && event.shiftKey && is("h")) return "visibility";
  if (mod && is("k")) return "command";
  if (mod && (code === "Slash" || key === "/")) return "code";
  if (mod && is("p")) return "preview";
  if (code === "Escape" || key === "escape") return "escape";
  if (code === "Delete" || code === "Backspace" || key === "delete" || key === "backspace") {
    return "delete";
  }
  if (event.shiftKey && (code === "Digit1" || key === "!")) return "fit";
  return null;
};

// Typing in a field must stay typing. Undo is the one exception: it means "undo my last edit"
// everywhere, including mid-text-edit, which is what every editor does.
const PB_EDITABLE = (target) =>
  target &&
  (target.isContentEditable ||
    ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));

// WHEN THE FRAME HAS ACTUALLY REPAINTED THE NEW DOCUMENT. Opening a draft replaces the tree in the
// session and the frames re-render from a broadcast — no navigation, so `FrameLoader`'s `load` never
// fires again and its spinner can never come back. The editor raises the busy overlay when it asks
// for the swap; this is what takes it down, and it is the only signal that means "the canvas you are
// looking at is the one you asked for".
//
// Posted rather than pushed: this is the frame's own LiveView, and the overlay belongs to the editor
// around it. A `postMessage` costs nothing and stays in the browser; a push would be a round trip
// per patch to tell the server something it already knows.
//
// The last revision announced lives as a JS property on the ELEMENT, the same place `FrameLoader`
// keeps `__pbLoaded` and for the same reason: a `data-*` the server did not render is stripped on
// the next patch, and a field on the hook is gone the moment LiveView remounts it.
function announcePainted(el) {
  const revision = el.dataset.revision;
  if (revision === undefined || revision === el.__pbPainted) return;

  el.__pbPainted = revision;
  window.parent.postMessage({ pb: true, kind: "painted", revision }, window.origin);
}

const PbCanvas = {
  mounted() {
    // There is deliberately NO hover handler. The outline is a CSS rule inside the canvas document,
    // because nothing on the server consumes hover — the layers rail highlights the SELECTION, as the
    // prototype does. Pushing a `hover` event per mouseover meant a round trip and a re-render of the
    // whole document for every pixel the pointer travelled, which is what made selecting an element
    // take seconds: the click's diff queued behind hundreds of hover diffs, and LiveView's progress
    // bar flashed on each one.

    this.onDblClick = (event) => {
      if (previewing()) return;

      // Where the gesture began, not what the first click drew under the pointer since — see
      // `onSelectClick`.
      const target = this.pressed || event.target;

      const node = target.closest('[data-kind="text"]');
      if (!node) return this.onDblSelect(event, target);

      node.setAttribute("contenteditable", "plaintext-only");
      node.focus();

      const finish = () => {
        node.removeAttribute("contenteditable");
        this.pushEvent("set_text", { id: node.dataset.nodeId, text: node.textContent });
        node.removeEventListener("blur", finish);
      };

      node.addEventListener("blur", finish, { once: true });

      // COMMITTING IS A KEYSTROKE, not only a click somewhere else. Escape leaves, ⌘/Ctrl+Enter
      // saves, and plain Enter saves too — a heading or a button label is one line, and typing into
      // one and pressing Enter means "done", not "give me a second line". Shift+Enter is the way to
      // ask for the newline, which is the convention every editor with a one-line field uses.
      node.addEventListener("keydown", (ev) => {
        if (ev.key === "Escape") return node.blur();
        if (ev.key !== "Enter") return;
        if (ev.shiftKey && !(ev.metaKey || ev.ctrlKey)) return;

        ev.preventDefault();
        node.blur();
      });
    };

    // THE NODE ITSELF, WHEN THAT IS WHAT WAS MEANT. A single click resolves upwards, because the
    // words in a heading are the heading and an expression sitting alone in a `<div>` is, to anyone
    // pointing at it, that div's content. That is right for the common case and leaves no way at all
    // to reach the thing under the pointer: `{@size}` selected the div around it, the Inspector
    // showed the div, and the one node whose source somebody wanted to edit could not be selected
    // from the canvas at all.
    //
    // So the second click says "no, THAT one". Not a special case for expressions — any node the
    // single click would have resolved past, which is the same set on the same rule, so a comment
    // and a token behave the way an expression does without either being named here.
    this.onDblSelect = (event, target) => {
      const exact = target.closest("[data-node-id]");
      if (!exact) return;

      // Nothing was resolved past, so there is nothing a second click could mean that the first one
      // did not already do.
      if (styleableNode(target) === exact) return;

      event.preventDefault();
      event.stopPropagation();
      this.markSelected(exact.dataset.nodeId);
      this.pushEvent("select", { id: exact.dataset.nodeId });
    };

    this.onKey = (event) => {
      // The same repeat guard as the chrome's. This is the copy that matters: the caret is usually
      // inside the canvas, so this is where a held key would be caught.
      if (event.repeat) return;

      const shortcut = PB_SHORTCUTS(event);
      if (!shortcut) return;
      if (PB_EDITABLE(event.target) && shortcut !== "undo" && shortcut !== "redo") return;

      event.preventDefault();
      window.parent.postMessage({ pb: true, kind: "shortcut", key: shortcut }, window.origin);
    };

    this.handleEvent("pb:drop-rejected", ({ message }) =>
      window.parent.postMessage({ pb: true, kind: "error", message }, window.origin),
    );

    this.handleEvent("pb:open-rail", ({ action }) =>
      window.parent.postMessage({ pb: true, kind: "rail", action }, window.origin),
    );

    // The preview bar's own way out, riding the shortcut channel because ⌘P already means exactly
    // this and the chrome already knows how to answer it.
    this.handleEvent("pb:leave-preview", () =>
      window.parent.postMessage({ pb: true, kind: "shortcut", key: "preview" }, window.origin),
    );

    // The selection RING is client state. The server still owns the selection — the inspector, the
    // layers rail and the toolbar all read it — but drawing the ring from a server render meant every
    // click re-rendered all ~70 nodes of the document, and a click took over half a second to show
    // anything. Marking the node here is instant, and the server's answer moves nothing that is
    // already right.
    this.markSelected = (id) => {
      const doc = this.el.ownerDocument;
      // THE PANEL BELONGS TO THE ELEMENT IT WAS OPENED ON. It survives a patch — that is what lets
      // someone try six spreads in a row — but a NEW selection is a new question, and carrying the
      // open panel over to it both hides the element just clicked and offers rows that describe
      // something else.
      const previous = this.selectedId;
      if ((id || null) !== previous) this.layoutOpen = false;
      this.selectedId = id || null;
      doc
        .querySelectorAll('[data-node-id][data-selected="true"]')
        .forEach((el) => el.removeAttribute("data-selected"));
      if (!id) return this.placeToolbar?.();
      const node = doc.querySelector(`[data-node-id="${CSS.escape(id)}"]`);
      if (node) node.setAttribute("data-selected", "true");
      // A SELECTION MADE SOMEWHERE ELSE HAS TO BE FINDABLE. Clicking a review note anchored to an
      // element three screens down used to ring something nobody could see. A selection made ON the
      // canvas is already in view by definition, so only bring it into view when the ring moved.
      if (node && id !== previous) node.scrollIntoView({ block: "nearest", behavior: "smooth" });
      // The floating toolbar is positioned from the selected element's box, so it has to move WITH
      // the ring. A selection made in the layers rail arrives as a push_event AFTER the DOM patch
      // that rendered the toolbar, so repositioning only on `updated()` left the bar wherever the
      // previous selection had put it — usually the bottom-left of the canvas.
      this.placeToolbar?.();
    };

    // Selections made ANYWHERE — the layers rail, a comment's deep link, undo — arrive here.
    this.handleEvent("pb:selected", ({ id }) => this.markSelected(id));

    // The held elements, painted the same way the ring is: an id list the client applies, never
    // `data-marked` rendered per node — that would re-render the whole document on every ⌘-click.
    this.handleEvent("pb:marked", ({ ids }) => {
      const doc = this.el.ownerDocument;
      const held = new Set(ids);

      for (const el of doc.querySelectorAll("[data-marked='true']")) {
        if (!held.has(el.dataset.nodeId)) el.removeAttribute("data-marked");
      }

      for (const id of held) {
        doc.querySelector(`[data-node-id="${CSS.escape(id)}"]`)?.setAttribute("data-marked", "true");
      }
    });

    // PREVIEW IS READ-ONLY, AND THAT HAS TO MEAN EVERY WAY IN. The flag was read here and nowhere
    // else, so selection was off while double-click still rewrote text and a drag still moved
    // nodes — a mode that says "this is how visitors see it" while quietly letting you edit it.
    const previewing = () => this.el.dataset.preview === "true";

    // WHAT WAS CLICKED IS NOT ALWAYS WHAT CAN BE EDITED. A run of text, an EEx expression and a
    // comment carry no attributes and no classes of their own — `Node.container?/1` is the server's
    // word for it, and the inspector already answers a click on one with a near-empty panel whose
    // only offer is a button reading "Style the element around it". So clicking the words in a
    // heading cost two clicks to reach the heading, or a trip to the layers rail.
    //
    // On the canvas the words ARE the heading. Both click paths resolve through this: the ordinary
    // one below, and `onCapture`, which answers clicks on links and submits — those are the words
    // most likely to be clicked, and resolving in only one of the two would have made a nav link
    // behave differently from a paragraph.
    //
    // Nothing is lost. Double-click still edits the words, because that handler looks for
    // `[data-kind="text"]` under the pointer and never consults the selection, and the layers rail
    // can still select a run on its own for anyone who wants exactly that.
    const STYLEABLE = new Set(["tag", "component", "slot"]);

    const styleableNode = (target) => {
      let node = target.closest("[data-node-id]");

      while (node && node.dataset.kind && !STYLEABLE.has(node.dataset.kind)) {
        const around = node.parentElement && node.parentElement.closest("[data-node-id]");
        if (!around) break;
        node = around;
      }

      return node;
    };

    this.onSelectClick = (event) => {
      // A DOUBLE CLICK BELONGS TO WHAT WAS UNDER THE POINTER WHEN IT BEGAN. The first click selects
      // the element around the pointer, and that can change what is under it before the second one
      // lands: an element near the top of the frame is scrolled down, clear of the toolbar's band,
      // and the toolbar takes the spot the chip left; one taller than the frame gets the toolbar
      // pinned over its content. The second click then pressed whichever toolbar button had slid
      // under the pointer, and the `dblclick` found no node there and did nothing — the expression
      // the gesture was aimed at could not be reached.
      //
      // So the press that starts a gesture is kept and answers the `dblclick`, and the rest of the
      // gesture is no click of its own — the first one already selected. Stopped outright, so no
      // toolbar button, link guard or LiveView binding hears it, and prevented, because the link
      // guard is skipped along with them. Kept until the next single click rather than the
      // `dblclick`, so the third press of a triple-click is swallowed too. A gesture begun ON the
      // toolbar is the toolbar's own; one that leaves preview halfway still answers from its own
      // first press, which is why this runs before the preview check.
      if (event.detail <= 1) {
        this.pressed = event.target.closest("#pb-el-toolbar") ? null : event.target;
      } else if (this.pressed && !previewing()) {
        event.preventDefault();
        return event.stopImmediatePropagation();
      }

      if (previewing()) return;
      if (event.target.closest("a[href], button[type=submit], form")) return;
      // THE TOOLBAR IS NOT THE DOCUMENT. It lives in the top layer, outside every `[data-node-id]`,
      // so a click on its own buttons read as "clicked empty space" and dropped the ring — then
      // `placeToolbar` hid the bar the reader had just pressed. Every action on it acts on the
      // CURRENT selection, so pressing one must never change what is selected.
      if (event.target.closest("#pb-el-toolbar")) return;

      const node = styleableNode(event.target);

      // ⌘ OR CTRL HOLDS A SECOND ELEMENT rather than replacing the first. The `phx-click="select"`
      // on the node would still fire and throw the held ones away, so the click is stopped here and
      // re-sent as a mark.
      if (node && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        event.stopPropagation();
        return this.pushEvent("mark", { id: node.dataset.nodeId });
      }

      // A COMPONENT'S OWN BEHAVIOUR IS NOT THE EDITOR'S. A kit component may carry its own
      // `phx-click` — flash, toast, banner, badge, rating and pagination all do — and a dismiss is
      // `JS.push(...)` followed by `JS.hide(to: "#its-own-id")`. LiveView binds the INNERMOST
      // `phx-click`, which is the component's and not the wrapper's `select`, so clicking one in the
      // canvas ran its dismiss: the element went `display:none` on the client, the server never
      // heard about it, and because `contain/2` flattens a component to a single static blob nothing
      // ever re-sent that markup. The author saw the component they had just placed vanish, with the
      // code still holding it and no way back but a reload.
      //
      // In the canvas a component is a picture of itself, so its behaviour is stopped and the click
      // means what every other click here means: select this node. Preview mode returns above, where
      // a click is the page's rather than the editor's — a live component is still drawn cold there,
      // and runs only on the published page.
      const bound = event.target.closest("[phx-click]");

      if (node && bound && bound !== node && node.contains(bound)) {
        event.preventDefault();
        event.stopPropagation();
        this.markSelected(node.dataset.nodeId);
        return this.pushEvent("select", { id: node.dataset.nodeId });
      }

      // Resolving upwards means the wrapper under the pointer would still report ITS id, so the
      // click is stopped and re-sent for the one that was resolved to.
      const clicked = event.target.closest("[data-node-id]");

      if (node && clicked && node !== clicked) {
        event.preventDefault();
        event.stopPropagation();
        this.markSelected(node.dataset.nodeId);
        return this.pushEvent("select", { id: node.dataset.nodeId });
      }

      this.markSelected(node ? node.dataset.nodeId : null);
    };
    this.el.ownerDocument.addEventListener("click", this.onSelectClick, true);

    // Deselect only when the click actually missed every node. A `phx-click` on the container would
    // fire on the way up from a node's own click and cancel the selection that just happened.
    this.onClick = (event) => {
      // A link or a submit button inside the document must not act. The canvas is an editing
      // surface: clicking `<a href="/">` to select it navigated the whole editor away — LiveView's
      // own interceptor treated the page's `data-phx-link` anchor as a live redirect.
      // Links and submits are handled in the capture listener below; this only has to deal with a
      // click that missed every node, which is what clears the selection.
      if (event.target.closest("a[href], button[type=submit], form")) return;
      if (event.target.closest("#pb-el-toolbar")) return;
      // NOT IN PREVIEW. Clearing the selection there moves the Inspector while editing is off, and
      // with a palette item armed the same empty `select` places it.
      if (previewing()) return;
      if (!event.target.closest("[data-node-id]")) this.pushEvent("select", {});
    };

    // THE MENU LIVES IN THE CHROME, NOT IN HERE. This frame renders the SITE's document and never
    // loads the admin stylesheet, so a menu drawn here would arrive unstyled — and building a second
    // inline-styled copy of it is exactly the drift the shared component exists to prevent. The
    // right-click is forwarded instead, with its point; the chrome translates it through the frame's
    // own box and opens the one menu there.
    this.onContext = (event) => {
      // Not in preview: that menu is the editor's — wrap, cut, delete — and choosing any entry selects
      // the node it was opened on. The browser's own menu is what a visitor gets.
      if (previewing()) return;

      const node = event.target.closest("[data-node-id]");
      if (!node) return;

      event.preventDefault();
      window.parent.postMessage(
        {
          pb: true,
          kind: "context",
          id: node.dataset.nodeId,
          // Hidden from visitors, itself or with what is around it: the menu's entry says Show.
          hidden: !!node.closest("[data-pb-hidden]"),
          x: event.clientX,
          y: event.clientY,
        },
        window.origin,
      );
    };

    this.el.ownerDocument.addEventListener("contextmenu", this.onContext);

    // ---- drag and drop -------------------------------------------------------------------
    // Hybrid, in the sense the two halves answer two different questions:
    //
    //   * GEOMETRY is the browser's. Where the pointer sits inside a box decides "before", "after"
    //     or "inside", and that is resolved here, per pointer move, with no round trip — which is
    //     why NOTHING is pushed on hover. (Pushing per hover is what once made this editor take
    //     seconds per gesture; see the note at the top of this hook.)
    //   * LEGALITY is the server's. `pb:drop-hints` arrives ONCE, at dragstart, carrying the whole
    //     tree's verdict for the thing being dragged — computed by the same function that later
    //     admits or refuses the drop, so the line cannot promise something the server will reject.
    //     Until it lands (a few ms) the resolver guesses optimistically and the server is still the
    //     one that decides; if it refuses, `EditorSession.apply_drop/2` places the node beside the
    //     target instead of losing the gesture, and says so.
    //
    // Rects are cached for the life of one drag and the indicator is only touched when the resolved
    // position actually changes: reading a box and then writing a style, per dragover, forced a
    // synchronous layout of the whole document on every pointer move.
    const indicator = document.createElement("div");
    indicator.style.cssText =
      "position:absolute;left:0;top:0;z-index:2147483647;pointer-events:none;background:#3a6cf4;" +
      "display:none;border-radius:2px;will-change:transform;";

    // Names where a redirected drop is actually going. A silently moved drop is the one thing worse
    // than a refused one. A field adds the form it joins, or that it starts one, in a part of its own.
    const caption = document.createElement("span");
    caption.style.cssText =
      "position:absolute;left:0;top:-18px;white-space:nowrap;font:600 10px/1.6 ui-sans-serif,system-ui;" +
      "display:none;gap:3px;";
    const captionPart = () => {
      const part = document.createElement("span");
      part.style.cssText = "padding:0 6px;border-radius:4px;background:#b45309;color:#fff;";
      caption.appendChild(part);
      return part;
    };
    const captionBase = captionPart();
    const captionForm = captionPart();
    indicator.appendChild(caption);
    document.body.appendChild(indicator);
    this.indicator = indicator;

    let rects = new Map();
    const rectOf = (el) => {
      let rect = rects.get(el);
      if (!rect) rects.set(el, (rect = el.getBoundingClientRect()));
      return rect;
    };

    // `pb_drop.js` owns the geometry — rows against stacks, reversed rows, the climb out of a
    // container that will not take the node. It is a pure function of four lookups, which is what
    // lets it be tested against plain rectangles instead of a rendered page.
    let axes = new Map();
    const styleOf = (el) => {
      if (!el) return null;
      let style = axes.get(el);
      if (!style) axes.set(el, (style = getComputedStyle(el)));
      return style;
    };

    this.forgetRects = () => {
      rects.clear();
      axes.clear();
    };

    // A CONTAINER WITH NOTHING IN IT HAS NO HEIGHT, so there was nowhere to aim: an empty column in
    // a fresh row collapses to 0px and the pointer went straight through it to whatever was behind.
    // For the length of one drag they get a floor and a dashed edge — the JS owns this, so nothing
    // has to be rendered per node and no class needs the runtime compiler to have seen it.
    let opened = [];

    // WHATEVER THE POINTER IS AIMED AT MUST NOT MOVE. Giving every empty container a 34px floor
    // changes the height of the whole document, so anything below the first opened box slides down
    // mid-gesture — an author aiming under a table watched the table itself jump away as the blocks
    // appeared above it. The floors are still worth having (a fresh 0px column is unreachable
    // without them); what is not worth having is the page moving under the cursor.
    //
    // So: measure the node under the pointer before opening, measure it again after, and scroll by
    // the difference. The document grew, the thing being aimed at did not move, and the cached drop
    // boxes are dropped because every one of them is now wrong.
    const anchorFor = (event) => {
      const el =
        (event && event.target && event.target.closest && event.target.closest("[data-node-id]")) ||
        (event &&
          this.el.ownerDocument.elementFromPoint &&
          this.el.ownerDocument.elementFromPoint(event.clientX, event.clientY));

      return el && el.getBoundingClientRect ? el : null;
    };

    const openEmpties = (event) => {
      const anchor = anchorFor(event);
      const before = anchor && anchor.getBoundingClientRect().top;

      openEmptiesNow();

      if (anchor === null || before === null) return;

      const after = anchor.getBoundingClientRect().top;
      const scroller = this.el.ownerDocument.scrollingElement;

      if (scroller && after !== before) {
        scroller.scrollTop += after - before;
        this.forgetRects();
      }
    };

    const openEmptiesNow = () => {
      // A box THIS CODE already opened measures the 34px floor it was given, so the height test
      // below reads it as content and skips it — and the entry holding its real styles would be
      // dropped with the rest of the list, leaving nothing to restore it with. It is carried over
      // instead: a node stays this hook's responsibility until it is closed.
      const held = new Map(opened.map((entry) => [entry[0], entry]));
      opened = [];
      // `:not([data-ws])` marks a node that holds a place without being content — the indentation
      // left behind when a container is emptied, and anything folded away with the eye, a comment
      // included. Counting either as content leaves the one box that most needs a floor without one.
      for (const el of this.el.querySelectorAll("[data-node-id]")) {
        if (!nests(el) || el.querySelector("[data-node-id]:not([data-ws])")) continue;
        if (held.has(el)) {
          opened.push(held.get(el));
          continue;
        }
        if (el.getBoundingClientRect().height > 18) continue;
        opened.push([
          el,
          el.style.minHeight,
          el.style.outline,
          el.style.outlineOffset,
          el.style.background
        ]);
        // The same tone the render path already uses for a hollow box. 34px of white inside a hard
        // blue dash reads as a broken layout rather than as a place to aim.
        el.style.minHeight = "34px";
        el.style.outline = "1px dashed #c9c7ee";
        el.style.outlineOffset = "-1px";
        el.style.background = "rgba(91, 87, 214, 0.04)";
      }
    };

    const closeEmpties = () => {
      for (const [el, minHeight, outline, offset, background] of opened) {
        el.style.minHeight = minHeight;
        el.style.outline = outline;
        el.style.outlineOffset = offset;
        el.style.background = background;
      }
      opened = [];
    };

    // AUTO-SCROLL AT THE EDGES. `edgeVelocity` decides how fast; one rAF loop applies it for the
    // whole drag and is cancelled the moment the gesture ends. Every scrolled pixel invalidates the
    // cached boxes, so the line keeps pointing where the pointer really is.
    let scrollBy = 0;
    let scrolling = null;

    const runScroll = () => {
      if (!scrollBy) return (scrolling = null);
      const scroller = this.el.ownerDocument.scrollingElement;
      if (scroller) {
        scroller.scrollTop += scrollBy;
        rects.clear();
      }
      scrolling = requestAnimationFrame(runScroll);
    };

    const edgeScroll = (event) => {
      scrollBy = edgeVelocity(event.clientY, this.el.ownerDocument.documentElement.clientHeight);
      if (scrollBy && !scrolling) scrolling = requestAnimationFrame(runScroll);
    };

    const stopScroll = () => {
      scrollBy = 0;
      if (scrolling) cancelAnimationFrame(scrolling);
      scrolling = null;
    };

    let painted = null;
    const hideIndicator = () => {
      painted = null;
      indicator.style.display = "none";
    };

    // The server's verdict when it has arrived, an optimistic yes when it has not. Unknown ids —
    // the document root — accept: the tree always has somewhere to put a node.
    const accepts = (id) => {
      const hints = window.__pbDropHints;
      return !hints || hints[id] !== false;
    };

    const nests = (node) => {
      const hints = window.__pbDropHints;
      if (hints) return hints[node.dataset.nodeId] === true;
      return node.dataset.kind !== "text" && node.dataset.kind !== "eex";
    };

    const parentOf = (node) => node.parentElement?.closest("[data-node-id]") || null;

    // A runtime component is named by what the author called it, not by the `div` it renders into.
    const labelOf = (node) => node.dataset.component || node.tagName.toLowerCase();

    // Everything the resolver needs to read off the page. It asks for these rather than reaching for
    // the DOM itself, which is what lets the geometry be checked against plain rectangles.
    const lookup = {
      rectOf,
      styleOf,
      parentOf,
      // NOT ONLY DIRECT CHILDREN. A runtime component renders its slot children through its own
      // markup, so they sit several elements deep inside the component's wrapper with no wrapper of
      // their own. Reading direct children alone found none of them, `indexOf` answered -1, and the
      // drop was appended to the end of the component instead of landing in the slot.
      //
      // The descendant sweep is filtered back to the ones this element really parents, so a node
      // nested inside ANOTHER node is not counted as a sibling of it.
      childrenOf: (parent) => {
        const host = parent || this.el;
        const direct = [...host.children].filter((el) => el.dataset.nodeId);
        if (direct.length) return direct;

        return [...host.querySelectorAll("[data-node-id]")].filter(
          (el) => parentOf(el) === parent
        );
      },
      idOf: (el) => el.dataset.nodeId,
      labelOf,
      accepts,
      nests,
    };

    // What a field drag reads off the canvas: the forms the server marked (`data-pb-form`, their
    // people name) and the node a drop at a form's end lands in front of (`data-pb-send`).
    const formLookup = {
      byId: (id) =>
        this.el.ownerDocument.querySelector(`[data-node-id="${CSS.escape(String(id))}"]`),
      isForm: (el) => !!el && el.hasAttribute("data-pb-form"),
      formOf: (el) => (el && el.closest ? el.closest("[data-pb-form]") : null),
      nameOf: (form) => form.getAttribute("data-pb-form") || "",
      landingOf: (form) => form.querySelector("[data-pb-send]"),
      precedes: (a, b) =>
        a !== b &&
        !a.contains(b) &&
        !b.contains(a) &&
        !!(b.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_PRECEDING),
      contains: (a, b) => a === b || a.contains(b),
    };

    // A line in front of `el`, along the way its siblings run.
    const before = (el) => ({
      rect: rectOf(el),
      axis: axisOf(styleOf(parentOf(el))).axis,
      before: true,
      inside: false,
    });

    const resolveDrop = (event) =>
      resolveDropAt(
        { x: event.clientX, y: event.clientY },
        event.target.closest("[data-node-id]"),
        lookup,
      );

    // How far an "inside" outline reaches past the container's own bounds. A box drawn AROUND the
    // container reads as the thing opening up to take the drop; a faint tint over the same box was
    // easy to miss, and on a short element — a collapsed alert is 24px tall — it was
    // indistinguishable from the line.
    const GROW = 4;

    const tones = { violet: "#7c3aed", blue: "#3a6cf4" };

    const paint = (target) => {
      const field = target.rect && window.__pbFieldDrag ? formLanding(target, formLookup) : null;
      const joins = field && formCaption(field);
      const key = target.rect
        ? `${target.parent_id}|${target.index}|${!!target.inside}|${!!target.redirected}|` +
          `${joins ? joins.text : ""}|${field && field.landing ? field.landing.dataset.nodeId : ""}`
        : null;
      if (key === painted) return;
      painted = key;

      // A field is drawn where it will land: in front of the Send button a spot past it moves to.
      const shown = field && field.landing ? before(field.landing) : target;
      const box = indicatorBox(shown, GROW);
      if (!box) return hideIndicator();

      const colour = target.redirected ? "#d97706" : "#3a6cf4";

      indicator.style.display = "block";
      indicator.style.transform =
        `translate3d(${box.left + window.scrollX}px, ${box.top + window.scrollY}px, 0)`;
      indicator.style.width = `${box.width}px`;
      indicator.style.height = `${box.height}px`;
      indicator.style.background = shown.inside ? "rgba(58,108,244,.08)" : colour;
      indicator.style.border = shown.inside ? `2px solid ${colour}` : "none";
      indicator.style.borderRadius = shown.inside ? "8px" : "2px";
      indicator.style.boxShadow = shown.inside ? `0 0 0 4px rgba(58,108,244,.10)` : "none";

      const base = target.inside
        ? `inside <${target.label}>`
        : target.redirected
          ? `after <${target.label}>`
          : "";

      captionBase.textContent = base;
      captionBase.style.display = base ? "inline-block" : "none";
      captionBase.style.background = colour;
      captionForm.textContent = joins ? (base ? `· ${joins.text}` : joins.text) : "";
      captionForm.style.display = joins ? "inline-block" : "none";
      captionForm.style.background = joins ? tones[joins.tone] : colour;
      caption.style.display = base || joins ? "flex" : "none";
    };

    // One request per drag, not per hover. The answer is stored on `window` rather than on the hook
    // because a drag that STARTED in the palette begins in the parent document — that side asks, and
    // the reply is handed to every canvas frame (see the `phx:pb:drop-hints` listener below).
    // THE FRAME TALKS UPWARDS. A drag that starts in here is answered by the CANVAS's own LiveView,
    // so the verdict lands in this document — and the layers rail, which the pointer is about to
    // cross into, lives in the parent one and would never see it. The hand-off already existed in
    // the other direction (`PbShortcuts` gives every frame the parent's copy); this is the return
    // leg, and without it every canvas-to-rail drag ran on an optimistic guess.
    const toParent = (payload) =>
      window.parent !== window &&
      window.parent.postMessage({ pb: true, ...payload }, window.origin);

    // Whether a field is being dragged in this frame: read by `paint`, and outlining its forms.
    const fieldDrag = (field) => {
      window.__pbFieldDrag = !!field;
      markFieldDrag(this.el.ownerDocument, field);
    };

    // What is being moved, faded while it is in flight. Without it the page looks unchanged for the
    // whole gesture and the only thing that says a drag is happening is a line somewhere else.
    let lifted = null;
    const lift = (node) => {
      lifted = [node, node.style.opacity];
      node.style.opacity = "0.4";
    };

    const drop = () => {
      if (lifted) lifted[0].style.opacity = lifted[1];
      lifted = null;
    };

    this.onDragStart = (event) => {
      if (previewing()) return event.preventDefault();

      const node = event.target.closest("[data-node-id]");
      if (!node) return;
      this.dragging = node.dataset.nodeId;
      window.__pbDropHints = null;
      fieldDrag(false);
      this.forgetRects();
      lift(node);
      openEmpties(event);
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", this.dragging);
      event.dataTransfer.setData(NODE_MIME, this.dragging);
      this.pushEvent("drag_start", { node_id: this.dragging });
      toParent({ kind: "drag", node_id: this.dragging });
    };

    // The effect has to MATCH what the source allowed, or the browser cancels the whole gesture: a
    // palette card sets `effectAllowed = "copy"`, and answering "move" made Chrome refuse the drop
    // silently — `dragleave` with `dropEffect: "none"` and no `drop` event at all. That is why a
    // component could be click-to-placed but never dragged in.
    //
    // A ROW DRAGGED OUT OF THE LAYERS RAIL allows "move" and nothing else, and it started in the
    // parent document so `this.dragging` is null here — answering "copy" to it was the same refusal
    // in mirror image, which is why a node could be reordered in the tree but never dragged from the
    // tree onto the page. `types` is the only part of a dataTransfer that is legible during a drag
    // (the values are held back until `drop`), which is what the marker type is for.
    const nodeDrag = (event) =>
      !!this.dragging || [...(event.dataTransfer?.types || [])].includes(NODE_MIME);

    // A DRAG THIS EDITOR STARTED — a canvas node or the grip, a row out of the rail, a palette or
    // snippet card, which between them set one of the two markers. Anything else was carried in
    // from outside the browser: a file out of Finder, a selection out of another tab. Those have no
    // source node in either of our documents, so the browser fires `dragend` nowhere we listen and
    // the broadcast below never runs — whatever such a drag opened would stand for the rest of the
    // session. It has no business inflating the author's layout to begin with.
    const editorDrag = (event) =>
      nodeDrag(event) || [...(event.dataTransfer?.types || [])].includes(TEMPLATE_MIME);

    const allow = (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = nodeDrag(event) ? "move" : "copy";
    };

    // `dragenter` has to be accepted too, not just `dragover`. Entering an element makes it the
    // current drop target in its DEFAULT state — refusing — and if the button comes up before the
    // next `dragover` lands, the drop is discarded. A drag that crosses INTO the frame and releases
    // in one motion, which is exactly how a palette card is dropped, hits that window every time.
    // A palette card's drag begins in the PARENT document, so this frame never sees a `dragstart`
    // for it — the empty containers have to open when the pointer first crosses in, or the one
    // gesture the whole tray exists for is the one that cannot reach a fresh column.
    //
    // PREVIEW TAKES NO DROP. The canvas answers no edit there, so accepting the drag would draw a
    // landing line for a drop that changes nothing. It is still TAKEN rather than left alone: a drag
    // the page does not cancel is the browser's, and the browser's answer to a file or a link carried
    // in from outside is to open it, taking the frame away from the document. Cancelled with an
    // effect of "none", the drag shows as refused and no `drop` fires at all.
    const refuse = (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = "none";
    };

    this.onDragEnter = (event) => {
      if (previewing()) return refuse(event);

      allow(event);
      if (!opened.length && editorDrag(event)) openEmpties(event);
    };

    this.onDragOver = (event) => {
      if (previewing()) return refuse(event);

      allow(event);
      edgeScroll(event);
      paint(resolveDrop(event));
    };

    // `dragleave` bubbles, so crossing from one nested element to the next fires it on the canvas
    // even though the pointer never left — which made the line blink out and back on every boundary
    // and read as lag. Only a pointer that has actually left the canvas hides it.
    this.onDragLeave = (event) => {
      if (event.relatedTarget && this.el.contains(event.relatedTarget)) return;
      stopScroll();
      hideIndicator();
    };

    this.onDrop = (event) => {
      event.preventDefault();
      stopScroll();
      closeEmpties();
      drop();
      hideIndicator();

      const target = resolveDrop(event);
      const payload = { parent_id: target.parent_id, index: target.index };

      // The tree, not the screen, decides where this goes — see `resolveDrop`.
      if (target.anchor_id) {
        payload.anchor_id = target.anchor_id;
        payload.anchor_before = target.anchor_before;
      }

      // A node dragged from inside the canvas is a move, and so is one dragged in from the layers
      // rail — that one begins in the parent document, so its id arrives on the dataTransfer rather
      // than on this hook. Anything else is the palette's template.
      const template = event.dataTransfer.getData(TEMPLATE_MIME);
      const moving = this.dragging || event.dataTransfer.getData(NODE_MIME);
      if (moving) payload.node_id = moving;
      else if (template) payload.template = template;
      else return;

      this.dragging = null;
      window.__pbDropHints = null;
      this.forgetRects();
      this.pushEvent("drop", payload);
    };

    // Everything this frame put on the author's document for the length of the gesture. Closing the
    // empty containers is the largest geometry change this hook makes, so the boxes measured against
    // the open layout go with them — whichever end the gesture came to.
    const restore = () => {
      stopScroll();
      closeEmpties();
      drop();
      hideIndicator();
      fieldDrag(false);
      this.forgetRects();
    };

    this.onDragEnd = () => {
      this.dragging = null;
      window.__pbDropHints = null;
      restore();
      toParent({ kind: "dragend" });
    };

    // THE GESTURE ENDED WHERE THIS FRAME CANNOT SEE IT — released over the palette, over the layers
    // rail, or cancelled. `dragend` fires on the source, which for all three is the chrome's
    // document, so the browser never tells this frame and the empty containers it opened kept their
    // floor and dashed edge until an unrelated edit repainted the node. The chrome broadcasts the
    // end into every frame instead (`endDrag`); this is the frame's half of it. Nothing is reported
    // back upwards — the chrome is where this came from.
    this.onDragAway = () => restore();

    // Auto-scrolling near an edge moves every box under the pointer, so a cached rect outlives its
    // truth by exactly one scroll. Capture phase catches inner scrollers too.
    this.el.ownerDocument.addEventListener("scroll", this.forgetRects, true);

    // A drag that starts INSIDE the canvas is answered by this frame's own LiveView, so the reply
    // lands here rather than in the chrome. `accepts` is read by `accepts/1` and `nests/1` above;
    // until it arrives they fall back to an optimistic yes, which is what the whole gesture used to
    // run on.
    // A reply that lands after this frame's drag ended is dropped, and not handed upwards either.
    this.handleEvent("pb:drop-hints", ({ accepts, field }) => {
      if (!this.dragging) return;
      window.__pbDropHints = accepts;
      fieldDrag(field);
      toParent({ kind: "hints", accepts, field: !!field });
    });

    this.handleEvent("pb:drop-moved", ({ message }) =>
      window.parent.postMessage({ pb: true, kind: "info", message }, window.origin),
    );

    // The floating element toolbar is positioned from the selection's bounding box rather than
    // nested inside it: putting it in the node would need `position:relative` on the author's own
    // element, which can silently change their layout.
    // The toolbar lives in the TOP LAYER (`popover`), so nothing in the author's document can paint
    // over it, and it is positioned in VIEWPORT coordinates — which is why it is repositioned on
    // scroll rather than moving with the page.
    const clamp = (value, low, high) => Math.max(low, Math.min(value, Math.max(low, high)));

    const showBar = (bar) => {
      bar.style.display = "flex";
      try {
        if (!bar.matches(":popover-open")) bar.showPopover();
      } catch (_unsupported) {
        // No popover support: the inline z-index still puts it above ordinary content.
      }
    };

    const hideBar = (bar) => {
      bar.style.display = "none";
      try {
        if (bar.matches(":popover-open")) bar.hidePopover();
      } catch (_unsupported) {}
    };

    this.placeToolbar = () => {
      const bar = this.el.ownerDocument.getElementById("pb-el-toolbar");
      const selected = this.el.querySelector('[data-selected="true"]');
      if (!bar) return;
      if (!selected) {
        this.layoutOpen = false;
        return hideBar(bar);
      }

      showBar(bar);
      this.applyLayoutOpen?.();

      const rect = selected.getBoundingClientRect();
      const view = this.el.ownerDocument.defaultView;
      const gap = 6;
      const height = bar.offsetHeight || 26;

      // ALWAYS the top edge. Just above the element when it fits, and pinned to the top of the frame
      // when the element's own top is scrolled out of view — which is the case that matters, because
      // selecting a full-page container used to send the bar to the BOTTOM of the screen, nowhere
      // near the thing it names. It is never sent below the element: the label belongs to the top.
      // Pinned is also ON the element, over whatever the author was pointing at in it, so the stage
      // and the scroll keep a band this tall clear above the document — the rule in
      // `#pb-canvas-chrome`, which has to change with the gap, the inset or the bar's height.
      const top = clamp(rect.top - height - gap, 4, view.innerHeight - height - 4);
      const left = clamp(rect.left, 4, view.innerWidth - bar.offsetWidth - 4);

      bar.style.left = `${left}px`;
      bar.style.top = `${top}px`;
    };

    // THE RING IS CLIENT STATE, so a frame that has just mounted has none — even when the session
    // it mounted from has had something selected all along. Nothing used to hand that over: the
    // server rendered the toolbar (it knows the selection) and this hook then hid it again, because
    // no node carried `data-selected`. Selecting from a panel looked like "the ring works but the
    // toolbar does not", and clicking anything in the frame first fixed it, which is what made it
    // look like a toolbar bug rather than a handover that never happened.
    //
    // One attribute on the root, read once. Not `data-selected` per node — that is still the
    // client's to paint, and rendering it per node would fight every patch.
    this.markSelected(this.el.dataset.selection || null);

    this.placeToolbar();
    window.addEventListener("scroll", this.placeToolbar, { passive: true });
    window.addEventListener("resize", this.placeToolbar);

    this.el.addEventListener("dblclick", this.onDblClick);
    this.el.addEventListener("click", this.onClick);

    // Capture phase, on the document: LiveView binds its own link interceptor further out, and a
    // `<a data-phx-link>` in the page would otherwise be treated as a live redirect and navigate the
    // canvas away from the document being edited. Capture runs before any of that.
    this.onCapture = (event) => {
      if (!event.target.closest?.("a[href], button[type=submit], form")) return;
      event.preventDefault();
      event.stopPropagation();

      // PREVIEW IS A PICTURE OF THE UNSAVED PAGE, NOT THE PAGE. A link there is still stopped — it
      // would take the frame away from the document — but it is not a selection either: the
      // Inspector changing under an author who clicked a post title to follow it reads as the click
      // having done something, with editing off.
      if (previewing()) return;

      const node = styleableNode(event.target);
      this.pushEvent("select", node ? { id: node.dataset.nodeId } : {});
    };

    // MOUSEDOWN, NOT CLICK, and in the capture phase: a press on a link or a submit is stopped by
    // `onCapture` below and a press on the element toolbar never bubbles to the document at all, and
    // a menu left open through either of those is the bug being fixed. Posted on every press —
    // the chrome decides whether anything is open, which is not a question this frame can answer.
    this.onPress = () => window.parent.postMessage({ pb: true, kind: "dismiss" }, window.origin);
    this.el.ownerDocument.addEventListener("mousedown", this.onPress, true);

    this.onSubmit = (event) => event.preventDefault();
    this.el.ownerDocument.addEventListener("click", this.onCapture, true);
    this.el.addEventListener("submit", this.onSubmit);
    this.el.addEventListener("dragstart", this.onDragStart);
    // The toolbar's grip is the handle for MOVING the selection — the whole element, from the one
    // control that says so. It carried `cursor:grab` and nothing else, so it looked like a handle
    // and did nothing. It lives in the TOP LAYER, outside this hook's element, so it is bound
    // directly rather than through the canvas's own listeners.
    // Bound on the DOCUMENT, not on the grip: the toolbar is re-rendered whenever the selection
    // changes, and a listener attached to the element itself dies with the first patch.
    this.onGripDrag = (event) => {
      if (!event.target.closest?.("#pb-el-grip") || !this.selectedId) return;
      this.dragging = this.selectedId;
      window.__pbDropHints = null;
      rects.clear();
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", this.dragging);
      // THE SAME MARKER THE NODE ITSELF SETS. Without it the grip moved the selection inside the
      // canvas — where `this.dragging` alone answers — and was invisible everywhere else: the rail
      // saw a drag carrying nothing it owned, never cancelled a `dragover`, and the browser fired no
      // `drop` at all. One handle, two behaviours, depending on where you let go.
      event.dataTransfer.setData(NODE_MIME, this.dragging);
      this.pushEvent("drag_start", { node_id: this.dragging });
      toParent({ kind: "drag", node_id: this.dragging });
    };

    // THE LAYOUT ROW OPENS IN THE BROWSER. It is already rendered — the server decided what it
    // contains when the selection changed — so revealing it needs no round trip, and asking for one
    // would patch the toolbar, restore the `display:none` its template carries and drop it out of
    // the top layer. Bound on the DOCUMENT because the toolbar is re-rendered on every selection and
    // a listener on the button itself dies with the first patch.
    // OPEN IS CLIENT STATE THAT MUST SURVIVE A PATCH. Choosing an option writes to the document, so
    // the server re-renders the toolbar — and the panel's own template carries `display:none`, which
    // the patch restores. Held only in the DOM, the panel therefore shut itself the moment you used
    // it, and trying a second option meant reopening it every time.
    //
    // The flag lives here and is re-applied in `placeToolbar`, which `updated()` already calls after
    // every patch — the same way the selection ring survives one.
    this.layoutOpen = false;

    this.applyLayoutOpen = () => {
      const row = this.el.ownerDocument.getElementById("pb-eltb-cols");
      if (row) row.style.display = this.layoutOpen ? "flex" : "none";
    };

    this.onLayoutToggle = (event) => {
      if (!event.target.closest?.("#pb-eltb-layout")) return;
      event.preventDefault();

      this.layoutOpen = !this.layoutOpen;
      this.applyLayoutOpen();
      this.placeToolbar?.();
    };

    this.el.ownerDocument.addEventListener("click", this.onLayoutToggle, true);
    this.el.ownerDocument.addEventListener("dragstart", this.onGripDrag, true);
    this.el.ownerDocument.addEventListener("dragend", this.onDragEnd, true);

    this.el.addEventListener("dragenter", this.onDragEnter);
    this.el.addEventListener("dragover", this.onDragOver);
    this.el.addEventListener("drop", this.onDrop);
    this.el.addEventListener("dragend", this.onDragEnd);
    this.el.addEventListener("dragleave", this.onDragLeave);
    window.addEventListener("keydown", this.onKey);
    window.addEventListener("pb:dragend", this.onDragAway);
    announcePainted(this.el);
  },
  updated() {
    // A patch re-renders from the server's HTML, which does not carry the ring — the attribute is
    // client state. Re-applying it here is what keeps a selection visible across an unrelated
    // update.
    this.markSelected?.(this.selectedId);
    this.placeToolbar?.();
    announcePainted(this.el);
  },
  destroyed() {
    window.removeEventListener("scroll", this.placeToolbar);
    window.removeEventListener("resize", this.placeToolbar);
    this.el.removeEventListener("dblclick", this.onDblClick);
    this.el.removeEventListener("click", this.onClick);
    this.el.ownerDocument.removeEventListener("click", this.onCapture, true);
    this.el.ownerDocument.removeEventListener("mousedown", this.onPress, true);
    this.el.ownerDocument.removeEventListener("click", this.onLayoutToggle, true);
    this.el.ownerDocument.removeEventListener("click", this.onSelectClick, true);
    this.el.ownerDocument.removeEventListener("contextmenu", this.onContext);
    this.el.removeEventListener("submit", this.onSubmit);
    this.el.removeEventListener("dragstart", this.onDragStart);
    this.el.removeEventListener("dragenter", this.onDragEnter);
    this.el.removeEventListener("dragover", this.onDragOver);
    this.el.removeEventListener("drop", this.onDrop);
    this.el.removeEventListener("dragend", this.onDragEnd);
    this.el.removeEventListener("dragleave", this.onDragLeave);
    this.el.ownerDocument.removeEventListener("dragstart", this.onGripDrag, true);
    this.el.ownerDocument.removeEventListener("dragend", this.onDragEnd, true);
    this.el.ownerDocument.removeEventListener("scroll", this.forgetRects, true);
    window.removeEventListener("keydown", this.onKey);
    window.removeEventListener("pb:dragend", this.onDragAway);
    this.indicator?.remove();
  },
};

// A number field the server bounds, bounded on the client too. The gear panel it lives in is
// `phx-update="ignore"`, so once rendered its inputs are never patched again: a value the server
// clamps is stored clamped while the field keeps showing what was typed, for the rest of the
// session. Snapping on blur rather than on every keystroke leaves typing alone.
const NumberBounds = {
  mounted() {
    // `getAttribute`, not `el.min`: an absent bound reads as "" there and `Number("")` is 0, which
    // would hold every unbounded field to zero.
    const bound = (name) => {
      const raw = this.el.getAttribute(name);

      return raw === null || raw === "" ? null : Number(raw);
    };

    this.onBlur = () => {
      const value = Number(this.el.value);

      if (this.el.value === "" || Number.isNaN(value)) return;

      const min = bound("min");
      const max = bound("max");

      let bounded = value;

      if (min !== null && !Number.isNaN(min)) bounded = Math.max(min, bounded);
      if (max !== null && !Number.isNaN(max)) bounded = Math.min(max, bounded);

      if (bounded !== value) {
        this.el.value = String(bounded);
        this.el.dispatchEvent(new Event("input", { bubbles: true }));
      }
    };

    this.el.addEventListener("blur", this.onBlur);
  },
  destroyed() {
    this.el.removeEventListener("blur", this.onBlur);
  },
};

// The admin sidebar's scrolling nav. It is drawn by the LiveView layout, so every live navigation
// replaces it with a fresh element at the top; this puts it back where the reader left it. The
// position lives in `sessionStorage`, one per tab, so it also survives the full page loads into and
// out of the builder. With nothing saved, the active link is scrolled into view instead.
const SIDEBAR_SCROLL_KEY = "admin-sidebar:scrollTop";

const SidebarScroll = {
  mounted() {
    let saved = null;

    try {
      saved = sessionStorage.getItem(SIDEBAR_SCROLL_KEY);
    } catch (_denied) {
      // Private browsing may refuse sessionStorage; fall back to the active link below.
    }

    const top = saved === null ? NaN : parseInt(saved, 10);

    if (Number.isNaN(top)) {
      this.el.querySelector("[aria-current='page']")?.scrollIntoView({ block: "nearest" });
    } else {
      this.el.scrollTop = top;
    }

    this.frame = null;
    this.onScroll = () => {
      if (this.frame !== null) return;

      this.frame = requestAnimationFrame(() => {
        this.frame = null;

        // A nav already swapped out reads 0; keep the position the reader actually left.
        if (!this.el.isConnected) return;

        try {
          sessionStorage.setItem(SIDEBAR_SCROLL_KEY, String(this.el.scrollTop));
        } catch (_denied) {
          // Without storage the position is simply not kept.
        }
      });
    };

    this.el.addEventListener("scroll", this.onScroll, { passive: true });
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);

    if (this.frame !== null) cancelAnimationFrame(this.frame);
  },
};

export default {
  NumberBounds,
  SidebarScroll,
  UploadSubmitsItself,
  MediaThumb,
  MentionBox,
  DashboardGrid,
  DashboardTray,
  PbCanvas,
};
