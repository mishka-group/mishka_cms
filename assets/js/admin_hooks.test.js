import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import AdminHooks from "./admin_hooks.js";

afterEach(() => {
  document.body.innerHTML = "";
});

// The gear panel this field lives in is `phx-update="ignore"`, so the server can never patch the
// value back. Whatever the field shows after the reader leaves it is what they keep seeing.
describe("NumberBounds", () => {
  function field(attrs) {
    document.body.innerHTML = `<input type="number" ${attrs} />`;

    const el = document.querySelector("input");
    const hook = Object.create(AdminHooks.NumberBounds);

    hook.el = el;
    hook.mounted();

    return el;
  }

  function blur(el, typed) {
    el.value = typed;
    el.dispatchEvent(new Event("blur"));

    return el.value;
  }

  test("snaps down to the maximum", () => {
    expect(blur(field('min="1" max="12"'), "999")).toBe("12");
  });

  test("snaps up to the minimum", () => {
    expect(blur(field('min="1" max="12"'), "0")).toBe("1");
  });

  test("leaves a value inside the bounds alone", () => {
    expect(blur(field('min="1" max="12"'), "7")).toBe("7");
  });

  test("leaves an empty field empty, which is not a zero", () => {
    expect(blur(field('min="1" max="12"'), "")).toBe("");
  });

  test("does nothing without bounds to hold it to", () => {
    expect(blur(field(""), "999")).toBe("999");
  });

  // The correction has to reach the server too, or the field and the stored value disagree the
  // other way round.
  test("announces the value it settled on", () => {
    const el = field('min="1" max="12"');
    const seen = [];

    el.addEventListener("input", () => seen.push(el.value));
    blur(el, "999");

    expect(seen).toEqual(["12"]);
  });
});

