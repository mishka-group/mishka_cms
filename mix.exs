defmodule MishkaCms.MixProject do
  use Mix.Project
  @version "0.0.1"

  def project do
    [
      app: :mishka_cms,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MishkaCms.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix Prod Stuff
      {:phoenix, "~> 1.8", override: true},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},

      # Req/Res Stuff
      {:bandit, "~> 1.12"},
      {:dns_cluster, "~> 0.3"},

      # Logger/Metrics Prod Stuff
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},

      # Dev/Test Stuff
      {:floki, "~> 0.38", only: :test},
      {:lazy_html, "~> 0.1", only: :test},
      {:igniter, "~> 0.8", only: :dev, override: true},
      {:usage_rules, "~> 1.2", only: [:dev]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},

      # Extra Stuff
      {:jason, "~> 1.4"},
      {:gettext, "~> 1.0"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors"
      ]
    ]
  end
end
