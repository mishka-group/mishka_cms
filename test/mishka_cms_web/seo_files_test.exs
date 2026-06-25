defmodule MishkaCmsWeb.SeoFilesTest do
  @moduledoc """
  A site's `/robots.txt`, `/sitemap.xml` and the gzipped `/sitemap-00001.xml.gz`… files beside it
  through the CMS's whole browser pipeline.

  They are `MishkaCmsCoreWeb.SeoController`'s, not a static file's or a page's. They answer the
  `Accept` a crawler sends for a text, an xml or a gzipped file, while a page asked the same is
  refused with a 406. An offline site answers them with its maintenance page, except to its admin,
  who gets them kept by no cache; a host no site answers to gets the lookup's 503.

  The controller serves the sitemap `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` stored and
  never builds one, so each test builds the site's before it asks for it. What goes in them is
  pinned in the library's own `MishkaCmsCoreWeb.SeoControllerTest`.

  `async: false` — the install flag, `SiteState`, `AssetsState` and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @sitemap_file "/sitemap-00001.xml.gz"
  @files ["/robots.txt", "/sitemap.xml", @sitemap_file]

  setup do
    Install.mark_installed!()
    snapshot = SettingsState.snapshot()
    host = "seo-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    # A page to list, so the sitemap has a file to serve.
    create_page!(site_id: site.id, path: "/listed")
    {:ok, _sitemap} = SitemapCompiler.compile_and_store(site.name)

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
      AssetsState.delete(site.name, "sitemap")
      :persistent_term.erase(:mishka_installed)
    end)

    %{site: site}
  end

  defp on_host(host) do
    build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp fetch(site, path, opts \\ []) do
    site.host
    |> on_host()
    |> as(opts[:as])
    |> then(&if(opts[:accept], do: put_req_header(&1, "accept", opts[:accept]), else: &1))
    |> get(path)
  end

  defp as(conn, nil), do: conn

  defp as(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp user!(site_id, permissions) do
    user = create_user!(site_id: site_id)

    ids =
      Enum.map(permissions, fn name ->
        case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
          {:ok, nil} -> create_permission!(name: name).id
          {:ok, permission} -> permission.id
        end
      end)

    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids},
      authorize?: false,
      tenant: site_id
    )
    |> Ash.update!()
  end

  # A page the site serves, in the routing table as a saved one leaves it.
  defp published!(site, path) do
    page = create_page!(site_id: site.id, path: path, template: ~S(<div><p>a page</p></div>))

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

    on_exit(fn -> WebRunTimeMetaDataState.delete(page.id) end)
    page
  end

  test "are the SEO controller's, not a static file or a page", %{site: site} do
    published!(site, "/about")
    {:ok, _sitemap} = SitemapCompiler.compile_and_store(site.name)
    uri = MishkaCmsWeb.Endpoint.struct_url()

    robots = fetch(site, "/robots.txt")

    assert robots.status == 200
    assert robots.private.phoenix_controller == MishkaCmsCoreWeb.SeoController
    assert robots.resp_body =~ ~r{\AUser-agent: \*\nDisallow: /admin/\n}
    assert robots.resp_body =~ "\nSitemap: http://#{site.host}:#{uri.port}/sitemap.xml\n"

    sitemap = fetch(site, "/sitemap.xml")

    assert sitemap.status == 200
    assert sitemap.private.phoenix_controller == MishkaCmsCoreWeb.SeoController

    assert sitemap.resp_body =~
             "<loc>http://#{site.host}:#{uri.port}#{@sitemap_file}</loc>"

    file = fetch(site, @sitemap_file)

    assert file.status == 200
    assert file.private.phoenix_controller == MishkaCmsCoreWeb.SeoController
    assert get_resp_header(file, "content-type") == ["application/gzip"]
    assert :zlib.gunzip(file.resp_body) =~ "<loc>http://#{site.host}:#{uri.port}/about</loc>"

    for conn <- [sitemap, file], do: assert(get_resp_header(conn, "x-robots-tag") == ["noindex"])

    for conn <- [robots, sitemap],
        do: assert(get_resp_header(conn, "cache-control") == ["private, max-age=60"])

    # SENT AS IT IS STORED: the server's response compression leaves a response marked
    # `no-transform` alone, and would gzip the gzipped file again otherwise.
    assert get_resp_header(file, "cache-control") == ["private, max-age=60, no-transform"]
  end

  @browser "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  test "answer the Accept a crawler sends for a text or an xml file", %{site: site} do
    for path <- ["/robots.txt", "/sitemap.xml"],
        accept <- ["text/plain", "application/xml", "text/xml", "*/*", @browser] do
      assert fetch(site, path, accept: accept).status == 200, "#{path} refused #{accept}"
    end
  end

  test "answer the Accept a crawler sends for a gzipped sitemap file", %{site: site} do
    for accept <- [
          "*/*",
          "application/gzip",
          "application/x-gzip",
          "application/xml",
          "text/xml",
          @browser
        ] do
      conn = fetch(site, @sitemap_file, accept: accept)

      assert conn.status == 200, "#{@sitemap_file} refused #{accept}"
      assert :zlib.gunzip(conn.resp_body) =~ "<urlset "
    end
  end

  test "answer a name that is no sitemap file with a 404 no cache keeps", %{site: site} do
    for path <- ["/sitemap-00002.xml.gz", "/sitemap-other.xml", "/sitemap-..%2Fx"] do
      conn = fetch(site, path)

      assert conn.status == 404, "#{path} was served"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  # THE PIPELINE ACCEPTS MORE ONLY FOR THE ROUTES THAT NAME IT. A page asked for text, xml or gzip
  # alone is refused before anything else runs; handed the format instead, its render fails with a
  # 500.
  test "leave a page asked for text, xml or gzip alone refused with a 406", %{site: site} do
    published!(site, "/about")

    assert fetch(site, "/about") |> html_response(200) =~ "a page"

    for path <- ["/about", "/auth"],
        accept <- [
          "text/plain",
          "application/xml",
          "text/xml",
          "application/gzip",
          "application/x-gzip"
        ] do
      assert_error_sent 406, fn -> fetch(site, path, accept: accept) end
    end
  end

  describe "an offline site" do
    setup %{site: site} do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      :ok
    end

    test "answers them with its maintenance page", %{site: site} do
      for path <- @files do
        conn = fetch(site, path)

        assert conn.status == 503
        assert get_resp_header(conn, "retry-after") == ["300"]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end

    test "gives them to its admin, kept by no cache", %{site: site} do
      admin = user!(site.id, ["*"])

      for path <- @files do
        conn = fetch(site, path, as: admin)

        assert conn.status == 200
        assert conn.private.phoenix_controller == MishkaCmsCoreWeb.SeoController

        assert get_resp_header(conn, "cache-control") ==
                 if(path == @sitemap_file,
                   do: ["private, no-store, no-transform"],
                   else: ["private, no-store"]
                 )
      end
    end
  end

  test "are the lookup's 503 on a host no site answers to" do
    host = "nobody-#{System.unique_integer([:positive])}.test"

    for path <- @files do
      conn = host |> on_host() |> get(path)

      assert conn.status == 503
      assert conn.resp_body =~ "No server available for this domain."
    end
  end
end
