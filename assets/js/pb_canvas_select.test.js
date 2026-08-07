import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// WHAT WAS CLICKED IS NOT ALWAYS WHAT CAN BE EDITED.
//
// Two things used to swallow a canvas click. A kit component carries its own `phx-click` — flash,
// toast, banner and badge all bind a dismiss — and LiveView binds the INNERMOST one, so clicking a
// toast ran its dismiss and hid it instead of selecting it. And a run of text, an EEx expression or
// a comment carries nothing to style, so selecting one opened a panel whose only offer was a button
// reading "Style the element around it" — the words in a heading cost two clicks to reach the
// heading.
//
// Both are resolved before the click reaches LiveView, so both are asserted on the resolution rather
// than through a browser: jsdom does no layout, and none of this is about layout.
function context(el, { preview = false } = {}) {
  el.dataset.preview = String(preview);

  // `markSelected` is DEFINED BY THE HOOK in `mounted()`, so a spy handed in here is overwritten.
  // What it does is observable in the DOM — it stamps `data-selected` — so that is what is read.
  return {
    el,
    pushed: [],
    pushEvent(name, payload) {
      this.pushed.push([name, payload]);
    },
    handleEvent: () => {},
  };
}

// PbCanvas binds on the DOCUMENT, not on its own element, so a hook left mounted goes on hearing
// every click in every later test — and its `markSelected` stamps `data-selected` on whatever it
// finds in the document it can still see. Each mount is torn down for that reason.
const live = [];

function canvas(html, opts) {
  document.body.innerHTML = `<div id="pb-canvas-root">${html}</div>`;
  const el = document.getElementById("pb-canvas-root");
  const ctx = context(el, opts);
  hooks.PbCanvas.mounted.call(ctx);
  live.push(ctx);
  return ctx;
}

function selected() {
  const el = document.querySelector('[data-node-id][data-selected="true"]');
  return el ? el.dataset.nodeId : null;
}

function clickOn(selector) {
  const target = document.querySelector(selector);
  const event = new MouseEvent("click", { bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  return event;
}

// A real double click is click, click, dblclick — and the first two resolve upwards, so a test that
// dispatched only the last one would assert the second click's answer against a selection the first
// two never made.
function doubleClickOn(selector) {
  const target = document.querySelector(selector);
  clickOn(selector);
  clickOn(selector);
  const event = new MouseEvent("dblclick", { bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  return event;
}

describe("canvas click resolution", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    // jsdom ships neither of these, and the hook's own `markSelected` uses both — without them it
    // throws before the click is ever re-sent, which reads exactly like the handler not running.
    vi.stubGlobal("CSS", { escape: (value) => value });
    Element.prototype.scrollIntoView = vi.fn();
  });

  afterEach(() => {
    while (live.length) hooks.PbCanvas.destroyed.call(live.pop());
  });

  it("selects a styleable element directly", () => {
    const ctx = canvas('<div data-node-id="d1" data-kind="tag"><b id="hit">x</b></div>');

    clickOn("#hit");

    expect(selected()).toBe("d1");
    // Nothing to re-send: the wrapper's own `select` reports the right id.
    expect(ctx.pushed).toEqual([]);
  });

  // ITEM 4. The words in a heading are the heading.
  it("resolves a text run to the element around it", () => {
    const ctx = canvas(
      '<h2 data-node-id="h2" data-kind="tag"><span id="hit" data-node-id="t1" data-kind="text">About</span></h2>',
    );

    const event = clickOn("#hit");

    expect(ctx.pushed).toEqual([["select", { id: "h2" }]]);
    expect(event.defaultPrevented).toBe(true);
  });

  it("resolves eex and comments the same way", () => {
    for (const kind of ["eex", "eex_block", "eex_comment", "html_comment"]) {
      const ctx = canvas(
        `<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="${kind}">x</span></div>`,
      );

      clickOn("#hit");

      expect(ctx.pushed, kind).toEqual([["select", { id: "p1" }]]);
    }
  });

  it("climbs past several unstyleable levels", () => {
    const ctx = canvas(
      '<div data-node-id="root" data-kind="tag">' +
        '<span data-node-id="e1" data-kind="eex">' +
        '<span id="hit" data-node-id="t1" data-kind="text">x</span>' +
        "</span></div>",
    );

    clickOn("#hit");

    expect(ctx.pushed).toEqual([["select", { id: "root" }]]);
  });

  it("leaves a text run selected when nothing styleable is around it", () => {
    const ctx = canvas('<span id="hit" data-node-id="t1" data-kind="text">x</span>');

    clickOn("#hit");

    expect(selected()).toBe("t1");
    expect(ctx.pushed).toEqual([]);
  });

  // ITEM 1. A component's own dismiss must not run in the editor.
  it("stops a component's own binding and selects the component", () => {
    const ctx = canvas(
      '<div data-node-id="toast" data-kind="component">' +
        '<button id="hit" phx-click="dismiss">x</button>' +
        "</div>",
    );

    const event = clickOn("#hit");

    expect(ctx.pushed).toEqual([["select", { id: "toast" }]]);
    expect(event.defaultPrevented).toBe(true);
  });

  it("does nothing at all in preview — there a click is the page's, not the editor's", () => {
    const ctx = canvas(
      '<div data-node-id="toast" data-kind="component">' +
        '<button id="hit" phx-click="dismiss">x</button>' +
        "</div>",
      { preview: true },
    );

    clickOn("#hit");

    // Only the selection is asserted. Whether the click's default is prevented belongs to the
    // separate capture guard for links and submits, which is not what this test is about.
    expect(ctx.pushed).toEqual([]);
    expect(selected()).toBe(null);
  });

  it("still holds a second element on meta-click, from the resolved node", () => {
    const ctx = canvas(
      '<h2 data-node-id="h2" data-kind="tag"><span id="hit" data-node-id="t1" data-kind="text">x</span></h2>',
    );

    const target = document.getElementById("hit");
    target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true }));

    expect(ctx.pushed).toEqual([["mark", { id: "h2" }]]);
  });
  // A LINK'S WORDS ARE STILL THE LINK. Clicks on links and submits are answered by a separate
  // capture guard, which must not navigate the canvas away from the document being edited — it also
  // selects, and for a while it selected the raw node while the ordinary path resolved. A nav link
  // then behaved differently from a paragraph, which is the inconsistency this whole item is about.
  it("resolves through the link guard as well", () => {
    const ctx = canvas(
      '<a href="/about" data-node-id="a1" data-kind="tag">' +
        '<span id="hit" data-node-id="t1" data-kind="text">About</span>' +
        "</a>",
    );

    const event = clickOn("#hit");

    expect(ctx.pushed).toEqual([["select", { id: "a1" }]]);
    // And it must not navigate.
    expect(event.defaultPrevented).toBe(true);
  });
});

