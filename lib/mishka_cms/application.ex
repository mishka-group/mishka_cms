# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # A malformed TRUSTED_PROXY_RANGES entry stops the boot, named, rather than failing every request
    # in the endpoint's `plug RemoteIp`
    :ok = MishkaCmsCore.Accounts.AuthRateLimit.validate_trusted_proxies!()

    # Start the partition counter for module compilation that we need to use in worker
    counter_ref = :atomics.new(1, signed: false)
    :persistent_term.put(:module_compiler_partition_counter, counter_ref)

    # Force loading ErrorHandler before it's needed, to prevent some race conditions and bad behavior
    {:module, _} =
      Code.ensure_loaded(MishkaCmsCore.Runtime.Compilers.UndefinedModuleError)

    children = [
      MishkaCmsWeb.Telemetry,
      MishkaCms.Repo,
      {DNSCluster, query: Application.get_env(:mishka_cms, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:mishka_cms, :ash_domains),
         Application.fetch_env!(:mishka_cms, Oban)
       )},
      # Start ETS for sites - MUST be before BootHandler
      {Phoenix.PubSub, name: MishkaCmsCore.PubSub},
      MishkaCmsCore.Runtime.States.SiteState,
      # ETS cache for global CMS settings (read everywhere, refreshed on change)
      MishkaCmsCore.Runtime.States.SettingsState,
      # ETS cache for the words runtime templates ask for with t/1 — see MishkaCmsCore.Runtime.Translations
      MishkaCmsCore.Runtime.States.TranslationsState,
      # Each site's redirect rules, read on every request — see MishkaCmsCore.Runtime.Redirects
      MishkaCmsCore.Runtime.States.RedirectsState,
      # Who a signed-in user is to the site gates, by id — see MishkaCmsCore.Runtime.States.ViewerState
      MishkaCmsCore.Runtime.States.ViewerState,
      # Hammer's ETS counters signing in and the reset and sign-in link requests are limited by,
      # before anything is served — see MishkaCmsCore.Accounts.AuthRateLimit
      MishkaCmsCore.Runtime.States.RateLimitState,
      # Serves only once the caches that say whether a site is up or offline are loaded, so an offline
      # site is never open at boot. A site still loading is not found yet, which refuses rather than opens.
      MishkaCmsWeb.Endpoint,
      # Start ETS for routing and finding page module, also is used for pagination
      MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState,
      {Absinthe.Subscription, MishkaCmsWeb.Endpoint},
      MishkaCmsCore.Runtime.States.AssetsState,
      MishkaCmsCore.Runtime.States.CompileFailureState,
      # Rendered palette-card previews. Keyed on the template a card would drop, because a
      # component's first render is a module compile and every later one is two milliseconds.
      MishkaCmsCore.Runtime.States.CardPreviewState,
      # Live page-builder editing sessions, shared by the editor chrome and its canvas iframe
      MishkaCmsCore.Runtime.States.EditorSessionState,
      # The undo history's documents, beside the session rather than in it — ETS flattens what it
      # stores, so fifty snapshots that share their nodes in memory would be copied fifty times over
      # on every read of the session. Started after it: its sweep reads that table's live tokens.
      MishkaCmsCore.Runtime.States.EditorHistoryState,
      # Co-editing avatars for the page builder, on the editing session's own PubSub topic
      MishkaCmsCore.Runtime.PageBuilder.Presence,
      MishkaCmsCore.Runtime.Handlers.CompileGate,
      AshGraphql.Subscription.Batcher,
      {Registry, keys: :unique, name: MishkaCms.ModuleCompilerHandlerRegistry},
      {PartitionSupervisor,
       child_spec: DynamicSupervisor,
       name: MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerPartition,
       partitions: System.schedulers_online()},
      # Unlinked tasks for BootHandler's per-site passes, so one site that raises is reported rather
      # than taking BootHandler down with it, and for the sitemap jobs a rebuilt `seo:sitemap:urls`
      # chain enqueues — MUST be before BootHandler
      {Task.Supervisor, name: MishkaCmsCore.Runtime.TaskSupervisor},
      {AshAuthentication.Supervisor, [otp_app: :mishka_cms]}
    ]

    # Only add BootHandler in non-test environments
    children =
      if Application.get_env(:mishka_cms_core, :env_test?, false) do
        children
      else
        children ++ [MishkaCmsCore.Runtime.Handlers.BootHandler]
      end

    opts = [strategy: :one_for_one, name: MishkaCms.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MishkaCmsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
