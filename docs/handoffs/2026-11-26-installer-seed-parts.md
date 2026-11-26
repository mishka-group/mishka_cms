# Handoff: installer choices are parts on `installer:seed` (2026-11-26)

## Where things are

- PRs, one per repo, all open, none merged:
  - core: mishka-group/mishka_cms_core#164 (issue #163)
  - host: mishka-group/mishka_cms#100 (issue #99)
  - blog: mishka-group/mishka_blog#81 (issue #80)
  - documentation: mishka-group/mishka_document#86 (issue #85)
- Branch `feat/dev-seed-event` in each. They depend on each other: merge core first, then the extensions, then the host; the release cascade bumps them in that order.

## What the code does now

- `MishkaCmsCore.Install.Seeds` reads every plugin on the `installer:seed` mishka_installer event. Its moduledoc holds the contract and a full example plugin.
- A plugin's `extra` is a list of parts: `id`, `label`, `summary`, `envs` (`[:dev]`, `[:prod]` or both), `required` (locked, always runs), `default` (ticked at start), optional `nav` (`path:` gets the `/:lang` prefix, `to:` stays literal).
- The core's own plugin, `MishkaCmsCore.Install.CoreSeed`, declares the production install's steps as parts; `Bootstrap.run/2` runs the chosen parts. A production build refuses a `[:dev]` part (`{:error, :dev_in_production}`).
- Each extension declares `pages` (dev and prod, runs `Extensions.install/3`, which records `<app>.installed`) and `samples` (dev only).
- The wizard shows one "What gets installed" list: each plugin is a closed row with a live count, opening to its parts; required parts carry a lock. The dev "load sample data" list is the same component.
- `priv/repo/dev_seeds.exs` and `stress_test_seeds.exs` call `Install.Seeds.run_all/2` and name no extension.

## Gotchas

- An install test that means to run one extension must name every other seed plugin with no part, or `MishkaCms.Test.SeedProbe.extensions_off!/0`: every extension's `pages` part starts ticked.
- A dev re-run on an installed database: the `pages` part is refused by the extension's own installer (no actor) and shows as a failed optional part; `samples` still runs.
- Old registrations under `dev:seed` log one "unregistered" warning each on the first boot after upgrading.

## Open, not in these PRs

- Wizard: a reload on the components step returns to step 1; a Site title edit resets after Back then Next.
- Blog and documentation admin pages do not follow a site switcher; the blog dashboard shows the same figures for every site.
- After a normal install the header has no Blog or Docs links (only the dev `samples` parts add nav).
- Documents: `?page=2` in a link opens page 1.
