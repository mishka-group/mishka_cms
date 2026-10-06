import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, test } from "vitest";

import { CompletionContext } from "@codemirror/autocomplete";
import { EditorState } from "@codemirror/state";
import { cssCompletionSource } from "@codemirror/lang-css";
import { ensureSyntaxTree } from "@codemirror/language";

import { EditorView } from "@codemirror/view";

import { extensionsFor, languageOf } from "./code_editor.js";

// WHAT THE ELEMENT CSS BOX ACTUALLY CONTAINS. The author's text is wrapped in `.pb-xxxxxxxx { … }`
// before it is served, so the box is a DECLARATION LIST — the element is already chosen, and writing
// a selector is how the mistake happens. Parsed with the grammar's default `StyleSheet` top rule the
// top level is where selectors go instead, and every reader downstream inherits that reading.
function stateOf(doc) {
  return EditorState.create({ doc, extensions: languageOf("css") });
}

function completionsAt(doc) {
  const state = stateOf(doc);
  const pos = doc.length;

  ensureSyntaxTree(state, pos, 5000);

  const result = cssCompletionSource(new CompletionContext(state, pos, false));

  return result ? result.options.map((option) => option.label) : [];
}

describe("the CSS box parses its contents as declarations", () => {
  test("the top of the document is a declaration list, not a stylesheet", () => {
    const state = stateOf("color: red;");
    const tree = ensureSyntaxTree(state, state.doc.length, 5000);

    expect(tree.topNode.name).toBe("Styles");
  });

  // THE BUG THIS FIXES. `dire` at the top level parsed as a `TagName`, and lang-css answers that
  // position with the list it has for it: HTML tag names. So `direction` — and every other property
  // — could not be completed at the one place this box expects them.
  test("a half-typed property completes to properties", () => {
    const labels = completionsAt("dire");

    expect(labels).toContain("direction");
    expect(labels).not.toContain("div");
  });

  test("and so does one written after another declaration", () => {
    expect(completionsAt("color: red;\nbackgr")).toContain("background-color");
  });

  test("a value still completes after the colon", () => {
    expect(completionsAt("display: fl")).toContain("flex");
  });

  // `&` is how the box says "this element", so nesting has to keep working.
  test("nesting still parses, and completes inside the block", () => {
    expect(completionsAt("&:hover {\n  opac")).toContain("opacity");
  });
});

// THE DARK PANE IS A PLACE TEXT GOES TO DIE. Reported on the editor issue as "the text isn't
// legible in the CSS box — the text is dark": the gutter's line numbers were `#56545e`, which is
// 2.4:1 against the pane and effectively invisible, and the way back out of a narrowed pane was
// 3.6:1. Both are readable now, and nothing here is allowed to sink below AA again.
//
// The check reads the SOURCE rather than importing the theme, because `EditorView.theme()` hands
// back an opaque extension — the colours cannot be read back off it. Matching `color:` on a word
// boundary is what keeps `caretColor`, `borderLeftColor` and every `backgroundColor` out: those are
// not text, and a selection tint is supposed to be close to its background.
describe("nothing in the editor's theme is too dark to read", () => {
  // Resolved from the runner's cwd (`assets/`, where `package.json` lives) rather than from
  // `import.meta.url`, which the jsdom transform does not hand back as a file: URL.
  const source = readFileSync(resolve(process.cwd(), "js/code_editor.js"), "utf8");
  const PANE = "#17161a";

  function channel(v) {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }

  function luminance(hex) {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  }

  function contrast(a, b) {
    const [x, y] = [luminance(a), luminance(b)];
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }

  const colours = [...source.matchAll(/\bcolor: "(#[0-9a-fA-F]{6})"/g)].map((m) => m[1]);

  test("the theme declares text colours at all", () => {
    expect(colours.length).toBeGreaterThan(5);
  });

  test.each([...new Set(colours)])("%s reads against the pane", (colour) => {
    expect(contrast(colour, PANE)).toBeGreaterThanOrEqual(4.5);
  });

  test("the gutter is readable, and the active line is brighter still", () => {
    const gutter = source.match(/"\.cm-gutters":[^}]*color: "(#[0-9a-fA-F]{6})"/)[1];
    const active = source.match(/"\.cm-activeLineGutter":[^}]*color: "(#[0-9a-fA-F]{6})"/)[1];

    expect(contrast(gutter, PANE)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(active, PANE)).toBeGreaterThan(contrast(gutter, PANE));
  });
});

// CODEMIRROR BUILDS ITS STYLESHEET AT RUNTIME, and this admin serves a CSP that refuses an unmarked
// one. Refused, the editor is not a textarea — it is a live editor with no layout, and nothing says
// so, because the bundle loaded perfectly and the real textarea is already hidden. The facet is what
// keeps it styled; without it the element goes into `document.head` bare.
describe("the editor's own stylesheet is marked for the page's policy", () => {
  function nonceIn(extensions) {
    const state = EditorState.create({ doc: "", extensions });

    return state.facet(EditorView.cspNonce);
  }

  test("the page's nonce is read off a script the server already marked", () => {
    const script = document.createElement("script");

    script.nonce = "test-nonce-value";
    document.head.appendChild(script);

    try {
      expect(nonceIn(extensionsFor("html", () => {}))).toBe("test-nonce-value");
    } finally {
      script.remove();
    }
  });

  // A page with no nonce serves no policy that needs one, and the empty string is the facet's own
  // "none given" — not a value that could match a directive.
  test("and is the empty string when the page carries none", () => {
    expect(nonceIn(extensionsFor("html", () => {}))).toBe("");
  });
});
