# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RedirectNavigationTest do
  @moduledoc """
  A site's redirect rule answers a live navigation as well as a request. `SiteLookupPlug` serves the
  rules on every request; a click from one page to another only patches `RuntimeLive`, so
  `handle_params/3` asks the same rule before the address picks a page.

  `async: false` — `SiteState`, the routing table, the redirect rules and the install flag are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  @moduletag :integration

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

    %{conn: on_site(), site: site, page: published!(site, ~S|<p data-role="here">here</p>|)}
  end

  defp published!(site, template) do
    path = "/redirect-#{System.unique_integer([:positive])}"
    page = create_page!(site_id: site.id, path: path, template: template)

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

    page
  end

  defp rule!(site, attrs) do
    Redirect
    |> Ash.Changeset.for_create(:master_create, Map.put(attrs, :site_id, site.id),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  test "a click to a moved address is sent where the rule says", %{
    conn: conn,
    site: site,
    page: page
  } do
    rule!(site, %{from_path: "/old-address", to: page.path})

    {:ok, view, _html} = live(conn, page.path)

    assert {:error, {:redirect, %{to: to}}} = render_patch(view, "/old-address?ref=menu")
    assert to == page.path <> "?ref=menu"
  end

  test "a navigate to a moved address, which remounts, is sent where the rule says", %{
    conn: conn,
    site: site,
    page: page
  } do
    rule!(site, %{from_path: "/old-address", to: page.path})

    {:ok, view, _html} = live(conn, page.path)

    assert {:error, {:redirect, %{to: to}}} = live_redirect(view, to: "/old-address?ref=menu")
    assert to == page.path <> "?ref=menu"
  end

  test "a rule leaving the site leaves it", %{conn: conn, site: site, page: page} do
    rule!(site, %{from_path: "/elsewhere", to: "https://example.com/new"})

    {:ok, view, _html} = live(conn, page.path)

    assert {:error, {:redirect, %{to: "https://example.com/new"}}} =
             render_patch(view, "/elsewhere")
  end

  test "an address no rule names is the page it always was", %{conn: conn, site: site, page: page} do
    rule!(site, %{from_path: "/old-address", to: "/nowhere"})

    {:ok, view, _html} = live(conn, page.path)

    assert render_patch(view, page.path <> "?again=1") =~ "here"
  end

  describe "a rewrite" do
    test "answers the target's page at the address asked for, on the first load and the connect",
         %{conn: conn, site: site, page: page} do
      rule!(site, %{kind: :rewrite, from_path: "/", from_query: "p=55", to: page.path})
      rule!(site, %{kind: :rewrite, from_path: "/alias", to: page.path})

      html = conn |> get("/alias") |> html_response(200)
      assert html =~ ~s(data-role="here")

      {:ok, view, _html} = live(on_site(), "/?p=55")
      assert has_element?(view, ~s([data-role="here"]))
    end

    test "a live navigation to a rewritten address keeps it and shows the target", %{
      conn: conn,
      site: site,
      page: page
    } do
      other = published!(site, ~S|<p data-role="there">there</p>|)
      rule!(site, %{kind: :rewrite, from_path: "/alias", to: other.path})

      {:ok, view, _html} = live(conn, page.path)

      assert render_patch(view, "/alias") =~ ~s(data-role="there")
    end

    @tag :capture_log
    test "two rules rewriting each other serve each other's page, once", %{
      conn: conn,
      site: site,
      page: page
    } do
      rule!(site, %{kind: :rewrite, from_path: "/a", to: "/b"})
      rule!(site, %{kind: :rewrite, from_path: "/b", to: "/a"})
      rule!(site, %{kind: :rewrite, from_path: "/c", to: page.path})

      assert_error_sent(404, fn -> get(conn, "/a") end)
      assert on_site() |> get("/c") |> html_response(200) =~ ~s(data-role="here")
    end
  end

  describe "a rule that answers 410 or 404" do
    @tag :capture_log
    test "answers the site's error page with that status", %{conn: conn, site: site} do
      rule!(site, %{kind: :gone, from_path: "/retired"})
      rule!(site, %{kind: :not_found, from_path: "/never"})

      assert_error_sent(410, fn -> get(conn, "/retired") end)
      assert_error_sent(404, fn -> get(on_site(), "/never") end)
    end

    @tag :capture_log
    test "a live navigation to it is refused with that status", %{
      conn: conn,
      site: site,
      page: page
    } do
      rule!(site, %{kind: :gone, from_path: "/retired"})

      {:ok, view, _html} = live(conn, page.path)
      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)

      catch_exit(render_patch(view, "/retired"))

      assert_receive {:DOWN, ^ref, :process, _pid,
                      {%MishkaCmsCore.ErrorsExceptions.NotFoundError{plug_status: 410}, _stack}}
    end
  end
end
