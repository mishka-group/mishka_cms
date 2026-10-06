// Where a drop would land, and what to draw for it.
//
// This is the half of the builder's drag and drop that the browser answers on its own — geometry,
// resolved per pointer move with no round trip. (Legality is the server's, and arrives once at
// dragstart; see the canvas hook in `app.js`.) It lives in its own file because it is the part with
// real cases in it — rows against stacks, reversed rows, a climb out of a container that will not
// take the node — and a pure function is the only shape of that logic anyone can check.
//
// Nothing here touches the DOM directly. The hook passes in the four things it knows how to look
// up, so a test can hand it plain rectangles instead of a rendered page.

// WHICH WAY THE CHILDREN RUN.
//
// Before this, "before or after" came from the pointer's Y and the line drawn for it was always
// horizontal. That is right for a stack and wrong for every row: in a four-across band the siblings
// sit side by side, so Y reads "after" for the whole height of the row and the line points at a
// place the drop was never going to land.
//
// `-reverse` is not cosmetic either. There the leftmost child is the LAST one, so visually-before is
// a HIGHER index — reading the pointer one way and writing the index the other is exactly how a
// block dropped to the left of its neighbour comes back on the right.
export function axisOf(style) {
  if (!style) return { axis: "y", reversed: false };
  const flex = style.display === "flex" || style.display === "inline-flex";
  const grid = style.display === "grid" || style.display === "inline-grid";
  const flow = flex ? style.flexDirection || "row" : "";
  return {
    axis: (flex && flow.startsWith("row")) || grid ? "x" : "y",
    reversed: flow.endsWith("-reverse"),
  };
}

// How far along its own axis the pointer sits inside a box. 0 is the leading edge, 1 the trailing
// one — in the direction the siblings are laid out, not always downwards.
function along(point, rect, axis) {
  return axis === "x"
    ? (point.x - rect.left) / (rect.width || 1)
    : (point.y - rect.top) / (rect.height || 1);
}

// The middle of a box means "put it inside"; the outer thirds mean "put it beside". A third rather
// than a half because beside is the commoner intent and needs the bigger target.
const INSIDE_FROM = 0.33;
const INSIDE_TO = 0.67;

/**
 * Resolve a pointer position to the parent and index a drop would use.
 *
 * @param {{x: number, y: number}} point pointer position, viewport coordinates
 * @param {object|null} node the `[data-node-id]` element under the pointer, or null for open canvas
 * @param {object} lookup
 *   - `rectOf(el)` → the element's box
 *   - `styleOf(el)` → the element's computed style (only `display` and `flexDirection` are read)
 *   - `parentOf(el)` → the nearest ancestor `[data-node-id]`, or null at the root
 *   - `childrenOf(el|null)` → that parent's `[data-node-id]` children, in DOM order
 *   - `idOf(el)` / `labelOf(el)` → the node's id and the name to show for it
 *   - `accepts(id)` → may this parent take the node at all
 *   - `nests(el)` → may this element hold children
 * @returns {{parent_id: string, index: number, rect: object|null, axis: string,
 *            anchor_id?: string, anchor_before?: boolean,
 *            inside?: boolean, before?: boolean, redirected?: boolean, label?: string|null}}
 */
export function resolveDrop(point, node, lookup) {
  const { rectOf, styleOf, parentOf, childrenOf, idOf, labelOf, accepts, nests } = lookup;

  if (!node) return { parent_id: "root", index: 9999, rect: null, axis: "y" };

  let current = node;
  let rect = rectOf(current);
  let flow = axisOf(styleOf(parentOf(current)));
  const ratio = along(point, rect, flow.axis);

  if (nests(current) && ratio > INSIDE_FROM && ratio < INSIDE_TO) {
    return {
      parent_id: idOf(current),
      index: 9999,
      rect,
      axis: flow.axis,
      inside: true,
      label: labelOf(current),
    };
  }

  let before = ratio < 0.5;
  let parent = parentOf(current);
  let redirected = false;

  // A parent that will not take this node is not a place to point at. Climb to the nearest one that
  // will and land after the branch that could not be entered, rather than promising a spot the
  // server is about to refuse.
  while (parent && !accepts(idOf(parent))) {
    current = parent;
    parent = parentOf(current);
    rect = rectOf(current);
    flow = axisOf(styleOf(parent));
    before = false;
    redirected = true;
  }

  const siblings = childrenOf(parent);
  const at = siblings.indexOf(current);
  const first = flow.reversed ? !before : before;

  return {
    parent_id: parent ? idOf(parent) : "root",
    index: first ? at : at + 1,
    // WHAT THE DROP IS ACTUALLY BESIDE, so the server can count for itself.
    //
    // `index` above is a position in the RENDERED list, and the tree's child list is a different
    // list: a `:slot` child renders no element of its own — the component's markup decides where its
    // content goes and hands it straight to `render_slot` — so the slot costs one tree place and
    // zero boxes on screen, while its children surface as siblings of the component's own. Counting
    // boxes therefore answered one too low for everything after a slot, which is why a field dropped
    // after the textarea landed in front of it, every time.
    //
    // The anchor cannot drift: `EditorSession.anchored/2` reads the node's real parent and its real
    // index out of the tree. `index` stays as the fallback for an anchor that has been deleted under
    // a drag in flight.
    //
    // `first`, not `before`: in a `-reverse` row visually-before is a HIGHER index, and the tree is
    // what is being written.
    anchor_id: idOf(current),
    anchor_before: first,
    rect,
    axis: flow.axis,
    label: redirected ? labelOf(current) : null,
    before,
    redirected,
  };
}

