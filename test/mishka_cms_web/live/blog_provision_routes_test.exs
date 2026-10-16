# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogProvisionRoutesTest do
  @moduledoc """
  The paths `MishkaBlog.Provision` gives a site are paths the runtime can actually answer.

  The router serves this application's hand-written marketing pages first and the database's pages
  last, from one `live "/*path"` catch-all. So a provisioned page whose path a static route also
  matches is a page nobody will ever see — and nothing about creating it would fail, because the
  clash is in the router rather than in the row.

  Here rather than in the blog's own suite because only this application has the router. The static
  routes are read OFF that router rather than listed here, so a route added later is covered without
  anyone remembering this file.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Provision

  # A value for every capture the provisioned paths use, so a real URL can be asked of the router.
  @captures %{"lang" => "en", "slug" => "hello-world"}

  test "no page this extension provisions is answered by a static route" do
    catch_all = runtime_route()

    for path <- Provision.page_paths() do
      url = fill(path)
      answered_by = route_info(url).route

      assert answered_by == catch_all,
             "#{path} is served at #{url} by the #{answered_by} route rather than by the " <>
               "runtime — the page would be created and never reached"
    end
  end

  # WHICH ROUTE IS THE DATABASE'S, read off the router rather than written down, so moving the
  # catch-all does not quietly turn the assertion above into a tautology.
  defp runtime_route do
    MishkaCmsWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.find_value(fn route ->
      case route.metadata[:phoenix_live_view] do
        {MishkaCmsWeb.RuntimeLive, _action, _opts, _live_session} -> route.path
        _another_page -> nil
      end
    end)
    |> case do
      nil -> flunk("the router has no RuntimeLive route, so nothing serves database pages")
      path -> path
    end
  end

  defp fill(path) do
    Regex.replace(~r/:(\w+)/, path, fn _whole, name ->
      Map.get(@captures, name) ||
        flunk("no sample value for :#{name} in #{path} — add one to @captures")
    end)
  end

  defp route_info(url),
    do: Phoenix.Router.route_info(MishkaCmsWeb.Router, "GET", url, "localhost")
end
