// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// A REBUILT SITE BUNDLE TAKES THE LINKED ONE'S PLACE without a flash. The socket pushes
// `mishka:css-updated` with the new address — `MishkaCmsWeb.RuntimeLive` for a live page, the
// builder's canvas for an open frame — and the newer sheet goes in beside `#mishka-runtime-css`; the
// old one leaves only once the newer has loaded, and stays for good if it fails. It lives apart from
// `boot.js`, which cannot be loaded without the bundler's colocated hooks, so a test can.

const ID = "mishka-runtime-css";
const PENDING = "data-mishka-runtime-css-pending";
const ADDRESS = /^\/assets\/css\/[^/]+\/[0-9a-f]{32}\.css$/;

export function swapRuntimeCss(detail, doc = document) {
  const href = detail && detail.href;
  if (!href || !ADDRESS.test(href)) return;

  const old = doc.getElementById(ID);
  const pending = doc.querySelector(`link[${PENDING}]`);

  // A NEWER SHEET OUTRANKS ONE STILL LOADING. Two rebuilds close together used to leave the first
  // one's link behind with no id, so the second found no sheet to swap and was appended at the end
  // of `<head>` — after the builder's generated styles, which it then overruled.
  if (pending) {
    if (pending.getAttribute("href") === href) return;
    pending.remove();
  }

  if (old && old.getAttribute("href") === href) return;

  const link = doc.createElement("link");
  link.rel = "stylesheet";
  link.href = href;

  // The page was served before the site's first compile, so it has no sheet to swap: this is it.
  if (!old) {
    link.id = ID;
    doc.head.appendChild(link);
    return;
  }

  link.setAttribute(PENDING, "");

  link.onload = () => {
    if (!link.isConnected) return;
    link.removeAttribute(PENDING);
    old.remove();
    link.id = ID;
  };

  link.onerror = () => link.remove();

  old.after(link);
}
