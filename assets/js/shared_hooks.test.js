// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, describe, expect, test, vi } from "vitest";

import SharedHooks from "./shared_hooks.js";

// A LiveView hook is a plain object bound to `this` with `el` on it; `handleEvent` is LiveView's,
// recorded here so a test can push the server's event.
function bind(hook, el) {
  const bound = Object.create(hook);
  const handlers = {};

  bound.el = el;
  bound.handleEvent = (name, handler) => (handlers[name] = handler);
  bound.push = (name, payload = {}) => handlers[name](payload);

  return bound;
}

// THE HOOK REMEMBERS EACH SCRIPT IT LOADED for as long as the module lives, so every test asks for
// an address of its own.
let tests = 0;
const fresh = (src) => `${src}&test=${++tests}`;

// What `MishkaCmsCore.Captcha.Widget` draws, inside a form.
function widget({ script, global, mode, options }) {
  document.body.innerHTML = `
    <form id="auth-form">
      <div id="captcha-sign_in" data-script="${script}" data-global="${global}" data-mode="${mode}"
           data-options='${JSON.stringify(options)}'>
        <input type="hidden" name="user[captcha_token]" value="" data-captcha-token />
        <div data-captcha-box></div>
      </div>
      <button type="submit">Sign in</button>
    </form>`;

  return document.getElementById("captcha-sign_in");
}

// The script the hook added, and the provider "finishing loading": its global, then its onload.
async function load(src, global, api) {
  const script = [...document.head.querySelectorAll("script")].find((s) => s.src.startsWith(src));
  const callback = new URL(script.src).searchParams.get("onload");

  window[global] = api;
  window[callback]();

  await Promise.resolve();
  await Promise.resolve();

  return script;
}

// Every promise the hook chained has run.
const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  document.body.innerHTML = "";
  document.head.innerHTML = "";
});

describe("Captcha — a widget (Turnstile, reCAPTCHA v2)", () => {
  const turnstileSrc = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  const options = { sitekey: "1x00000000000000000000AA", action: "sign_in" };

  function turnstile() {
    return { render: vi.fn(() => "widget-1"), reset: vi.fn(), remove: vi.fn() };
  }

  test("loads the provider once, draws the box with the options, and fills the token", async () => {
    const src = fresh(turnstileSrc);
    const el = widget({ script: src, global: "turnstile", mode: "widget", options });
    const hook = bind(SharedHooks.Captcha, el);
    const api = turnstile();

    hook.mounted();
    const script = await load(src, "turnstile", api);

    expect(new URL(script.src).searchParams.get("render")).toBe("explicit");
    expect(new URL(script.src).searchParams.get("onload")).toMatch(/^mishkaCaptchaLoaded/);
    expect(api.render).toHaveBeenCalledTimes(1);

    const [box, given] = api.render.mock.calls[0];
    expect(box).toBe(el.querySelector("[data-captcha-box]"));
    expect(given.sitekey).toBe(options.sitekey);
    expect(given.action).toBe("sign_in");

    given.callback("token-123");
    expect(el.querySelector("[data-captcha-token]").value).toBe("token-123");

    given["expired-callback"]();
    expect(el.querySelector("[data-captcha-token]").value).toBe("");
  });

  test("a second box with the same provider adds no second script", async () => {
    const src = fresh(turnstileSrc);
    const el = widget({ script: src, global: "turnstile", mode: "widget", options });
    const api = turnstile();

    bind(SharedHooks.Captcha, el).mounted();
    await load(src, "turnstile", api);
    bind(SharedHooks.Captcha, el).mounted();
    await Promise.resolve();

    expect(document.head.querySelectorAll("script")).toHaveLength(1);
  });

  test("the server's reset empties the token and asks the provider for a fresh check", async () => {
    const src = fresh(turnstileSrc);
    const el = widget({ script: src, global: "turnstile", mode: "widget", options });
    const hook = bind(SharedHooks.Captcha, el);
    const api = turnstile();

    hook.mounted();
    await load(src, "turnstile", api);
    api.render.mock.calls[0][1].callback("spent");

    hook.push("mishka:captcha:reset");

    expect(el.querySelector("[data-captcha-token]").value).toBe("");
    expect(api.reset).toHaveBeenCalledWith("widget-1");
  });

  test("a reCAPTCHA widget numbered 0 is still reset", async () => {
    const recaptcha = fresh("https://www.google.com/recaptcha/api.js?render=explicit&hl=en");
    const el = widget({ script: recaptcha, global: "grecaptcha", mode: "widget", options });
    const hook = bind(SharedHooks.Captcha, el);
    const api = { render: vi.fn(() => 0), reset: vi.fn() };

    hook.mounted();
    await load(recaptcha, "grecaptcha", api);
    hook.push("mishka:captcha:reset");
    hook.destroyed();

    expect(api.reset).toHaveBeenCalledWith(0);
  });
});

