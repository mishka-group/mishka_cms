// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { describe, expect, test } from "vitest";

import {
  byRecency,
  favourite,
  favourites,
  noteUse,
  recents,
  shows,
  storageKey,
  toggleFavourite,
} from "./pb_prefs.js";

// A stand-in for `window.localStorage`: same three methods, and the option of refusing every one of
// them the way private browsing does.
function store(initial = null, refuse = false) {
  let value = initial;

  return {
    getItem() {
      if (refuse) throw new Error("denied");
      return value;
    },
    setItem(_key, next) {
      if (refuse) throw new Error("denied");
      value = next;
    },
    read: () => value,
  };
}

describe("favourites", () => {
  test("a fresh browser has none", () => {
    expect(favourites(store(), "site-a")).toEqual([]);
    expect(favourite(store(), "site-a", "button")).toBe(false);
  });

  test("toggling adds, toggling again removes", () => {
    const storage = store();

    expect(toggleFavourite(storage, "site-a", "button")).toEqual(["button"]);
    expect(favourite(storage, "site-a", "button")).toBe(true);

    expect(toggleFavourite(storage, "site-a", "button")).toEqual([]);
    expect(favourite(storage, "site-a", "button")).toBe(false);
  });

  // A NAME ONLY MEANS SOMETHING INSIDE ONE SITE. Two sites can each have a `site-hero` and they are
  // different components; starring one must not light up the other.
  test("one site's stars are not another's", () => {
    const storage = store();

    toggleFavourite(storage, "site-a", "site-hero");

    expect(favourites(storage, "site-a")).toEqual(["site-hero"]);
    expect(favourites(storage, "site-b")).toEqual([]);
  });

  test("stars and recents live side by side without overwriting each other", () => {
    const storage = store();

    toggleFavourite(storage, "site-a", "button");
    noteUse(storage, "site-a", "alert");

    expect(favourites(storage, "site-a")).toEqual(["button"]);
    expect(recents(storage, "site-a")).toEqual(["alert"]);
  });
});

describe("recents", () => {
  test("newest first", () => {
    const storage = store();

    noteUse(storage, "site-a", "alert");
    noteUse(storage, "site-a", "button");

    expect(recents(storage, "site-a")).toEqual(["button", "alert"]);
  });

  test("reaching for the same one twice does not fill the row with it", () => {
    const storage = store();

    noteUse(storage, "site-a", "alert");
    noteUse(storage, "site-a", "button");
    noteUse(storage, "site-a", "alert");

    expect(recents(storage, "site-a")).toEqual(["alert", "button"]);
  });

  test("the list is capped", () => {
    const storage = store();

    for (const name of ["a", "b", "c", "d"]) noteUse(storage, "site-a", name, 3);

    expect(recents(storage, "site-a")).toEqual(["d", "c", "b"]);
  });
});

// PRIVATE BROWSING THROWS ON BOTH READ AND WRITE. A star is a convenience; losing it must not take
// the palette down with it.
describe("a storage that refuses", () => {
  test("reads as empty rather than raising", () => {
    const storage = store(null, true);

    expect(favourites(storage, "site-a")).toEqual([]);
    expect(recents(storage, "site-a")).toEqual([]);
  });

  test("writes are dropped rather than raising", () => {
    const storage = store(null, true);

    expect(() => toggleFavourite(storage, "site-a", "button")).not.toThrow();
    expect(() => noteUse(storage, "site-a", "button")).not.toThrow();
  });

  test("so does a value that is not JSON at all", () => {
    expect(favourites(store("{{{"), "site-a")).toEqual([]);
  });

  // Someone else's key with our name on it, or a version of this that stored a string.
  test("and a value of the wrong shape", () => {
    const storage = store(JSON.stringify({ "site-a": { fav: "button", recent: 3 } }));

    expect(favourites(storage, "site-a")).toEqual([]);
    expect(recents(storage, "site-a")).toEqual([]);
  });
});

describe("shows/3", () => {
  const lists = { fav: ["button"], recent: ["alert"] };

  test("no filter shows everything", () => {
    expect(shows("anything", null, lists)).toBe(true);
  });

  test("each filter shows only its own list", () => {
    expect(shows("button", "fav", lists)).toBe(true);
    expect(shows("alert", "fav", lists)).toBe(false);
    expect(shows("alert", "recent", lists)).toBe(true);
    expect(shows("button", "recent", lists)).toBe(false);
  });

  // A star filter with nothing starred hides everything, which is what lets the panel say "nothing
  // starred yet" instead of showing a blank column.
  test("an empty list hides everything, rather than reading as no filter", () => {
    expect(shows("button", "fav", { fav: [], recent: [] })).toBe(false);
  });
});

test("byRecency puts the last thing used first", () => {
  expect(byRecency(["alert", "button", "toast"], ["toast", "alert", "button"])).toEqual([
    "toast",
    "alert",
    "button",
  ]);
});

test("the storage key is namespaced", () => {
  expect(storageKey.startsWith("pb:")).toBe(true);
});
