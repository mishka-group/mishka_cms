# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Application do
  @moduledoc false
  use Application

  alias MishkaCmsCore.Supervision

  # What this tree does not start, because the dependencies' applications start it before this one:
  # `:mishka_cms_core` starts `MishkaCmsCore.PubSub`, the runtime compiler's partition counter and the
  # core's plugins, and `:mishka_cms_builder` starts the visual editor's sessions, history, card
  # previews, Presence and plugins. What is left of the core needs this app's repo or endpoint, so it
  # is started here, in the phases `MishkaCmsCore.Supervision` names.
  @impl true
  def start(_type, _args) do
    # A malformed TRUSTED_PROXY_RANGES entry stops the boot, named, rather than failing every request
    # in the endpoint's `plug RemoteIp`
    :ok = MishkaCmsCore.Accounts.AuthRateLimit.validate_trusted_proxies!()

    # Force loading ErrorHandler before it's needed, to prevent some race conditions and bad behavior
    {:module, _} =
      Code.ensure_loaded(MishkaCmsCore.Runtime.Compilers.UndefinedModuleError)

    # In start order; the comments say why each of the core's phases sits where it does.
    children =
      Enum.concat([
        [
          MishkaCmsWeb.Telemetry,
          MishkaCms.Repo,
          {DNSCluster, query: Application.get_env(:mishka_cms, :dns_cluster_query) || :ignore},
          {Oban,
           AshOban.config(
             Application.fetch_env!(:mishka_cms, :ash_domains),
             Application.fetch_env!(:mishka_cms, Oban)
           )}
        ],
        # The ETS caches a request reads first (sites, settings, translations, redirects, signed-in
        # viewers, sign-in rate limits), loaded from the repo above.
        Supervision.children(:caches),
        # Serves only once the caches that say whether a site is up or offline are loaded, so an
        # offline site is never open at boot. A site still loading is not found yet, which refuses
        # rather than opens.
        [MishkaCmsWeb.Endpoint],
        # Routing and page metadata, the compiled assets, the compile failures and the runtime
        # compiler, with the task supervisor BootHandler's per-site passes run under.
        Supervision.children(:engine),
        [
          {Absinthe.Subscription, MishkaCmsWeb.Endpoint},
          AshGraphql.Subscription.Batcher,
          {AshAuthentication.Supervisor, [otp_app: :mishka_cms]}
        ],
        # BootHandler, last: it compiles every site, so it needs everything above. Its unlinked
        # per-site tasks (one site that raises is reported rather than taking BootHandler down) and
        # the sitemap jobs a rebuilt `seo:sitemap:urls` chain enqueues run under the task supervisor
        # `:engine` started. None in a test run, where each test builds what it needs.
        Supervision.children(:boot)
      ])

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
