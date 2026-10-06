defmodule MishkaCms.ApplicationTest do
  @moduledoc """
  The order the host starts its children in.

  The endpoint answers requests the moment it starts, so the caches that say whether a site is up or
  offline have to be loaded before it: started the other way round, an offline site is open to anyone
  for the first moments after a boot.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, TranslationsState}

  # `Supervisor.which_children/1` lists the newest child first, so a child started later sits earlier
  # in the list.
  defp started_after?(later, earlier) do
    ids = MishkaCms.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    Enum.find_index(ids, &(&1 == later)) < Enum.find_index(ids, &(&1 == earlier))
  end

  test "the endpoint starts after the caches that say whether a site is up or offline" do
    for cache <- [SiteState, SettingsState, TranslationsState] do
      assert started_after?(MishkaCmsWeb.Endpoint, cache),
             "#{inspect(cache)} starts after the endpoint"
    end
  end
end
