# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.ApplicationTest do
  @moduledoc """
  The order the host starts its children in.

  The endpoint answers requests the moment it starts, so the caches that say whether a site is up or
  offline have to be loaded before it: started the other way round, an offline site is open to anyone
  for the first moments after a boot.

  The core's runtime processes come from `MishkaCmsCore.Supervision`, in its phases; what the core's
  and the builder's own applications start (`MishkaCmsCore.PubSub`, the editor's processes) is not
  started a second time here, which would stop the boot.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, TranslationsState}
  alias MishkaCmsCore.Supervision

  # `Supervisor.which_children/1` lists the newest child first, so a child started later sits earlier
  # in the list.
  defp started_after?(later, earlier) do
    ids = ids()
    Enum.find_index(ids, &(&1 == later)) < Enum.find_index(ids, &(&1 == earlier))
  end

  defp ids, do: MishkaCms.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

  defp id_of(child), do: Supervisor.child_spec(child, []).id

  test "the endpoint starts after the caches that say whether a site is up or offline" do
    for cache <- [SiteState, SettingsState, TranslationsState] do
      assert started_after?(MishkaCmsWeb.Endpoint, cache),
             "#{inspect(cache)} starts after the endpoint"
    end
  end

  test "the core's caches start before the endpoint and its engine after it" do
    for cache <- Supervision.children(:caches) do
      assert started_after?(MishkaCmsWeb.Endpoint, id_of(cache)),
             "#{inspect(id_of(cache))} starts after the endpoint"
    end

    for engine <- Supervision.children(:engine) do
      assert started_after?(id_of(engine), MishkaCmsWeb.Endpoint),
             "#{inspect(id_of(engine))} starts before the endpoint"
    end
  end

  test "the PubSub and the editor's processes are their own applications' children, not the host's" do
    ids = ids()

    for child <- [
          Phoenix.PubSub,
          MishkaCmsCore.PubSub,
          MishkaCmsBuilder.States.EditorSessionState,
          MishkaCmsBuilder.States.EditorHistoryState,
          MishkaCmsBuilder.States.CardPreviewState,
          MishkaCmsBuilder.Presence
        ] do
      refute child in ids, "the host starts #{inspect(child)} itself"
    end

    assert is_pid(Process.whereis(MishkaCmsCore.PubSub))
    assert is_pid(Process.whereis(MishkaCmsBuilder.Presence))
  end
end
