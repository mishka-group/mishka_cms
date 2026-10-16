// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { describe, expect, test } from "vitest";

import { PB_SHORTCUTS } from "./admin_hooks.js";

// THE KEYBOARD ON A KEYBOARD THAT IS NOT AMERICAN. `event.key` is the CHARACTER a layout produced,
// so every shortcut matched against `"z"` worked on a US layout and on no other: a Persian keyboard
// sends `ز` for the key where Z is, a Russian one `я`, Dvorak `;`. The editor's entire keyboard —
// undo, save, copy, cut, paste, duplicate, the command palette — was dead for those authors, and
// nothing on screen said so. Reported on the editor issue as Ctrl+Z not bringing a deleted block
// back, while reverting from the history sheet did, because that is a click.
//
// `event.code` names the key by where it sits, so it is the same everywhere.
function press(overrides = {}) {
  return {
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    key: "",
    code: "",
    ...overrides,
  };
}

// What a Persian layout actually sends for the physical Z, S, C, V and D keys.
const PERSIAN = { z: "ز", s: "س", c: "ذ", v: "ر", d: "ی" };

describe("shortcuts follow the key, not the character", () => {
  test.each([
    ["z", "undo"],
    ["s", "save"],
    ["c", "copy"],
    ["v", "paste"],
    ["d", "duplicate"],
  ])("⌘%s is %s on a US layout", (letter, action) => {
    expect(PB_SHORTCUTS(press({ metaKey: true, key: letter, code: `Key${letter.toUpperCase()}` })))
      .toBe(action);
  });

  test.each([
    ["z", "undo"],
    ["s", "save"],
    ["c", "copy"],
    ["v", "paste"],
    ["d", "duplicate"],
  ])("and ⌘%s is still %s on a Persian one", (letter, action) => {
    expect(PB_SHORTCUTS(press({ metaKey: true, key: PERSIAN[letter], code: `Key${letter.toUpperCase()}` })))
      .toBe(action);
  });

  test("⇧⌘Z is redo, whatever the layout calls that key", () => {
    expect(PB_SHORTCUTS(press({ metaKey: true, shiftKey: true, key: "ز", code: "KeyZ" }))).toBe("redo");
  });

  test("and Ctrl works the same as ⌘, for the people not on a Mac", () => {
    expect(PB_SHORTCUTS(press({ ctrlKey: true, key: "я", code: "KeyZ" }))).toBe("undo");
  });

  // A browser that sends no `code` — or a key `code` cannot spell — still has to work.
  test("falls back to the character when there is no code", () => {
    expect(PB_SHORTCUTS(press({ metaKey: true, key: "z" }))).toBe("undo");
    expect(PB_SHORTCUTS(press({ metaKey: true, key: "/" }))).toBe("code");
  });

  test("the keys that are not letters keep working", () => {
    expect(PB_SHORTCUTS(press({ key: "Escape", code: "Escape" }))).toBe("escape");
    expect(PB_SHORTCUTS(press({ key: "Backspace", code: "Backspace" }))).toBe("delete");
    expect(PB_SHORTCUTS(press({ key: "Delete", code: "Delete" }))).toBe("delete");
    expect(PB_SHORTCUTS(press({ metaKey: true, code: "Slash" }))).toBe("code");
    expect(PB_SHORTCUTS(press({ shiftKey: true, code: "Digit1" }))).toBe("fit");
  });

  // A letter with no modifier is TYPING, and must not be swallowed.
  test("⇧⌘H hides or shows, on any layout, and ⌘H alone is left to the system", () => {
    expect(PB_SHORTCUTS(press({ metaKey: true, shiftKey: true, key: "H", code: "KeyH" }))).toBe(
      "visibility",
    );
    expect(PB_SHORTCUTS(press({ metaKey: true, shiftKey: true, key: "ا", code: "KeyH" }))).toBe(
      "visibility",
    );
    expect(PB_SHORTCUTS(press({ metaKey: true, key: "h", code: "KeyH" }))).toBeNull();
  });

  test("a bare letter is not a shortcut", () => {
    expect(PB_SHORTCUTS(press({ key: "z", code: "KeyZ" }))).toBeNull();
    expect(PB_SHORTCUTS(press({ key: "ز", code: "KeyZ" }))).toBeNull();
  });
});
