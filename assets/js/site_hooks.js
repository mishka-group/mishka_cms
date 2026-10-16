// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HOOKS ONLY A PUBLIC PAGE EVER MOUNTS — the host's own marketing pages (Mishka Group, Chelekom,
// GuardedStruct, the installer, the theme builder) and nothing under /admin. Not one of these is
// named by an admin template; they animate starfields, type command lines and bob cards on pages a
// visitor sees.
//
// They are here rather than in `app.js` for the mirror of the reason `admin_hooks.js` exists: the
// admin bundle IS `app.js`, so every one of these was downloaded by every admin page, to sit
// unmounted behind a dashboard. `app.js` reaches them through `if (!MISHKA_ADMIN)` — false for the
// admin build, where esbuild drops the branch and this module with it.

export default {
};
