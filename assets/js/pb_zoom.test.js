import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import hooks from "./admin_hooks";

// The markup `Panels` renders for the two canvas zooms: the More menu's single-frame zoom, the view
// note under it, the all-breakpoints zoom, and the canvas scroll that carries both variables.
function markup({ single = 100, frame = 30 } = {}) {
  document.body.innerHTML = `
    <div id="pb-zoom" data-zoom="single" data-single-zoom="${single}" data-min="40" data-max="200"
      data-event="zoom_set">
      <button type="button" id="pb-zoom-out" data-zoom-step="-10"></button>
      <button type="button" id="pb-zoom-reset" data-zoom-reset="100"><span
        data-zoom-label="single">${single}%</span></button>
      <button type="button" id="pb-zoom-in" data-zoom-step="10"></button>
    </div>
    <span id="pb-viewnote">Desktop · <span data-zoom-label="single">${single}%</span></span>
    <span id="pb-frzoom" data-zoom="frame" data-frame-zoom="${frame}" data-min="20" data-max="100"
      data-event="frame_zoom_set">
      <button type="button" id="pb-frzoom-out" data-zoom-step="-10"></button>
      <button type="button" id="pb-frzoom-reset" data-zoom-reset="100"><span
        data-zoom-label="frame">${frame}%</span></button>
      <button type="button" id="pb-frzoom-in" data-zoom-step="10"></button>
    </span>
    <div id="pb-canvas-scroll" data-zoom="single frame" data-zoom-root
      data-single-zoom="${single}" data-frame-zoom="${frame}"
      style="--pb-single-zoom:${single / 100};--pb-frame-zoom:${frame / 100}"></div>
  `;
}

const $ = (id) => document.getElementById(id);
const scale = (prop) => $("pb-canvas-scroll").style.getPropertyValue(prop).trim();
const labels = (kind) =>
  [...document.querySelectorAll(`[data-zoom-label="${kind}"]`)].map((el) => el.textContent);
const click = (id) => $(id).dispatchEvent(new MouseEvent("click", { bubbles: true }));

