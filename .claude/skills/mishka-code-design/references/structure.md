# File and module layout

Read the repo you are in first. Its existing tree is the authority, and this file only summarises it. The repos are listed in SKILL.md under "Where to read the code". Read a local checkout or `deps/<repo>` when you have one, and GitHub otherwise.

## Shared rules

- **One concern per module, related code together.** A file holds one module and everything that belongs to its job. Don't split a concern across files, and don't keep a file that only forwards to Ash, mishka_installer or another module.
- **Shallow folders.** Use the double-underscore folders below for parts that belong to one owner; avoid deeper trees.
- **`__` folders sit beside what uses them.** The folder name drops its underscores in the module name:
  - `lib/app/resources/__changes/seal_secret.ex` → `App.Resources.Changes.SealSecret`
  - `lib/app/resources/__validations/status.ex` → `App.Resources.Validations.Status`
  - `lib/app/workers/__helpers/pipeline.ex` → `App.Workers.Helpers.Pipeline`
  - `lib/app/runtime/authoring/__strict/violation.ex` → `App.Runtime.Authoring.Strict.Violation`

  Folders in use: `__actions`, `__calculations`, `__changes`, `__checks`, `__embeddeds`, `__mixins`, `__notifiers`, `__preparations`, `__validations`, `__helpers`.
- **What other parts call stays at the top level.** Behaviours, events, provisioning and the domain stay there. What only one part uses moves into that part's `__` folder.
- **SPDX header on every file:** copy it from a neighbour, and keep REUSE (`REUSE.toml`, `LICENSES/`) passing.

## An extension (mishka_blog, mishka_document, mishka_cms_migration)

```
lib/
  app.ex                      # the Ash domain + code interfaces
  app/
    application.ex            # supervises the extension's mishka_installer plugins (plugins/0)
    provision.ex              # what installing on a site creates (permissions, settings)
    events.ex                 # the events the extension fires
    <behaviour>.ex            # a contract other extensions implement (e.g. source.ex, target.ex)
    resources/
      <resource>.ex           # Ash resources, guardedstruct inside
      __changes/  __validations/  __calculations/  __preparations/ …
    workers.ex                # what the app attaches for its jobs (e.g. telemetry)
    workers/__helpers/        # code only the jobs use
    plugins/                  # mishka_installer hook modules (blog style)
  app_web/live/admin/         # admin screens built with mishka_gervaz
test/
  support/                    # DataCase, factory, test plugins/fakes
  fixtures/                   # recorded real responses
config/                       # standalone dev/test config
mix.exs                       # mishka_dep/2 helper: sibling checkout or Hex
```

`mix.exs` takes Mishka siblings through `mishka_dep/2`. It uses the `../<name>` checkout when that is a git checkout, and Hex otherwise, so local work and CI each get the right one. A library that is being fixed alongside (for example guarded_struct) goes through the same helper.

## The engine (mishka_cms_core)

Areas live under `lib/mishka_cms_core/<area>/`: accounts, runtime, install, mail, notify, settings, ui_kit, sidebar, layouts and so on. Each area has its own `resources/` with the `__` folders, and its own `workers/`. Web code lives in `lib/mishka_cms_core_web/`. Shared helpers include `provider_registry.ex`, `settings.ex`, `supervision.ex` and `extension_router.ex`. Look there before writing a helper.

## The builder (mishka_cms_builder)

- `lib/mishka_cms_builder/`: editor session, placement, palette.
- `lib/mishka_cms_builder_web/live/`: canvas and panels.
- `assets/js/`: hooks, tested with bun under `assets/test/`.

## The host (mishka_cms)

- The Phoenix app.
- `__extensions/<name>` folders hold symlinks to the sibling checkouts' `lib`, `config` and so on.
- `mishka_dep` takes Hex when `MISHKA_DEPS=hex`.
- `config.exs` lists `ash_domains`, the Oban queues and `:extensions`.
- The dev reloader doesn't recompile core: stop the server, run `mix compile`, then start it again.

## Naming

- Elixir conventions, plus one vocabulary per repo. Pick one word per idea and use it in code, docs, tests and the README.
- A family of modules of the same kind shares one entry point name and argument order. mishka_installer's plugins all expose `call/1`, and a helper family exposes one public `call`.
- Callbacks of a behaviour keep the same argument order in every implementation.
