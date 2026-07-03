import { afterEach, describe, expect, test } from "vitest";

import AdminHooks from "./admin_hooks.js";

afterEach(() => {
  document.body.innerHTML = "";
});

// The gear panel this field lives in is `phx-update="ignore"`, so the server can never patch the
// value back. Whatever the field shows after the reader leaves it is what they keep seeing.
describe("NumberBounds", () => {
  function field(attrs) {
    document.body.innerHTML = `<input type="number" ${attrs} />`;

    const el = document.querySelector("input");
    const hook = Object.create(AdminHooks.NumberBounds);

    hook.el = el;
    hook.mounted();

    return el;
  }

  function blur(el, typed) {
    el.value = typed;
    el.dispatchEvent(new Event("blur"));

    return el.value;
  }

  test("snaps down to the maximum", () => {
    expect(blur(field('min="1" max="12"'), "999")).toBe("12");
  });

  test("snaps up to the minimum", () => {
    expect(blur(field('min="1" max="12"'), "0")).toBe("1");
  });

  test("leaves a value inside the bounds alone", () => {
    expect(blur(field('min="1" max="12"'), "7")).toBe("7");
  });

  test("leaves an empty field empty, which is not a zero", () => {
    expect(blur(field('min="1" max="12"'), "")).toBe("");
  });

  test("does nothing without bounds to hold it to", () => {
    expect(blur(field(""), "999")).toBe("999");
  });

  // The correction has to reach the server too, or the field and the stored value disagree the
  // other way round.
  test("announces the value it settled on", () => {
    const el = field('min="1" max="12"');
    const seen = [];

    el.addEventListener("input", () => seen.push(el.value));
    blur(el, "999");

    expect(seen).toEqual(["12"]);
  });
});