// PREVIEW IS A PICTURE OF THE UNSAVED PAGE, NOT THE PAGE. Nothing behind it runs — no request, live
// components drawn cold — so a click there cannot follow a link and must not stand in for one by
// moving the Inspector. Every way a click in the frame reaches the editor is asserted here, because
// guarding one of them left the others selecting with editing off.
describe("a click in preview", () => {
  let posted;

  beforeEach(() => {
    document.body.innerHTML = "";
    posted = [];
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    vi.stubGlobal("CSS", { escape: (value) => value });
    Element.prototype.scrollIntoView = vi.fn();
    vi.spyOn(window.parent, "postMessage").mockImplementation((message) => posted.push(message));
  });

  afterEach(() => {
    while (live.length) hooks.PbCanvas.destroyed.call(live.pop());
    vi.restoreAllMocks();
  });

  it("on a link neither navigates nor selects", () => {
    const ctx = canvas(
      '<div data-node-id="c" data-kind="component"><a id="hit" href="/x">x</a></div>',
      { preview: true },
    );

    const event = clickOn("#hit");

    expect(ctx.pushed).toEqual([]);
    expect(event.defaultPrevented).toBe(true);
  });

  it("on a submit neither submits nor selects", () => {
    const ctx = canvas(
      '<form data-node-id="f" data-kind="tag"><button id="hit" type="submit">go</button></form>',
      { preview: true },
    );

    const event = clickOn("#hit");

    expect(ctx.pushed).toEqual([]);
    expect(event.defaultPrevented).toBe(true);
  });

  // Missing every node is a deselect while editing, and with a palette item armed the same push
  // places it.
  it("on no node at all clears nothing", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag">x</div><i id="hit">outside</i>',
      { preview: true },
    );

    clickOn("#hit");

    expect(ctx.pushed).toEqual([]);
  });

  it("with the right button opens the browser's menu, not the editor's", () => {
    canvas('<div data-node-id="p1" data-kind="tag"><b id="hit">x</b></div>', { preview: true });

    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    document.getElementById("hit").dispatchEvent(event);

    expect(posted.filter((message) => message.kind === "context")).toEqual([]);
    expect(event.defaultPrevented).toBe(false);
  });
});

