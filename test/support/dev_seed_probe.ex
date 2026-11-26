# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Test.DevSeedProbe do
  @moduledoc """
  A `dev:seed` plugin under the key `"mishka_seed_probe"` that writes nothing: it appends the site it
  was fired for to `reports`, the way an extension's seed answers, so a test can tick it in the
  installer's dev step and see it run without seeding a whole extension. Registered for one test with
  `MishkaCmsCore.Test.Installer.register!/3`.
  """
  use MishkaInstaller.Event.Hook, event: "dev:seed"

  @impl true
  def call(%{key: "mishka_seed_probe", reports: reports} = payload),
    do: {:reply, %{payload | reports: reports ++ [%{site_id: payload.site_id}]}}

  def call(payload), do: {:reply, payload}
end
