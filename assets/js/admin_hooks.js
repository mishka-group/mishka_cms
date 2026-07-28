// THE HOOKS ONLY THE ADMIN EVER MOUNTS — the dashboard's widget grid, the Assets dropzone. No
// public template names one of these, and the elements they attach to exist only under /admin.
//
// They live here rather than in `app.js` so the RUNTIME JAVASCRIPT COMPILER can leave them out. That
// compiler builds each site's bundle with `app.js` as its entry point, so every hook below — and
// `sortablejs` with them — was being shipped to every visitor of every site, to sit unmounted.
//
// `app.js` reaches them through `if (MISHKA_ADMIN)`, which esbuild replaces at build time: true for
// the admin bundle, false for a site's, where the branch and this whole module are then dropped.

import Sortable from "sortablejs";

// THE DROPZONE IS THE SUBMIT, in the editor's Assets sheet. That sheet is 620px of overlay beside a
// canvas, and a Create button in it is a second step for something the drop already said: put this
// file in this folder. The form is mounted with `submit={false}` so Gervaz draws no button; this is
// what presses it.
//
// IT WATCHES THE INPUT, NOT THE EVENTS. Listening for `change`/`input` looks obvious and is wrong:
// LiveView stages the file in its OWN listener, and a listener that runs first submits a form that
// has no files yet. That is not a race to lose carefully — the picker path always loses it, because
// a capture listener on this container runs before LiveView's on the document. The file then sits
// staged at 0% forever, which is exactly what it did.
//
// `data-phx-active-refs` is LiveView's own record of what is staged, and `data-phx-preflighted-refs`
// of what it has already begun. A ref in the first and not the second is a file waiting to go, and
// that is true however it arrived — dropped or picked. Submitting moves the ref into preflighted,
// so the next mutation finds nothing waiting: no timer, no debounce, no double upload.
const UploadSubmitsItself = {
  mounted() {
    this.watch();
  },
  updated() {
    // A save replaces the input with a fresh one, and the observer is still on the old node.
    this.watch();
  },
  watch() {
    const input = this.el.querySelector('input[type="file"]');
    if (!input || input === this.input) return;

    this.observer?.disconnect();
    this.input = input;
    this.observer = new MutationObserver(() => this.submitWaiting());
    this.observer.observe(input, {
      attributes: true,
      attributeFilter: ["data-phx-active-refs", "data-phx-preflighted-refs"],
    });

    // A file may already be staged — a reconnect, or one left behind by an earlier failure.
    this.submitWaiting();
  },
  submitWaiting() {
    const refs = (name) =>
      (this.input.getAttribute(name) || "").split(",").filter((ref) => ref !== "");

    const started = refs("data-phx-preflighted-refs");
    const waiting = refs("data-phx-active-refs").filter((ref) => !started.includes(ref));

    if (waiting.length > 0) this.input.form?.requestSubmit();
  },
  destroyed() {
    this.observer?.disconnect();
  },
};

// A THUMBNAIL WHOSE IMAGE MAY NEVER ARRIVE — the media gallery's cards, the Assets sheet's rows, the
// media table's preview cell. Every one of them paints a type glyph BEHIND the <img>, so a file that
// no longer exists on disk only has to get the image out of the way for the glyph to be what you
// see. A loaded image gets a background of its own where the element asks for one, or a transparent
// PNG picks up the tile's tint instead of sitting on paper.
//
// It exists because `onload=`/`onerror=` cannot: an enforced CSP blocks inline event handlers
// outright, and there is no nonce or hash that applies to them — the attribute is the violation.
// A listener bound from the admin bundle is ordinary same-origin script, which the policy allows.
//
// THE `complete` CHECK IS THE PART THE ATTRIBUTES DID NOT NEED. They were parsed before the request
// started, so no event could be missed. A hook mounts after the element is in the document, and a
// cached image is already finished by then — it will never fire `load` again, and without this every
// second visit to the page would show the glyph under an image that is perfectly fine.
const MediaThumb = {
  mounted() {
    this.sync();
  },
  updated() {
    this.sync();
  },
  sync() {
    const img = this.el.querySelector("img");
    if (!img) return;

    if (img !== this.img) {
      this.detach();
      this.img = img;
      this.settled = (event) => this.settle(event.type === "load");
      img.addEventListener("load", this.settled);
      img.addEventListener("error", this.settled);
    }

    // A patch may have swapped the src for another record's, so the verdict on the old one is
    // cleared before the new one is judged.
    img.style.display = "";
    img.style.background = "";
    if (img.complete) this.settle(img.naturalWidth > 0);
  },
  settle(loaded) {
    if (!loaded) {
      this.img.style.display = "none";
      return;
    }

    const background = this.el.dataset.loadedBackground;
    if (background) this.img.style.background = background;
  },
  detach() {
    if (!this.img) return;
    this.img.removeEventListener("load", this.settled);
    this.img.removeEventListener("error", this.settled);
    this.img = null;
  },
  destroyed() {
    this.detach();
  },
};

