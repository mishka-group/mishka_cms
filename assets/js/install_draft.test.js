// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, describe, expect, test } from "vitest";

import InstallHooks from "./install_draft.js";

const KEY = "mishka-install-draft";

// A LiveView hook bound to `this`: `handleEvent` records the server's handlers so a test can push,
// and `pushEvent` records what the hook sends to the server.
function bind(hook) {
  const bound = Object.create(hook);
  const handlers = {};

  bound.pushed = [];
  bound.handleEvent = (name, handler) => (handlers[name] = handler);
  bound.pushEvent = (name, payload) => bound.pushed.push([name, payload]);
  bound.serverPush = (name, payload) => handlers[name](payload);

  return bound;
}

afterEach(() => sessionStorage.clear());

describe("InstallDraft", () => {
  test("on mount it hands back the answers this tab kept", () => {
    sessionStorage.setItem(KEY, JSON.stringify({ config: { email: "a@b.test" } }));
    const hook = bind(InstallHooks.InstallDraft);

    hook.mounted();

    expect(hook.pushed).toEqual([["restore_draft", { draft: { config: { email: "a@b.test" } } }]]);
  });

  test("with nothing kept, or something unreadable, it hands back null", () => {
    const hook = bind(InstallHooks.InstallDraft);
    hook.mounted();

    sessionStorage.setItem(KEY, "{not json");
    hook.reconnected();

    expect(hook.pushed).toEqual([
      ["restore_draft", { draft: null }],
      ["restore_draft", { draft: null }],
    ]);
  });

  test("the server's answers are kept, and null forgets them", () => {
    const hook = bind(InstallHooks.InstallDraft);
    hook.mounted();

    hook.serverPush("install-draft", { draft: { languages: ["en"] } });
    expect(JSON.parse(sessionStorage.getItem(KEY))).toEqual({ languages: ["en"] });

    hook.serverPush("install-draft", { draft: null });
    expect(sessionStorage.getItem(KEY)).toBeNull();
  });
});
