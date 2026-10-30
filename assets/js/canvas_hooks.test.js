// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, describe, expect, test } from "vitest";

import { handOverHooks, handedOverHooks } from "./canvas_hooks.js";

// The page builder's canvas: a site's bundle marked for its hooks alone, then the admin's `app.js`.
const script = (marked) => {
  const el = document.createElement("script");
  el.src = "/assets/js/localhost/cafe.js";
  if (marked) el.setAttribute("data-mishka-site-hooks", "");
  return el;
};

const GlobalChelekomFloating = { mounted() {} };
const LocalhostDocToc = { mounted() {} };

afterEach(() => {
  delete window.MishkaSiteHooks;
});

describe("handOverHooks", () => {
  test("a bundle marked for its hooks hands them over and opens no socket", () => {
    expect(handOverHooks({ GlobalChelekomFloating }, script(true))).toBe(true);

    expect(handedOverHooks()).toEqual({ GlobalChelekomFloating });
  });

  test("a bundle loaded as a page's own script keeps its hooks and boots", () => {
    expect(handOverHooks({ GlobalChelekomFloating }, script(false))).toBe(false);

    expect(handedOverHooks()).toEqual({});
  });

  test("a script that is not running from a tag boots as before", () => {
    expect(handOverHooks({ GlobalChelekomFloating }, null)).toBe(false);
  });

  test("two marked bundles add up rather than replace each other", () => {
    handOverHooks({ GlobalChelekomFloating }, script(true));
    handOverHooks({ LocalhostDocToc }, script(true));

    expect(handedOverHooks()).toEqual({ GlobalChelekomFloating, LocalhostDocToc });
  });
});

describe("handedOverHooks", () => {
  test("is empty where no bundle handed anything over, as on every public page", () => {
    expect(handedOverHooks()).toEqual({});
  });
});
