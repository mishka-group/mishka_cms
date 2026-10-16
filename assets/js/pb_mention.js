// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// The two decisions the browser makes about naming somebody in a review note, with no DOM in
// either of them. The hook in `app.js` owns the textarea and the pushes; this owns the reading and
// the writing, so both can be tested without a LiveSocket.
//
// The server decides WHO may be named — that is a tenancy question. This decides only WHEN a name
// is being written and WHERE it goes, which are the two things only the caret knows.

// A name is `@address` that starts a chunk: at the very beginning of the note, or after whitespace.
// Anchoring it that way is what keeps a QUOTED address from reading as a mention — the `@` in
// `sara@example.com` has a letter in front of it, so it is not one, while `@sara@example.com` is.
// The second `@` is part of what is being typed, which is why the class allows it.
const AT_CARET = /(?:^|\s)@([A-Za-z0-9._%+@-]*)$/;

/**
 * What is being named at the caret, if anything.
 *
 * @param {string} value the whole textarea
 * @param {number} caret where the caret is
 * @returns {{query: string, at: number}|null} the partial handle and where its `@` sits, or null
 */
export function mentionAt(value, caret) {
  const found = String(value ?? "")
    .slice(0, caret)
    .match(AT_CARET);

  if (!found) return null;

  return { query: found[1], at: caret - found[1].length - 1 };
}

/**
 * The note with `handle` written where the partial name was, and where the caret lands after.
 *
 * The trailing space is deliberate: without it the next word runs into the name, and the caret is
 * left inside a mention that is still open, so the list re-opens on the very next keystroke.
 *
 * @param {string} value the whole textarea
 * @param {number} at where the `@` sits (from `mentionAt`)
 * @param {number} caret where the caret is
 * @param {string} handle the name that was picked
 * @returns {{value: string, caret: number}}
 */
export function withMention(value, at, caret, handle) {
  const text = String(value ?? "");
  const before = text.slice(0, at);
  const written = `@${handle} `;

  return {
    value: `${before}${written}${text.slice(caret)}`,
    caret: before.length + written.length,
  };
}
