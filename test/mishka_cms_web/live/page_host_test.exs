# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageHostTest do
  @moduledoc """
  A site's page and its GraphQL socket on an address that writes the site's host in capital letters
  or with the root's dot, which a browser sends as it was typed.

  `async: false`: `SiteState` and the routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  require Phoenix.ChannelTest

  alias MishkaCmsCore.Runtime.{OriginValidator, SiteAvailability}
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsWeb.GraphqlSocket

  @moduletag :integration
  @moduletag skip:
               OriginValidator.host_name("A.") != "a" &&
                 "needs a core that reads a host in capital letters"

  setup do
    host = "page-host-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)
    page = create_page!(site_id: site.id, path: "/here", template: ~S|<p id="here">here</p>|)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: 0,
        active: true,
        mode: :hybrid
      })

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0
      })

    on_exit(fn ->
      SiteState.delete(site.id)
      WebRunTimeMetaDataState.delete_by_site(site.name)
    end)

    {:ok, site: site, hosts: [String.upcase(host), host <> ".", String.upcase(host) <> "."]}
  end

  defp on(conn, host) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  test "the page is drawn, and its LiveView connects", %{conn: conn, hosts: hosts} do
    for host <- hosts do
      {:ok, view, html} = conn |> on(host) |> live("/here")

      assert html =~ ~s(id="here")
      assert has_element?(view, "#here")
    end
  end

  test "another site's page is not", %{conn: conn} do
    assert conn |> on("OTHER-PAGE-HOST.test.") |> get("/here") |> response(503)
  end

  test "the GraphQL socket is the site's", %{site: site, hosts: hosts} do
    for host <- hosts do
      uri = URI.parse("http://#{host}/ws/gql/websocket")

      assert {:ok, socket} =
               Phoenix.ChannelTest.connect(GraphqlSocket, %{}, connect_info: %{uri: uri})

      assert socket.id == SiteAvailability.socket_id(site.id)
    end
  end
end
