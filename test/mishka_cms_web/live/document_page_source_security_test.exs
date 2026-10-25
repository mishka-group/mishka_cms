# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.DocumentPageSourceSecurityTest do
  @moduledoc """
  The rows a documentation page reads once and shares between its head, its frame and its blocks
  (`MishkaDocument.PageSource`) are read as the visitor, so a visitor is shown, by any of the three,
  nothing a read of their own would keep from them: not in the page, not in its contents, not in the
  header's language menu, not in the head's `hreflang` links, not in a title.

  Each rule is asked of a guest and of a reader holding the lock, through the router, the runtime
  LiveView and the site's layout: a locked edition of an open document, a locked page of an open
  one, a locked document whose own edition a guest is refused, a page whose own lock opens inside a
  document whose lock does not, and a draft.

  `async: false` — the install flag, `SiteState`, the routing table and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @lock ["members:read"]

  # ONE SITE FOR THE WHOLE MODULE, set up once. Provisioning compiles every page of the site, which
  # was nearly all that this setup cost each test, and the tests below only add to the site and ask
  # for it: what a test adds or changes is taken back by the savepoint that
  # `MishkaCms.DataCase.setup_module_sandbox/0` gives it, and the cache by the snapshot it takes of
  # it. The name is unique per module: a component's module is named from its site's name, so a
  # reused one renders the previous module's pages against a site that module rolled back.
  setup_all do
    context = MishkaCms.DataCase.setup_module_sandbox()

    SiteState.clear()
    name = "docsource#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    Settings.put("cms.offline", false)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", "prefix_others", site_id: site.id)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SiteState.clear()
    end)

    seed_site_layout!(site)
    MishkaDocument.Provision.ensure!(site)
    register_routes!(site)

    Map.put(context, :site, site)
  end

  describe "a locked edition of an open document" do
    setup %{site: site} do
      guide = document!(site, "guide", "Open guide", "en")
      install = page!(site, version!(site, guide), "install", "Install it", "en")
      rahnama = document!(site, "rahnama", "Locked rahnama", "fa", guide, permissions: @lock)
      page!(site, version!(site, rahnama), "nasb", "Locked nasb", "fa", group: install)
      :ok
    end

    test "is named nowhere to a guest", %{site: site} do
      for path <- ["/docs/guide", "/docs/guide/install"] do
        html = page(on_site(site), path)

        assert html =~ "Open guide"
        refute html =~ "Locked rahnama"
        refute html =~ "Locked nasb"
        refute html =~ "/fa/docs/rahnama"
        assert offered(html) == []
        assert hreflangs(html) == []
      end
    end

    test "is offered to a reader holding the lock, in the menu and in the head", %{site: site} do
      html = page(signed_in(site, @lock), "/docs/guide/install")

      assert {"fa", "/fa/docs/rahnama/nasb"} in offered(html)
      assert {"fa", "/fa/docs/rahnama/nasb"} in hreflangs(html)
      assert html =~ "Locked nasb"
    end
  end

  describe "a locked page of an open document" do
    setup %{site: site} do
      version = version!(site, document!(site, "guide", "Open guide", "en"))
      page!(site, version, "install", "Install it", "en")
      page!(site, version, "salaries", "Locked salaries", "en", permissions: @lock)
      :ok
    end

    test "answers a guest the site's 404, with nothing of the page in it, and is not in the contents",
         %{site: site} do
      assert_missing(on_site(site), "/docs/guide/salaries", "Locked salaries")
      assert_missing(signed_in(site, []), "/docs/guide/salaries", "Locked salaries")

      refute page(on_site(site), "/docs/guide/install") =~ "Locked salaries"
    end

    test "opens for a reader holding its lock, and is in their contents", %{site: site} do
      reader = signed_in(site, @lock)

      assert page(reader, "/docs/guide/salaries") =~ "Locked salaries"
      assert page(reader, "/docs/guide/install") =~ "Locked salaries"
    end
  end

  # THE EDITION BEING READ IS READ AS THE VISITOR. The frame once read it as the system, which
  # put a locked document's name into the bar and the header's menu of a page meant to refuse its
  # guest.
  describe "a locked document, the edition being read" do
    setup %{site: site} do
      guide = document!(site, "handbook", "Members handbook", "en", nil, permissions: @lock)
      install = page!(site, version!(site, guide), "install", "Members install", "en")
      rahnama = document!(site, "rahnama", "Open rahnama", "fa", guide)
      page!(site, version!(site, rahnama), "nasb", "Open nasb", "fa", group: install)
      :ok
    end

    test "is refused to a guest, and nothing of it is in the answer", %{site: site} do
      for path <- ["/docs/handbook", "/docs/handbook/install"] do
        assert_missing(on_site(site), path, "Members handbook")
        assert_missing(on_site(site), path, "Members install")
      end
    end

    test "is read, with its editions, for a reader holding its lock", %{site: site} do
      html = page(signed_in(site, @lock), "/docs/handbook/install")

      assert html =~ "Members install"
      assert {"en", "/docs/handbook/install"} in offered(html)
      assert {"fa", "/fa/docs/rahnama/nasb"} in offered(html)
    end
  end

  # A PAGE WHOSE OWN LOCK OPENS FOR ITS READER INSIDE A DOCUMENT WHOSE LOCK DOES NOT is the one rule
  # that draws a document around a page its reader may not otherwise open: they get that page and
  # nothing else of the document.
  describe "a page whose own lock opens inside a locked document" do
    setup %{site: site} do
      version =
        version!(
          site,
          document!(site, "board", "Board papers", "en", nil, permissions: ["board:read"])
        )

      page!(site, version, "minutes", "Board minutes", "en")
      page!(site, version, "salaries", "Shared salaries", "en", permissions: @lock)
      :ok
    end

    test "opens that page for a reader holding its lock, and no other page of the document", %{
      site: site
    } do
      reader = signed_in(site, @lock)
      html = page(reader, "/docs/board/salaries")

      assert html =~ "Shared salaries"
      refute html =~ "Board minutes"

      assert_missing(reader, "/docs/board/minutes", "Board minutes")
      assert_missing(reader, "/docs/board", "Board minutes")
    end

    test "is refused to a guest", %{site: site} do
      assert_missing(on_site(site), "/docs/board/salaries", "Shared salaries")
    end
  end

  describe "a draft" do
    setup %{site: site} do
      guide = document!(site, "guide", "Open guide", "en")
      install = page!(site, version!(site, guide), "install", "Install it", "en")

      draft =
        version!(site, guide,
          version_number: "2.0.0",
          status: :draft,
          is_latest_for_version: false,
          published_at: ~U[2026-06-01 00:00:00Z]
        )

      page!(site, draft, "upcoming", "Not written yet", "en")
      page!(site, draft, "install", "Install it again", "en")

      unwritten =
        document!(site, "pish-nevis", "Unfinished rahnama", "fa", guide, status: :draft)

      page!(site, version!(site, unwritten), "nasb", "Unfinished nasb", "fa", group: install)
      :ok
    end

    test "is offered to no one, and its addresses are no page", %{site: site} do
      for conn <- [on_site(site), signed_in(site, @lock)] do
        html = page(conn, "/docs/guide/install?v=2.0.0")

        assert html =~ "Install it"
        refute html =~ "Install it again"
        refute html =~ "Not written yet"
        refute html =~ "2.0.0"
        refute html =~ "Unfinished"
        assert offered(html) == []

        assert_missing(conn, "/docs/guide/upcoming", "Not written yet")
        assert_missing(conn, "/fa/docs/pish-nevis/nasb", "Unfinished nasb")
      end
    end
  end

  # THE PAGE AS A READER GETS IT: the HTTP render and the connected mount after it.
  defp page(conn, path) do
    conn = get(conn, path)
    assert conn.status == 200, "#{path} answered #{conn.status}"
    {:ok, view, _html} = live(conn)
    render_async(view, 5_000)
    html_response(conn, 200) <> render(view)
  end

  # THE SITE'S 404, as a request and as a mount, and nothing of the record in its body.
  defp assert_missing(conn, path, title) do
    {404, _headers, body} = assert_error_sent(404, fn -> get(conn, path) end)
    refute body =~ title
    assert_raise NotFoundError, fn -> live(conn, path) end
  end

  # The languages the header's menu offers, each at its address.
  defp offered(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#site-language-menu a[hreflang]")
    |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})
    |> Enum.uniq()
  end

  # The languages the head names in its `hreflang` links, at their paths.
  defp hreflangs(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|link[rel="alternate"][hreflang]:not([hreflang="x-default"])|)
    |> Enum.map(fn link ->
      {hd(LazyHTML.attribute(link, "hreflang")),
       link |> LazyHTML.attribute("href") |> hd() |> URI.parse() |> Map.get(:path)}
    end)
    |> Enum.uniq()
  end

  defp document!(site, slug, name, language, translates \\ nil, overrides \\ []) do
    create_workspace!(
      [
        site_id: site.id,
        skip_version: true,
        status: :active,
        name: name,
        slug: slug,
        language: language,
        permissions: [],
        language_group_id: translates && (translates.language_group_id || translates.id)
      ] ++ overrides
    )
  end

  defp version!(site, document, overrides \\ []) do
    create_workspace_version!(
      [
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        version_number: "1.0.0",
        is_latest_for_version: true,
        published_at: ~U[2026-03-01 00:00:00Z]
      ] ++ overrides
    )
  end

  defp page!(site, version, slug, title, language, overrides \\ []) do
    {translates, overrides} = Keyword.pop(overrides, :group)

    create_section!(
      [
        site_id: site.id,
        workspace_version_id: version.id,
        title: title,
        slug: slug,
        language: language,
        language_group_id: translates && (translates.language_group_id || translates.id),
        content: "<p>#{title}.</p>",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: []
      ] ++ overrides
    )
  end

  defp register_routes!(site) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
    |> Enum.each(fn page ->
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
    end)
  end

  defp signed_in(site, permissions) do
    user = create_user!(site_id: site.id)

    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(permissions, &permission!(&1).id)},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()

    site
    |> on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end
end
