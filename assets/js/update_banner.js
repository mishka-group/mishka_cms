// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// WHAT A READER HAS OPEN CHANGED UNDER THEM, and only a reload brings it in: the site's JavaScript
// was rebuilt (`mishka:js-updated`), or the page itself was (`mishka:page-updated`, pushed once the
// page's compile job has finished). One banner at the bottom offers the reload; a second
// announcement adds nothing. It lives apart from `boot.js`, which cannot be loaded without the
// bundler's colocated hooks, so a test can.

const ID = "mishka-update-banner";

export function showUpdateBanner(doc = document, reload = () => window.location.reload()) {
  if (doc.getElementById(ID)) return;

  const bar = doc.createElement("div");
  bar.id = ID;
  bar.style.cssText =
    "position:fixed;left:50%;bottom:1rem;transform:translateX(-50%);z-index:99999;" +
    "background:#111827;color:#fff;padding:.6rem 1rem;border-radius:.6rem;" +
    "box-shadow:0 6px 24px rgba(0,0,0,.25);display:flex;align-items:center;gap:.75rem;" +
    "font:500 14px system-ui,sans-serif;";

  const text = doc.createElement("span");
  text.textContent = "This page was updated.";

  const button = doc.createElement("button");
  button.textContent = "Refresh";
  button.style.cssText =
    "background:#4f46e5;color:#fff;border:0;border-radius:.4rem;padding:.35rem .8rem;" +
    "cursor:pointer;font:600 13px system-ui,sans-serif;";
  button.onclick = () => reload();

  bar.appendChild(text);
  bar.appendChild(button);
  doc.body.appendChild(bar);
}
