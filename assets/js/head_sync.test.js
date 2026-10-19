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
