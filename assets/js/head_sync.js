// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HEAD OF A DATABASE PAGE AFTER A PATCH. `MishkaCmsWeb.RuntimeLive.page_head/1` draws the SEO tags
// and the JSON-LD with the response and marks each `data-mishka-seo`; a patch to another page of
// the same LiveView keeps the head it had, so `handle_params/3` pushes `mishka:head` with the tags
// and the schema the new address resolved, and this swaps them for the marked ones. It lives apart
// from `boot.js`, which cannot be loaded without the bundler's colocated hooks, so a test can.
//
// The site's head code rides the same push as `head_code`: its items, each with the key of the entry
// (or extension) it came from, and the response's nonce. Every head code tag in the document is
// marked `data-mishka-head` with its key. A key no longer listed is taken out, a key not yet in the
// document is added, and one already there is left alone, so a script on every page never runs
// twice. A script added here gets the nonce, so the policy lets it run.

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

const HEAD_MARK = "data-mishka-head";
const HEAD_CODE_TAGS = new Set(["script", "meta", "link"]);

function headCodeNode(doc, { tag, attrs, content }, key, nonce) {
  if (!HEAD_CODE_TAGS.has(tag) || !attrs || typeof attrs !== "object") return null;

  const node = doc.createElement(tag);

  for (const [name, value] of Object.entries(attrs)) {
    if (!NAME.test(name) || /^on/i.test(name) || name === "nonce" || typeof value !== "string") continue;
    node.setAttribute(name, value);
  }

  if (tag === "script") {
    if (nonce) node.setAttribute("nonce", nonce);
    if (typeof content === "string") node.textContent = content;
  }

  node.setAttribute(HEAD_MARK, key);
  return node;
}

export function syncHeadCode(detail, doc = document) {
  if (!detail || !Array.isArray(detail.items)) return;

  const head = doc.head;
  const wanted = new Map();

  for (const item of detail.items) {
    if (!item || typeof item.key !== "string") continue;
    if (!wanted.has(item.key)) wanted.set(item.key, []);
    wanted.get(item.key).push(item);
  }

  const present = new Set();

  head.querySelectorAll(`[${HEAD_MARK}]`).forEach((node) => {
    const key = node.getAttribute(HEAD_MARK);
    if (wanted.has(key)) present.add(key);
    else node.remove();
  });

  for (const [key, items] of wanted) {
    if (present.has(key)) continue;

    for (const item of items) {
      const node = headCodeNode(doc, item, key, detail.nonce);
      if (node) head.appendChild(node);
    }
  }
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

  syncHeadCode(detail && detail.head_code, doc);
}
