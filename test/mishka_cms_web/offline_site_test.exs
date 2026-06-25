defmodule MishkaCmsWeb.OfflineSiteTest do
  @moduledoc """
  What an offline site answers, through the whole browser pipeline, to someone who is not its admin.

  Every address gets the maintenance page — the front page too, before any language redirect — except
  the few an admin needs to get back in: signing in, and the dashboard, which sends a signed-out admin
  to sign in. Those are whole path segments, so a page whose address merely starts the same way is
  closed like any other. The maintenance page itself offers the site's own sign-in first.

  The page is the site's own when its Error Page holds an `:offline` entry, and the built-in one
  otherwise — a site with no Error Page, one without the entry, or one that does not compile.

  `async: false` — the install flag, `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage}
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, Helpers}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.{AssetsState, CompileFailureState, SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Settings

  setup %{conn: conn} do
    Install.mark_installed!()
    host = "offline-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true
      })

    {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

    on_exit(fn ->
      SettingsState.delete(site.id, "cms.offline")
      :persistent_term.erase(:mishka_installed)
      SiteState.delete(site.id)
    end)

    conn =
      conn
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  # A published address in the routing table, as a saved page leaves one.
  defp published!(site, path) do
    id = Ecto.UUID.generate()

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: id,
        site: site.name,
        path: path,
        title: path,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0
      })

    on_exit(fn -> WebRunTimeMetaDataState.delete(id) end)
  end

  # The site's Error Page with these entries, in the routing table as a saved one leaves it.
  defp error_page!(site, entries, attrs \\ %{}) do
    error_page =
      ErrorPage
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            name: "#{site.name} errors",
            path: ErrorAddress.path(site.name),
            error_pages: entries
          },
          attrs
        ),
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: error_page.id,
        site: site.name,
        path: error_page.path,
        title: error_page.name,
        created_at: DateTime.utc_now(),
        section: "ErrorPage",
        priority: 0
      })

    on_exit(fn -> WebRunTimeMetaDataState.delete(error_page.id) end)
    error_page
  end

  defp entry(status, template), do: %{status: status, template: template}

  # A site owner's plugin that answers an offline site with a page of its own.
  defmodule OwnersPage do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "web:request:site_unavailable"

    @impl true
    def call(conn, meta) do
      if meta[:state] == :offline,
        do:
          {:reply, conn |> Plug.Conn.send_resp(503, "The owner's own page") |> Plug.Conn.halt()},
        else: {:reply, conn}
    end
  end

  # Says which page the gate drew, in place of drawing it.
  defmodule PageWatcher do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "web:request:offline_page"

    @impl true
    def call(conn, meta) do
      body = "#{meta[:source]} #{inspect(meta[:reason])} #{meta[:site] && meta[:site].name}"
      {:reply, conn |> Plug.Conn.send_resp(503, body) |> Plug.Conn.halt()}
    end
  end

  # Says which Error Page's offline entry raised as it was drawn, to the process that compiled it.
  defmodule DrawWatcher do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:compile:offline_page_failed"

    @impl true
    def call(data, _meta) do
      send(self(), {:offline_page_failed, data.site, data.reason})
      {:reply, data}
    end
  end

  defp maintenance?(conn), do: conn.status == 503 and conn.resp_body =~ "Down for Maintenance"

  defp register!(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  # With `/en` published, `LanguagePlug` sends `/` there; an offline site answers before it does.
  test "the front page is the maintenance page, not a redirect to a language first", %{
    conn: conn,
    site: site
  } do
    published!(site, "/en")

    assert conn |> get("/") |> maintenance?()
  end

  test "an address that only starts like a sign-in or asset route is closed", %{conn: conn} do
    for path <- ["/authors", "/authentic", "/installation-guide", "/assets-list", "/admin"] do
      assert conn |> get(path) |> maintenance?(), "#{path} was not closed"
    end
  end

  test "the dashboard sends a signed-out admin to sign in", %{conn: conn} do
    conn = get(conn, "/admin/dashboard")

    assert conn.status == 302
    assert redirected_to(conn) =~ "/auth"
  end

  # A MASTER SIGNS IN ON THE MASTER SITE'S OWN ADDRESS AND NOWHERE ELSE, so any other site's page
  # offers only its own sign-in, and neither links to the master site nor names it.
  test "the maintenance page offers the site's own sign-in and no master sign-in", %{conn: conn} do
    n = System.unique_integer([:positive])

    master =
      create_site!(name: "master-#{n}", host: "master-#{n}.test", active: true, master: true)

    body = conn |> get("/") |> Map.fetch!(:resp_body)

    assert body =~ "/auth?master_user=false"
    refute body =~ "master_user=true"
    refute body =~ "Master sign in"
    refute body =~ master.host
  end

  test "the master site's own maintenance page offers its sign-in first, and a master's" do
    n = System.unique_integer([:positive])
    host = "master-#{n}.test"
    master = create_site!(name: host, host: host, active: true, master: true)

    :ok =
      SiteState.save(%{
        id: master.id,
        name: master.name,
        host: master.host,
        priority: master.priority,
        active: true,
        master: true
      })

    {:ok, _} = Settings.put("cms.offline", true, site_id: master.id)

    on_exit(fn ->
      SettingsState.delete(master.id, "cms.offline")
      SiteState.delete(master.id)
    end)

    body =
      build_conn()
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
      |> get("/")
      |> Map.fetch!(:resp_body)

    site_sign_in = :binary.match(body, "/auth?master_user=false")
    master_sign_in = :binary.match(body, "/auth?master_user=true")

    assert site_sign_in != :nomatch
    assert master_sign_in != :nomatch
    assert elem(site_sign_in, 0) < elem(master_sign_in, 0)
  end

  test "a plugin on web:request:site_unavailable may answer with a page of its own", %{conn: conn} do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: OwnersPage,
        event: "web:request:site_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile("web:request:site_unavailable", :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, OwnersPage, false) end)

    conn = get(conn, "/")

    assert conn.status == 503
    assert conn.resp_body == "The owner's own page"
  end

  describe "the page" do
    test "is the offline entry of the site's own Error Page, a 503 at the address asked for", %{
      conn: conn,
      site: site
    } do
      error_page!(site, [
        entry(404, "<p>Not here</p>"),
        entry(:offline, ~S|<p id="own-offline">Back at {@status}, answered {@conn.status}</p>|)
      ])

      conn = get(conn, "/blog/some-post?page=2")

      assert conn.status == 503
      assert conn.request_path == "/blog/some-post"
      assert conn.resp_body =~ ~s(<p id="own-offline">Back at offline, answered 503</p>)
      refute conn.resp_body =~ "Down for Maintenance"
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    end

    test "is never cached and asks to be tried again later", %{conn: conn, site: site} do
      error_page!(site, [entry(:offline, "<p>Soon</p>")])

      conn = get(conn, "/")

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "retry-after") == ["300"]
    end

    test "the built-in one is never cached either", %{conn: conn} do
      conn = get(conn, "/")

      assert maintenance?(conn)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "retry-after") == ["300"]
    end

    test "is the built-in one when the Error Page holds no offline entry", %{
      conn: conn,
      site: site
    } do
      error_page!(site, [entry(404, "<p>Not here</p>"), entry(500, "<p>Broke</p>")])

      assert conn |> get("/") |> maintenance?()
    end

    test "is the built-in one when the Error Page does not compile", %{conn: conn, site: site} do
      error_page = error_page!(site, [entry(:offline, "<p id=\"own-offline\">Soon</p>")])
      module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
      CompileFailureState.record(module, "a broken helper")
      on_exit(fn -> CompileFailureState.clear(module) end)

      conn = get(conn, "/")

      assert maintenance?(conn)
      refute conn.resp_body =~ "own-offline"
    end

    test "the built-in one reads the site's own maintenance message", %{conn: conn, site: site} do
      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)
      {:ok, _} = Settings.put("cms.maintenance_message", "Global words", site_id: nil)
      {:ok, _} = Settings.put("cms.maintenance_message", "Back on Monday", site_id: site.id)

      body = conn |> get("/") |> Map.fetch!(:resp_body)

      assert body =~ "Back on Monday"
      refute body =~ "Global words"
    end

    test "a plugin on web:request:offline_page hears the site's own page was drawn", %{
      conn: conn,
      site: site
    } do
      error_page!(site, [entry(:offline, "<p>Soon</p>")])
      register!(PageWatcher, "web:request:offline_page")

      conn = get(conn, "/")

      assert conn.status == 503
      assert conn.resp_body == "error_page nil #{site.name}"
    end

    test "and hears why the built-in one was drawn instead", %{conn: conn, site: site} do
      register!(PageWatcher, "web:request:offline_page")

      assert conn |> get("/") |> Map.fetch!(:resp_body) == "built_in :no_error_page #{site.name}"

      error_page!(site, [entry(404, "<p>Not here</p>")])

      assert conn |> get("/") |> Map.fetch!(:resp_body) ==
               "built_in :no_offline_entry #{site.name}"
    end

    # The site's own page links the site's stylesheet, and a visitor is the one who reads it.
    test "reaches a visitor with the stylesheet it links", %{conn: conn, site: site} do
      :ok =
        AssetsState.save(%{
          id: site.name,
          type: "css",
          value: "/* #{site.name} css */",
          hash: "offline#{System.unique_integer([:positive])}",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn -> AssetsState.delete_by_site(site.name) end)

      error_page!(site, [entry(:offline, ~s(<p id="own-offline">Soon</p>))], %{
        root_layout_template: StarterContent.error_root_layout()
      })

      page = get(conn, "/")
      assert page.status == 503
      assert page.resp_body =~ "own-offline"

      [href] =
        Regex.run(~r|<link rel="stylesheet" href="(/assets/css/[^"]+)"|, page.resp_body,
          capture: :all_but_first
        )

      stylesheet = get(conn, href)

      assert stylesheet.status == 200
      assert stylesheet.resp_body == "/* #{site.name} css */"
    end

    # A root layout shared with the 404 and the 500 can raise on `@status` being `:offline`, and the
    # gate draws the page inside a plug, where a raise is a bare 500.
    test "is the built-in one when the offline entry raises as it is drawn, and the 404 still works",
         %{conn: conn, site: site} do
      register!(DrawWatcher, "runtime:compile:offline_page_failed")

      layout =
        ~S|<html><title><%= Plug.Conn.Status.reason_phrase(@status) %></title><body><%= @inner_content %></body></html>|

      error_page =
        error_page!(
          site,
          [
            entry(404, ~s(<p id="own-404">Not here</p>)),
            entry(:offline, ~s(<p id="own-offline">Soon</p>))
          ],
          %{root_layout_template: layout}
        )

      module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
      on_exit(fn -> CompileFailureState.clear({module, :offline}) end)

      conn = get(conn, "/")

      assert maintenance?(conn)
      refute conn.resp_body =~ "own-offline"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "retry-after") == ["300"]
      assert_received {:offline_page_failed, site_name, reason} when is_binary(reason)
      assert site_name == site.name

      not_found =
        %Plug.Conn{assigns: %{current_site: site, current_user: nil}}
        |> then(&ErrorCompiler.render_page(module, &1, 404))
        |> IO.iodata_to_binary()

      assert not_found =~ ~s(<p id="own-404">Not here</p>)
      assert not_found =~ "<title>Not Found</title>"
    end

    test "is the site's own again once the layout that raised is fixed and recompiled", %{
      conn: conn,
      site: site
    } do
      error_page =
        error_page!(site, [entry(:offline, ~s(<p id="own-offline">Soon</p>))], %{
          root_layout_template: ~S|<p><%= Integer.to_string(@status) %></p><%= @inner_content %>|
        })

      module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
      on_exit(fn -> CompileFailureState.clear({module, :offline}) end)

      assert conn |> get("/") |> maintenance?()

      error_page
      |> Ash.Changeset.for_update(
        :update,
        %{root_layout_template: ~S|<p><%= @status %></p><%= @inner_content %>|},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      {:ok, _} =
        ModuleCompilerHandler.compile_or_return_module(
          module,
          error_page.path,
          site.name,
          site.id,
          :update
        )

      assert conn |> get("/") |> Map.fetch!(:resp_body) =~ ~s(<p id="own-offline">Soon</p>)
    end

    test "and a plugin on web:request:offline_page hears the entry did not draw", %{
      conn: conn,
      site: site
    } do
      register!(PageWatcher, "web:request:offline_page")

      error_page =
        error_page!(site, [entry(:offline, "<p>Soon</p>")], %{
          root_layout_template: ~S|<p><%= Integer.to_string(@status) %></p><%= @inner_content %>|
        })

      module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
      on_exit(fn -> CompileFailureState.clear({module, :offline}) end)

      body = conn |> get("/") |> Map.fetch!(:resp_body)

      assert String.starts_with?(body, ~s(built_in {:render, "))
      assert String.ends_with?(body, "} #{site.name}")
    end
  end
end
