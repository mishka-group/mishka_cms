import { describe, expect, it } from "vitest";
import {
  axisOf,
  edgeVelocity,
  formCaption,
  formLanding,
  indicatorBox,
  resolveDrop,
} from "./pb_drop";

// A fake page: nodes are plain objects with a box, a layout and children. The resolver never
// touches the DOM, so this is the whole world it needs.
function page(root) {
  const parents = new Map();

  const link = (node) => {
    for (const child of node.children || []) {
      parents.set(child, node);
      link(child);
    }
  };
  link(root);

  return {
    root,
    lookup: {
      rectOf: (node) => node.rect,
      styleOf: (node) => node && node.style,
      parentOf: (node) => parents.get(node) || null,
      childrenOf: (node) => (node || root).children || [],
      idOf: (node) => node.id,
      labelOf: (node) => node.label || node.id,
      accepts: (id) => root.refuses !== id,
      nests: (node) => node.nests !== false,
    },
  };
}

// A stack: three bands one under the other, 100 tall each.
function stack() {
  const children = [0, 1, 2].map((i) => ({
    id: `s${i}`,
    nests: false,
    rect: { left: 0, right: 300, top: i * 100, bottom: i * 100 + 100, width: 300, height: 100 },
  }));

  return page({
    id: "col",
    style: { display: "block" },
    rect: { left: 0, right: 300, top: 0, bottom: 300, width: 300, height: 300 },
    children,
  });
}

// A row: four cards side by side, 100 wide each — the layout the whole change is for.
function row(flexDirection = "row") {
  const children = [0, 1, 2, 3].map((i) => ({
    id: `c${i}`,
    nests: false,
    rect: { left: i * 100, right: i * 100 + 100, top: 0, bottom: 200, width: 100, height: 200 },
  }));

  return page({
    id: "band",
    style: { display: "flex", flexDirection },
    rect: { left: 0, right: 400, top: 0, bottom: 200, width: 400, height: 200 },
    children,
  });
}

describe("axisOf", () => {
  it("reads a flex row as horizontal and a flex column as vertical", () => {
    expect(axisOf({ display: "flex", flexDirection: "row" })).toEqual({
      axis: "x",
      reversed: false,
    });
    expect(axisOf({ display: "flex", flexDirection: "column" })).toEqual({
      axis: "y",
      reversed: false,
    });
  });

  it("marks a reversed row, on either axis", () => {
    expect(axisOf({ display: "flex", flexDirection: "row-reverse" })).toEqual({
      axis: "x",
      reversed: true,
    });
    expect(axisOf({ display: "flex", flexDirection: "column-reverse" })).toEqual({
      axis: "y",
      reversed: true,
    });
  });

  // Grid children flow across before they wrap, so the gap between two of them is a vertical one.
  it("reads a grid as horizontal", () => {
    expect(axisOf({ display: "grid" }).axis).toBe("x");
  });

  // Anything that is not a row is a stack, including a missing parent at the document root.
  it("falls back to vertical", () => {
    expect(axisOf({ display: "block" }).axis).toBe("y");
    expect(axisOf(null)).toEqual({ axis: "y", reversed: false });
  });
});

describe("resolveDrop in a stack", () => {
  const { root, lookup } = stack();

  it("lands before the band when the pointer is in its top half", () => {
    const at = resolveDrop({ x: 150, y: 110 }, root.children[1], lookup);
    expect(at).toMatchObject({ parent_id: "col", index: 1, before: true, axis: "y" });
  });

  it("lands after it when the pointer is in the bottom half", () => {
    const at = resolveDrop({ x: 150, y: 190 }, root.children[1], lookup);
    expect(at).toMatchObject({ parent_id: "col", index: 2, before: false });
  });
});

describe("resolveDrop in a row", () => {
  const { root, lookup } = row();

  // THE CASE THE CHANGE IS FOR. Y says nothing in a row — every card spans the same 200px — so the
  // old resolver read the pointer's height and answered "after" for the whole band.
  it("decides on X, not Y", () => {
    const left = resolveDrop({ x: 210, y: 190 }, root.children[2], lookup);
    expect(left).toMatchObject({ parent_id: "band", index: 2, before: true, axis: "x" });

    const right = resolveDrop({ x: 290, y: 10 }, root.children[2], lookup);
    expect(right).toMatchObject({ parent_id: "band", index: 3, before: false });
  });

  it("puts a drop past the last card at the end", () => {
    const at = resolveDrop({ x: 390, y: 100 }, root.children[3], lookup);
    expect(at.index).toBe(4);
  });
});

