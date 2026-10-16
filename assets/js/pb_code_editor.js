// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HOOK CARRIES NO CODEMIRROR AT ALL. It fetches `code_editor.js` the first time a code box
// appears on screen and mounts what that file hangs on `window.PbCodeMirror`. The admin bundle stays
// the size it was; the 262 KB is paid by the one screen that uses it, once, and then it is cached.
//
// THE TEXTAREA STAYS THE FORM FIELD. CodeMirror is mounted beside it and writes into it on every
// change, so save, validation and `CodeCheck` never learn that an editor exists — and if this script
// or the bundle fails to load, the box is a working textarea rather than nothing.
//
// `phx-update="ignore"` on the wrapper is what stops LiveView reconciling away the DOM CodeMirror
// built. The cost is that a server-side change does not reach the editor by itself; `updated()`
// pushes it in, but only when the text really differs, or every keystroke elsewhere on the page
// would drop the cursor to the end mid-word.

export function bundleUrl(meta = "pb-code-editor-src") {
  const tag = document.querySelector(`meta[name="${meta}"]`);
  return tag ? tag.content : null;
}

// A bundle the layout publishes the address of in a `<meta name=…>`, loaded as a plain script the
// first time something asks for it, and the object it hangs on `window[global]`. `loadEditor` below
// is CodeMirror's; `pb_content_editor.js` makes the rich-text editor's.
//
// One request however many boxes mount at once: the second and third await the same promise.
//
// A FAILURE IS NOT CACHED. `loading` used to be set to the promise whatever became of it, so the
// first fetch that did not arrive was the last one this tab ever tried: every code box opened
// afterwards awaited the same settled rejection and stayed a plain textarea, through every
// selection and every live navigation, until the browser was reloaded. One rebuild of the bundle
// under an open tab was enough to do it — a request landing mid-write reads a truncated script,
// which loads without defining anything. Clearing it here costs one more `<script>` on the next box
// and buys back the retry.
export function bundleLoader(meta, global) {
  let loading = null;
  let attempts = 0;

  // THE RETRY CARRIES A DIFFERENT URL, because the likeliest thing to have gone wrong is a
  // half-written file — and a half-written file is a 200 with an ETag, which the browser is
  // entitled to hand back unchanged however many times it is asked for. Re-requesting the address
  // that just failed would re-read the same bytes out of the cache and fail identically for as long
  // as they live there.
  function fetchBundle(src) {
    const url = attempts ? `${src}?retry=${attempts}` : src;

    attempts += 1;

    return new Promise((resolve, reject) => {
      const script = document.createElement("script");

      const fail = (message) => {
        script.remove();
        reject(new Error(message));
      };

      script.src = url;
      script.onload = () =>
        window[global] ? resolve(window[global]) : fail(`bundle loaded without ${global}`);
      script.onerror = () => fail("could not load " + url);
      document.head.appendChild(script);
    });
  }

  return function load() {
    if (window[global]) return Promise.resolve(window[global]);
    if (loading) return loading;

    const src = bundleUrl(meta);
    if (!src) return Promise.reject(new Error(`no ${meta} meta tag`));

    loading = fetchBundle(src).catch((error) => {
      loading = null;
      throw error;
    });

    return loading;
  };
}

export const loadEditor = bundleLoader("pb-code-editor-src", "PbCodeMirror");

