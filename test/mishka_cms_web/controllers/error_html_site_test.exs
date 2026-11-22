# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ErrorHTMLSiteTest do
  @moduledoc """
  Which site's Error Page answers a failed request, through the endpoint: an error raised before the
  browser pipeline named the site (a bad CSRF token, a POST no route matches, a request the parsers
  refuse) and one raised after it, for an open site, one closed to its visitors, and no site at all.
  What cannot be drawn is the status's plain text, with the status it had.

  `async: false`: `SiteState`, the settings cache and the installer's events are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Settings
  alias MishkaCmsWeb.ErrorHTML
  alias MishkaInstaller.Event.{Event, EventHandler}

  @sign_in "/api/auth/user/password/sign_in"
  @raises ~S|<p>{raise "cannot draw"}</p>|

  # Each tells the process that draws the page what it was handed, then answers what that process
  # asked for, or what it was handed.
  for name <- ["BeforeRender", "BeforeCompile", "AfterCompile", "CompileError"] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "ErrorHTML.Render.#{name}"

      @impl true
      def call(data, _meta) do
        send(self(), {unquote(name), data})
        {:reply, Process.get({:answer, unquote(name)}, & &1).(data)}
      end
    end
  end

  setup %{conn: conn} do
    host = "error-html-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)
    cache!(site)

    on_exit(fn ->
      SiteState.delete(site.id)
      WebRunTimeMetaDataState.delete_by_site(site.name)
    end)

    {:ok, conn: on(conn, host), site: site}
  end

  defp cache!(site, attrs \\ %{}) do
    :ok =
      SiteState.save(
        Map.merge(
          %{
            id: site.id,
            name: site.name,
            host: site.host,
            priority: 0,
            active: true,
            mode: :hybrid
          },
          attrs
        )
      )
  end

  # The plug that finds the site reads the `Host` header, which `put_req_header/3` refuses to set.
  defp on(conn, host) do
    conn
    |> Map.put(:host, host)
    |> host_header(host)
  end

  defp host_header(conn, host),
    do: Map.update!(conn, :req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])

  defp no_host_header(conn), do: Map.update!(conn, :req_headers, &List.keydelete(&1, "host", 0))

  # The site's Error Page with these entries, in the routing table as a saved one leaves it.
  defp error_page!(site, entries, attrs \\ %{}) do
    entries =
      Enum.map(entries, fn {status, template} -> %{status: status, template: template} end)

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

    routed!(site, error_page.id, error_page.path, "ErrorPage")
    error_page
  end

  defp routed!(site, id, path, section) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: id,
        site: site.name,
        path: path,
        title: path,
        created_at: DateTime.utc_now(),
        section: section,
        priority: 0
      })
  end

  # A template its own save may refuse, as a row stored before the rule holds it.
  defp store!(error_page, status, template),
    do: Ash.Seed.update!(error_page, %{error_pages: [%{status: status, template: template}]})

  defp module(error_page, site), do: Helpers.module_name(error_page.id, site.name, "ErrorPage")

  # Before the pipeline has named the site.
  defp no_route(conn), do: conn |> post("/no-such-page", %{}) |> response(404)

  defp bad_csrf(conn) do
    {403, _headers, body} =
      assert_error_sent(403, fn ->
        conn
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(@sign_in, %{"_csrf_token" => "wrong"})
      end)

    body
  end

  # After it.
  defp no_page(conn) do
    {404, _headers, body} = assert_error_sent(404, fn -> get(conn, "/no-such-page") end)
    body
  end

  # The log's lines about an error page: another process may log while a request is answered.
  defp warnings(log) do
    for line <- String.split(log, "\n"), line =~ "[warning]" and line =~ "error page", do: line
  end

  # The conn an error raised before the pipeline hands to the view.
  defp bare(host), do: build_conn() |> on(host) |> put_private(:phoenix_endpoint, @endpoint)

  defp drawn(content), do: content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp plugin!(name, answer \\ & &1) do
    module = Module.concat(__MODULE__, name)
    event = "ErrorHTML.Render.#{name}"
    Process.put({:answer, name}, answer)

    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
  end

  describe "an open site" do
    test "answers with its own page before the pipeline and after it", %{conn: conn, site: site} do
      error_page!(site, [{403, "<p>own 403</p>"}, {404, "<p>own 404</p>"}])

      assert no_route(conn) =~ "own 404"
      assert bad_csrf(conn) =~ "own 403"
      assert no_page(conn) =~ "own 404"
    end

    test "answers a request the endpoint refuses before the router", %{conn: conn, site: site} do
      error_page!(site, [
        {400, "<p>own 400</p>"},
        {406, "<p>own 406</p>"},
        {413, "<p>own 413</p>"}
      ])

      {400, _headers, body} = assert_error_sent(400, fn -> get(conn, "/?a=%ff") end)
      assert body =~ "own 400"

      {406, _headers, body} =
        assert_error_sent(406, fn ->
          conn |> put_req_header("accept", "application/xml") |> get("/")
        end)

      assert body =~ "own 406"

      {413, _headers, body} =
        assert_error_sent(413, fn ->
          conn
          |> put_req_header("content-type", "application/x-www-form-urlencoded")
          |> post("/no-such-page", "a=" <> String.duplicate("a", 9_000_000))
        end)

      assert body =~ "own 413"
    end

    test "speaks its first language before the pipeline", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("site.languages", ["de", "en"], site_id: site.id)
      on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)
      error_page!(site, [{404, "<p>in {Gettext.get_locale(MishkaCmsCore.Gettext)}</p>"}])

      assert no_route(conn) =~ "in de"
    end

    test "with no Error Page answers the plain text and one warning", %{conn: conn, site: site} do
      {body, log} = with_log(fn -> no_route(conn) end)

      assert body == "Not Found"
      assert [_warning] = warnings(log)
      assert log =~ "site #{site.name} has no error page for 404.html"
    end

    test "with no Error Page is not answered by its catch-all Page", %{conn: conn, site: site} do
      routed!(site, Ecto.UUID.generate(), "/*path", "Page")
      {body, log} = with_log(fn -> no_route(conn) end)

      assert body == "Not Found"
      assert [_warning] = warnings(log)
      assert log =~ "has no error page for 404.html"
    end

    test "whose page has no entry for the status answers its plain text and one warning", %{
      conn: conn,
      site: site
    } do
      error_page!(site, [{404, "<p>own 404</p>"}])
      {body, log} = with_log(fn -> bad_csrf(conn) end)

      assert body == "Forbidden"
      assert [_warning] = warnings(log)

      assert ErrorHTML.render("451.html", %{conn: bare(site.host)}) ==
               "Unavailable For Legal Reasons"

      assert ErrorHTML.render("999.html", %{conn: bare(site.host)}) == "Internal Server Error"
    end
  end

  describe "the site is the one SiteLookupPlug finds" do
    setup %{site: site} do
      error_page!(site, [{404, "<p>own 404</p>"}])
      :ok
    end

    test "by the Host header, whatever host the request target names", %{conn: conn, site: site} do
      assert conn |> post("http://elsewhere.test/no-such-page", %{}) |> response(404) =~ "own 404"
      assert conn |> host_header(site.host <> ":4000") |> no_route() =~ "own 404"
    end

    test "and not by the request target", %{conn: conn, site: site} do
      for conn <- [host_header(conn, "elsewhere.test"), no_host_header(conn)] do
        assert conn |> post("http://#{site.host}/no-such-page", %{}) |> response(404) ==
                 "Not Found"
      end
    end
  end

  describe "a site closed to its visitors answers the plain text before the pipeline, unlogged" do
    setup %{site: site} do
      error_page!(site, [{403, "<p>own 403</p>"}, {404, "<p>own 404</p>"}])
      plugin!("CompileError")
      :ok
    end

    defp assert_plain(conn, reason) do
      log =
        capture_log(fn ->
          assert no_route(conn) == "Not Found"
          assert_received {"CompileError", %{error: ^reason, template: "404.html"}}
          assert bad_csrf(conn) == "Forbidden"
          assert_received {"CompileError", %{error: ^reason, template: "403.html"}}
        end)

      assert warnings(log) == []
    end

    test "while it is offline", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      on_exit(fn -> SettingsState.delete(site.id, "cms.offline") end)

      assert_plain(conn, :offline)
    end

    test "while it is API only", %{conn: conn, site: site} do
      cache!(site, %{mode: :api_only})

      assert_plain(conn, :api_only)
    end

    test "while it is switched off", %{conn: conn, site: site} do
      cache!(site, %{active: false})

      assert_plain(conn, :inactive)
    end

    test "and so does a host no site has", %{conn: conn} do
      conn |> on("no-site.test") |> assert_plain(:not_found)
    end
  end

  describe "a page that raises as it is drawn" do
    test "answers the status it had, before the pipeline and after it", %{conn: conn, site: site} do
      error_page!(site, [{403, @raises}, {404, @raises}])

      for {request, plain} <- [
            {&no_route/1, "Not Found"},
            {&bad_csrf/1, "Forbidden"},
            {&no_page/1, "Not Found"}
          ] do
        {body, log} = with_log(fn -> request.(conn) end)

        assert body == plain
        assert [_warning] = warnings(log)
        assert log =~ "failed to render error page for"
        assert log =~ "RuntimeError"
        assert log =~ "cannot draw"
      end
    end

    test "answers the same with a root layout of its own", %{conn: conn, site: site} do
      error_page!(site, [{404, @raises}], %{
        root_layout_template: "<html><body><%= @inner_content %></body></html>"
      })

      for request <- [&no_route/1, &no_page/1] do
        {body, log} = with_log(fn -> request.(conn) end)

        assert body == "Not Found"
        assert [_warning] = warnings(log)
      end
    end

    test "or throws or exits", %{conn: conn, site: site} do
      error_page!(site, [{403, "<p>{throw(:away)}</p>"}, {404, "<p>{exit(:away)}</p>"}])

      for {request, plain} <- [{&no_route/1, "Not Found"}, {&bad_csrf/1, "Forbidden"}] do
        {body, log} = with_log(fn -> request.(conn) end)

        assert body == plain
        assert [_warning] = warnings(log)
      end
    end

    test "for an assign the pipeline sets is drawn after it, and logs no assigns before it", %{
      conn: conn,
      site: site
    } do
      reads = "<p>own {@conn.assigns.current_user}</p>"
      error_page!(site, [{403, reads}, {404, reads}])

      assert no_page(conn) =~ "own"
      {body, log} = with_log(fn -> bad_csrf(conn) end)

      assert body == "Forbidden"
      assert [_warning] = warnings(log)
      assert log =~ "KeyError"
      assert log =~ ":current_user"
      refute log =~ "InvalidCSRFTokenError"
    end

    # What such an error says is below its first line.
    test "for an argument logs which argument, on one short line", %{conn: conn, site: site} do
      error_page!(site, [{404, "<p>{String.to_integer(@conn.request_path)}</p>"}])
      {body, log} = with_log(fn -> no_route(conn) end)

      assert body == "Not Found"
      assert [warning] = warnings(log)
      assert warning =~ "1st argument"
      assert byte_size(warning) < 500
    end

    test "logs a short line for whatever it raised", %{conn: conn, site: site} do
      error_page!(site, [{404, "<p>{raise String.duplicate(\"long \", 1000)}</p>"}])
      {body, log} = with_log(fn -> no_route(conn) end)

      assert body == "Not Found"
      assert [warning] = warnings(log)
      assert byte_size(warning) < 500
    end
  end

  describe "a page that does not compile" do
    test "answers the plain text and one warning that says so", %{conn: conn, site: site} do
      error_page = error_page!(site, [{404, "<p>ok</p>"}])
      store!(error_page, 404, "<p>{no_such_function(1)}</p>")
      on_exit(fn -> CompileFailureState.clear(module(error_page, site)) end)

      for _request <- [:compiles, :known_broken] do
        {body, log} = with_log(fn -> no_route(conn) end)

        assert body == "Not Found"
        assert [_warning] = warnings(log)
        assert log =~ site.name
        assert log =~ "404.html"
        assert log =~ "does not compile"
        refute log =~ "has no error page"
      end
    end
  end

  describe "nothing raises" do
    test "with no table to find the site in", %{site: site} do
      :ets.rename(:mishka_sites_host_index, :mishka_sites_host_index_away)

      log =
        try do
          capture_log(fn ->
            assert ErrorHTML.render("403.html", %{conn: bare(site.host)}) == "Forbidden"
          end)
        after
          :ets.rename(:mishka_sites_host_index_away, :mishka_sites_host_index)
        end

      assert [_warning] = warnings(log)
    end

    test "for what is not a conn, or holds no site" do
      assert ErrorHTML.render("404.html", %{conn: %{}}) == "Not Found"
      assert ErrorHTML.render("404.html", %{conn: nil}) == "Not Found"

      for site <- [nil, %{name: nil}, %{name: "no-id"}] do
        conn = "no-site.test" |> bare() |> assign(:current_site, site)
        assert ErrorHTML.render("404.html", %{conn: conn}) == "Not Found"
      end
    end

    test "for what a plugin answers", %{site: site} do
      conn = bare(site.host)
      error_page!(site, [{404, "<p>own 404</p>"}])
      plugin!("CompileError")

      for name <- ["BeforeRender", "BeforeCompile", "AfterCompile"] do
        plugin!(name, fn _data -> "not a map" end)
        assert ErrorHTML.render("404.html", %{conn: conn}) == "Not Found"
        Process.delete({:answer, name})
      end

      for answer <- [
            fn _data -> "not a map" end,
            fn _data -> throw(:away) end,
            &%{&1 | fallback: {:no, :content}}
          ] do
        Process.put({:answer, "CompileError"}, answer)
        assert ErrorHTML.render("404.html", %{conn: bare("no-site.test")}) == "Not Found"
      end
    end
  end

  describe "a site's page is compiled once and served from memory" do
    setup %{site: site} do
      compiles = :counters.new(1, [])
      queries = :counters.new(1, [])
      name = site.name
      test = self()
      handlers = [{:compiles, name}, {:queries, name}]

      :telemetry.attach(
        {:compiles, name},
        [:mishka_cms, :runtime, :compilers, :error, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata.site == name, do: :counters.add(compiles, 1, 1)
        end,
        nil
      )

      :telemetry.attach(
        {:queries, name},
        [:mishka_cms, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test, do: :counters.add(queries, 1, 1)
        end,
        nil
      )

      on_exit(fn -> Enum.each(handlers, &:telemetry.detach/1) end)

      {:ok, compiles: compiles, queries: queries}
    end

    test "by the first request, and the second reads neither the database nor compiles", %{
      conn: conn,
      site: site,
      compiles: compiles,
      queries: queries
    } do
      error_page = error_page!(site, [{404, "<p>own 404</p>"}])
      :counters.put(queries, 1, 0)

      refute Helpers.loaded?(module(error_page, site))
      assert no_route(conn) =~ "own 404"
      assert Helpers.loaded?(module(error_page, site))
      assert :counters.get(compiles, 1) == 1

      :counters.put(queries, 1, 0)
      assert no_route(conn) =~ "own 404"
      assert bad_csrf(conn) == "Forbidden"
      assert :counters.get(queries, 1) == 0
      assert :counters.get(compiles, 1) == 1
    end

    test "however many first requests arrive at once", %{site: site, compiles: compiles} do
      error_page!(site, [{404, "<p>own 404</p>"}])

      pages =
        1..20
        |> Enum.map(fn _request ->
          Task.async(fn -> drawn(ErrorHTML.render("404.html", %{conn: bare(site.host)})) end)
        end)
        |> Task.await_many(60_000)

      assert Enum.all?(pages, &(&1 =~ "own 404"))
      assert :counters.get(compiles, 1) == 1
    end
  end

  describe "events" do
    test "hand each plugin the request, its Error Page and what was drawn of it", %{
      conn: conn,
      site: site
    } do
      error_page = error_page!(site, [{404, "<p>own 404</p>"}])
      module = module(error_page, site)
      %{id: id, name: name} = site
      path = ErrorAddress.path(name)

      for event <- ["BeforeRender", "BeforeCompile", "AfterCompile", "CompileError"],
          do: plugin!(event)

      assert no_route(conn) =~ "own 404"

      assert_received {"BeforeRender",
                       %{
                         conn: %Plug.Conn{assigns: %{current_site: %{id: ^id}}},
                         status_code: "404",
                         template: "404.html"
                       }}

      assert_received {"BeforeCompile", %{path: ^path, site: %{id: ^id}, status_code: "404"}}

      assert_received {"AfterCompile",
                       %{
                         conn: %Plug.Conn{
                           assigns: %{
                             page_module: ^module,
                             page_data: %{error: %{path: ^path}}
                           }
                         },
                         content: %Phoenix.LiveView.Rendered{}
                       }}

      refute_received {"CompileError", _data}
    end

    test "hand CompileError the reason of each fallback", %{conn: conn, site: site} do
      plugin!("CompileError")

      no_route(conn)
      assert_received {"CompileError", data}
      assert data == %{error: :no_error_page, template: "404.html", fallback: "Not Found"}

      error_page = error_page!(site, [{404, "<p>ok</p>"}])
      store!(error_page, 404, "<p>{no_such_function(1)}</p>")
      on_exit(fn -> CompileFailureState.clear(module(error_page, site)) end)
      no_route(conn)
      assert_received {"CompileError", %{error: :compilation_error, template: "404.html"}}

      other = create_site!(name: "other-" <> site.name, host: "other-" <> site.host, active: true)
      cache!(other)

      on_exit(fn ->
        SiteState.delete(other.id)
        WebRunTimeMetaDataState.delete_by_site(other.name)
      end)

      error_page!(other, [{403, @raises}])
      conn |> on(other.host) |> bad_csrf()

      assert_received {"CompileError",
                       %{error: %RuntimeError{message: "cannot draw"}, fallback: "Forbidden"}}
    end

    test "let a plugin brand the page of a host no site has", %{conn: conn} do
      plugin!("CompileError", &%{&1 | fallback: {:safe, "<p>branded #{&1.fallback}</p>"}})

      assert conn |> on("no-site.test") |> no_route() == "<p>branded Not Found</p>"
    end
  end
end
