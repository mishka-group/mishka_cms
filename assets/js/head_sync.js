// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HEAD OF A DATABASE PAGE AFTER A PATCH. `MishkaCmsWeb.RuntimeLive.page_head/1` draws the SEO tags
// and the JSON-LD with the response and marks each `data-mishka-seo`; a patch to another page of
// the same LiveView keeps the head it had, so `handle_params/3` pushes `mishka:head` with the tags
// and the schema the new address resolved, and this swaps them for the marked ones. It lives apart
// from `boot.js`, which cannot be loaded without the bundler's colocated hooks, so a test can.

const MARK = "data-mishka-seo";
const TAGS = new Set(["meta", "link"]);
const NAME = /^[a-z][a-z0-9:_-]*$/i;

function tagFor(doc, { tag, attrs }) {
  if (!TAGS.has(tag) || !attrs || typeof attrs !== "object") return null;

  const node = doc.createElement(tag);

  for (const [name, value] of Object.entries(attrs)) {
    if (!NAME.test(name) || /^on/i.test(name) || value === false || value === null) continue;
    node.setAttribute(name, value === true ? "" : String(value));
  }

  node.setAttribute(MARK, "");
  return node;
}

export function syncHead(detail, doc = document) {
  const head = doc.head;
  const tags = Array.isArray(detail && detail.tags) ? detail.tags : [];
  const schema = Array.isArray(detail && detail.schema) ? detail.schema : [];

  head.querySelectorAll(`[${MARK}]`).forEach((node) => node.remove());

  for (const entry of tags) {
    const node = entry && tagFor(doc, entry);
    if (node) head.appendChild(node);
  }

  for (const json of schema) {
    if (typeof json !== "string") continue;

    const script = doc.createElement("script");
    script.type = "application/ld+json";
    script.textContent = json;
    script.setAttribute(MARK, "");
    head.appendChild(script);
  }
}