describe("PbZoom", () => {
  let mounted;
  let pushes;

  function mount(id) {
    const hook = Object.create(hooks.PbZoom);
    hook.el = $(id);
    hook.pushEvent = (event, payload) => pushes.push({ from: id, event, payload });
    hook.mounted();
    mounted.push(hook);
    return hook;
  }

  // What a LiveView patch does to these elements: every attribute, style and label back to what the
  // server renders, then `updated()` on each hook it touched.
  function serverRenders({ single, frame }) {
    const scroll = $("pb-canvas-scroll");
    scroll.dataset.singleZoom = String(single);
    scroll.dataset.frameZoom = String(frame);
    scroll.setAttribute("style", `--pb-single-zoom:${single / 100};--pb-frame-zoom:${frame / 100}`);

    $("pb-zoom").dataset.singleZoom = String(single);
    $("pb-frzoom").dataset.frameZoom = String(frame);

    for (const label of document.querySelectorAll('[data-zoom-label="single"]')) {
      label.textContent = `${single}%`;
    }
    for (const label of document.querySelectorAll('[data-zoom-label="frame"]')) {
      label.textContent = `${frame}%`;
    }

    $("pb-zoom-out").disabled = single <= 40;
    $("pb-zoom-in").disabled = single >= 200;
    $("pb-frzoom-out").disabled = frame <= 20;
    $("pb-frzoom-in").disabled = frame >= 100;

    for (const hook of mounted) hook.updated();
  }

  beforeEach(() => {
    vi.useFakeTimers();
    mounted = [];
    pushes = [];
    markup();
    mount("pb-zoom");
    mount("pb-frzoom");
    mount("pb-canvas-scroll");
  });

  afterEach(() => {
    for (const hook of mounted) hook.destroyed();
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  it("paints the variable and every label on the click itself, with nothing pushed yet", () => {
    click("pb-frzoom-in");

    expect(scale("--pb-frame-zoom")).toBe("0.4");
    expect(labels("frame")).toEqual(["40%"]);

    click("pb-zoom-in");

    expect(scale("--pb-single-zoom")).toBe("1.1");
    expect(labels("single")).toEqual(["110%", "110%"]);
    expect(pushes).toEqual([]);
  });

  it("resets to the reset button's value at once", () => {
    click("pb-frzoom-reset");

    expect(scale("--pb-frame-zoom")).toBe("1");
    expect(labels("frame")).toEqual(["100%"]);
  });

  it("stops at both bounds", () => {
    for (let i = 0; i < 12; i++) click("pb-frzoom-in");
    expect(labels("frame")).toEqual(["100%"]);
    expect(scale("--pb-frame-zoom")).toBe("1");

    for (let i = 0; i < 20; i++) click("pb-frzoom-out");
    expect(labels("frame")).toEqual(["20%"]);
    expect(scale("--pb-frame-zoom")).toBe("0.2");

    for (let i = 0; i < 20; i++) click("pb-zoom-in");
    expect(labels("single")).toEqual(["200%", "200%"]);
    expect(scale("--pb-single-zoom")).toBe("2");
  });

  it("clamps a step that would land past a bound to the bound", () => {
    serverRenders({ single: 100, frame: 95 });

    click("pb-frzoom-in");

    expect(labels("frame")).toEqual(["100%"]);
  });

  it("disables − and + at the bounds as soon as the browser reaches them", () => {
    expect($("pb-frzoom-out").disabled).toBe(false);

    click("pb-frzoom-out");

    expect($("pb-frzoom-out").disabled).toBe(true);
    expect($("pb-frzoom-in").disabled).toBe(false);

    click("pb-frzoom-in");

    expect($("pb-frzoom-out").disabled).toBe(false);

    for (let i = 0; i < 7; i++) click("pb-frzoom-in");

    expect(labels("frame")).toEqual(["100%"]);
    expect($("pb-frzoom-in").disabled).toBe(true);
  });

  it("pushes the final value once, after the clicking stops", () => {
    click("pb-frzoom-in");
    vi.advanceTimersByTime(200);
    click("pb-frzoom-in");
    vi.advanceTimersByTime(200);
    click("pb-frzoom-in");
    vi.advanceTimersByTime(299);

    expect(pushes).toEqual([]);

    vi.advanceTimersByTime(1);

    expect(pushes).toEqual([
      { from: "pb-frzoom", event: "frame_zoom_set", payload: { value: 60 } },
    ]);

    vi.advanceTimersByTime(5000);

    expect(pushes).toHaveLength(1);
  });

  it("pushes nothing when the clicks end where the server already is", () => {
    click("pb-zoom-in");
    click("pb-zoom-out");
    vi.advanceTimersByTime(1000);

    expect(pushes).toEqual([]);
  });

  it("paints its own value back over a patch that still carries the server's old one", () => {
    click("pb-frzoom-in");
    click("pb-zoom-out");

    serverRenders({ single: 100, frame: 30 });

    expect(scale("--pb-frame-zoom")).toBe("0.4");
    expect(scale("--pb-single-zoom")).toBe("0.9");
    expect(labels("frame")).toEqual(["40%"]);
    expect(labels("single")).toEqual(["90%", "90%"]);

    vi.advanceTimersByTime(300);

    expect(pushes.map((push) => push.payload.value).sort()).toEqual([40, 90]);
  });

  it("keeps clicks made after a push when that push is rendered back", () => {
    click("pb-frzoom-in");
    vi.advanceTimersByTime(300);
    click("pb-frzoom-in");

    serverRenders({ single: 100, frame: 40 });

    expect(labels("frame")).toEqual(["50%"]);
    expect(scale("--pb-frame-zoom")).toBe("0.5");

    vi.advanceTimersByTime(300);

    expect(pushes.map((push) => push.payload.value)).toEqual([40, 50]);
  });

  it("takes a value the server changed by itself", () => {
    click("pb-zoom-in");
    click("pb-zoom-in");
    vi.advanceTimersByTime(300);
    serverRenders({ single: 120, frame: 30 });

    serverRenders({ single: 100, frame: 30 });

    expect(scale("--pb-single-zoom")).toBe("1");
    expect(labels("single")).toEqual(["100%", "100%"]);
    expect(pushes).toHaveLength(1);
  });

  it("drops a pending push when the server changes the zoom by itself", () => {
    click("pb-frzoom-in");

    serverRenders({ single: 100, frame: 100 });
    vi.advanceTimersByTime(1000);

    expect(labels("frame")).toEqual(["100%"]);
    expect(scale("--pb-frame-zoom")).toBe("1");
    expect($("pb-frzoom-in").disabled).toBe(true);
    expect(pushes).toEqual([]);
  });

  it("still pushes when the clicked control is removed before the clicking settles", () => {
    click("pb-frzoom-in");

    const controls = mounted.find((hook) => hook.el.id === "pb-frzoom");
    controls.destroyed();
    mounted = mounted.filter((hook) => hook !== controls);
    $("pb-frzoom").remove();

    vi.advanceTimersByTime(300);

    expect(pushes).toEqual([
      { from: "pb-zoom", event: "frame_zoom_set", payload: { value: 40 } },
    ]);
  });

  it("leaves a click outside the zoom buttons alone", () => {
    $("pb-canvas-scroll").dispatchEvent(new MouseEvent("click", { bubbles: true }));
    vi.advanceTimersByTime(1000);

    expect(scale("--pb-frame-zoom")).toBe("0.3");
    expect(pushes).toEqual([]);
  });
});
