# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.MixProject do
  use Mix.Project
  @version "0.0.1"
  @source_url "https://github.com/mishka-group/mishka_cms"

  def project do
    [
      app: :mishka_cms,
      version: @version,
      name: "Mishka CMS",
      description: description(),
      package: package(),
      homepage_url: "https://mishka.tools/cms",
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md"],
        source_url: @source_url
      ],
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      # `lib/mix/` calls `Mix`, and `test/support` (compiled in :test, where `mix ci` runs dialyzer)
      # calls ExUnit; neither is in the default PLT. `.dialyzer_ignore.exs` lists what dialyzer
      # reports that is not a defect, each with the reason.
      dialyzer: [plt_add_apps: [:mix, :ex_unit], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  defp description do
    "An open source real-time CMS for Elixir and Phoenix LiveView, where one install runs many websites."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Shahryar Tavakkoli", "Mona Aghili"],
      links: %{
        "Mishka CMS" => "https://mishka.tools/cms",
        "Official document" => "https://mishka.tools/cms/docs",
        "GitHub" => @source_url,
        "Sponsor" => "https://github.com/sponsors/mishka-group",
        "Contributors" => "#{@source_url}/graphs/contributors"
      }
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, ci: :test]
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

  # Every extension carries its own harness now — a repo, endpoint, router and case template under
  # its `test/support` — and runs on its own with `cd __extensions/<ext> && mix test`. None of them
  # may be listed here: Mix does not compile a path dependency's `test/support`, so those modules are
  # invisible from this project and running their tests from here would only fail to compile.
  #
  # What stays in `test/` is what exists only here: the web layer, the installer, and the handful of
  # assertions that need several extensions installed at once (see
  # `MishkaCms.Activity.CrossExtensionDiscoveryTest`).
  defp test_paths, do: ["test"]

  defp deps do
    [
      # Phoenix Prod Stuff
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},

      # Ash Stuff
      {:ash_archival, "~> 2.0"},
      {:ash_events, "~> 0.8"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_authentication_phoenix, "~> 3.0.0-rc.11"},
      {:ash_authentication, "~> 5.0.0-rc.15"},
      {:jose, "~> 1.11"},
      {:ash_postgres, "~> 2.15"},
      {:ash_json_api, "~> 1.7"},
      {:ash_graphql, "~> 1.12"},
      {:ash_phoenix, "~> 2.3"},
      {:ash, "~> 3.37"},
      {:ash_paper_trail, "~> 0.8"},
      {:ash_slug, "~> 0.2"},
      {:ash_oban, "~> 0.10"},

      # Queue Stuff
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},

      # Global deps
      {:absinthe_phoenix, "~> 2.0"},
      {:sourceror, "~> 1.13", only: [:dev, :test]},
      {:open_api_spex, "~> 3.22"},
      {:mishka_installer, "~> 0.1.14"},

      # DataBase Stuff
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:decimal, "~> 3.2"},
      {:postgrex, "~> 0.22"},

      # Req/Res Stuff
      {:bandit, "~> 1.13"},
      {:swoosh, "~> 1.29"},
      {:req, "~> 0.7"},
      {:dns_cluster, "~> 0.3"},

      # Runtime Asset Stuff
      {:esbuild, "~> 0.10"},
      {:tailwind, "~> 0.5 and >= 0.5.2"},
      {:igniter_js, "~> 0.5 and >= 0.5.2"},
      {:ex_brotli, "~> 0.6"},
      {:picosat_elixir, "~> 0.2"},

      # Logger/Metrics Prod Stuff
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},

      # Dev/Test Stuff
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:file_system, "~> 1.1", only: [:test, :dev]},
      {:floki, "~> 0.38", only: :test},
      {:lazy_html, "~> 0.1", only: :test},
      {:igniter, "~> 0.8", only: :dev},
      {:usage_rules, "~> 1.2", only: [:dev]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.6", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Extra Stuff
      {:jason, "~> 1.4"},
      {:gettext, "~> 1.0"},
      {:bcrypt_elixir, "~> 3.3"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:html_sanitize_ex, "~> 1.5"},
      {:guarded_struct, "~> 0.1.4"},

      # Extensions
      mishka_dep(:mishka_cms_core, "~> 0.0.3"),
      # The visual page builder.
      mishka_dep(:mishka_cms_builder, "~> 0.0.1-alpha.2"),
      mishka_dep(:mishka_blog, "~> 0.0.1"),
      mishka_dep(:mishka_document, "~> 0.0.1"),
      mishka_dep(:mishka_gervaz, "~> 0.0.2"),

      # Sign-in providers: each registers itself with Mishka CMS through mishka_installer. Leave out
      # the ones the sites do not offer.
      mishka_dep(:mishka_cms_auth_google, "~> 0.0.1"),
      mishka_dep(:mishka_cms_auth_github, "~> 0.0.1"),
      mishka_dep(:mishka_cms_auth_slack, "~> 0.0.1"),
      mishka_dep(:mishka_cms_auth_discord, "~> 0.0.1")
    ]
  end

  # A package is the checkout under `__extensions/<name>` when there is one (`MISHKA_DEPS=hex` skips
  # them). Otherwise it is its Hex release, at the version the second argument names.
  defp mishka_dep(name, version) do
    if File.dir?(Path.expand("__extensions/#{name}", __DIR__)) and
         System.get_env("MISHKA_DEPS") != "hex" do
      {name, path: "__extensions/#{name}", override: true}
    else
      {name, version}
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      # `bun`, never npm: `assets/` is a bun project and the two do not agree. Nothing installed the
      # JS dependencies at all before this, so a fresh clone ran `assets.build` against a missing
      # `node_modules` and bundled an editor with no CodeMirror in it.
      "assets.setup": [
        "cmd --cd assets bun install --frozen-lockfile",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["tailwind mishka_cms", "esbuild mishka_cms", "admin_css"],
      "assets.deploy": [
        "tailwind mishka_cms --minify",
        "esbuild mishka_cms --minify",
        "admin_css --minify",
        "phx.digest"
      ],
      ci: [
        # First: after `compile`, Mix prunes the code path and the Hex archive's task is not found.
        "hex.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "deps.audit",
        "dialyzer",
        "ex_dna --max-clones 0",
        "test"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors"
      ],
      dev_reset: [
        &reset_generated/1,
        "ecto.create",
        "oban.install --yes",
        "ash.codegen cms_with_extensions",
        "ash.migrate"
      ]
    ]
  end

  # Everything `dev_reset` regenerates has to be gone BEFORE it runs, or `mix ash.codegen` diffs the
  # resources against the surviving snapshots and appends an incremental migration describing a
  # schema that is about to be dropped — which then fails to apply against an empty database.
  #
  # Both databases go: the dev one, and the TEST one, because a stale test schema outlives a dev
  # reset and the next `mix test` migrates on top of it.
  defp reset_generated(_args) do
    File.rm_rf!("priv/resource_snapshots")

    # `.formatter.exs` is real config, not generated, and must survive. `Path.wildcard/2` already
    # skips it (dotfiles need `match_dot: true`), but that is a default someone could quietly undo —
    # so the rejection is spelled out rather than relied upon.
    "priv/repo/migrations/*.exs"
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == ".formatter.exs"))
    |> Enum.each(&File.rm!/1)

    Mix.Task.run("ecto.drop")
    drop_test_database()
  end

  # The test repo's settings come straight from `config/test.exs` and its database is dropped from
  # here, so a fresh clone needs nothing built for the test environment. A test database that
  # cannot be dropped is reported and the reset goes on.
  defp drop_test_database do
    opts =
      "config/test.exs"
      |> Config.Reader.read!(env: :test)
      |> get_in([:mishka_cms, MishkaCms.Repo])

    case Ecto.Adapters.Postgres.storage_down(opts) do
      :ok ->
        Mix.shell().info("The database for MishkaCms.Repo (test) has been dropped")

      {:error, :already_down} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Could not drop the test database: #{inspect(reason)}")
    end
  end
end