// The sidebar nav is replaced on every live navigation; the hook puts the new one where the reader
// left the old one, and with nothing remembered shows the page's own link.
describe("SidebarScroll", () => {
  const KEY = "admin-sidebar:scrollTop";
  let frames;
  let storage;

  // A `sessionStorage` stand-in that records writes, or refuses every call like a private window.
  function fakeStorage({ refuse = false } = {}) {
    const values = new Map();
    const refuseCall = () => {
      throw new DOMException("denied", "SecurityError");
    };

    return {
      writes: [],
      getItem(key) {
        if (refuse) refuseCall();

        return values.has(key) ? values.get(key) : null;
      },
      setItem(key, value) {
        if (refuse) refuseCall();

        this.writes.push([key, value]);
        values.set(key, String(value));
      },
    };
  }

  beforeEach(() => {
    frames = [];
    storage = fakeStorage();
    vi.stubGlobal("sessionStorage", storage);
    vi.stubGlobal("requestAnimationFrame", (fn) => frames.push(fn));
    vi.stubGlobal("cancelAnimationFrame", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // jsdom has no layout, so `scrollTop` is held on the element by hand and every write recorded.
  function nav() {
    document.body.innerHTML = `
      <nav id="admin-sidebar-nav">
        <a href="/admin/dashboard/runtime/pages">Pages</a>
        <a href="/admin/dashboard/runtime/sites" aria-current="page">Sites</a>
      </nav>`;

    const el = document.querySelector("nav");
    const writes = [];
    let top = 0;

    Object.defineProperty(el, "scrollTop", {
      configurable: true,
      get: () => top,
      set: (value) => {
        top = value;
        writes.push(value);
      },
    });

    const active = el.querySelector("[aria-current='page']");
    active.scrollIntoView = vi.fn();

    return { el, writes, active };
  }

  function mount(el) {
    const hook = Object.create(AdminHooks.SidebarScroll);

    hook.el = el;
    hook.mounted();

    return hook;
  }

  function flush() {
    const pending = frames;

    frames = [];
    pending.forEach((fn) => fn(0));
  }

  test("puts a new nav back at the position the last one was left at", () => {
    storage.setItem(KEY, "240");
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([240]);
    expect(active.scrollIntoView).not.toHaveBeenCalled();
  });

  test("with nothing remembered, shows the active link without moving the rest", () => {
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([]);
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  test("treats a remembered value that is not a number as nothing remembered", () => {
    storage.setItem(KEY, "top");
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([]);
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  test("remembers where the reader scrolled, once a frame however many scroll events fire", () => {
    const { el } = nav();

    mount(el);
    el.scrollTop = 120;
    el.dispatchEvent(new Event("scroll"));
    el.scrollTop = 180;
    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(1);

    flush();

    expect(storage.writes).toEqual([[KEY, "180"]]);
  });

  test("keeps the last position when the nav was swapped out before its frame ran", () => {
    storage.setItem(KEY, "300");
    storage.writes = [];
    const { el } = nav();

    mount(el);
    el.dispatchEvent(new Event("scroll"));
    el.remove();
    flush();

    expect(storage.writes).toEqual([]);
    expect(storage.getItem(KEY)).toBe("300");
  });

  test("stops listening and drops a pending frame once destroyed", () => {
    const { el } = nav();
    const hook = mount(el);

    el.dispatchEvent(new Event("scroll"));
    hook.destroyed();

    expect(cancelAnimationFrame).toHaveBeenCalledTimes(1);

    frames = [];
    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(0);
  });

  test("works without storage, as in a private window", () => {
    storage = fakeStorage({ refuse: true });
    vi.stubGlobal("sessionStorage", storage);
    const { el, active } = nav();

    expect(() => mount(el)).not.toThrow();
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });

    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(1);
    expect(() => flush()).not.toThrow();
    expect(storage.writes).toEqual([]);
  });
});

// A chip puts its variable where the caret last was, in whichever text field of the SEO tab that
// was, and tells the form it changed.
describe("PbSeoFields", () => {
  function form() {
    document.body.innerHTML = `
      <form id="pb-seo-form">
        <input type="text" name="seo[title]" value="About us" data-seo-vars />
        <textarea name="seo[description]" data-seo-vars>Hello</textarea>
        <input type="text" name="seo[plain]" value="Plain" />
        <input type="text" id="pb-seo-image" name="seo[image]" value="" data-seo-vars />
        <select name="seo[type]"><option value="">Default</option></select>
        <button type="button" data-seo-var="{{site.name}}">site.name</button>
      </form>`;

    const el = document.querySelector("form");
    const hook = Object.create(AdminHooks.PbSeoFields);
    const handlers = {};

    hook.el = el;
    hook.handleEvent = (name, handler) => (handlers[name] = handler);
    hook.mounted();

    return { el, hook, handlers, chip: el.querySelector("[data-seo-var]") };
  }

  test("types a value the editor sends into its field, and announces it", () => {
    const { el, handlers } = form();
    const seen = [];

    el.addEventListener("input", (event) => seen.push([event.target.name, event.target.value]));
    handlers["pb-seo-set"]({ id: "pb-seo-image", value: "/uploads/cover.png" });

    expect(el.querySelector("#pb-seo-image").value).toBe("/uploads/cover.png");
    expect(seen).toEqual([["seo[image]", "/uploads/cover.png"]]);

    handlers["pb-seo-set"]({ id: "pb-seo-missing", value: "/x.png" });
    expect(seen.length).toBe(1);
  });

  function focus(field, caret) {
    field.focus();
    field.setSelectionRange(caret, caret);
  }

  test("inserts at the caret of the field last focused", () => {
    const { el, chip } = form();
    const title = el.querySelector("[name='seo[title]']");

    focus(title, 5);
    chip.focus();
    chip.click();

    expect(title.value).toBe("About{{site.name}} us");
    expect(title.selectionStart).toBe(5 + "{{site.name}}".length);
    expect(document.activeElement).toBe(title);
  });

  test("replaces a selection", () => {
    const { el, chip } = form();
    const description = el.querySelector("[name='seo[description]']");

    description.focus();
    description.setSelectionRange(0, 5);
    chip.click();

    expect(description.value).toBe("{{site.name}}");
  });

  test("announces the change so the form sends it", () => {
    const { el, chip } = form();
    const title = el.querySelector("[name='seo[title]']");
    const seen = [];

    el.addEventListener("input", (event) => seen.push(event.target.name));
    focus(title, 0);
    chip.click();

    expect(seen).toEqual(["seo[title]"]);
  });

  test("leaves a field that takes no variables alone, and fills the title's end instead", () => {
    const { el, chip } = form();
    const title = el.querySelector("[name='seo[title]']");
    const plain = el.querySelector("[name='seo[plain]']");

    focus(title, 0);
    focus(plain, 5);
    chip.click();

    expect(plain.value).toBe("Plain");
    expect(title.value).toBe("About us{{site.name}}");
  });

  test("goes to the end of the title before any field has been focused, and stays there", () => {
    const { el, chip } = form();
    const title = el.querySelector("[name='seo[title]']");

    el.querySelector("select").focus();
    chip.click();

    expect(title.value).toBe("About us{{site.name}}");
    expect(document.activeElement).toBe(title);
    expect(el.querySelector("[name='seo[description]']").value).toBe("Hello");

    chip.click();
    expect(title.value).toBe("About us{{site.name}}{{site.name}}");
  });

  test("finds the field again after it was replaced", () => {
    const { el, chip } = form();
    const title = el.querySelector("[name='seo[title]']");

    focus(title, 0);

    const replaced = title.cloneNode();
    replaced.value = "New";
    title.replaceWith(replaced);
    replaced.setSelectionRange(3, 3);
    chip.click();

    expect(replaced.value).toBe("New{{site.name}}");
  });

  test("stops listening when destroyed", () => {
    const { el, hook, chip } = form();
    const title = el.querySelector("[name='seo[title]']");

    focus(title, 0);
    hook.destroyed();
    chip.click();

    expect(title.value).toBe("About us");
  });
});
