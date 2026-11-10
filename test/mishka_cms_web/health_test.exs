# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.HealthTest do
  @moduledoc """
  `GET /_health` through the whole endpoint: answered by `MishkaCmsCore.Runtime.Plugs.HealthPlug`
  for any host, before the site lookup that answers an unknown host with its own 503 page, and
  without a session cookie.

  `async: false` — the boot status the probe reads is the node's.
  """
  use MishkaCmsWeb.ConnCase, async: false

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.SiteState

  setup do
    on_exit(fn -> BootHandler.put_status(:initializing) end)
    :ok
  end

  defp probe(host), do: %{build_conn() | host: host} |> get("/_health")

  test "answers the boot's state, not the site page, on a host no site has" do
    :ok = BootHandler.put_status(:initializing)

    for host <- ["localhost", "no-site.example.com"] do
      conn = probe(host)

      assert conn.status == 503
      assert conn.resp_body == "booting"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  test "200 ok once the boot is done and every active site's bundles are built" do
    SiteState.clear()
    :ok = BootHandler.put_status(:ready)

    conn = probe("localhost")

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end