describe("resolveDrop in a reversed row", () => {
  const { root, lookup } = row("row-reverse");

  // `c2` is drawn third from the right. Aiming at its left edge means "put this one further along
  // the reversed order", which is a HIGHER index — the opposite of what the same gesture means in a
  // normal row.
  it("inverts the index, because visually-first is last", () => {
    const left = resolveDrop({ x: 210, y: 100 }, root.children[2], lookup);
    expect(left).toMatchObject({ before: true, index: 3 });

    const right = resolveDrop({ x: 290, y: 100 }, root.children[2], lookup);
    expect(right).toMatchObject({ before: false, index: 2 });
  });
});

describe("resolveDrop into a container", () => {
  it("goes inside when the pointer is in the middle third, along the container's own axis", () => {
    const { root, lookup } = stack();
    root.children[1].nests = true;

    const at = resolveDrop({ x: 150, y: 150 }, root.children[1], lookup);
    expect(at).toMatchObject({ parent_id: "s1", index: 9999, inside: true, label: "s1" });
  });

  // In a ROW the middle third is a horizontal band, not a vertical one. A pointer at the far left of
  // a card is beside it however high up it sits.
  it("uses X for the middle third inside a row", () => {
    const { root, lookup } = row();
    root.children[1].nests = true;

    expect(resolveDrop({ x: 150, y: 100 }, root.children[1], lookup).inside).toBe(true);
    expect(resolveDrop({ x: 105, y: 100 }, root.children[1], lookup).inside).toBeUndefined();
  });

  it("never offers to nest inside something that cannot hold children", () => {
    const { root, lookup } = stack();
    const at = resolveDrop({ x: 150, y: 150 }, root.children[1], lookup);
    expect(at.inside).toBeUndefined();
  });
});

describe("resolveDrop when the parent refuses", () => {
  // The server has already said this branch will not take the node. Pointing into it would promise
  // something the drop is about to undo, so the resolver climbs out and lands after the branch.
  it("climbs to an ancestor that accepts, and says so", () => {
    const inner = {
      id: "inner",
      nests: false,
      rect: { left: 10, right: 290, top: 10, bottom: 90, width: 280, height: 80 },
    };
    const locked = {
      id: "locked",
      label: "chelekom-card",
      style: { display: "block" },
      rect: { left: 0, right: 300, top: 0, bottom: 100, width: 300, height: 100 },
      children: [inner],
    };
    const { root, lookup } = page({
      id: "col",
      refuses: "locked",
      style: { display: "block" },
      rect: { left: 0, right: 300, top: 0, bottom: 300, width: 300, height: 300 },
      children: [locked, { id: "after", nests: false, rect: { left: 0, right: 300, top: 100, bottom: 200, width: 300, height: 100 } }],
    });

    const at = resolveDrop({ x: 150, y: 20 }, inner, lookup);
    expect(at).toMatchObject({
      parent_id: "col",
      index: 1,
      redirected: true,
      label: "chelekom-card",
    });
    expect(at.rect).toBe(root.children[0].rect);
  });
});

describe("resolveDrop with nothing under the pointer", () => {
  it("falls to the end of the document", () => {
    const { lookup } = stack();
    expect(resolveDrop({ x: 0, y: 0 }, null, lookup)).toMatchObject({
      parent_id: "root",
      index: 9999,
      rect: null,
    });
  });
});

describe("indicatorBox", () => {
  const rect = { left: 100, right: 200, top: 40, bottom: 240, width: 100, height: 200 };

  it("draws an upright line down a row's edge", () => {
    expect(indicatorBox({ rect, axis: "x", before: true }, 4)).toEqual({
      left: 100,
      top: 40,
      width: 2,
      height: 200,
      shape: "upright",
    });

    expect(indicatorBox({ rect, axis: "x", before: false }, 4).left).toBe(200);
  });

  it("draws a line across a stack's edge", () => {
    expect(indicatorBox({ rect, axis: "y", before: false }, 4)).toEqual({
      left: 100,
      top: 240,
      width: 100,
      height: 2,
      shape: "across",
    });
  });

  it("draws an outline grown past a container being entered", () => {
    expect(indicatorBox({ rect, axis: "x", inside: true }, 4)).toEqual({
      left: 96,
      top: 36,
      width: 108,
      height: 208,
      shape: "inside",
    });
  });

  it("draws nothing when there is no box", () => {
    expect(indicatorBox({ rect: null, axis: "y" }, 4)).toBeNull();
  });
});

