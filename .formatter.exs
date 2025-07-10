[
  import_deps: [
    :ash_oban,
    :oban,
    :ash_events,
    :ash_state_machine,
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_postgres,
    :ash_phoenix,
    :ash,
    :reactor,
    :ash_archival,
    :ecto,
    :ecto_sql,
    :phoenix,
    :guarded_struct,
    :mishka_gervaz
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/ash_test_generator.ex",
    "priv/*/entry_dev_test_seeds.ex"
  ]
]
