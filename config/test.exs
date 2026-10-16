# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config
config :mishka_cms, Oban, testing: :manual
config :mishka_cms_core, token_signing_secret: "wx4H2IZdYD3YU8ttLCI9jr2UBCVZHorf"
config :bcrypt_elixir, log_rounds: 1
config :mishka_cms_core, seed_announce: false
# config :ash, policies: [show_policy_breakdowns?: true]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mishka_cms, MishkaCms.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "mishka_cms_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mishka_cms, MishkaCmsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qs9cQou7AVmLGmR6xwAdBj66SuM1pYvIKfYeTZ47aKibHEjJYLId1GlX8B+uqoUz",
  server: false

# In test we don't send emails
config :mishka_cms_core, MishkaCmsCore.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Email goes to the test adapter unless a test picks another provider — see `MishkaCmsCore.Mail`.
config :mishka_cms_core, mail_dev_mailbox: true, mail_default_provider: "dev_mailbox"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :mishka_cms_core, :env_test?, true

# EVERY TEST SIGNS IN FROM 127.0.0.1, so the limits the CMS ships with would throttle the suite long
# before they throttled anybody guessing a password. The tests of the limiter lift this and set
# their own through the settings.
config :mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit, limit: 1_000_000

# A captcha provider's verify request never leaves the machine: a test answers it with
# `Req.Test.stub(MishkaCmsCore.Captcha, ...)` — see `MishkaCmsCore.Captcha.Provider.siteverify/2`.
config :mishka_cms_core, MishkaCmsCore.Captcha.Provider,
  req_options: [plug: {Req.Test, MishkaCmsCore.Captcha}]

# mishka_installer decides whether to start its own supervision tree (Mnesia registry, event and
# compile handlers) from `MishkaInstaller.__information__().env`, so that ITS suite runs without
# them — but a dependency is built in the host's env, so our test run inherited that and every
# `Hook.call` returned its input untouched: no dashboard widgets, no settings:register, no filter
# seams. `:project_env` is the library's own override, and it is kept because it works whenever it
# is consulted.
#
# IT IS NOT ENOUGH ON ITS OWN. `__information__/0` reads `System.get_env("MIX_ENV")` BEFORE this
# key, and the choice is a compile-time branch in the dependency — so an exported `MIX_ENV` at the
# moment `deps/` was built silently wins, and a routine `mix deps.get` is all it takes.
# `MishkaCmsCore.Application` therefore supervises whatever the library left out, ahead of the first
# plugin and in every environment; see `MishkaCmsCore.Application.installer_children/0`.
config :mishka_installer, project_env: :dev

config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand(".mnesia/test"),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

# A BUNDLE A DEVELOPER PLACED BY HAND WINS HERE, until a version is picked in the installer.
# Production looks up the newest release instead, so a stale file in an image cannot stand in for it —
# see `MishkaCmsCore.Runtime.Handlers.UiKitHandler.prefer_local?/0`. Both environments still fall
# back to the other source, so neither dead-ends.
config :mishka_cms_core, :prefer_local_ui_kits, true

# THE STYLED KIT FROM A FIXTURE, WITH NOTHING TO DOWNLOAD. A server downloads its kits into
# `priv/cms_ui_kits/` at install, and none ships there; the tests read the copy of Chelekom's styled
# bundle mishka_cms_core keeps in its `test/fixtures/cms_ui_kits/`.
config :mishka_cms_core,
       :ui_kits_dir,
       Path.expand("../__extensions/mishka_cms_core/test/fixtures/cms_ui_kits", __DIR__)

# The code default also offers the headless package, which is not among the fixtures, so every cold
# catalogue — the install
# wizard, the Studio sheet — fell through to a real HTTP request and parsed Chelekom behind it, and a
# test waiting on that render timed out whenever the internet was slow. `url: nil` fails without a
# request, so a missing file is reported rather than fetched. A test about downloading configures
# its own list and a `:ui_kit_req_options` plug, and restores this one afterwards.
config :mishka_cms_core, :official_ui_kits, [
  %{key: :styled, label: "Chelekom — styled", file: "chelekom.json", tag: "test", url: nil}
]

# The tests read dates and numbers in English, which ships with `localize`: nothing is downloaded.
config :localize, allow_runtime_locale_download: false