describe("edgeVelocity", () => {
  const H = 800;

  it("stays still in the middle, where there is nothing to reach for", () => {
    expect(edgeVelocity(400, H)).toBe(0);
    expect(edgeVelocity(56, H)).toBe(0);
    expect(edgeVelocity(H - 56, H)).toBe(0);
  });

  it("scrolls up near the top and down near the bottom", () => {
    expect(edgeVelocity(10, H)).toBeLessThan(0);
    expect(edgeVelocity(H - 10, H)).toBeGreaterThan(0);
  });

  // A nudge creeps and a push moves: the closer to the edge, the faster.
  it("rises as the pointer closes on the edge", () => {
    expect(Math.abs(edgeVelocity(4, H))).toBeGreaterThan(Math.abs(edgeVelocity(40, H)));
    expect(edgeVelocity(H - 4, H)).toBeGreaterThan(edgeVelocity(H - 40, H));
  });

  it("never exceeds the speed it was given", () => {
    for (let y = 0; y <= H; y += 7) expect(Math.abs(edgeVelocity(y, H, { speed: 18 }))).toBeLessThanOrEqual(18);
  });
});

// THE ANCHOR — what the drop was actually beside, so the server can count for itself.
//
// `index` above is a position in the RENDERED list, and that is not the tree's child list whenever
// the parent is a component with a `:slot` child: the slot renders no element of its own, so it
// costs a tree place and no box, and everything after it measured one too low. A field dropped after
// a textarea landed in front of it, every time. The anchor is the fix — `EditorSession.anchored/2`
// reads the parent and the index off the tree — so these assert the two things it needs to be true:
// the id is the node the pointer was beside, and the flag is in TREE order, not screen order.
describe("resolveDrop's anchor", () => {
  it("names the sibling the pointer is beside, on either side of it", () => {
    const { root, lookup } = stack();

    expect(resolveDrop({ x: 150, y: 110 }, root.children[1], lookup)).toMatchObject({
      anchor_id: "s1",
      anchor_before: true,
    });

    expect(resolveDrop({ x: 150, y: 190 }, root.children[1], lookup)).toMatchObject({
      anchor_id: "s1",
      anchor_before: false,
    });
  });

  // A `-reverse` row draws its LAST child first, so "put it to the left of this one" means a higher
  // index. `before` is what the eye saw and stays as it is — the flag on the wire has to be what the
  // TREE will do, or the fix would reintroduce the bug it replaces on exactly this layout.
  it("is written in tree order, not screen order, in a reversed row", () => {
    const { root, lookup } = row("row-reverse");

    const left = resolveDrop({ x: 210, y: 100 }, root.children[2], lookup);
    expect(left).toMatchObject({ before: true, index: 3, anchor_id: "c2", anchor_before: false });

    const right = resolveDrop({ x: 290, y: 100 }, root.children[2], lookup);
    expect(right).toMatchObject({ before: false, index: 2, anchor_id: "c2", anchor_before: true });
  });

  // Climbing out of a branch the server refuses re-aims at the branch itself. The anchor has to
  // follow, or it would name a node inside the very container that will not take the drop.
  it("follows the climb out of a parent that refuses", () => {
    const inner = {
      id: "inner",
      nests: false,
      rect: { left: 10, right: 290, top: 10, bottom: 90, width: 280, height: 80 },
    };
    const locked = {
      id: "locked",
      style: { display: "block" },
      rect: { left: 0, right: 300, top: 0, bottom: 100, width: 300, height: 100 },
      children: [inner],
    };
    const { lookup } = page({
      id: "col",
      refuses: "locked",
      style: { display: "block" },
      rect: { left: 0, right: 300, top: 0, bottom: 300, width: 300, height: 300 },
      children: [locked],
    });

    expect(resolveDrop({ x: 150, y: 20 }, inner, lookup)).toMatchObject({
      anchor_id: "locked",
      anchor_before: false,
      redirected: true,
    });
  });

  // Going INSIDE a container is not beside anything, and the open canvas has nothing under the
  // pointer at all. Both must leave the anchor off entirely, or `anchored/2` would rewrite a parent
  // that was already right.
  it("is absent for a drop inside a container and for the open canvas", () => {
    const { root, lookup } = stack();
    root.children[1].nests = true;

    expect(resolveDrop({ x: 150, y: 150 }, root.children[1], lookup).anchor_id).toBeUndefined();
    expect(resolveDrop({ x: 150, y: 150 }, null, lookup).anchor_id).toBeUndefined();
  });
});

