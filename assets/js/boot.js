// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE SOCKET, THE PROGRESS BAR AND THE PAGE-LEVEL LISTENERS — everything that is the same whoever is
// looking. It takes the hooks rather than owning them, because the two audiences bring different
// ones: `app.js` brings the admin's, `site.js` brings a public page's.
//
// Splitting this out is what lets the two be separate ENTRY POINTS rather than one entry with a
// build-time flag. A flag left `sortablejs` in every site's bundle — the package declares no
// `sideEffects: false`, so esbuild must keep it even after the hooks that use it are dropped. An
// entry point that never mentions it cannot ship it.

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/mishka_cms";
import topbar from "../vendor/topbar";
import { syncHead } from "./head_sync";

export function boot(Hooks) {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: { ...colocatedHooks, ...Hooks },
  });

  // Show progress bar on live navigation and form submits
  topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
  window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
  window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

  // Handle remove_expanded event from server
  window.addEventListener("phx:remove_expanded", (e) => {
    const el = document.getElementById(e.detail.id);
    if (el) {
      el.remove();
    }
  });

  // Handle MishkaGervaz form JS hooks (after_save, on_error)
  window.addEventListener("phx:gervaz:exec-js", (e) => {
    const el = document.getElementById(e.detail.target);
    if (el) liveSocket.execJS(el, e.detail.js);
  });

  window.addEventListener("phx:mishka:css-updated", (e) => {
    const href = e.detail && e.detail.href;
    if (!href || !/^\/assets\/css\/[^\/]+\/[0-9a-f]{32}\.css$/.test(href)) return;

    const old = document.getElementById("mishka-runtime-css");
    if (old && old.getAttribute("href") === href) return;

    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;

    // The page was served before the site's first compile, so it has no sheet to swap: this is it.
    if (!old) {
      link.id = "mishka-runtime-css";
      document.head.appendChild(link);
      return;
    }

    link.onload = () => {
      link.id = "mishka-runtime-css";
      old.remove();
    };

    link.onerror = () => {
      old.id = "mishka-runtime-css";
      link.remove();
    };

    old.removeAttribute("id");
    old.after(link);
  });

  window.addEventListener("phx:mishka:head", (e) => syncHead(e.detail));

  window.addEventListener("phx:mishka:js-updated", () => {
    if (document.getElementById("mishka-update-banner")) return;

    const bar = document.createElement("div");
    bar.id = "mishka-update-banner";
    bar.style.cssText =
      "position:fixed;left:50%;bottom:1rem;transform:translateX(-50%);z-index:99999;" +
      "background:#111827;color:#fff;padding:.6rem 1rem;border-radius:.6rem;" +
      "box-shadow:0 6px 24px rgba(0,0,0,.25);display:flex;align-items:center;gap:.75rem;" +
      "font:500 14px system-ui,sans-serif;";

    const text = document.createElement("span");
    text.textContent = "This page was updated.";

    const button = document.createElement("button");
    button.textContent = "Refresh";
    button.style.cssText =
      "background:#4f46e5;color:#fff;border:0;border-radius:.4rem;padding:.35rem .8rem;" +
      "cursor:pointer;font:600 13px system-ui,sans-serif;";
    button.onclick = () => window.location.reload();

    bar.appendChild(text);
    bar.appendChild(button);
    document.body.appendChild(bar);
  });

  // connect if there are any LiveViews on the page
  liveSocket.connect();

  // expose liveSocket on window for web console debug logs and latency simulation:
  // >> liveSocket.enableDebug()
  // >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
  // >> liveSocket.disableLatencySim()
  window.liveSocket = liveSocket;

  // The lines below enable quality of life phoenix_live_reload
  // development features:
  //
  //     1. stream server logs to the browser console
  //     2. click on elements to jump to their definitions in your code editor
  //
  if (process.env.NODE_ENV === "development") {
    window.addEventListener(
      "phx:live_reload:attached",
      ({ detail: reloader }) => {
        // Enable server log streaming to client.
        // Disable with reloader.disableServerLogs()
        reloader.enableServerLogs();

        // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
        //
        //   * click with "c" key pressed to open at caller location
        //   * click with "d" key pressed to open at function component definition location
        let keyDown;
        window.addEventListener("keydown", (e) => (keyDown = e.key));
        window.addEventListener("keyup", (e) => (keyDown = null));
        window.addEventListener(
          "click",
          (e) => {
            if (keyDown === "c") {
              e.preventDefault();
              e.stopImmediatePropagation();
              reloader.openEditorAtCaller(e.target);
            } else if (keyDown === "d") {
              e.preventDefault();
              e.stopImmediatePropagation();
              reloader.openEditorAtDef(e.target);
            }
          },
          true,
        );

        window.liveReloader = reloader;
      },
    );
  }

}