// Admin dashboard widget grid: drag-to-reorder within the grid, and a shared Sortable group with
// the widget library tray so chips drop in ("add_at") and widgets drag off the board ("hide" via
// the tray's onAdd). Dragging is enabled only while data-customize="true". Touch-friendly: the
// short delayOnTouchOnly hold starts a drag while taps and page scroll keep working.
const DashboardGrid = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      animation: 150,
      handle: "[data-drag-handle]",
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      disabled: this.el.dataset.customize !== "true",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        const index = evt.newIndex;
        evt.item.remove();
        this.pushEvent("add_at", { id, index });
      },
      onEnd: (evt) => {
        if (evt.from !== evt.to || evt.oldIndex === evt.newIndex) return;
        const ids = Array.from(
          this.el.querySelectorAll(":scope > [data-id]"),
        ).map((el) => el.dataset.id);
        this.pushEvent("reorder", { ids });
      },
    });
  },
  updated() {
    this.sorter?.option("disabled", this.el.dataset.customize !== "true");
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// The widget library tray: chips drag onto the grid (handled by the grid's onAdd); a widget card
// dropped HERE is removed from the board ("hide"). Chips also add on plain click/tap.
const DashboardTray = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      sort: false,
      animation: 150,
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        evt.item.remove();
        this.pushEvent("hide", { id });
      },
    });
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// A number field the server bounds, bounded on the client too. The gear panel it lives in is
// `phx-update="ignore"`, so once rendered its inputs are never patched again: a value the server
// clamps is stored clamped while the field keeps showing what was typed, for the rest of the
// session. Snapping on blur rather than on every keystroke leaves typing alone.
const NumberBounds = {
  mounted() {
    // `getAttribute`, not `el.min`: an absent bound reads as "" there and `Number("")` is 0, which
    // would hold every unbounded field to zero.
    const bound = (name) => {
      const raw = this.el.getAttribute(name);

      return raw === null || raw === "" ? null : Number(raw);
    };

    this.onBlur = () => {
      const value = Number(this.el.value);

      if (this.el.value === "" || Number.isNaN(value)) return;

      const min = bound("min");
      const max = bound("max");

      let bounded = value;

      if (min !== null && !Number.isNaN(min)) bounded = Math.max(min, bounded);
      if (max !== null && !Number.isNaN(max)) bounded = Math.min(max, bounded);

      if (bounded !== value) {
        this.el.value = String(bounded);
        this.el.dispatchEvent(new Event("input", { bubbles: true }));
      }
    };

    this.el.addEventListener("blur", this.onBlur);
  },
  destroyed() {
    this.el.removeEventListener("blur", this.onBlur);
  },
};

// The admin sidebar's scrolling nav. It is drawn by the LiveView layout, so every live navigation
// replaces it with a fresh element at the top; this puts it back where the reader left it. The
// position lives in `sessionStorage`, one per tab, so it also survives the full page loads into and
// out of the builder. With nothing saved, the active link is scrolled into view instead.
const SIDEBAR_SCROLL_KEY = "admin-sidebar:scrollTop";

const SidebarScroll = {
  mounted() {
    let saved = null;

    try {
      saved = sessionStorage.getItem(SIDEBAR_SCROLL_KEY);
    } catch (_denied) {
      // Private browsing may refuse sessionStorage; fall back to the active link below.
    }

    const top = saved === null ? NaN : parseInt(saved, 10);

    if (Number.isNaN(top)) {
      this.el.querySelector("[aria-current='page']")?.scrollIntoView({ block: "nearest" });
    } else {
      this.el.scrollTop = top;
    }

    this.frame = null;
    this.onScroll = () => {
      if (this.frame !== null) return;

      this.frame = requestAnimationFrame(() => {
        this.frame = null;

        // A nav already swapped out reads 0; keep the position the reader actually left.
        if (!this.el.isConnected) return;

        try {
          sessionStorage.setItem(SIDEBAR_SCROLL_KEY, String(this.el.scrollTop));
        } catch (_denied) {
          // Without storage the position is simply not kept.
        }
      });
    };

    this.el.addEventListener("scroll", this.onScroll, { passive: true });
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);

    if (this.frame !== null) cancelAnimationFrame(this.frame);
  },
};

export default {
  NumberBounds,
  SidebarScroll,
  UploadSubmitsItself,
  MediaThumb,
  DashboardGrid,
  DashboardTray,
};
