# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RecordPermissionsTest do
  @moduledoc """
  A page that shows a record — a post, a category, a tag, a document or a page of one — opens only
  for whoever the record admits too: the record's own `permissions`, which the plugin answering for
  its kind puts in the head on `runtime:page:seo`, asked by `MishkaCmsWeb.RuntimeLive` after the
  page's own, as a page's are. A visitor who is not signed in is sent to sign in; a user holding
  none of them is answered as though the address were not there; the head of a locked record says
  `noindex, nofollow`. A record that names none asks for what is above it: a post for its
  categories', a category or a page of a document for the nearest locked one above it, and a page of
  a document last for its document's. A tag locks nothing but its own page.

  Here rather than in an extension's suite because only this application has the router, the
  runtime LiveView and the root layout that renders the head.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  plugin registry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()

  # A refused live mount takes its LiveView down with the 404, which is logged.
  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory
  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @locked ["members:read"]

  # A unique site name per test: a component's module is named from its site's name, so a reused one
  # renders the previous test's module against a site that test rolled back.
  setup %{url_mode: url_mode} do
    SiteState.clear()
    name = "recordacl#{System.unique_integer([:positive])}"
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
    {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", url_mode, site_id: site.id)

    # Each extension registers its plugin as it starts; registering it again keeps the one record,
    # and compiling the event here is what makes the chain hold both before the first request.
    {:ok, _registered} = MishkaBlog.Plugins.PageSeo.register()
    {:ok, _registered} = MishkaDocument.Plugins.PageSeo.register()
    :ok = EventHandler.do_compile(Seo.event(), :start, false)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SiteState.clear()
    end)

    MishkaBlog.Provision.ensure!(site)
    MishkaDocument.Provision.ensure!(site)
    register_routes!(site)

    %{site: site}
  end

  describe "a post that names permissions" do
    test "sends a visitor who is not signed in to sign in", %{url_mode: url_mode, site: site} do
      post = post!(site, @locked)

      assert english_sign_in?(
               redirected_to(get(on_site(site), english(url_mode, "/blog/#{post.slug}"))),
               url_mode
             )

      assert {:error, {:redirect, %{to: to}}} =
               live(on_site(site), english(url_mode, "/blog/#{post.slug}"))

      assert english_sign_in?(to, url_mode)
    end

    test "answers the site's 404 to a user holding none of them", %{
      url_mode: url_mode,
      site: site
    } do
      post = post!(site, @locked)

      for held <- [[], ["members:write"], ["admin:dashboard:blog:post"]] do
        assert_error_sent(404, fn ->
          get(signed_in(site, held), english(url_mode, "/blog/#{post.slug}"))
        end)
      end
    end

    test "opens for a user holding one of them, with a head kept out of an index", %{
      url_mode: url_mode,
      site: site
    } do
      post = post!(site, @locked)

      for held <- [["members:read"], ["members:*"], ["*"]] do
        doc =
          site
          |> signed_in(held)
          |> get(english(url_mode, "/blog/#{post.slug}"))
          |> html_response(200)
          |> LazyHTML.from_document()

        assert robots(doc) == ["noindex, nofollow"], "#{inspect(held)} saw an indexable head"
      end
    end
  end

  test "a post that names none opens for everyone, indexable", %{url_mode: url_mode, site: site} do
    post = post!(site, [])

    doc =
      site
      |> on_site()
      |> get(english(url_mode, "/blog/#{post.slug}"))
      |> html_response(200)
      |> LazyHTML.from_document()

    assert robots(doc) == ["index, follow, max-image-preview:large"]
  end

  test "a category or a tag that names permissions sends a visitor to sign in", %{
    url_mode: url_mode,
    site: site
  } do
    category =
      create_collection!(site_id: site.id, status: :active, language: "en", permissions: @locked)

    tag =
      [language: "en", permissions: @locked]
      |> MishkaBlog.Dev.Generator.tag(site.id)
      |> generate()

    for path <- [
          english(url_mode, "/blog/category/#{category.slug}"),
          english(url_mode, "/blog/tag/#{tag.slug}")
        ] do
      assert english_sign_in?(redirected_to(get(on_site(site), path)), url_mode), "#{path} opened"
    end
  end

  describe "a post filed under a locked category" do
    test "is closed by the category when it names nothing itself", %{
      url_mode: url_mode,
      site: site
    } do
      post = post!(site, [])
      file!(post, category!(site, @locked))

      assert english_sign_in?(
               redirected_to(get(on_site(site), english(url_mode, "/blog/#{post.slug}"))),
               url_mode
             )

      assert_error_sent(404, fn ->
        get(signed_in(site, []), english(url_mode, "/blog/#{post.slug}"))
      end)

      assert html_response(
               get(signed_in(site, @locked), english(url_mode, "/blog/#{post.slug}")),
               200
             )
    end

    test "opens with its own permissions when it names some, not the category's", %{
      url_mode: url_mode,
      site: site
    } do
      post = post!(site, ["staff:read"])
      file!(post, category!(site, @locked))

      assert_error_sent(404, fn ->
        get(signed_in(site, @locked), english(url_mode, "/blog/#{post.slug}"))
      end)

      assert html_response(
               get(signed_in(site, ["staff:read"]), english(url_mode, "/blog/#{post.slug}")),
               200
             )
    end

    test "under a category of a locked one is closed too, as that category is", %{
      url_mode: url_mode,
      site: site
    } do
      members = category!(site, @locked)
      guides = category!(site, [], parent_collection_id: members.id)
      post = post!(site, [])
      file!(post, guides)

      for path <- [
            english(url_mode, "/blog/#{post.slug}"),
            english(url_mode, "/blog/category/#{guides.slug}")
          ] do
        assert english_sign_in?(redirected_to(get(on_site(site), path)), url_mode),
               "#{path} opened"

        assert html_response(get(signed_in(site, @locked), path), 200)
      end
    end

    test "is open to everyone when no category of it is locked, whatever its tags", %{
      url_mode: url_mode,
      site: site
    } do
      post = post!(site, [])
      file!(post, category!(site, []))

      tag =
        [language: "en", permissions: @locked]
        |> MishkaBlog.Dev.Generator.tag(site.id)
        |> generate()

      Ash.create!(MishkaBlog.PostTag, %{post_id: post.id, tag_id: tag.id}, authorize?: false)

      assert html_response(get(on_site(site), english(url_mode, "/blog/#{post.slug}")), 200)
    end
  end

  describe "a document" do
    test "that names permissions closes its front page and every page of it", %{
      url_mode: url_mode,
      site: site
    } do
      document!(site, @locked, [])

      for path <- [english(url_mode, "/docs/guide"), english(url_mode, "/docs/guide/install")] do
        assert english_sign_in?(redirected_to(get(on_site(site), path)), url_mode),
               "#{path} opened"
      end

      assert_error_sent(404, fn ->
        get(signed_in(site, []), english(url_mode, "/docs/guide/install"))
      end)

      assert html_response(
               get(signed_in(site, @locked), english(url_mode, "/docs/guide/install")),
               200
             )
    end

    # THE PLUGIN READS AS THE VISITOR THE PAGE IS DRAWN FOR, so the reader the lock opens for is the
    # one the record is described to: the document's name on its front page, the page's title on it.
    test "that names permissions is described in the head to a reader who may open it", %{
      url_mode: url_mode,
      site: site
    } do
      document!(site, @locked, [])

      for {path, title} <- [
            {english(url_mode, "/docs/guide"), "Guide"},
            {english(url_mode, "/docs/guide/install"), "Install"}
          ] do
        doc =
          site
          |> signed_in(@locked)
          |> get(path)
          |> html_response(200)
          |> LazyHTML.from_document()

        assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() == title
        assert robots(doc) == ["noindex, nofollow"]
      end
    end

    test "that names none leaves a page of it to its own", %{url_mode: url_mode, site: site} do
      document!(site, [], ["staff:*"])

      assert html_response(get(on_site(site), english(url_mode, "/docs/guide")), 200)

      assert english_sign_in?(
               redirected_to(get(on_site(site), english(url_mode, "/docs/guide/install"))),
               url_mode
             )

      assert_error_sent(404, fn ->
        get(signed_in(site, @locked), english(url_mode, "/docs/guide/install"))
      end)

      assert html_response(
               get(signed_in(site, ["staff:*"]), english(url_mode, "/docs/guide/install")),
               200
             )
    end

    test "closes a page under a locked page of it with that page's", %{
      url_mode: url_mode,
      site: site
    } do
      install = document!(site, [], ["staff:*"])

      create_section!(
        site_id: site.id,
        workspace_version_id: install.workspace_version_id,
        parent_section_id: install.id,
        title: "Upgrade",
        slug: "upgrade",
        content: "<p>Run the upgrade.</p>",
        content_review_status: :approved,
        technical_review_status: :approved
      )

      assert html_response(get(on_site(site), english(url_mode, "/docs/guide")), 200)

      assert english_sign_in?(
               redirected_to(
                 get(on_site(site), english(url_mode, "/docs/guide/install/upgrade"))
               ),
               url_mode
             )

      assert_error_sent(404, fn ->
        get(signed_in(site, @locked), english(url_mode, "/docs/guide/install/upgrade"))
      end)

      assert html_response(
               get(
                 signed_in(site, ["staff:*"]),
                 english(url_mode, "/docs/guide/install/upgrade")
               ),
               200
             )
    end
  end

  defp post!(site, permissions) do
    create_blog_post!(
      site_id: site.id,
      title: "Members only",
      language: "en",
      status: :published,
      published_at: ~U[2026-09-01 08:30:00Z],
      permissions: permissions
    )
  end

  defp category!(site, permissions, overrides \\ []) do
    create_collection!(
      [site_id: site.id, status: :active, language: "en", permissions: permissions] ++ overrides
    )
  end

  defp file!(post, category) do
    Ash.create!(MishkaBlog.PostCollection, %{post_id: post.id, collection_id: category.id},
      authorize?: false
    )
  end

  # A document at `/en/docs/guide` with one approved page, `install`, in its latest version.
  defp document!(site, permissions, page_permissions) do
    document =
      create_workspace!(
        site_id: site.id,
        skip_version: true,
        status: :active,
        name: "Guide",
        slug: "guide",
        language: "en",
        permissions: permissions
      )

    version =
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        version_number: "1.0.0",
        is_latest_for_version: true,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

    create_section!(
      site_id: site.id,
      workspace_version_id: version.id,
      title: "Install",
      slug: "install",
      content: "<p>Run the installer.</p>",
      content_review_status: :approved,
      technical_review_status: :approved,
      permissions: page_permissions
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

  defp member!(site, permissions) do
    user = create_user!(site_id: site.id)

    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(permissions, &permission!(&1).id)},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp signed_in(site, permissions) do
    site
    |> on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(member!(site, permissions))
  end

  # Whether `path` is the site's sign-in page in English, the site's first language, in `url_mode`.
  defp english_sign_in?(path, url_mode),
    do: String.starts_with?(path, english(url_mode, "/auth?"))

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp robots(doc),
    do: LazyHTML.attribute(LazyHTML.query(doc, ~s(meta[name="robots"])), "content")
end
