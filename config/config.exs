# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

config :mishka_cms, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 5, modules: 8, assets: 2, sitemaps: 1, maintenance: 2, notify: 5, mail: 2],
  repo: MishkaCms.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 604_800}
  ]

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

config :mishka_cms,
  ecto_repos: [MishkaCms.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: []

# Configures the endpoint
config :mishka_cms, MishkaCmsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MishkaCmsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MishkaCms.PubSub,
  live_view: [signing_salt: "SUCSjzEp"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
