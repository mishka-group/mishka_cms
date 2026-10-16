// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// A PREVIEW IS ONE PAGE, NOT A SITE — loaded by the `:preview` layout and by nothing else.
//
// `/_preview/:resource/:token` draws one record. A link built on `@page.path` points back at it and
// pages here (see `MishkaCmsWeb.DraftPreviewLive`). Every other link names a PUBLISHED address — a
// post, the home page, another site — and followed in this tab it swaps the draft for the live page,
// which looks close enough that nothing says the draft is gone.
//
// Which draft of that other page to show instead cannot be known: a page may have many. So it opens
// published, in a new tab, and this tab stays the draft.
//
// CAPTURED ON WINDOW, ahead of LiveView's own click listener. A `<.link navigate>` is otherwise
// LiveView's to follow, and LiveView reads `target="_blank"` only off the element clicked — a `<span>`
// inside the link is not the link — so a target attribute alone would still navigate this tab.

export function destination(anchor, here) {
  const href = anchor.getAttribute("href");
  if (href === null || anchor.hasAttribute("download")) return null;

  const current = new URL(here.href);
  const url = new URL(href, current);

  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.origin === current.origin && url.pathname === current.pathname) return null;

  return url.href;
}

function openElsewhere(event) {
  if (event.defaultPrevented || event.button !== 0) return;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;

  const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
  const url = anchor && destination(anchor, window.location);
  if (!url) return;

  event.preventDefault();
  event.stopImmediatePropagation();
  window.open(url, "_blank", "noopener");
}

window.addEventListener("click", openElsewhere, true);

// A PREVIEW SUBMITS NOTHING. Its page is drawn by the real module, so a sign-in form here is the real
// form: captured on window ahead of LiveView, its submit never reaches the server or the browser.
function holdSubmit(event) {
  event.preventDefault();
  event.stopImmediatePropagation();
}

window.addEventListener("submit", holdSubmit, true);
