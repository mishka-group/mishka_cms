# Friction log

A row for every guess, or every missing tool to see the real result. **Rows are never deleted**:
closing a row fills the last column with what catches it now, one of:

- `check:<name>`: a step in `mix ci`, a CI job, or a test
- `skill rule`: written in `AGENTS.md` or a skill
- `helper:<name>`: a test helper (its doc says what it does not prove)
- `decided`: a design choice, written where the code is
- `open`: nothing yet. An `open` row seen twice must become a `check`.

| Date | What was missing or guessed | Where | How it is caught now |
|---|---|---|---|
| 2026-11-22 | Core was released before the host's `AsyncLocaleTest` ran, so core needed a second release in one cycle | release cycle | skill rule (`mishka-release`: rehearse on the host before wave 1) |
| 2026-11-23 | `/favicon.ico` of a site with no favicon was tested as a 404 after core changed it to the Mishka mark | `test/mishka_cms_web/seo_files_test.exs` | check:test suite |
| 2026-11-23 | CI ran no credo, sobelow, dialyzer or ex_dna, so their findings went stale on master | `.github/workflows/ci.yml` | check:ci (all four turned on) |
| 2026-11-26 | The commit hook was not active in this clone (`core.hooksPath` unset, `mix hooks` never run), so commits went in without it; its format and credo commands were run by hand on the staged files | `.githooks/pre-commit` | check:ci (lint runs format and credo on every push) |
| 2026-11-26 | The blog and documentation plugins still subscribe through `MishkaCmsCore.Dev.Seeds.event/0` with the old one-map `extra`, so the installer shows no part for them and the core keeps that function only until they declare their `pages` and `samples` parts on `installer:seed` | `test/mishka_cms/install/blog_provision_bootstrap_test.exs`, `test/mishka_cms/install/document_provision_bootstrap_test.exs` | check:test (both bootstrap tests and `dev_seeds_test.exs` pass on the blog's and documentation's `installer:seed` parts) |
| 2026-11-26 | The install tests chose one extension's parts, or none, and named no other plugin, so every other extension's `pages` part, ticked at the start, ran too and put its components on the site | `test/mishka_cms/install/blog_provision_bootstrap_test.exs`, `test/mishka_cms/install/document_provision_bootstrap_test.exs`, `test/mishka_cms/install/dev_seeds_test.exs`, `test/mishka_cms/install/bootstrap_test.exs`, `test/mishka_cms_web/live/install_live_test.exs` | helper:`MishkaCms.Test.SeedProbe.extensions_off!/0` (a core or wizard test stops the extensions' plugins), and each extension test names every other plugin of `Seeds.plugins/1` with no part |