/**
 * The box to paint for a resolved target: an upright line down a row's edge, a horizontal one across
 * a stack's, or a grown outline around a container being entered.
 *
 * Returned as plain numbers so the hook can write them and a test can read them.
 *
 * @param {object} target the result of `resolveDrop`
 * @param {number} grow how far an "inside" outline reaches past the container's own bounds
 */
export function indicatorBox(target, grow) {
  const { rect } = target;
  if (!rect) return null;

  if (target.inside) {
    return {
      left: rect.left - grow,
      top: rect.top - grow,
      width: rect.width + grow * 2,
      height: rect.height + grow * 2,
      shape: "inside",
    };
  }

  if (target.axis === "x") {
    return {
      left: target.before ? rect.left : rect.right,
      top: rect.top,
      width: 2,
      height: rect.height,
      shape: "upright",
    };
  }

  return {
    left: rect.left,
    top: target.before ? rect.top : rect.bottom,
    width: rect.width,
    height: 2,
    shape: "across",
  };
}

// HOW FAST TO SCROLL WHEN THE POINTER NEARS AN EDGE.
//
// A page taller than the frame could not be dropped into below the fold at all: HTML drag does not
// scroll for you, and there is no way to let go and grab again mid-gesture. Speed rises the closer
// the pointer gets, so a nudge creeps and a push moves.
//
// Pure, and separate from the loop that applies it, because the loop is `requestAnimationFrame` —
// which a browser suspends outright in a hidden tab, and which therefore cannot be observed in a
// headless check. The arithmetic can.
//
// @returns pixels to scroll per frame: negative for up, positive for down, 0 for "not near an edge"
export function edgeVelocity(y, height, { edge = 56, speed = 18 } = {}) {
  const fromTop = y;
  const fromBottom = height - y;
  if (fromTop < edge) return -Math.ceil(((edge - fromTop) / edge) * speed);
  if (fromBottom < edge) return Math.ceil(((edge - fromBottom) / edge) * speed);
  return 0;
}

/**
 * The form a field being dragged joins at a resolved target, and the node it lands in front of.
 *
 * A field joins the form its landing parent is in, or the form it is dropped against (the drop's
 * anchor is itself a form, its top or bottom edge). A spot past that form's first Send button lands
 * in front of it, so `landing` is that button (or the node the server lands such a drop before) and
 * the line is drawn there; `null` keeps the resolved spot.
 *
 * @param {object} target the result of `resolveDrop`
 * @param {object} lookup
 *   - `byId(id)` → the `[data-node-id]` element, or null
 *   - `formOf(el)` → `el` when it is a form, else its nearest form ancestor, or null
 *   - `isForm(el)` → whether `el` is a form
 *   - `nameOf(form)` → the form's people name, "" for a form that does not work yet
 *   - `landingOf(form)` → the node a drop at the form's end lands before, or null
 *   - `precedes(a, b)` → `a` comes before `b` in document order, neither inside the other
 *   - `contains(a, b)` → `b` is `a` or inside it
 * @returns {{form: object|null, name: string|null, landing: object|null}}
 */
export function formLanding(target, lookup) {
  const { byId, formOf, isForm, nameOf, landingOf, precedes, contains } = lookup;
  const parent = target.parent_id && target.parent_id !== "root" ? byId(target.parent_id) : null;
  const anchor = target.anchor_id ? byId(target.anchor_id) : null;
  const inside = parent ? formOf(parent) : null;
  const against = !inside && anchor && isForm(anchor) ? anchor : null;
  const form = inside || against;

  if (!form) return { form: null, name: null, landing: null };

  const name = nameOf(form) || null;
  const send = landingOf(form);

  if (!send || (against && target.anchor_before)) return { form, name, landing: null };
  if (against) return { form, name, landing: send };

  const past = target.inside
    ? contains(parent, send) || precedes(send, parent)
    : anchor && target.anchor_before
      ? precedes(send, anchor)
      : !!anchor && (contains(anchor, send) || precedes(send, anchor));

  return { form, name, landing: past ? send : null };
}

/**
 * The words a field drag adds to the caption, and their colour: "joins Contact form" in violet, or
 * "starts a new form" in the line's blue.
 *
 * @param {{form: object|null, name: string|null}} landing the result of `formLanding`
 * @returns {{text: string, tone: "violet"|"blue"}}
 */
export function formCaption(landing) {
  if (!landing.form) return { text: "starts a new form", tone: "blue" };
  if (!landing.name) return { text: "joins this form", tone: "violet" };

  const numbered = /^Form \d+$/.test(landing.name);
  return { text: numbered ? `joins ${landing.name}` : `joins ${landing.name} form`, tone: "violet" };
}
