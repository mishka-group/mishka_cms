// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE ADMIN'S JAVASCRIPT, and only the admin's.
//
// Loaded by every page under /admin — the dashboard, the page builder and its canvas. A visitor
// never receives this file; their page is served `site.js`, built per site by
// `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler`.
//
// The two used to be one. The runtime compiler took THIS file as its entry point and spliced the
// site's own hooks into it, so every visitor of every site downloaded the page builder, the
// dashboard's widget grid and `sortablejs` in order never to mount any of them. Two entry points
// with a shared `boot/1` is what keeps that honest: neither side can grow into the other's bundle
// without somebody writing the import.

import { boot } from "./boot";
import SharedHooks from "./shared_hooks";
import AdminHooks from "./admin_hooks";

boot({ ...SharedHooks, ...AdminHooks });
