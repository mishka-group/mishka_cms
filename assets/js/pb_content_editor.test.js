import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

// THE HOOK THE ADMIN BUNDLE CARRIES for the content editor: it fetches the editor's bundle on the
// first mount, as `pb_code_editor.js` does CodeMirror's, and when the bundle does not come the
// author still edits the field — as HTML, in a box that writes into the hidden textarea.

async function hookModule() {
  vi.resetModules();

  return await import("./pb_content_editor.js");
}

function surface() {
  document.body.innerHTML = `
    <textarea id="ed-value" name="form[content]" hidden></textarea>
    <div id="ed-surface" data-value-id="ed-value" data-label-plain="Editor did not load"><p data-role="content-editor-loading">Loading</p></div>`;

  document.getElementById("ed-value").value = "<p>Stored</p>";

  return document.getElementById("ed-surface");
}

function pending() {
  const list = Array.from(document.head.querySelectorAll("script"));

  return list[list.length - 1];
}

beforeEach(() => {
  document.head.innerHTML =
    '<meta name="pb-content-editor-src" content="/assets/js/content_editor.js" />';
  delete window.MishkaContentEditor;
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  document.head.innerHTML = "";
  document.body.innerHTML = "";
  delete window.MishkaContentEditor;
  vi.restoreAllMocks();
});

describe("ContentEditor", () => {
  test("fetches the bundle the layout names and mounts its engine on the surface", async () => {
    const { ContentEditor } = await hookModule();
    const handle = { updated: vi.fn(), destroyed: vi.fn() };
    const mount = vi.fn(() => handle);
    const hook = Object.assign(Object.create(ContentEditor), { el: surface() });

    hook.mounted();

    expect(pending().src).toContain("/assets/js/content_editor.js");

    window.MishkaContentEditor = { mount };
    pending().onload();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(mount).toHaveBeenCalledWith(hook);
    expect(hook.el.querySelector("[data-role='content-editor-loading']")).toBeNull();

    hook.updated();
    hook.destroyed();

    expect(handle.updated).toHaveBeenCalled();
    expect(handle.destroyed).toHaveBeenCalled();
  });

  test("with no bundle, the field is edited as HTML and still reaches the form", async () => {
    const { ContentEditor } = await hookModule();
    const el = surface();
    const hook = Object.assign(Object.create(ContentEditor), { el });
    const mirror = document.getElementById("ed-value");
    const heard = vi.fn();
    mirror.addEventListener("input", heard);

    hook.mounted();
    pending().onerror();
    await new Promise((resolve) => setTimeout(resolve, 0));

    const box = el.querySelector("[data-role='content-editor-plain']");
    expect(box.value).toBe("<p>Stored</p>");
    expect(el.textContent).toContain("Editor did not load");
    expect(el.textContent).not.toContain("Loading");

    box.value = "<p>Typed</p>";
    box.dispatchEvent(new Event("input"));

    expect(mirror.value).toBe("<p>Typed</p>");
    expect(heard).toHaveBeenCalledTimes(1);
  });

  test("a surface gone before the bundle arrives mounts nothing", async () => {
    const { ContentEditor } = await hookModule();
    const mount = vi.fn();
    const hook = Object.assign(Object.create(ContentEditor), { el: surface() });

    hook.mounted();
    hook.destroyed();

    window.MishkaContentEditor = { mount };
    pending().onload();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(mount).not.toHaveBeenCalled();
  });
});
