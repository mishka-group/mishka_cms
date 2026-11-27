// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE INSTALL WIZARD'S ANSWERS, KEPT IN THIS TAB, so a reload carries on where it stopped. Nothing
// is installed before the last step, so the answers cannot wait in the database, and the LiveView
// that holds them goes with the page. The browser's `sessionStorage` keeps them for this tab alone
// and drops them when the tab closes.
//
// A hook because `Phoenix.LiveView.JS` cannot read or write the browser's storage. The server
// decides what is kept: it pushes `install-draft` with the answers, the master password never
// among them, and `null` once the install starts. On mount, and again after a reconnect to a new
// server process, the hook hands back whatever it holds as `restore_draft`.
const KEY = "mishka-install-draft";

function read() {
  try {
    return JSON.parse(sessionStorage.getItem(KEY));
  } catch {
    return null;
  }
}

// Storage a browser refuses (private mode, a full quota) keeps nothing, and the wizard works as it
// did without it.
function write(draft) {
  try {
    if (draft) sessionStorage.setItem(KEY, JSON.stringify(draft));
    else sessionStorage.removeItem(KEY);
  } catch {
    // nothing kept
  }
}

const InstallDraft = {
  mounted() {
    this.handleEvent("install-draft", ({ draft }) => write(draft));
    this.restore();
  },
  reconnected() {
    this.restore();
  },
  restore() {
    this.pushEvent("restore_draft", { draft: read() });
  },
};

export default { InstallDraft };
