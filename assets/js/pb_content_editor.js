// THE HOOK CARRIES NO EDITOR AT ALL, as `pb_code_editor.js` carries no CodeMirror. It fetches
// `content_editor.js` the first time a content editor appears — the address the layout publishes as
// `<meta name="pb-content-editor-src">` — and runs the engine that file hangs on
// `window.MishkaContentEditor` on this element: the surface of the markup
// `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` draws for `extra %{content_editor: true}`.
//
// THE HIDDEN TEXTAREA STAYS THE FORM FIELD. The engine writes the HTML into it and dispatches
// `input`, so save and validation never learn that an editor exists; if the bundle does not arrive,
// a plain box on the surface writes into it instead, and the author edits the HTML itself.
import { bundleLoader } from "./pb_code_editor";

export const loadContentEditor = bundleLoader("pb-content-editor-src", "MishkaContentEditor");

export const ContentEditor = {
  mounted() {
    loadContentEditor()
      .then((bundle) => {
        if (this.gone || !this.el.isConnected) return;
        this.loaded();
        this.editor = bundle.mount(this);
      })
      .catch((error) => this.plain(error));
  },

  updated() {
    if (this.editor) this.editor.updated();
  },

  destroyed() {
    this.gone = true;
    if (this.editor) this.editor.destroyed();
    this.editor = null;
  },

  // The server draws "Loading the editor…" in the surface, which stays there when this hook never
  // runs at all — an admin bundle built without it says so instead of showing nothing.
  loaded() {
    const loading = this.el.querySelector("[data-role='content-editor-loading']");
    if (loading) loading.remove();
  },

  // The surface is `phx-update="ignore"`, so what is put in it here stays through every patch.
  plain(error) {
    console.warn("[ContentEditor] staying with the HTML:", error.message);
    this.loaded();

    const mirror = document.getElementById(this.el.dataset.valueId);
    if (!mirror || this.gone || this.el.querySelector("[data-role='content-editor-plain']")) return;

    const notice = document.createElement("p");
    notice.textContent = this.el.dataset.labelPlain || "";

    const box = document.createElement("textarea");
    box.dataset.role = "content-editor-plain";
    box.dir = "auto";
    box.spellcheck = false;
    box.value = mirror.value;
    box.addEventListener("input", () => {
      mirror.value = box.value;
      mirror.dispatchEvent(new Event("input", { bubbles: true }));
    });

    this.el.append(notice, box);
  },
};
