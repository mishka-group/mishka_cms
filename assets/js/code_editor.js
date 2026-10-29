// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view";
import { EditorState } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { closeBrackets, closeBracketsKeymap, autocompletion } from "@codemirror/autocomplete";
import {
  bracketMatching,
  syntaxHighlighting,
  HighlightStyle,
  LanguageSupport,
} from "@codemirror/language";
import { parseMixed } from "@lezer/common";
import { tags } from "@lezer/highlight";
import { cssLanguage, cssCompletionSource } from "@codemirror/lang-css";
import { htmlLanguage } from "@codemirror/lang-html";
import { javascript } from "@codemirror/lang-javascript";
import { elixir, elixirLanguage } from "codemirror-lang-elixir";

// LOADED ON DEMAND, NOT WITH THE ADMIN BUNDLE. CodeMirror and its grammars are the largest thing the
// admin could ship and they are wanted on two screens. This file is a separate esbuild entry,
// fetched by mishka_cms_core's `PbCodeEditor` hook (its `assets/js/pb_code_editor.js`) the first
// time a code box appears and never on the pages with none.
//
// It hangs itself on `window.PbCodeMirror` rather than exporting, because the loader injects it as a
// plain script tag: an ES module import would need the bundle format changed for everything.

// THERE IS NO HEEx GRAMMAR, ANYWHERE — not in CodeMirror, and not in a highlighter we could have
// used instead. HEEx is HTML with Elixir inside `{…}` and `<%= … %>`, so it is built here out of the
// two grammars that DO exist: lezer's HTML parser for the document, and Livebook's Elixir parser
// nested into the expressions through `parseMixed`.
//
// Mapping HEEx to plain `html` is the tempting shortcut and it is what shipped first. Tags and
// attributes come out right and every expression comes out as undifferentiated text — which on a
// page of components is most of the interesting part of the file.

// A REAL SCANNER, NOT A PATTERN. `{` inside a quoted attribute value does not open an expression and
// `}` inside a string does not close one, so this tracks quotes and depth the way the tokenizer on
// the server side does. `class={@a && "}"}` is the case that decides it: everything simpler cuts the
// expression at the brace inside the string and colours the rest of the line as Elixir.
export function expressionRanges(text, offset) {
  const ranges = [];
  let index = 0;

  while (index < text.length) {
    const opened = text.indexOf("{", index);
    if (opened < 0) break;

    const closed = closingBrace(text, opened + 1);
    if (closed < 0) break;

    // The braces themselves stay HTML — what is nested is the expression between them.
    if (closed > opened + 1) ranges.push({ from: offset + opened + 1, to: offset + closed });
    index = closed + 1;
  }

  return ranges;
}

function closingBrace(text, start) {
  let depth = 0;
  let index = start;

  while (index < text.length) {
    const char = text[index];

    if (char === '"' || char === "'") {
      index = endOfString(text, index + 1, char);
      continue;
    }

    if (char === "{") depth += 1;
    else if (char === "}" && depth === 0) return index;
    else if (char === "}") depth -= 1;

    index += 1;
  }

  return -1;
}

function endOfString(text, start, quote) {
  let index = start;

  while (index < text.length) {
    if (text[index] === "\\") index += 2;
    else if (text[index] === quote) return index + 1;
    else index += 1;
  }

  return index;
}

// Where an expression may appear: between tags, and as an attribute's value — `class={@x}` with no
// quotes is an UnquotedAttributeValue, `class="{@x}"` is an AttributeValue.
const EXPRESSION_HOSTS = ["Text", "AttributeValue", "UnquotedAttributeValue"];

const heexLanguage = htmlLanguage.configure(
  {
    wrap: parseMixed((node, input) => {
      if (!EXPRESSION_HOSTS.includes(node.name)) return null;

      const ranges = expressionRanges(input.read(node.from, node.to), node.from);
      if (!ranges.length) return null;

      return { parser: elixirLanguage.parser, overlay: ranges };
    }),
  },
  "heex",
);

