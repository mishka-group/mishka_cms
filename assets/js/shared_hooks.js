// THE HOOKS BOTH SIDES MOUNT. A flash notice dismisses itself wherever it appears, and a
// copy-to-clipboard button is a copy-to-clipboard button. Everything else belongs to exactly one
// audience — see `admin_hooks.js` and `site_hooks.js`.

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

export default {
  FlashAutoDismiss,
  CopyToClipboard,
};
