# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

# Settings providers — extension modules exporting `definitions/0` (a list of
# `MishkaCmsCore.Settings.define/3` maps), aggregated into the settings store at boot. Extensions
# append themselves here (or register at runtime via the `settings:register` hook). The core's own
# settings live in `MishkaCmsCore.Settings` directly.
config :mishka_cms_core, :settings_providers, []

# THE UI KITS the first-run installer fetches come, by default, from the newest stable release of
# mishka-group/mishka_chelekom that attaches them — or a pre-release, or the files on its `master`,
# as the operator picks in the installer. No version is written anywhere. Set this to fetch exact
# files instead (one or several, from anywhere) — to hold a version or use your own fork — or to
# `[]` for an air-gapped install that uses only the bundles already in `priv/cms_ui_kits/`. The
# installer then offers no version choice.
#
#     config :mishka_cms_core, :official_ui_kits, [
#       %{
#         key: :styled,
#         label: "Chelekom — styled",
#         file: "chelekom.json",
#         tag: "v0.0.10-alpha.6",
#         url: "https://github.com/…/releases/download/v0.0.10-alpha.6/chelekom.json"
#       }
#     ]

# HOW LONG A CSS OR JS BUILD WAITS while another one installs the Tailwind or esbuild binary, in
# milliseconds — ten minutes unless set. The download has no timeout of its own, so a build that
# waits longer gives up with an error; a slow connection on a fresh install may need more.
#
#     config :mishka_cms_core, :asset_install_wait, :timer.minutes(20)

# Kept out of every request and LiveView event log: a parameter whose name holds one of these words
# — an account password, a provider's API key (`mailer.resend.api_key`), a sign-in token.
config :phoenix, :filter_parameters, ["password", "secret", "api_key", "token"]

# MishkaGervaz gettext backend - use our app's Gettext for i18n in DSL labels
config :mishka_gervaz, :gettext_backend, MishkaCmsCore.Gettext

config :mishka_cms, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 5, modules: 8, assets: 2, sitemaps: 1, maintenance: 2, notify: 5, mail: 2],
  repo: MishkaCms.Repo,
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"0 4 * * *", MishkaCmsCore.Notify.Workers.PruneWorker}]},
    {Oban.Plugins.Pruner, max_age: 604_800}
  ]

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash_graphql, authorize_update_destroy_with_error?: true

config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [
    no_filter_static_forbidden_reads?: false
    # show_policy_breakdowns?: true,
    # log_policy_breakdowns: :error,
    # log_successful_policy_breakdowns: :error
  ],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :tokens,
        :postgres,
        :json_api,
        :graphql,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :json_api,
        :graphql,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

# Which repo the resources write through and which endpoint they broadcast on. Read with
# `Application.compile_env!/2` inside `postgres do repo … end` and `pub_sub do module … end`, so the
# resources name a setting instead of naming this application — that is what lets an extension be
# compiled and tested outside the CMS. Resolved at compile time, so it costs nothing at run time.
config :mishka_cms_core,
  repo: MishkaCms.Repo,
  endpoint: MishkaCmsWeb.Endpoint,
  host_app: :mishka_cms,
  # The base compiled runtime modules are built on, so templates can use this app's
  # components and `~p` routes. See `MishkaCmsCore.Runtime.CompiledPageBase`.
  web_module: MishkaCmsWeb,
  core_components: MishkaCmsWeb.CoreComponents

config :mishka_cms,
  ecto_repos: [MishkaCms.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    MishkaCmsCore.Runtime,
    MishkaCmsCore.Accounts,
    MishkaCmsCore.Notify,
    MishkaCmsCore.Mail
  ]

# Extensions - each must have a .Routes submodule implementing ExtensionRouter behaviour.
# Read by `MishkaCmsCore`, so it lives under that app's name rather than the host's.
config :mishka_cms_core,
  extensions: [
    MishkaCmsCoreWeb
  ]

# Configures the endpoint
config :mishka_cms, MishkaCmsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MishkaCmsWeb.ErrorHTML, json: MishkaCmsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MishkaCmsCore.PubSub,
  live_view: [signing_salt: "SUCSjzEp"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :mishka_cms_core, MishkaCmsCore.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  mishka_cms: [
    args:
      ~w(js/app.js js/site.js js/code_editor.js js/preview.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  mishka_cms_css: [
    # CSS only
    args: ~w(css/app.css --bundle --outdir=../priv/static/assets/css),
    cd: Path.expand("../assets", __DIR__)
  ],
  mishka_cms_js: [
    args: [],
    env: %{"NODE_PATH" => Path.expand("../priv/static/temp/js_assets/node_modules", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  mishka_cms: [
    args: ~w(
    --input=assets/css/app.css
    --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ],
  mishka_cms_css: [
    args: ~w(),
    cd: Path.expand("..", __DIR__)
  ],
  # THE ADMIN CHROME — the one stylesheet in this app that is NOT compiled at runtime.
  #
  # A site's CSS is built dynamically by `MishkaCmsCore.Runtime.Compilers.TailwindCompiler`, because
  # a site's classes live in database rows that change without a deploy. The admin's classes do not:
  # they are in templates, fixed at build time, and compiling them per request bought nothing. This
  # profile is that split made explicit — `admin_*` is static and shipped, everything else is the
  # runtime compiler's.
  #
  # It must stay out of `app.css`: the runtime compiler inlines that file into the static base every
  # site's CSS is built on, so the dashboard's utilities would end up inside every public page.
  # Args are supplied by `mix admin_css`, not here: the `@source` globs must be ABSOLUTE (Tailwind v4
  # filters relative ones through .gitignore, which excludes several vendored extensions), so the
  # input is generated. Configuring `--input` here would win over the task's and silently compile the
  # wrong file — which is exactly what happened the first time.
  admin_chrome: [
    args: ~w(),
    cd: Path.expand("..", __DIR__)
  ],
  # The host's public marketing pages. Static, known at build time, and deliberately NOT inside any
  # site's runtime bundle — see `Mix.Tasks.AdminCss`.
  public_pages: [
    args: ~w(),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
