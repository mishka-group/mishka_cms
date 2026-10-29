// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// LOADED ON DEMAND, NOT WITH THE ADMIN BUNDLE — the rich-text editor's engine, Tiptap and
// ProseMirror, fetched by mishka_cms_core's `ContentEditor` hook (its
// `assets/js/pb_content_editor.js`) the first time a content editor appears, the way `code_editor.js`
// is for CodeMirror. It hangs itself on `window.MishkaContentEditor`.
//
// `../vendor/editor.js` is Mishka Chelekom's headless `editor` engine (the `chelekom-headless-editor`
// hook, ui kit 0.0.10-alpha.9, Chelekom commit 1973a209), copied byte for byte out of
// mishka_cms_core's `priv/cms_ui_kits/chelekom_headless.json` and never edited — the drift test in
// `test/mishka_cms/content_editor_engine_test.exs` says how to refresh it. What the CMS adds is
// `../vendor/editor_extensions.js`, the file the engine imports for its extensions.
import Editor from "../vendor/editor.js";
import { attach, detach, repaint } from "../vendor/editor_extensions.js";

// The engine is a LiveView hook object. It runs on an object of its own, handed the four things of
// the real hook it calls, so the hook that loaded it keeps its own `mounted`/`updated`/`destroyed`.
export function mount(hook) {
  const engine = Object.assign(Object.create(Editor), {
    el: hook.el,
    pushEventTo: (...args) => hook.pushEventTo(...args),
    handleEvent: (...args) => hook.handleEvent(...args),
    removeHandleEvent: (ref) => hook.removeHandleEvent(ref),
  });

  attach(hook.el, hook);
  engine.mounted();

  return {
    engine,

    updated() {
      engine.updated();
      repaint(hook.el);
    },

    destroyed() {
      engine.destroyed();
      detach(hook.el);
    },
  };
}

window.MishkaContentEditor = { mount };