// THE SECOND CLICK SAYS "NO, THAT ONE".
//
// Resolving upwards is right for the common case and left no way at all to reach what was under the
// pointer. `{@size}` alone in a `<div>` selected the div, the Inspector showed the div, and the one
// node whose source somebody wanted to edit could not be selected from the canvas at all — the rail
// was the only way in, and in the rail it is a row with no children, easy to miss.
describe("double click selects the node under the pointer", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    vi.stubGlobal("CSS", { escape: (value) => value });
    Element.prototype.scrollIntoView = vi.fn();
  });

  afterEach(() => {
    while (live.length) hooks.PbCanvas.destroyed.call(live.pop());
  });

  // NOT A SPECIAL CASE FOR EXPRESSIONS. It is every kind the single click resolves past, on the same
  // rule, so a comment behaves the way a token does without either being named in the hook.
  it("reaches every kind a single click resolves past", () => {
    for (const kind of ["eex", "eex_block", "eex_comment", "html_comment"]) {
      const ctx = canvas(
        `<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="${kind}">x</span></div>`,
      );

      const event = doubleClickOn("#hit");

      expect(ctx.pushed.at(-1), kind).toEqual(["select", { id: "c1" }]);
      expect(selected(), kind).toBe("c1");
      expect(event.defaultPrevented, kind).toBe(true);
    }
  });

  // And the single click on its own is untouched — it still answers with the element around it.
  it("while one click still resolves upwards", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="e1" data-kind="eex">x</span></div>',
    );

    clickOn("#hit");

    expect(ctx.pushed).toEqual([["select", { id: "p1" }]]);
    expect(selected()).toBe("p1");
  });

  // A DOUBLE CLICK ON TEXT IS STILL A DOUBLE CLICK ON TEXT. Editing in place is the older gesture
  // and the more valuable one; this must not have taken it away.
  it("leaves text editing exactly where it was", () => {
    const ctx = canvas(
      '<h2 data-node-id="h2" data-kind="tag"><span id="hit" data-node-id="t1" data-kind="text">About</span></h2>',
    );

    doubleClickOn("#hit");

    const text = document.getElementById("hit");
    expect(text.getAttribute("contenteditable")).toBe("plaintext-only");
    expect(ctx.pushed.at(-1)).toEqual(["select", { id: "h2" }]);
  });

  // Nothing was resolved past, so there is nothing a second click could mean that the first did not.
  it("does nothing extra on a node the single click already reached", () => {
    const ctx = canvas('<div data-node-id="d1" data-kind="tag"><b id="hit">x</b></div>');

    const event = doubleClickOn("#hit");

    expect(ctx.pushed).toEqual([]);
    expect(event.defaultPrevented).toBe(false);
  });

  it("and nothing at all in preview", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="e1" data-kind="eex">x</span></div>',
      { preview: true },
    );

    doubleClickOn("#hit");

    expect(ctx.pushed).toEqual([]);
    expect(selected()).toBe(null);
  });

  // Clicking nothing is already a deselect, twice over. What matters is that the second click adds
  // nothing to it — there is no node under the pointer for it to have meant.
  it("and nothing of its own when the pointer is on no node at all", () => {
    const ctx = canvas('<div data-node-id="p1" data-kind="tag">x</div><i id="hit">outside</i>');

    doubleClickOn("#hit");

    expect(ctx.pushed).toEqual([
      ["select", {}],
      ["select", {}],
    ]);
  });
});