// `heex` and `html` are the same document with different amounts of Elixir in it, so both get the
// mixed parser: an ordinary page with no expressions loses nothing by being read this way.
// THE ELEMENT CSS BOX IS A DECLARATION LIST, NOT A STYLESHEET. What the author writes is wrapped in
// `.pb-xxxxxxxx { … }` before it is served, so `color: red` at the top level is a declaration — but
// the CSS grammar's default top rule is `StyleSheet`, where the top level is where SELECTORS go.
//
// Everything downstream of that reads wrong. Typing `dire` there parses as a `TagName`, and
// `@codemirror/lang-css`'s completion answers the list it has for that position: HTML TAG NAMES.
// Property names are only offered inside a `Block` or `Styles` node, so `direction`, `display` and
// every other property could not be completed at the one place this box expects them.
//
// The grammar already has the rule for it. `Styles` is lezer-css's top rule for a declaration list —
// the same node `@media` bodies use — so parsing with it makes the box's contents mean what the
// compiler will make them mean, and the completion source needs no patching to follow.
const cssDeclarations = () => {
  const language = cssLanguage.configure({ top: "Styles" });

  return new LanguageSupport(language, language.data.of({ autocomplete: cssCompletionSource }));
};

const LANGUAGES = {
  css: () => cssDeclarations(),
  html: () => heexLanguage,
  heex: () => heexLanguage,
  elixir: () => elixir(),
  js: () => javascript(),
  javascript: () => javascript(),
};

const theme = EditorView.theme(
  {
    // FULL HEIGHT, SO CODEMIRROR OWNS THE SCROLLING. Left to size itself it grows to its content and
    // the wrapper around it scrolls instead — which means the gutter scrolls away with the text, and
    // the scrollbar being styled below is not the one the reader sees.
    "&": {
      backgroundColor: "transparent",
      color: "#c9c7d1",
      fontSize: "11.5px",
      height: "100%",
    },
    ".cm-content": {
      fontFamily: "'Space Grotesk', ui-monospace, monospace",
      padding: "10px 0",
      caretColor: "#c8a2ff",
    },
    // READABLE, then quiet — in that order. These were `#56545e`, which is 2.4:1 against the pane
    // and effectively invisible: the line numbers were there, and you could not read one. A gutter
    // is meant to sit behind the code, but a number nobody can read is not restraint, it is a
    // missing feature. `#8b8995` measures 5.3:1 and still reads as the dimmer column, and the
    // active line takes the code's own colour so the row you are on is the bright one.
    ".cm-gutters": {
      backgroundColor: "transparent",
      border: "none",
      color: "#8b8995",
      fontSize: "10.5px",
    },
    ".cm-activeLine": { backgroundColor: "rgba(255,255,255,.03)" },
    ".cm-activeLineGutter": { backgroundColor: "transparent", color: "#c9c7d1" },
    ".cm-cursor": { borderLeftColor: "#c8a2ff" },
    "&.cm-focused": { outline: "none" },
    ".cm-selectionBackground, ::selection": { backgroundColor: "#312d3d" },
    ".cm-tooltip": { backgroundColor: "#221f27", border: "1px solid #3b3746" },
    // THE BAR ARRIVES WITH THE POINTER, not with the content. A native scrollbar on a dark panel is
    // a light grey slab that sits there being the brightest thing on a screen made of code; this is
    // the panel's own border colour, invisible until somebody is actually pointing at the pane.
    // Both spellings, because Firefox has never implemented the pseudo-elements and WebKit has
    // never implemented `scrollbar-color`.
    ".cm-scroller": {
      overflow: "auto",
      scrollbarWidth: "thin",
      scrollbarColor: "transparent transparent",
    },
    "&:hover .cm-scroller": { scrollbarColor: "#3b3746 transparent" },
    ".cm-scroller::-webkit-scrollbar": { width: "8px", height: "8px" },
    ".cm-scroller::-webkit-scrollbar-track": { backgroundColor: "transparent" },
    ".cm-scroller::-webkit-scrollbar-corner": { backgroundColor: "transparent" },
    ".cm-scroller::-webkit-scrollbar-thumb": {
      backgroundColor: "transparent",
      borderRadius: "8px",
    },
    "&:hover .cm-scroller::-webkit-scrollbar-thumb": { backgroundColor: "#3b3746" },
    "&:hover .cm-scroller::-webkit-scrollbar-thumb:hover": { backgroundColor: "#56545e" },
  },
  { dark: true },
);

