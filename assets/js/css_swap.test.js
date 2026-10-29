// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { beforeEach, describe, expect, test } from "vitest";

import { swapRuntimeCss } from "./css_swap.js";

const address = (c) => `/assets/css/localhost/${c.repeat(32)}.css`;
const A = address("a");
const B = address("b");
const C = address("c");

// The builder's canvas: its bundle, then the style the browser generator injects after it.
const HEAD = `
  <link rel="stylesheet" href="${A}" id="mishka-runtime-css" />
  <style id="generated">.pl-\\[30px\\]{padding-left:30px}</style>
`;

const sheets = () =>
  [...document.head.querySelectorAll("link[rel=stylesheet]")].map((l) => ({
    href: l.getAttribute("href"),
    id: l.id || null,
    pending: l.hasAttribute("data-mishka-runtime-css-pending"),
  }));

const pendingLink = () => document.head.querySelector("link[data-mishka-runtime-css-pending]");

beforeEach(() => {
  document.head.innerHTML = HEAD;
});

describe("swapRuntimeCss", () => {
  test("puts the newer sheet beside the old one, above anything after it", () => {
    swapRuntimeCss({ href: B });

    expect(sheets()).toEqual([
      { href: A, id: "mishka-runtime-css", pending: false },
      { href: B, id: null, pending: true },
    ]);

    expect(document.head.lastElementChild.id).toBe("generated");
  });

  test("the old sheet leaves only once the newer has loaded", () => {
    swapRuntimeCss({ href: B });
    pendingLink().onload();

    expect(sheets()).toEqual([{ href: B, id: "mishka-runtime-css", pending: false }]);
    expect(document.head.lastElementChild.id).toBe("generated");
  });

  test("a sheet that fails to load leaves the last one in place", () => {
    swapRuntimeCss({ href: B });
    pendingLink().onerror();

    expect(sheets()).toEqual([{ href: A, id: "mishka-runtime-css", pending: false }]);
  });

  // Two rebuilds close together used to leave the first one's link behind without an id, so the
  // second was appended after the generated styles and overruled them.
  test("a newer sheet outranks one still loading, and stays above the generated styles", () => {
    swapRuntimeCss({ href: B });
    const first = pendingLink();

    swapRuntimeCss({ href: C });

    expect(first.isConnected).toBe(false);
    expect(sheets()).toEqual([
      { href: A, id: "mishka-runtime-css", pending: false },
      { href: C, id: null, pending: true },
    ]);

    first.onload();
    expect(sheets()[0]).toEqual({ href: A, id: "mishka-runtime-css", pending: false });

    pendingLink().onload();
    expect(sheets()).toEqual([{ href: C, id: "mishka-runtime-css", pending: false }]);
    expect(document.head.lastElementChild.id).toBe("generated");
  });

  // An undo gives the same bytes back, so the same address: the change still loading is dropped.
  test("going back to the address it links drops the one still loading", () => {
    swapRuntimeCss({ href: B });
    swapRuntimeCss({ href: A });

    expect(sheets()).toEqual([{ href: A, id: "mishka-runtime-css", pending: false }]);
  });

  test("an address it already links or is already loading changes nothing", () => {
    swapRuntimeCss({ href: A });
    expect(sheets()).toEqual([{ href: A, id: "mishka-runtime-css", pending: false }]);

    swapRuntimeCss({ href: B });
    const loading = pendingLink();
    swapRuntimeCss({ href: B });

    expect(pendingLink()).toBe(loading);
    expect(sheets()).toHaveLength(2);
  });

  // The builder's canvas drawn before anything compiled: an empty link holds the bundle's place.
  test("an empty link's place is where the first bundle goes, above the generated styles", () => {
    document.head.innerHTML = `
      <link rel="stylesheet" id="mishka-runtime-css" />
      <style id="generated"></style>
    `;

    swapRuntimeCss({ href: B });
    pendingLink().onload();

    expect(sheets()).toEqual([{ href: B, id: "mishka-runtime-css", pending: false }]);
    expect(document.head.lastElementChild.id).toBe("generated");
  });

  test("a page served before the first compile takes the sheet as its own", () => {
    document.head.innerHTML = "";

    swapRuntimeCss({ href: B });

    expect(sheets()).toEqual([{ href: B, id: "mishka-runtime-css", pending: false }]);
  });

  test("refuses anything that is not a bundle address", () => {
    for (const href of [
      "https://evil.test/x.css",
      "/assets/css/localhost/abc.css",
      "/assets/css/../admin.css",
      `/assets/css/localhost/${"a".repeat(32)}`,
      undefined,
    ]) {
      swapRuntimeCss({ href });
    }

    swapRuntimeCss(undefined);

    expect(sheets()).toEqual([{ href: A, id: "mishka-runtime-css", pending: false }]);
  });
});
