defmodule MishkaCmsWeb.CspNonceSessionTest do
  @moduledoc """
  Every response names its own CSP nonce, and the LiveView it serves renders with exactly that one.

  The nonce used to live in the session cookie for the whole visit, so a socket rendered with
  whatever the cookie held when it connected. It is now minted per response and signed into the
  page's LiveView session by `MishkaCmsCore.Runtime.CspNonce.session/1`, which every
  `live_session` in the router names. These pin both halves for a database page and for the
  dashboard: the header, the dead render and the connected socket agree, and two loads of one visit
  never share a nonce.

  `async: false` — the install flag and `SiteState` are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)
    MishkaCmsCore.Settings.put("cms.offline", false)

    seed_auth_pages!(site)
    %{site: site}
  end

  defp visit(conn \\ fresh_conn(), path), do: get(conn, path)

  defp fresh_conn, do: Phoenix.ConnTest.build_conn() |> on_localhost() |> init_test_session(%{})

  defp on_localhost(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp header_nonce(conn) do
    # Phoenix's own `content-security-policy` (`base-uri`, `frame-ancestors`) sits beside ours, so
    # every policy header is read, enforcing or report-only, whichever this audience is in.
    policies =
      Enum.join(
        get_resp_header(conn, "content-security-policy") ++
          get_resp_header(conn, "content-security-policy-report-only"),
        " "
      )

    [_all, nonce] = Regex.run(~r/'nonce-([^']+)'/, policies)
    nonce
  end

  defp socket_nonce(conn) do
    {:ok, view, _html} = live(conn)
    :sys.get_state(view.pid).socket.assigns.csp_nonce
  end

  describe "a database page" do
    test "renders with the nonce its own response named, on the dead render and the socket" do
      conn = visit("/en/auth")
      nonce = header_nonce(conn)

      assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
      assert socket_nonce(conn) == nonce
    end

    test "two loads of one visit get two nonces, and each socket keeps its own" do
      first = visit("/en/auth")
      second = first |> recycle() |> on_localhost() |> visit("/en/auth")

      refute header_nonce(first) == header_nonce(second)
      assert socket_nonce(first) == header_nonce(first)
      assert socket_nonce(second) == header_nonce(second)
    end
  end

  describe "the dashboard" do
    setup do
      permission =
        case Permission
             |> Ash.Query.filter(name == "admin:dashboard:*")
             |> Ash.read_one!(authorize?: false) do
          nil -> create_permission!(name: "admin:dashboard:*")
          held -> held
        end

      master =
        [site_id: nil]
        |> create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      conn =
        fresh_conn()
        |> Plug.Conn.put_session(:master_mode, true)
        |> AshAuthentication.Plug.Helpers.store_in_session(master)

      %{admin: conn}
    end

    test "is handed its response's nonce through its live_session", %{admin: admin} do
      conn = visit(admin, "/admin/dashboard")

      assert socket_nonce(conn) == header_nonce(conn)
    end
  end
end