export const PbCodeEditor = {
  mounted() {
    const textarea = this.el.querySelector("textarea");
    if (!textarea) return;

    // DIRTY TRACKING IS BOUND TO THE TEXTAREA, NOT TO CODEMIRROR, and that is what makes the Apply
    // button work on the plain box too: CodeMirror writes into the textarea and dispatches `input`,
    // so one listener covers both the upgraded editor and the fallback nobody upgraded.
    this.pane = this.el.closest("[data-pane]");
    this.form = textarea.form;
    this.pristine = textarea.value;
    this.watch = () => this.mark(textarea.value);
    textarea.addEventListener("input", this.watch);

    // ⌘↵ APPLIES, because the button is in a header and the cursor is not. Somebody forty lines into
    // a document has no reason to look up at a pane title, and the first report of this feature was
    // "I changed it and nothing happened" from someone who had typed the change and never pressed
    // the only control that commits it. This is the gesture every other editor uses for "run it".
    this.enter = (event) => {
      if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return;
      event.preventDefault();
      this.submit();
    };
    textarea.addEventListener("keydown", this.enter);

    loadEditor()
      .then((editor) => this.attach(editor, textarea))
      // A textarea nobody upgraded is still a textarea somebody can type in.
      .catch((error) => this.plain(textarea, error))
      .then(() => this.reveal(textarea));
  },

  // A box the server marked `data-focus` is scrolled into view and takes the cursor.
  reveal(textarea) {
    if (!this.el.hasAttribute("data-focus") || !this.el.isConnected) return;

    this.el.scrollIntoView({ block: "center" });

    if (this.view) this.view.focus();
    else textarea.focus();
  },

  // AND IT HAS TO SAY WHICH ONE IT IS. Unannounced, a box with no line numbers, no colours and no
  // completions does not read as a plain textarea — it reads as the editor, broken, and the report
  // that comes back is that the panel stopped working. One line naming what happened turns that into
  // something the reader can act on, and re-opening the pane is a real retry now.
  //
  // Written with a style attribute rather than classes on purpose: Tailwind generates rules for the
  // class names it finds in SOURCE, and a name that exists only in this file is a name it never
  // sees. A notice that appears when things have gone wrong cannot depend on the build having
  // guessed it was coming.
  plain(textarea, error) {
    console.warn("[PbCodeEditor] staying with the textarea:", error.message);

    if (this.el.querySelector("[data-role='pb-cm-plain']")) return;

    const notice = document.createElement("p");

    notice.dataset.role = "pb-cm-plain";
    notice.textContent = "Editor did not load — plain text box. Close and reopen to try again.";
    notice.style.cssText =
      "margin:0;padding:2px 0 4px;font-size:10.5px;font-weight:600;color:#e0bd80";

    this.el.insertBefore(notice, textarea);
  },

  // The button appears and disappears by an attribute on the pane, so typing costs no server round
  // trip at all — and typing a change back to what it was takes the button away again, because an
  // Apply that would do nothing is a button that teaches you to distrust the ones that would.
  mark(value) {
    if (!this.pane) return;

    if (value === this.pristine) this.pane.removeAttribute("data-dirty");
    else this.pane.setAttribute("data-dirty", "true");
  },

  attach(editor, textarea) {
    if (this.view || !this.el.isConnected) return;

    textarea.style.display = "none";

    const host = document.createElement("div");
    host.dataset.role = "pb-cm";

    // TWO SHAPES OF BOX, and the difference has to be declared rather than guessed. A pane with a
    // definite height — the drawer, the Code window — wants the editor to fill it and scroll inside;
    // a box that grows with its content — a handler body in a scrolling form — wants the opposite.
    // CodeMirror's `height: 100%` resolves against THIS element, so filling means giving it one.
    // Without it the editor sized itself to 921px inside a 207px pane and everything past line
    // sixteen was clipped away with no scrollbar to reach it.
    if (this.el.dataset.fill === "true") host.style.height = "100%";

    this.el.appendChild(host);

    this.view = editor.create(
      host,
      textarea.value,
      this.el.dataset.language,
      (text) => {
        textarea.value = text;
        // `input` so a `phx-change` form still hears it; the textarea is the field either way.
        textarea.dispatchEvent(new Event("input", { bubbles: true }));
      },
      { onSubmit: () => this.submit() },
    );
  },

  // Nothing to apply is not worth a round trip: every apply of markup costs a real compile on the
  // server, so an idle ⌘↵ would spend a second proving the document still says what it said.
  submit() {
    if (this.form && this.pane && this.pane.hasAttribute("data-dirty")) this.form.requestSubmit();
  },

  // A server-sent value is the NEW pristine: an apply that succeeded, or a different element
  // selected, is not something the reader still has unapplied changes to.
  updated() {
    const textarea = this.el.querySelector("textarea");
    if (!textarea) return;

    const incoming = textarea.value;
    this.pristine = incoming;
    this.mark(incoming);

    if (!this.view || incoming === this.view.state.doc.toString()) return;

    this.view.dispatch({
      changes: { from: 0, to: this.view.state.doc.length, insert: incoming },
    });
  },

  destroyed() {
    const textarea = this.el.querySelector("textarea");

    if (textarea && this.watch) textarea.removeEventListener("input", this.watch);
    if (textarea && this.enter) textarea.removeEventListener("keydown", this.enter);
    if (this.view) this.view.destroy();
  },
};
