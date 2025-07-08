defmodule MishkaCms.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MishkaCmsWeb.Telemetry,
      MishkaCms.Repo,
      {DNSCluster, query: Application.get_env(:mishka_cms, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:mishka_cms, :ash_domains),
         Application.fetch_env!(:mishka_cms, Oban)
       )},
      {Phoenix.PubSub, name: MishkaCms.PubSub},
      MishkaCmsWeb.Endpoint
    ]

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