// The drawer's own palette, so the editor does not arrive wearing somebody else's colour scheme.
const highlight = HighlightStyle.define([
  { tag: tags.keyword, color: "#c8a2ff" },
  { tag: [tags.atom, tags.bool, tags.number], color: "#e6c477" },
  { tag: [tags.string, tags.special(tags.string)], color: "#8ee0b8" },
  { tag: tags.comment, color: "#8b8995", fontStyle: "italic" },
  { tag: [tags.tagName, tags.angleBracket], color: "#8ee0b8" },
  { tag: tags.attributeName, color: "#c8a2ff" },
  { tag: [tags.propertyName, tags.definition(tags.propertyName)], color: "#c8a2ff" },
  { tag: [tags.function(tags.variableName), tags.labelName], color: "#8ee0b8" },
  { tag: [tags.variableName, tags.definition(tags.variableName)], color: "#c9c7d1" },
  { tag: tags.operator, color: "#a3a1ad" },
]);

export function languageOf(name) {
  const build = LANGUAGES[name];
  return build ? [build()] : [];
}

export function extensionsFor(name, onChange, options = {}) {
  return [
    // FIRST, so it beats the default binding for the same chord. `Mod-` is ⌘ on a Mac and Ctrl
    // everywhere else, which CodeMirror resolves for us.
    keymap.of([
      {
        key: "Mod-Enter",
        run: () => {
          if (!options.onSubmit) return false;
          options.onSubmit();
          return true;
        },
      },
    ]),
    lineNumbers(),
    history(),
    bracketMatching(),
    closeBrackets(),
    highlightActiveLine(),
    autocompletion(),
    keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
    syntaxHighlighting(highlight),
    theme,
    EditorView.cspNonce.of(cspNonce()),
    EditorView.lineWrapping,
    EditorState.readOnly.of(!!options.readOnly),
    ...languageOf(name),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) onChange(update.state.doc.toString());
    }),
  ];
}

// THE EDITOR BRINGS ITS OWN STYLESHEET, AND THE PAGE HAS A POLICY ABOUT THOSE. CodeMirror has no
// CSS file: it builds one `<style>` element at runtime and puts it in `document.head`, which is
// exactly what `style-src-elem` governs. This admin serves a nonce and no `'unsafe-inline'`, so an
// unmarked element is refused — and CodeMirror refused is not a plain textarea, it is a live editor
// with none of its layout: the gutter stacks above the code instead of beside it, `white-space`
// falls back to `normal` so indentation and line breaks collapse, and nothing reports why. The
// textarea is already hidden by then, and the hook's "Editor did not load" notice does not fire
// because the bundle loaded perfectly.
//
// `EditorView.cspNonce` is the library's own answer and it is one facet. It replaces having the
// layout patch `document.createElement` for the whole page, which only ever covered the two screens
// that asked for the in-browser Tailwind JIT and left every other code field in the admin —
// JS hooks, stylesheets, a resource with `extra %{code: …}` — unstyled.
//
// Read back off a script the server already marked. Browsers blank the nonce CONTENT attribute so a
// CSS attribute selector cannot exfiltrate it, and keep the IDL property readable by scripts in the
// same document; that asymmetry is the intended way to do this.
function cspNonce() {
  for (const script of document.scripts) if (script.nonce) return script.nonce;

  return "";
}

window.PbCodeMirror = {
  create(parent, doc, language, onChange, options = {}) {
    return new EditorView({
      parent,
      state: EditorState.create({ doc, extensions: extensionsFor(language, onChange, options) }),
    });
  },
};
