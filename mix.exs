# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.MixProject do
  use Mix.Project
  @version "0.0.1"

  def project do
    [
      app: :mishka_cms,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(),
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
      {:phoenix, "~> 1.8", override: true},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},

      # Ash Stuff
      {:ash_archival, "~> 2.0"},
      {:ash_events, "~> 0.8"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_authentication_phoenix, "~> 3.0.0-rc.11"},
      {:ash_authentication,
       github: "team-alembic/ash_authentication", branch: "main", override: true},
      {:jose, "~> 1.11", override: true},
      {:ash_postgres, "~> 2.14"},
      {:ash_json_api, "~> 1.7"},
      {:ash_graphql, "~> 1.12"},
      {:ash_phoenix, "~> 2.3"},
      {:ash, "~> 3.36"},
      {:ash_paper_trail, "~> 0.8"},
      {:ash_slug, "~> 0.2"},
      {:ash_oban, "~> 0.10"},

      # Queue Stuff
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},

      # Global deps
      {:absinthe_phoenix, "~> 2.0"},
      {:sourceror, "~> 1.12", only: [:dev, :test]},
      {:open_api_spex, "~> 3.22"},
      {:mishka_installer, "~> 0.1.14"},

      # DataBase Stuff
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:decimal, "~> 3.2", override: true},
      {:postgrex, "~> 0.22"},

      # Req/Res Stuff
      {:bandit, "~> 1.13"},
      {:swoosh, "~> 1.29"},
      {:req, "~> 0.7"},
      {:dns_cluster, "~> 0.3"},

      # Runtime Asset Stuff
      {:esbuild, "~> 0.10"},
      {:tailwind, "~> 0.5"},
      {:igniter_js, "~> 0.5"},
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
      {:igniter, "~> 0.8", only: :dev, override: true},
      {:usage_rules, "~> 1.2", only: [:dev]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},

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
      {:html_sanitize_ex, "~> 1.5", override: true},
      {:guarded_struct, "~> 0.1.4"},

      # Extentions
      mishka_dep(:mishka_cms_core),
      mishka_dep(:mishka_blog),
      mishka_dep(:mishka_document),
      mishka_dep(:mishka_gervaz)
    ]
  end

  # A CMS package is the checkout under `__extensions/<name>` when there is one, and otherwise
  # `mishka-group/<name>` on GitHub at the revision mix.lock pins, as in a Docker build.
  # `MISHKA_DEPS=github` takes GitHub even beside a checkout. To move the pins to the newest master:
  #
  #     MISHKA_DEPS=github MIX_DEPS_PATH=<an empty folder> mix deps.update mishka_cms_core mishka_blog mishka_document mishka_gervaz
  #
  # From GitHub each package is `override: true`, because they name each other as `path: "../<name>"`.
  defp mishka_dep(name) do
    case File.dir?(Path.expand("__extensions/#{name}", __DIR__)) and
           System.get_env("MISHKA_DEPS") != "github" do
      true -> {name, path: "__extensions/#{name}"}
      false -> {name, github: "mishka-group/#{name}", branch: "master", override: true}
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
