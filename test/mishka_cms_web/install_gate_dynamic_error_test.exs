defmodule MishkaCmsWeb.InstallGateDynamicErrorTest do
  @moduledoc """
  Endpoint-level proof that a post-install `GET /install` routes through the app's dynamic error
  pipeline (`render_errors` → `MishkaCmsWeb.ErrorHTML`) rather than the old manual
  `send_resp(404, "Not found")`.

  A raised error is *sent then re-raised* by `Phoenix.Endpoint.RenderErrors`, so the request is
  driven with `assert_error_sent/2`; its success alone distinguishes the new behaviour from the
  old manual response (which sent without raising and would flunk it). The site has no compiled
  `ErrorPage`, so `ErrorHTML` renders its graceful plain fallback — the styled per-site page only
  appears once a site has one; what matters here is that `/install` reaches the same pipeline any
  unknown route does, with `current_site` resolved. `async: false` — the install flag and
  `SiteState` are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # Taking the fallback branch is the point of the test, and `ErrorHTML` logs a warning when it does.
  @moduletag :capture_log

  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.SiteState

  @host "install-gate-host.test"

  setup do
    Install.mark_installed!()

    :ok =
      SiteState.save(%{
        id: Ecto.UUID.generate(),
        name: "install-gate-site",
        host: @host,
        priority: 100,
        active: true
      })

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    :ok
  end

  test "GET /install is served through the dynamic error pipeline, not a manual 404", %{
    conn: conn
  } do
    # SiteLookupPlug reads the raw `host` header (Plug forbids `put_req_header("host", …)`, so set
    # it directly like the plug tests do); `conn.host` feeds the origin check.
    conn =
      conn
      |> Map.put(:host, @host)
      |> Map.update!(:req_headers, &[{"host", @host} | List.keydelete(&1, "host", 0)])

    {status, _headers, body} =
      assert_error_sent(404, fn -> get(conn, "/install") end)

    assert status == 404
    refute body == "Not found"
  end
end