// WHICH FORM A FIELD JOINS, and where it lands in it — see `formLanding`.
// Plain objects standing in for elements: an id, a parent, and document order by position.
function world() {
  const nodes = {};
  let order = 0;

  const add = (id, parent, extra = {}) => {
    nodes[id] = { id, parent: parent ? nodes[parent] : null, at: order++, ...extra };
    return nodes[id];
  };

  const inside = (a, b) => {
    for (let node = b; node; node = node.parent) if (node === a) return true;
    return false;
  };

  const lookup = {
    byId: (id) => nodes[id] || null,
    isForm: (el) => !!el && el.form !== undefined,
    formOf: (el) => {
      for (let node = el; node; node = node.parent) if (node.form !== undefined) return node;
      return null;
    },
    nameOf: (form) => form.form,
    landingOf: (form) => Object.values(nodes).find((n) => n.send && inside(form, n)) || null,
    precedes: (a, b) => a !== b && !inside(a, b) && !inside(b, a) && a.at < b.at,
    contains: (a, b) => inside(a, b),
  };

  // form > card > [grid > [col1, col2], footer > [note, send]], then a loose box.
  add("page", null);
  add("form", "page", { form: "Contact" });
  add("card", "form");
  add("grid", "card");
  add("col1", "grid");
  add("col2", "grid");
  add("footer", "card");
  add("note", "footer");
  add("send", "footer", { send: true });
  add("loose", "page");
  add("plain", "page", { form: "" });

  return { nodes, lookup };
}

describe("formLanding", () => {
  it("keeps a spot aimed between two fields deep in a card", () => {
    const { lookup, nodes } = world();
    const target = { parent_id: "grid", anchor_id: "col1", anchor_before: false };

    expect(formLanding(target, lookup)).toEqual({
      form: nodes.form,
      name: "Contact",
      landing: null,
    });
  });

  it("moves a spot past the Send button in front of it", () => {
    const { lookup, nodes } = world();

    for (const target of [
      { parent_id: "footer", anchor_id: "send", anchor_before: false },
      { parent_id: "form", inside: true },
      { parent_id: "card", anchor_id: "footer", anchor_before: false },
    ]) {
      expect(formLanding(target, lookup).landing).toBe(nodes.send);
    }
  });

  it("but not a spot in front of it", () => {
    const { lookup } = world();
    const target = { parent_id: "footer", anchor_id: "send", anchor_before: true };

    expect(formLanding(target, lookup).landing).toBe(null);
  });

  it("joins a form dropped on its bottom edge, before its Send, and its top edge at the top", () => {
    const { lookup, nodes } = world();

    const bottom = formLanding({ parent_id: "page", anchor_id: "form", anchor_before: false }, lookup);
    const top = formLanding({ parent_id: "page", anchor_id: "form", anchor_before: true }, lookup);

    expect(bottom).toEqual({ form: nodes.form, name: "Contact", landing: nodes.send });
    expect(top).toEqual({ form: nodes.form, name: "Contact", landing: null });
  });

  it("joins no form anywhere else", () => {
    const { lookup } = world();
    const target = { parent_id: "page", anchor_id: "loose", anchor_before: false };

    expect(formLanding(target, lookup)).toEqual({ form: null, name: null, landing: null });
  });

  it("names a form that does not work yet by nothing", () => {
    const { lookup, nodes } = world();
    const target = { parent_id: "page", anchor_id: "plain", anchor_before: false };

    expect(formLanding(target, lookup)).toEqual({ form: nodes.plain, name: null, landing: null });
  });
});

describe("formCaption", () => {
  it("joins a named form in violet, a numbered one bare, a new one in blue", () => {
    expect(formCaption({ form: {}, name: "Contact" })).toEqual({
      text: "joins Contact form",
      tone: "violet",
    });

    expect(formCaption({ form: {}, name: "Form 2" }).text).toBe("joins Form 2");
    expect(formCaption({ form: {}, name: null }).text).toBe("joins this form");
    expect(formCaption({ form: null, name: null })).toEqual({
      text: "starts a new form",
      tone: "blue",
    });
  });
});

