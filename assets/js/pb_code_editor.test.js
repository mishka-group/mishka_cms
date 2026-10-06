import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// WHAT A CODE BOX DOES WHEN CODEMIRROR DOES NOT ARRIVE. The editor is not in the admin bundle; it is
// a second script fetched the first time a box appears. So there is a window in which it can fail —
// a rebuild of the bundle under an open tab, a restart between the page load and the first box — and
// the question these answer is whether that failure is survivable or terminal.
//
// It was terminal. The promise was cached whatever became of it, so one bad fetch turned every code
// box in that tab into a plain textarea, permanently, through live navigation and every reselection,
// and only a browser reload put it back. That is the shape of the bug reported as "the editor stopped
// showing code" — and the shape of the fix that closed it is: the next box tries again.

function scripts() {
  return Array.from(document.head.querySelectorAll("script"));
}

function pending() {
  const list = scripts();

  return list[list.length - 1];
}

async function loader() {
  vi.resetModules();

  return await import("./pb_code_editor.js");
}

beforeEach(() => {
  document.head.innerHTML = '<meta name="pb-code-editor-src" content="/assets/js/code_editor.js" />';
  delete window.PbCodeMirror;
});

afterEach(() => {
  document.head.innerHTML = "";
  delete window.PbCodeMirror;
});

describe("fetching the editor", () => {
  test("a box that loads it gets what the bundle defined", async () => {
    const { loadEditor } = await loader();
    const promise = loadEditor();

    window.PbCodeMirror = { create: () => {} };
    pending().onload();

    await expect(promise).resolves.toBe(window.PbCodeMirror);
  });

  test("a bundle that loads without defining anything is a failure, not a success", async () => {
    const { loadEditor } = await loader();
    const promise = loadEditor();

    pending().onload();

    await expect(promise).rejects.toThrow("without PbCodeMirror");
  });

  test("two boxes mounting together share one request", async () => {
    const { loadEditor } = await loader();

    const first = loadEditor();
    const second = loadEditor();

    expect(scripts()).toHaveLength(1);

    window.PbCodeMirror = { create: () => {} };
    pending().onload();

    await expect(first).resolves.toBe(await second);
  });

  // THE REGRESSION. Before, this second call returned the first call's settled rejection and no
  // second request was ever made.
  test("and a box opened after a failure tries again", async () => {
    const { loadEditor } = await loader();

    const failed = loadEditor();

    pending().onerror();
    await expect(failed).rejects.toThrow("could not load");

    expect(scripts()).toHaveLength(0);

    const retry = loadEditor();

    expect(scripts()).toHaveLength(1);

    window.PbCodeMirror = { create: () => {} };
    pending().onload();

    await expect(retry).resolves.toBe(window.PbCodeMirror);
  });

  // A TRUNCATED FILE IS A 200 WITH AN ETAG. Asking for the same address again is answered out of the
  // cache with the same broken bytes, so the retry has to be a different request.
  test("and asks for it at an address the cache cannot answer", async () => {
    const { loadEditor } = await loader();

    const failed = loadEditor();
    const src = pending().src;

    pending().onerror();
    await expect(failed).rejects.toThrow();

    loadEditor();

    expect(pending().src).not.toBe(src);
    expect(pending().src).toContain("retry=");
  });

  test("no address published, no request attempted", async () => {
    document.head.innerHTML = "";

    const { loadEditor } = await loader();

    await expect(loadEditor()).rejects.toThrow("no pb-code-editor-src meta tag");
    expect(scripts()).toHaveLength(0);
  });
});

// A handler the Code window adds or points at is marked `data-focus`, and takes the cursor.
describe("a box the server focuses", () => {
  function box(focused) {
    const el = document.createElement("div");
    if (focused) el.setAttribute("data-focus", "");
    el.innerHTML = "<textarea>IO.inspect(params)</textarea>";
    document.body.appendChild(el);

    return el;
  }

  async function mount(el) {
    const { PbCodeEditor } = await loader();
    const hook = Object.assign(Object.create(PbCodeEditor), { el });

    hook.mounted();
    await new Promise((resolve) => setTimeout(resolve, 0));

    return hook;
  }

  beforeEach(() => {
    Element.prototype.scrollIntoView = vi.fn();
  });

  afterEach(() => {
    document.body.innerHTML = "";
    delete Element.prototype.scrollIntoView;
  });

  test("scrolls into view and focuses the editor", async () => {
    const view = { focus: vi.fn(), destroy: () => {} };
    window.PbCodeMirror = { create: () => view };
    const el = box(true);

    await mount(el);

    expect(view.focus).toHaveBeenCalled();
    expect(el.scrollIntoView).toHaveBeenCalled();
  });

  test("focuses the plain box when the editor does not load", async () => {
    const el = box(true);
    const hook = await mount(el);

    pending().onerror();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(document.activeElement).toBe(el.querySelector("textarea"));
    expect(hook.view).toBeUndefined();
  });

  test("and a box nobody focused is left alone", async () => {
    const view = { focus: vi.fn(), destroy: () => {} };
    window.PbCodeMirror = { create: () => view };
    const el = box(false);

    await mount(el);

    expect(view.focus).not.toHaveBeenCalled();
    expect(el.scrollIntoView).not.toHaveBeenCalled();
  });
});
