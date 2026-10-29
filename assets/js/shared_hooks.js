// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HOOKS BOTH SIDES MOUNT. A flash notice dismisses itself wherever it appears, a
// copy-to-clipboard button is a copy-to-clipboard button, and a captcha is asked on the sign-in pages
// and tried on the settings page. Everything else belongs to exactly one audience — see
// `site_hooks.js`, and the admin's hooks `app.js` imports from `mishka_cms_core` and
// `mishka_cms_builder`.

// A NOTICE THAT WAITS TO BE CLICKED IS A NOTICE SITTING OVER THE THING YOU WERE ABOUT TO CLICK, and
// in the editor that is most of the screen — the Review sheet's own header, the top bar's buttons.
// It leaves on its own now, by the same route the click takes, so dismissing early and waiting it
// out end identically.
//
// Client-side because that is all it is: a timer. The server has nothing to decide here, and one
// `Process.send_after` per flash would be a message per notice for something CSS and `setTimeout`
// already do.
const FlashAutoDismiss = {
  mounted() {
    this.arm();
  },
  updated() {
    // A second notice reuses this element, so the clock has to start again — otherwise the first
    // one's timer dismisses the second one early, or not at all.
    this.arm();
  },
  arm() {
    clearTimeout(this.timer);
    const after = parseInt(this.el.dataset.dismissAfter, 10);
    if (!after) return;
    this.timer = setTimeout(() => {
      this.el.style.transition = "opacity .2s ease";
      this.el.style.opacity = "0";
      setTimeout(() => this.pushEvent("lv:clear-flash", { key: this.el.dataset.kind }), 200);
    }, after);
  },
  destroyed() {
    clearTimeout(this.timer);
  },
};

// Copy the element's data-copy value to the clipboard, with a brief "Copied!" flash.
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.getAttribute("data-copy") || "";
      navigator.clipboard.writeText(text).then(() => {
        const original = this.el.innerHTML;
        this.el.innerHTML = "Copied!";
        setTimeout(() => {
          this.el.innerHTML = original;
        }, 1200);
      });
    });
  },
};

// ONE HOOK FOR EVERY CAPTCHA PROVIDER. `MishkaCmsCore.Captcha.Widget` draws a box with the provider's
// script, the global it defines, how to draw it and its options, so a provider an extension adds
// needs no script of its own when its browser API is the one Turnstile, reCAPTCHA and hCaptcha
// share: `render(element, options)` with a `callback` handing back the token, `reset(widget)`, and
// for a score `execute(sitekey, {action})`.
//
// Both sides mount it: the sign-in pages load the site bundle, or the app's own while their site is
// offline, and the settings page tries a provider's keys.
//
// A provider's script is loaded once per address, by `onload=` callback — both providers call it
// once their API can be used. A script element added from here is allowed by its origin, which the
// security headers name on the sites that use the provider.
const captchaScripts = {};
let captchaLoads = 0;

function loadCaptcha(src, global) {
  if (!captchaScripts[src]) {
    const callback = `mishkaCaptchaLoaded${captchaLoads++}`;

    captchaScripts[src] = new Promise((resolve, reject) => {
      window[callback] = () => resolve(window[global]);

      const script = document.createElement("script");
      script.src = `${src}${src.includes("?") ? "&" : "?"}onload=${callback}`;
      script.async = true;
      script.onerror = () => {
        delete captchaScripts[src];
        reject(new Error(`could not load ${src}`));
      };
      document.head.appendChild(script);
    });
  }

  return captchaScripts[src];
}

// THE TOKEN GOES IN THE BOX'S HIDDEN INPUT, the form's `captcha_token` field, and is good for one
// check: a refused submit is answered with `mishka:captcha:reset`, which empties it and asks the
// provider for a fresh one. A widget's token comes back through its `callback`; a score's is asked
// for as the form is sent — the submit is held back until it arrives, then sent again with it.
const Captcha = {
  mounted() {
    this.input = this.el.querySelector("[data-captcha-token]");
    this.box = this.el.querySelector("[data-captcha-box]");
    this.form = this.el.closest("form");
    this.options = JSON.parse(this.el.dataset.options || "{}");
    this.handleEvent("mishka:captcha:reset", () => this.reset());

    loadCaptcha(this.el.dataset.script, this.el.dataset.global)
      .then((api) => {
        if (!this.el.isConnected) return;

        this.api = api;

        if (this.el.dataset.mode === "score") this.holdSubmit();
        else this.draw();
      })
      .catch(() => {});
  },

  draw() {
    this.widget = this.api.render(this.box, {
      ...this.options,
      callback: (token) => (this.input.value = token),
      "expired-callback": () => (this.input.value = ""),
      "error-callback": () => (this.input.value = ""),
    });
  },

  // On the form itself, so it runs before LiveView's listener on the window and can stop it. A score
  // the provider could not give lets the submit through once without a token, so the page says why
  // rather than doing nothing.
  holdSubmit() {
    this.onSubmit = (event) => {
      if (this.input.value || this.sendBare) {
        this.sendBare = false;
        return;
      }

      event.preventDefault();
      event.stopImmediatePropagation();

      const send = (token) => {
        this.input.value = token || "";
        this.sendBare = !token;
        this.form.requestSubmit();
      };

      this.api.ready(() =>
        Promise.resolve()
          .then(() => this.api.execute(this.options.sitekey, { action: this.options.action }))
          .then(send, () => send(null)),
      );
    };

    if (this.form) this.form.addEventListener("submit", this.onSubmit);
  },

  reset() {
    this.input.value = "";

    if (this.api && this.widget !== undefined) this.api.reset(this.widget);
  },

  destroyed() {
    if (this.form && this.onSubmit) this.form.removeEventListener("submit", this.onSubmit);

    if (this.api && this.widget !== undefined && typeof this.api.remove === "function") {
      this.api.remove(this.widget);
    }
  },
};

export default {
  FlashAutoDismiss,
  CopyToClipboard,
  Captcha,
};
