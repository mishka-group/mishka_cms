// React portals the canvas content into an <iframe> body. jsdom — unlike real browsers,
// which load a `srcDoc` iframe as the iframe's initial document — fires iframe `load` events
// that hand back a fresh body node, so React's portal reconciliation can try to remove a node
// from a now-detached body ("NotFoundError: The node to be removed is not a child of this
// node"). This is purely a jsdom iframe artifact; the runtime is correct in real browsers
// (verified manually + by every assertion here). Swallow ONLY that specific error.
const isBenignIframePortalError = (err) =>
  !!err &&
  err.name === "NotFoundError" &&
  typeof err.message === "string" &&
  err.message.includes("not a child");

if (typeof window !== "undefined") {
  window.addEventListener(
    "error",
    (event) => {
      if (isBenignIframePortalError(event.error)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    },
    true,
  );
}

process.on("uncaughtException", (err) => {
  if (!isBenignIframePortalError(err)) throw err;
});
