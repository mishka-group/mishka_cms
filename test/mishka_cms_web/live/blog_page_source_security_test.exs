# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogPageSourceSecurityTest do
  @moduledoc """
  The rows a blog page reads once and shares between its head, its frame and its blocks
  (`MishkaBlog.PageSource`) are read as the visitor, so a visitor is shown, by any of the three,
  nothing a read of their own would keep from them: not in the article, not in the header's
  language menu, not in the head's `hreflang` links, not in a title.

  Each rule is asked of a guest and of a reader holding the lock, through the router, the runtime
  LiveView and the site's layout: a locked edition of an open post, a post page locked on the site,
  a post locked by the category it is filed under, a locked post whose own edition a guest is
  refused, and a draft edition.

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

  setup do
    SiteState.clear()
    name = "blogsource#{System.unique_integer([:positive])}"
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
    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", "prefix_others", site_id: site.id)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SiteState.clear()
    end)

    seed_site_layout!(site)
    MishkaBlog.Provision.ensure!(site)
    register_routes!(site)

    %{site: site}
  end

  describe "a locked edition of an open post" do
    setup %{site: site} do
      open = post!(site, "open-post", "Open to all", "en")
      group = open.language_group_id || open.id
      post!(site, "ghofl", "Behind the lock", "fa", language_group_id: group, permissions: @lock)
      :ok
    end

    test "is named nowhere to a guest", %{site: site} do
      html = page(on_site(site), "/blog/open-post")

      assert html =~ "Open to all"
      refute html =~ "Behind the lock"
      refute html =~ "/fa/blog/ghofl"
      assert offered(html) == []
      assert hreflangs(html) == []
    end

    test "is offered to a reader holding the lock, in the menu and in the head", %{site: site} do
      html = page(signed_in(site, @lock), "/blog/open-post")

      assert {"fa", "/fa/blog/ghofl"} in offered(html)
      assert {"fa", "/fa/blog/ghofl"} in hreflangs(html)
      assert html =~ "Behind the lock"
    end
  end

  describe "a post whose page on the site is locked" do
    setup %{site: site} do
      post!(site, "on-a-locked-page", "Kept by its page", "en")

      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site.id and path == "/:lang/blog/:slug")
      |> Ash.read_one!(authorize?: false)
      |> Ash.update!(%{permissions: @lock}, action: :master_update, authorize?: false)

      register_routes!(site)
      :ok
    end

    test "answers a guest the site's 404, with nothing of the post in it", %{site: site} do
      assert_missing(on_site(site), "/blog/on-a-locked-page", "Kept by its page")
    end

    test "opens for a reader holding the page's lock", %{site: site} do
      assert page(signed_in(site, @lock), "/blog/on-a-locked-page") =~ "Kept by its page"
    end
  end

  describe "a post filed under a locked category" do
    setup %{site: site} do
      post = post!(site, "filed-away", "Filed away from guests", "en")
      group = post.language_group_id || post.id
      post!(site, "bayegani", "Bayegani", "fa", language_group_id: group)

      locked =
        create_collection!(
          site_id: site.id,
          status: :active,
          name: "Staff",
          slug: "staff",
          language: "en",
          permissions: @lock
        )

      Ash.create!(MishkaBlog.PostCollection, %{post_id: post.id, collection_id: locked.id},
        authorize?: false
      )

      :ok
    end

    test "answers a guest the site's 404, with nothing of the post in it", %{site: site} do
      assert_missing(on_site(site), "/blog/filed-away", "Filed away from guests")
      assert_missing(signed_in(site, []), "/blog/filed-away", "Filed away from guests")
    end

    test "opens for a reader holding the category's lock, its editions offered", %{site: site} do
      html = page(signed_in(site, @lock), "/blog/filed-away")

      assert html =~ "Filed away from guests"
      assert {"fa", "/fa/blog/bayegani"} in offered(html)
    end
  end

  # THE EDITION BEING READ IS READ AS THE VISITOR. The frame once read it as the system, which put
  # a locked post's title into the header's menu of a page meant to refuse its guest.
  describe "a locked post, the edition being read" do
    setup %{site: site} do
      locked = post!(site, "members-only", "A title for members", "en", permissions: @lock)
      group = locked.language_group_id || locked.id
      post!(site, "baraye-hame", "Baraye hame", "fa", language_group_id: group)
      :ok
    end

    test "is refused to a guest, and no title of it is in the answer", %{site: site} do
      assert_missing(on_site(site), "/blog/members-only", "A title for members")
    end

    test "is read, with its editions, for a reader holding its lock", %{site: site} do
      html = page(signed_in(site, @lock), "/blog/members-only")

      assert html =~ "A title for members"
      assert {"en", "/blog/members-only"} in offered(html)
      assert {"fa", "/fa/blog/baraye-hame"} in offered(html)
    end
  end

  describe "a draft edition" do
    setup %{site: site} do
      open = post!(site, "out-now", "Out now", "en")
      group = open.language_group_id || open.id
      post!(site, "pish-nevis", "Not written yet", "fa", language_group_id: group, status: :draft)
      :ok
    end

    test "is offered to no one, and its address is no page", %{site: site} do
      for conn <- [on_site(site), signed_in(site, @lock)] do
        html = page(conn, "/blog/out-now")

        assert html =~ "Out now"
        refute html =~ "Not written yet"
        refute html =~ "pish-nevis"
        assert offered(html) == []
      end

      assert_missing(on_site(site), "/fa/blog/pish-nevis", "Not written yet")
      assert_missing(signed_in(site, @lock), "/fa/blog/pish-nevis", "Not written yet")
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

  defp post!(site, slug, title, language, overrides \\ []) do
    create_blog_post!(
      [
        site_id: site.id,
        slug: slug,
        title: title,
        language: language,
        status: :published,
        published_at: ~U[2026-09-01 08:30:00Z],
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
