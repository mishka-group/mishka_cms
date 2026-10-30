// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// A SITE'S HOOKS ON THE PAGE BUILDER'S CANVAS. The canvas draws a site's document, and its
// components name the site's runtime hooks — `GlobalChelekomFloating`, `LocalhostDocToc` — which
// live in the site's bundle and nowhere in the admin's `app.js`. Without them LiveView logged
// "unknown hook found" for each, and a slider, a splitter, a tree or a chart drew no box.
//
// The bundle cannot simply be loaded there: it boots its own LiveSocket, and a second socket inside
// the frame would fight the canvas LiveView for the same DOM. So the root layout loads it MARKED,
// ahead of `app.js`, and its `boot/1` hands its hooks over here instead of booting; the admin's
// `boot/1` then registers them under its own. Both scripts are deferred, so they run in the order
// the layout wrote them, and the hooks are in place before the canvas's socket mounts anything.
//
// It lives apart from `boot.js`, which cannot be loaded without the bundler's colocated hooks, so a
// test can.

const MARK = "data-mishka-site-hooks";

// `document.currentScript` is the running bundle only while it is being evaluated, which is when
// `boot/1` asks.
export function handOverHooks(hooks, script = document.currentScript, win = window) {
  if (!script || !script.hasAttribute(MARK)) return false;

  win.MishkaSiteHooks = { ...win.MishkaSiteHooks, ...hooks };
  return true;
}

export function handedOverHooks(win = window) {
  return win.MishkaSiteHooks || {};
}
