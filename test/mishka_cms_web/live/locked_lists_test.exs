# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.LockedListsTest do
  @moduledoc """
  The blog's and the documentation's page lists leave out what their visitor may not open: a post
  filed under a locked category, a locked category, a locked document, a locked page of one. The
  provisioned pages hand their blocks the visitor (`current_user`), the blocks read for it, and the
  rows, the count and the pages are of what that visitor may open. A visitor holding the lock sees
  them.

  Here rather than in an extension's suite because only this application has the router, the
  runtime LiveView and the session the visitor comes from.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  plugin registry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()

  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory
  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @locked ["members:read"]

  setup %{url_mode: url_mode} do
    SiteState.clear()
    name = "lockedlists#{System.unique_integer([:positive])}"
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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SiteState.clear()
    end)

    MishkaBlog.Provision.ensure!(site)
    MishkaDocument.Provision.ensure!(site)
    register_routes!(site)

    members = category!(site, "Members", @locked)
    open = category!(site, "Open", [])
    behind = post!(site, "Behind the lock")
    everyone = post!(site, "For everyone")
    file!(behind, members)
    file!(behind, open)
    file!(everyone, open)

    shared = tag!(site, "shared")
    tag_post!(behind, shared)
    tag_post!(everyone, shared)
    tag_post!(behind, tag!(site, "only-behind"))

    document = document!(site, "guide", "Guide", [])
    version = version!(site, document)
    page!(site, version, "install", "Install", [])
    page!(site, version, "salaries", "Salaries", @locked)

    version!(site, document!(site, "handbook", "Handbook", @locked))

    %{site: site}
  end

  test "the blog's posts and categories leave out what the visitor may not open", %{
    url_mode: url_mode,
    site: site
  } do
    assert seen(
             site,
             nil,
             english(url_mode, "/blog"),
             "#blog-posts [data-role=\"blog-list-title\"]"
           ) == [
             "For everyone"
           ]

    assert seen(
             site,
             [],
             english(url_mode, "/blog"),
             "#blog-posts [data-role=\"blog-list-title\"]"
           ) == [
             "For everyone"
           ]

    assert Enum.sort(
             seen(
               site,
               @locked,
               english(url_mode, "/blog"),
               "#blog-posts [data-role=\"blog-list-title\"]"
             )
           ) ==
             ["Behind the lock", "For everyone"]

    assert seen(
             site,
             nil,
             english(url_mode, "/blog/categories"),
             "[data-role=\"blog-category-name\"]"
           ) == [
             "Open"
           ]

    assert Enum.sort(
             seen(
               site,
               @locked,
               english(url_mode, "/blog/categories"),
               "[data-role=\"blog-category-name\"]"
             )
           ) ==
             ["Members", "Open"]
  end

  test "the count beside a category or a tag is of the posts the visitor may open, and a tag " <>
         "leading only to a locked one is left out",
       %{url_mode: url_mode, site: site} do
    tags = ~s([data-role="blog-tag"])

    assert categories(site, nil, url_mode) == ["Open 1"]
    assert Enum.sort(categories(site, @locked, url_mode)) == ["Members 1", "Open 2"]

    assert seen(site, nil, english(url_mode, "/blog/tags"), tags) == ["shared 1"]
    assert seen(site, [], english(url_mode, "/blog/tags"), tags) == ["shared 1"]

    assert seen(site, @locked, english(url_mode, "/blog/tags"), tags) == [
             "shared 2",
             "only-behind 1"
           ]
  end

  test "the documents and a document's contents leave out what the visitor may not open",
       %{url_mode: url_mode, site: site} do
    assert seen(site, nil, english(url_mode, "/docs"), "[data-role=\"doc-list-title\"]") == [
             "Guide"
           ]

    assert Enum.sort(
             seen(site, @locked, english(url_mode, "/docs"), "[data-role=\"doc-list-title\"]")
           ) == [
             "Guide",
             "Handbook"
           ]

    assert seen(
             site,
             nil,
             english(url_mode, "/docs/guide/install"),
             "[data-role=\"doc-sidebar-link\"]"
           ) == [
             "Install"
           ]

    assert seen(
             site,
             @locked,
             english(url_mode, "/docs/guide/install"),
             "[data-role=\"doc-sidebar-link\"]"
           ) ==
             ["Install", "Salaries"]
  end

  # Each category on the English categories page with the count beside it, for a visitor holding
  # `permissions`.
  defp categories(site, permissions, url_mode) do
    names =
      seen(
        site,
        permissions,
        english(url_mode, "/blog/categories"),
        ~s([data-role="blog-category-name"])
      )

    counts =
      seen(
        site,
        permissions,
        english(url_mode, "/blog/categories"),
        ~s([data-role="blog-category-count"])
      )

    Enum.zip_with(names, counts, &"#{&1} #{&2}")
  end

  # What the page at `path` lists at `selector`, for a visitor holding `permissions` — `nil` for one
  # who is not signed in.
  defp seen(site, permissions, path, selector) do
    {:ok, view, _html} = live(visitor(site, permissions), path)

    view
    |> render_async(5_000)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp visitor(site, nil), do: on_site(site)

  defp visitor(site, permissions) do
    site
    |> on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(member!(site, permissions))
  end

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp category!(site, name, permissions) do
    create_collection!(
      site_id: site.id,
      name: name,
      slug: String.downcase(name),
      status: :active,
      language: "en",
      permissions: permissions
    )
  end

  defp post!(site, title) do
    create_blog_post!(
      site_id: site.id,
      title: title,
      language: "en",
      status: :published,
      published_at: ~U[2026-09-01 08:30:00Z],
      permissions: []
    )
  end

  defp file!(post, category) do
    Ash.create!(MishkaBlog.PostCollection, %{post_id: post.id, collection_id: category.id},
      authorize?: false
    )
  end

  defp tag!(site, name) do
    [name: name, slug: name, language: "en", permissions: []]
    |> MishkaBlog.Dev.Generator.tag(site.id)
    |> generate()
  end

  defp tag_post!(post, tag) do
    Ash.create!(MishkaBlog.PostTag, %{post_id: post.id, tag_id: tag.id}, authorize?: false)
  end

  defp document!(site, slug, name, permissions) do
    create_workspace!(
      site_id: site.id,
      skip_version: true,
      status: :active,
      name: name,
      slug: slug,
      language: "en",
      permissions: permissions
    )
  end

  defp version!(site, document) do
    create_workspace_version!(
      site_id: site.id,
      workspace_id: document.id,
      status: :stable,
      version_number: "1.0.0",
      is_latest_for_version: true,
      published_at: ~U[2026-03-01 00:00:00Z]
    )
  end

  defp page!(site, version, slug, title, permissions) do
    create_section!(
      site_id: site.id,
      workspace_version_id: version.id,
      title: title,
      slug: slug,
      content: "<p>#{title}.</p>",
      content_review_status: :approved,
      technical_review_status: :approved,
      permissions: permissions
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
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end
end
