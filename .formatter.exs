[
  import_deps: [
    :ash_oban,
    :oban,
    :ash_postgres,
    :ash_phoenix,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix
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
