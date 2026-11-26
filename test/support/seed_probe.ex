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

  alias MishkaCmsCore.Install.Extensions

  @impl true
  def call(%{key: "mishka_seed_probe", part: "pages"} = payload) do
    report =
      case Extensions.install(payload.site_id, "mishka_blog", payload.answers) do
        {:ok, report} -> report
        {:error, reason} -> %{error: reason}
      end

    {:reply, %{payload | reports: payload.reports ++ [report]}}
  end

  def call(%{key: "mishka_seed_probe", reports: reports} = payload),
    do:
      {:reply, %{payload | reports: reports ++ [%{site_id: payload.site_id, part: payload.part}]}}

  def call(payload), do: {:reply, payload}
end
