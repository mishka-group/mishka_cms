// THE HOOKS ONLY THE ADMIN EVER MOUNTS — the dashboard's widget grid. No public template names one
// of these, and the elements they attach to exist only under /admin.
//
// They live here rather than in `app.js` so the RUNTIME JAVASCRIPT COMPILER can leave them out. That
// compiler builds each site's bundle with `app.js` as its entry point, so every hook below — and
// `sortablejs` with them — was being shipped to every visitor of every site, to sit unmounted.
//
// `app.js` reaches them through `if (MISHKA_ADMIN)`, which esbuild replaces at build time: true for
// the admin bundle, false for a site's, where the branch and this whole module are then dropped.

import Sortable from "sortablejs";

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

export default {
  NumberBounds,
  DashboardGrid,
  DashboardTray,
};