describe("Captcha — a score (reCAPTCHA v3)", () => {
  const scoreSrc = "https://www.google.com/recaptcha/api.js?render=site-key&hl=en";
  const options = { sitekey: "site-key", action: "sign_in" };

  function recaptcha(token) {
    return {
      ready: (fn) => fn(),
      execute: vi.fn(() => Promise.resolve(token)),
    };
  }

  test("holds the submit back until the token arrives, then sends the form with it", async () => {
    const src = fresh(scoreSrc);
    const el = widget({ script: src, global: "grecaptcha", mode: "score", options });
    const form = el.closest("form");
    const hook = bind(SharedHooks.Captcha, el);
    const api = recaptcha("v3-token");
    const liveView = vi.fn();
    window.addEventListener("submit", liveView);
    form.requestSubmit = vi.fn();

    hook.mounted();
    await load(src, "grecaptcha", api);

    const held = new Event("submit", { bubbles: true, cancelable: true });
    form.dispatchEvent(held);
    await settled();

    expect(held.defaultPrevented).toBe(true);
    expect(liveView).not.toHaveBeenCalled();
    expect(api.execute).toHaveBeenCalledWith("site-key", { action: "sign_in" });
    expect(el.querySelector("[data-captcha-token]").value).toBe("v3-token");
    expect(form.requestSubmit).toHaveBeenCalledTimes(1);

    const sent = new Event("submit", { bubbles: true, cancelable: true });
    form.dispatchEvent(sent);

    expect(liveView).toHaveBeenCalledTimes(1);
    expect(api.execute).toHaveBeenCalledTimes(1);

    window.removeEventListener("submit", liveView);
  });

  test("a score the provider cannot give sends the form once without one, so the page says why", async () => {
    const src = fresh(scoreSrc);
    const el = widget({ script: src, global: "grecaptcha", mode: "score", options });
    const form = el.closest("form");
    const hook = bind(SharedHooks.Captcha, el);
    const api = { ready: (fn) => fn(), execute: vi.fn(() => Promise.reject(new Error("offline"))) };
    const liveView = vi.fn();
    window.addEventListener("submit", liveView);
    form.requestSubmit = vi.fn(() =>
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })),
    );

    hook.mounted();
    await load(src, "grecaptcha", api);

    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    await settled();

    expect(api.execute).toHaveBeenCalledTimes(1);
    expect(liveView).toHaveBeenCalledTimes(1);
    expect(el.querySelector("[data-captcha-token]").value).toBe("");

    window.removeEventListener("submit", liveView);
  });

  test("after a refusal the next submit asks for a new token", async () => {
    const src = fresh(scoreSrc);
    const el = widget({ script: src, global: "grecaptcha", mode: "score", options });
    const form = el.closest("form");
    const hook = bind(SharedHooks.Captcha, el);
    const api = recaptcha("again");
    form.requestSubmit = vi.fn();

    hook.mounted();
    await load(src, "grecaptcha", api);
    el.querySelector("[data-captcha-token]").value = "spent";

    hook.push("mishka:captcha:reset");
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    await settled();

    expect(api.execute).toHaveBeenCalledTimes(1);
    expect(el.querySelector("[data-captcha-token]").value).toBe("again");
  });
});
