// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// A LINK THAT LEAVES THE PREVIEW OPENS THE PUBLISHED PAGE IN A NEW TAB; ONE THAT STAYS, STAYS.
//
// The reported shape: a draft of a blog list, where a post's title is a `<.link navigate>` to the
// published post. Followed in the preview's own tab, the draft was gone and nothing said so.
//
// LiveView's click listener sits on window in the bubble phase, and a link it owns never reaches the
// browser's default. The stand-in below is registered the same way and BEFORE the preview script, as
// it is when the site bundle's tag comes first — so it is the capture phase, not load order, that has
// to put the preview's listener ahead, and "LiveView did not see it" is asserted rather than assumed.
const liveView = vi.fn();
window.addEventListener("click", (event) => liveView(event));
const liveViewSubmit = vi.fn();
window.addEventListener("submit", (event) => liveViewSubmit(event));
const { destination } = await import("./preview");

const here = "http://localhost/_preview/page/tok";

let opened;

function link(html) {
  document.body.innerHTML = html;
  return document.querySelector("a");
}

function click(el, init = {}) {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
  el.dispatchEvent(event);
  return event;
}

describe("a click in the preview", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/_preview/page/tok?page=2");
    opened = [];
    vi.spyOn(window, "open").mockImplementation((...args) => opened.push(args));
    liveView.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.body.innerHTML = "";
  });

  it("on a link to another page opens it published, in a new tab", () => {
    const a = link('<a href="/blog/post/hello" data-phx-link="redirect">Hello</a>');

    const event = click(a);

    expect(opened).toEqual([[`${window.location.origin}/blog/post/hello`, "_blank", "noopener"]]);
    expect(event.defaultPrevented).toBe(true);
    expect(liveView).not.toHaveBeenCalled();
  });

  it("on something INSIDE that link does the same — the case a target attribute misses", () => {
    link('<a href="/blog/post/hello" data-phx-link="redirect"><span id="t">Hello</span></a>');

    click(document.getElementById("t"));

    expect(opened).toHaveLength(1);
    expect(liveView).not.toHaveBeenCalled();
  });

  it("on a link to this preview is left to LiveView, so paging stays here", () => {
    const a = link('<a href="/_preview/page/tok?page=3" data-phx-link="patch">Next</a>');

    const event = click(a);

    expect(opened).toEqual([]);
    expect(event.defaultPrevented).toBe(false);
    expect(liveView).toHaveBeenCalledTimes(1);
  });

  it("with a modifier held is the browser's own new tab, not ours", () => {
    const a = link('<a href="/blog/post/hello">Hello</a>');

    click(a, { metaKey: true });
    click(a, { ctrlKey: true });

    expect(opened).toEqual([]);
  });

  it("on something that is not a link does nothing", () => {
    link('<a href="/elsewhere">x</a><button id="b">Sort</button>');

    click(document.getElementById("b"));

    expect(opened).toEqual([]);
    expect(liveView).toHaveBeenCalledTimes(1);
  });
});

describe("where a link goes", () => {
  const at = (html) => destination(link(html), { href: here });

  it("is nowhere new when it is this page — a hash, a query, the same path", () => {
    expect(at('<a href="#comments">c</a>')).toBeNull();
    expect(at('<a href="?page=4">4</a>')).toBeNull();
    expect(at('<a href="/_preview/page/tok?sort=oldest">s</a>')).toBeNull();
  });

  it("is the absolute published address for a path elsewhere, and another site as written", () => {
    expect(at('<a href="/blog">b</a>')).toBe("http://localhost/blog");
    expect(at('<a href="https://example.com/x">x</a>')).toBe("https://example.com/x");
  });

  it("is nothing to open for mail, phone, script, a download, or no href at all", () => {
    expect(at('<a href="mailto:a@b.c">m</a>')).toBeNull();
    expect(at('<a href="tel:123">t</a>')).toBeNull();
    expect(at('<a href="javascript:void(0)">j</a>')).toBeNull();
    expect(at('<a href="/file.pdf" download>d</a>')).toBeNull();
    expect(at("<a>none</a>")).toBeNull();
  });
});

// A PREVIEW DRAWS THE PAGE'S REAL FORMS — a sign-in page's included — so none of them may submit.
describe("a form in the preview", () => {
  afterEach(() => {
    document.body.innerHTML = "";
    liveViewSubmit.mockClear();
  });

  it("submits nothing, to LiveView or to the browser", () => {
    document.body.innerHTML =
      '<form id="f" action="/api/auth/user/password/sign_in" method="post" phx-submit="sign_in"><input name="email"></form>';

    const event = new Event("submit", { bubbles: true, cancelable: true });
    document.getElementById("f").dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(liveViewSubmit).not.toHaveBeenCalled();
  });
});
