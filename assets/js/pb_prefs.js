// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// Which components this person stars, and which ones they reached for last.
//
// Neither is content. A star says nothing about the site, the page or the document — it says what
// one author keeps needing — so it never touches the server, never enters the editor session, and
// never costs a round trip. Same reasoning as the theme toggle, which has stored itself the same
// way since long before the builder existed.
//
// Everything here is a pure function over a storage object so a test can hand it a plain map. The
// hook in `app.js` supplies `window.localStorage` and the DOM.

const KEY = "pb:palette";
const RECENT_LIMIT = 8;

// PRIVATE BROWSING REFUSES localStorage — reading it there throws rather than returning null. A
// starred component is a convenience; losing it must not take the palette down with it, so every
// path through here degrades to "nothing is starred" instead of raising.
function read(storage) {
  try {
    return JSON.parse(storage.getItem(KEY) || "{}") || {};
  } catch {
    return {};
  }
}

function write(storage, all) {
  try {
    storage.setItem(KEY, JSON.stringify(all));
  } catch {
    // Nothing to do and nothing to say: the palette still works, the star just will not be there
    // next time.
  }
}

// Scoped by site, because a name only means something inside one. Two sites can both have a
// `site-hero` and they are different components; starring one must not star the other.
function bucket(storage, scope) {
  const entry = read(storage)[scope] || {};
  return {
    fav: Array.isArray(entry.fav) ? entry.fav : [],
    recent: Array.isArray(entry.recent) ? entry.recent : [],
  };
}

export function favourites(storage, scope) {
  return bucket(storage, scope).fav;
}

export function recents(storage, scope) {
  return bucket(storage, scope).recent;
}

export function favourite(storage, scope, name) {
  return favourites(storage, scope).includes(name);
}

export function toggleFavourite(storage, scope, name) {
  const current = bucket(storage, scope);
  const fav = current.fav.includes(name)
    ? current.fav.filter((entry) => entry !== name)
    : [...current.fav, name];

  write(storage, { ...read(storage), [scope]: { ...current, fav } });
  return fav;
}

// NEWEST FIRST, AND ONLY ONCE. Reaching for the same component twice should not fill the row with
// it, and the one you just used belongs at the front rather than wherever it first appeared.
export function noteUse(storage, scope, name, limit = RECENT_LIMIT) {
  const current = bucket(storage, scope);
  const recent = [name, ...current.recent.filter((entry) => entry !== name)].slice(0, limit);

  write(storage, { ...read(storage), [scope]: { ...current, recent } });
  return recent;
}

/**
 * Whether a card survives the current filter.
 *
 * `null` is no filter at all, which is not the same as an empty list: a star filter with nothing
 * starred hides everything, and saying so is how the panel can offer "nothing starred yet" instead
 * of a blank column.
 */
export function shows(name, mode, lists) {
  if (mode === "fav") return lists.fav.includes(name);
  if (mode === "recent") return lists.recent.includes(name);
  return true;
}

/**
 * Sort the cards of a recent-filtered list back into use order.
 *
 * The palette draws in category order, which for "what did I just use" is no order at all — the
 * point of the row is that the last thing is first.
 */
export function byRecency(names, recent) {
  return [...names].sort((a, b) => recent.indexOf(a) - recent.indexOf(b));
}

export const limit = RECENT_LIMIT;
export const storageKey = KEY;
