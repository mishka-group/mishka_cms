// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { beforeEach, describe, expect, test } from "vitest";

import { syncHead } from "./head_sync.js";

const FIRST = `
  <meta charset="utf-8" />
  <title>First</title>
  <meta name="description" content="First page" data-mishka-seo />
  <link rel="canonical" href="https://example.test/docs/first" data-mishka-seo />
  <script type="application/ld+json" data-mishka-seo>{"name":"First"}</script>
  <link rel="stylesheet" href="/site.css" id="mishka-runtime-css" />
`;

const attrs = (selector) => [...document.head.querySelectorAll(selector)].map((n) => n.outerHTML);

beforeEach(() => {
  document.head.innerHTML = FIRST;
});

describe("syncHead", () => {
  test("replaces the marked tags with the ones the address resolved", () => {
    syncHead({
      tags: [
        { tag: "meta", attrs: { name: "description", content: "Second page" } },
        { tag: "link", attrs: { rel: "canonical", href: "https://example.test/docs/second" } },
      ],
      schema: ['{"name":"Second"}'],
    });

    expect(document.head.querySelector('meta[name="description"]').content).toBe("Second page");
    expect(document.head.querySelector('link[rel="canonical"]').href).toBe(
      "https://example.test/docs/second",
    );
    expect(document.head.querySelectorAll('meta[name="description"]')).toHaveLength(1);

    const schema = document.head.querySelectorAll('script[type="application/ld+json"]');
    expect(schema).toHaveLength(1);
    expect(schema[0].textContent).toBe('{"name":"Second"}');
  });

  test("marks what it draws, so the next patch replaces it", () => {
    syncHead({ tags: [{ tag: "meta", attrs: { name: "robots", content: "noindex" } }], schema: [] });
    expect(attrs("[data-mishka-seo]")).toHaveLength(1);

    syncHead({ tags: [], schema: [] });
    expect(attrs("[data-mishka-seo]")).toHaveLength(0);
  });

  test("leaves every tag the response did not mark where it is", () => {
    syncHead({ tags: [], schema: [] });

    expect(document.head.querySelector('meta[charset="utf-8"]')).not.toBeNull();
    expect(document.head.querySelector("title").textContent).toBe("First");
    expect(document.getElementById("mishka-runtime-css")).not.toBeNull();
  });

  test("writes a boolean attribute as present or absent, and a number as text", () => {
    syncHead({
      tags: [{ tag: "link", attrs: { rel: "preload", as: "font", crossorigin: true, hidden: false, width: 4 } }],
    });

    const link = document.head.querySelector('link[rel="preload"]');
    expect(link.hasAttribute("crossorigin")).toBe(true);
    expect(link.hasAttribute("hidden")).toBe(false);
    expect(link.getAttribute("width")).toBe("4");
  });

  test("draws only a meta or a link, and no event handler or odd attribute name", () => {
    syncHead({
      tags: [
        { tag: "script", attrs: { src: "/evil.js" } },
        { tag: "meta", attrs: { name: "robots", onload: "alert(1)", "data-x onclick": "alert(2)", content: "index" } },
        null,
        { tag: "meta" },
      ],
      schema: [42, null],
    });

    expect(document.head.querySelector("script[src]")).toBeNull();
    const meta = document.head.querySelector('meta[name="robots"]');
    expect(meta.getAttribute("content")).toBe("index");
    expect(meta.hasAttribute("onload")).toBe(false);
    expect(meta.attributes).toHaveLength(3);
    expect(document.head.querySelectorAll('script[type="application/ld+json"]')).toHaveLength(0);
  });

  test("takes a detail with no tags as an empty head", () => {
    syncHead(undefined);
    syncHead({});

    expect(attrs("[data-mishka-seo]")).toHaveLength(0);
  });
});

describe("syncHeadCode", () => {
  const everyPage = { key: "plausible", tag: "script", attrs: { defer: "defer", src: "https://plausible.io/js/script.js" }, content: "" };
  const pricing = { key: "pricing", tag: "meta", attrs: { name: "pricing-pixel", content: "1" }, content: null };

  beforeEach(() => {
    document.head.innerHTML =
      FIRST + `<script defer src="https://plausible.io/js/script.js" data-mishka-head="plausible"></script>`;
  });

  test("adds a page's entry and keeps the one on every page as it is", () => {
    const before = document.head.querySelector('[data-mishka-head="plausible"]');

    syncHead({ tags: [], schema: [], head_code: { nonce: "n0nce", items: [everyPage, pricing] } });

    expect(document.head.querySelector('[data-mishka-head="plausible"]')).toBe(before);
    expect(document.head.querySelectorAll('[data-mishka-head="plausible"]')).toHaveLength(1);
    expect(document.head.querySelector('meta[name="pricing-pixel"]').getAttribute("data-mishka-head")).toBe("pricing");
  });

  test("takes a page's entry out when the visitor leaves that page", () => {
    syncHead({ tags: [], schema: [], head_code: { nonce: "n0nce", items: [everyPage, pricing] } });
    syncHead({ tags: [], schema: [], head_code: { nonce: "n0nce", items: [everyPage] } });

    expect(document.head.querySelector('meta[name="pricing-pixel"]')).toBeNull();
    expect(document.head.querySelectorAll('[data-mishka-head="plausible"]')).toHaveLength(1);
  });

  test("gives an added script the nonce and drops handlers and a nonce of its own", () => {
    document.head.innerHTML = FIRST;

    syncHead({
      tags: [],
      schema: [],
      head_code: {
        nonce: "n0nce",
        items: [{ key: "k", tag: "script", attrs: { src: "/a.js", onload: "x()", nonce: "other" }, content: "" }],
      },
    });

    const script = document.head.querySelector('[data-mishka-head="k"]');
    expect(script.getAttribute("nonce")).toBe("n0nce");
    expect(script.hasAttribute("onload")).toBe(false);
  });

  test("leaves head code alone when the push carries none", () => {
    syncHead({ tags: [], schema: [] });

    expect(document.head.querySelectorAll("[data-mishka-head]")).toHaveLength(1);
  });
});
