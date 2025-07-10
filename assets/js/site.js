// A SITE'S JAVASCRIPT — what a visitor downloads, and the entry point
// `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler` builds each site's bundle from. It appends
// that site's own runtime hooks to the object below before bundling.
//
// Nothing here reaches the admin's. That is the whole point of the file existing: see `app.js`.

import { boot } from "./boot";
import SharedHooks from "./shared_hooks";
import SiteHooks from "./site_hooks";

boot({ ...SharedHooks, ...SiteHooks });