// THE TOOLBAR ARRIVES BETWEEN THE TWO CLICKS. The first click selects the element around the
// pointer, and that can put the toolbar where the pointer is: an element near the top of the frame
// is scrolled clear of the toolbar's band and the bar takes the chip's old spot, and one taller than
// the frame gets the bar pinned over its content. In a browser the second click and the `dblclick`
// then land on the toolbar, not on the chip that was pointed at. `doubleClickOn` above dispatches
// all three on the chip, which is the one sequence such a double click never produces.
describe("a double click the toolbar slid under", () => {
  const toolbar =
    '<div id="pb-el-toolbar"><button id="pb-eltb-delete" type="button" phx-click="toolbar">x</button></div>';

  let heard;

  beforeEach(() => {
    document.body.innerHTML = "";
    vi.stubGlobal("requestAnimationFrame", (fn) => fn(0));
    vi.stubGlobal("CSS", { escape: (value) => value });
    Element.prototype.scrollIntoView = vi.fn();
    // Where LiveView listens for `phx-click`: a click that reaches this would press the button.
    heard = vi.fn();
    window.addEventListener("click", heard);
  });

  afterEach(() => {
    window.removeEventListener("click", heard);
    while (live.length) hooks.PbCanvas.destroyed.call(live.pop());
  });

  // `detail` is the browser's click count, which is how the second press of a gesture is told apart.
  function press(selector, detail) {
    const event = new MouseEvent("click", { bubbles: true, cancelable: true, detail });
    document.querySelector(selector).dispatchEvent(event);
    return event;
  }

  function dblclick(selector) {
    const event = new MouseEvent("dblclick", { bubbles: true, cancelable: true, detail: 2 });
    document.querySelector(selector).dispatchEvent(event);
    return event;
  }

  it("still selects the node the gesture began on", () => {
    for (const kind of ["eex", "eex_block", "eex_comment", "html_comment"]) {
      const ctx = canvas(
        `<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="${kind}">x</span></div>` +
          toolbar,
      );

      press("#hit", 1);
      heard.mockClear();
      const second = press("#pb-eltb-delete", 2);
      dblclick("#pb-el-toolbar");

      expect(ctx.pushed.at(-1), kind).toEqual(["select", { id: "c1" }]);
      expect(selected(), kind).toBe("c1");
      // And the button that slid under the pointer was never pressed, nor was a link followed.
      expect(second.defaultPrevented, kind).toBe(true);
      expect(heard, kind).not.toHaveBeenCalled();

      hooks.PbCanvas.destroyed.call(live.pop());
    }
  });

  it("still opens the words it began on for editing", () => {
    const ctx = canvas(
      '<h2 data-node-id="h2" data-kind="tag"><span id="hit" data-node-id="t1" data-kind="text">About</span></h2>' +
        toolbar,
    );

    press("#hit", 1);
    press("#pb-eltb-delete", 2);
    dblclick("#pb-el-toolbar");

    expect(document.getElementById("hit").getAttribute("contenteditable")).toBe("plaintext-only");
    expect(ctx.pushed).toEqual([["select", { id: "h2" }]]);
  });

  it("answers from the first press when the chip moved before the second", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="eex">x</span></div>' +
        '<div data-node-id="p2" data-kind="tag"><span id="moved" data-node-id="c2" data-kind="eex">y</span></div>',
    );

    press("#hit", 1);
    press("#moved", 2);
    dblclick("#moved");

    expect(ctx.pushed).toEqual([
      ["select", { id: "p1" }],
      ["select", { id: "c1" }],
    ]);
    expect(selected()).toBe("c1");
  });

  // The third press of a triple-click lands on the same toolbar the second one did.
  it("swallows every later press of the gesture, not only the second", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="eex">x</span></div>' +
        toolbar,
    );

    press("#hit", 1);
    press("#pb-eltb-delete", 2);
    dblclick("#pb-el-toolbar");
    heard.mockClear();
    const third = press("#pb-eltb-delete", 3);

    expect(third.defaultPrevented).toBe(true);
    expect(heard).not.toHaveBeenCalled();
    expect(ctx.pushed.at(-1)).toEqual(["select", { id: "c1" }]);
  });

  it("leaves the toolbar's own clicks alone", () => {
    canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="eex">x</span></div>' +
        toolbar,
    );

    press("#hit", 1);
    const single = press("#pb-eltb-delete", 1);

    expect(single.defaultPrevented).toBe(false);
    expect(heard).toHaveBeenCalledTimes(1);

    // A gesture that began ON the toolbar is the toolbar's, second press included.
    const again = press("#pb-eltb-delete", 2);

    expect(again.defaultPrevented).toBe(false);
    expect(heard).toHaveBeenCalledTimes(2);
  });

  // There a double click is the page's own — a component's client-side toggle still runs — not the
  // editor's.
  it("and swallows nothing in preview", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="hit" data-node-id="c1" data-kind="eex">x</span></div>',
      { preview: true },
    );

    press("#hit", 1);
    heard.mockClear();
    const second = press("#hit", 2);
    dblclick("#hit");

    expect(second.defaultPrevented).toBe(false);
    expect(heard).toHaveBeenCalledTimes(1);
    expect(ctx.pushed).toEqual([]);
  });

  // Leaving preview is a patch, and one can land between two presses of the same double click.
  it("and never answers from a press made before a gesture that began in preview", () => {
    const ctx = canvas(
      '<div data-node-id="p1" data-kind="tag"><span id="before" data-node-id="c1" data-kind="eex">x</span></div>' +
        '<div data-node-id="p2" data-kind="tag"><span id="hit" data-node-id="c2" data-kind="eex">y</span></div>',
    );

    press("#before", 1);
    ctx.el.dataset.preview = "true";
    press("#hit", 1);
    ctx.el.dataset.preview = "false";
    press("#hit", 2);
    dblclick("#hit");

    expect(ctx.pushed.at(-1)).toEqual(["select", { id: "c2" }]);
    expect(selected()).toBe("c2");
  });
});
