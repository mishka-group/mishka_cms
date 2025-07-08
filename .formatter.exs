[
  import_deps: [
    :phoenix
  ],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/ash_test_generator.ex",
    "priv/*/entry_dev_test_seeds.ex"
  ]
]
