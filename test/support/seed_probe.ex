# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Test.SeedProbe do
  @moduledoc """
  An `installer:seed` plugin under the key `"mishka_seed_probe"`, so a test can tick its parts in
  the installer without seeding a whole extension. Its `"pages"` part installs the blog through
  `MishkaCmsCore.Install.Extensions.install/4`, the way an extension's own pages part does; any
  other part writes nothing and reports the site and the part. Registered for one test with
  `MishkaCmsCore.Test.Installer.register!/3`.
  """
  use MishkaInstaller.Event.Hook, event: "installer:seed"

  alias MishkaCmsCore.Install.{Extensions, Seeds}
  alias MishkaInstaller.Event.Event

  @key "mishka_seed_probe"

  @doc """
  Stops every extension's `installer:seed` plugin for the length of the calling test, so an install
  runs the core's parts and the probe's only, and switches them back on at exit (`Event.enable/2`).
  Every extension's pages start ticked, so without it a test of the core installs every extension
  the host links. Call it from a test's `setup`. It proves nothing about an extension's own parts;
  their own tests do.
  """
  @spec extensions_off!() :: :ok
  def extensions_off! do
    stopped =
      for %{key: key, plugin: plugin} <- Extensions.offered(Seeds.event()),
          key not in [Seeds.core_key(), @key],
          do: plugin

    Enum.each(stopped, fn plugin -> {:ok, _stopped} = Event.stop(:name, plugin, false) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(stopped, fn plugin -> {:ok, _enabled} = Event.enable(plugin, false) end)
    end)
  end

  @impl true
  def call(%{key: @key, part: "pages"} = payload) do
    report =
      case Extensions.install(payload.site_id, "mishka_blog", payload.answers) do
        {:ok, report} -> report
        {:error, reason} -> %{error: reason}
      end

    {:reply, %{payload | reports: payload.reports ++ [report]}}
  end

  def call(%{key: @key, reports: reports} = payload),
    do:
      {:reply, %{payload | reports: reports ++ [%{site_id: payload.site_id, part: payload.part}]}}

  def call(payload), do: {:reply, payload}
end
