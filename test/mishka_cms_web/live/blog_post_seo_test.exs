# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogPostSeoTest do
  @moduledoc """
  The head of the blog's provisioned post page, `/:lang/blog/:slug`, as a crawler reads it: the
  post's own title, description, image, authors and JSON-LD, put there by
  `MishkaBlog.Plugins.PageSeo` on `runtime:page:seo`.

  Here rather than in the blog's own suite because only this application has the router, the
  runtime LiveView and the root layout that renders the head.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  plugin registry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory
  import MishkaBlog.Dev.Generator, only: [blogger: 2, post_blogger: 1, post_collection: 1]
  import Ash.Generator, only: [generate: 1]

  alias MishkaBlog.Plugins.PageSeo
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.{Seo, ShareCard}
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @moduletag :integration

  # A unique site name per test: a component's module is named from its site's name, so a reused one
  # renders the previous test's module against a site that test rolled back.
  setup %{url_mode: url_mode} do
    SiteState.clear()
    name = "blogseo#{System.unique_integer([:positive])}"
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
    {:ok, _} = Settings.put("site.language_urls", url_mode, site_id: site.id)
    {:ok, _} = Settings.put("site.title", "The Studio", site_id: site.id)

    # The extension registers the plugin as it starts; registering it again keeps the one record, and
    # compiling the event here is what makes the chain hold it before the first request.
    {:ok, _registered} = PageSeo.register()
    :ok = EventHandler.do_compile(Seo.event(), :start, false)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SettingsState.delete(site.id, "site.title")
      SiteState.clear()
    end)

    Provision.ensure!(site)
    register_routes!(site)

    %{site: site, conn: on_site(site)}
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

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp attr(doc, selector, name), do: LazyHTML.attribute(LazyHTML.query(doc, selector), name)

  defp json_ld(doc) do
    doc
    |> LazyHTML.query(~s(script[type="application/ld+json"]))
    |> Enum.map(&Jason.decode!(LazyHTML.text(&1)))
  end

  # A published post with an author and a category.
  defp post!(site, overrides \\ []) do
    post =
      create_blog_post!(
        [
          site_id: site.id,
          title: "Ash in production",
          excerpt: "What a year of Ash taught us.",
          featured_image_url: "/media/cover.png",
          status: :published,
          published_at: ~U[2026-09-01 08:30:00Z]
        ] ++ overrides
      )

    user = create_user!(site_id: site.id)
    author = [user_id: user.id, display_name: "Shahryar"] |> blogger(site.id) |> generate()
    [post_id: post.id, blogger_id: author.id] |> post_blogger() |> generate()

    category = create_collection!(site_id: site.id, status: :active, name: "Engineering")
    [post_id: post.id, collection_id: category.id] |> post_collection() |> generate()

    post
  end

  test "a post's address is answered with the post's own head", %{
    url_mode: url_mode,
    site: site,
    conn: conn
  } do
    post = post!(site)
    base = Seo.base(site.host)
    url = base <> english(url_mode, "/blog/#{post.slug}")

    doc =
      conn
      |> get(english(url_mode, "/blog/#{post.slug}"))
      |> html_response(200)
      |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() ==
             "Ash in production"

    assert attr(doc, ~s(link[rel="canonical"]), "href") == [url]
    assert attr(doc, ~s(meta[property="og:type"]), "content") == ["article"]
    assert attr(doc, ~s(meta[property="og:title"]), "content") == ["Ash in production"]
    assert attr(doc, ~s(meta[name="description"]), "content") == ["What a year of Ash taught us."]
    assert attr(doc, ~s(meta[property="og:image"]), "content") == [base <> "/media/cover.png"]
    assert attr(doc, ~s(meta[name="twitter:card"]), "content") == ["summary_large_image"]
    assert attr(doc, ~s(meta[name="author"]), "content") == ["Shahryar"]

    assert attr(doc, ~s(meta[property="article:published_time"]), "content") == [
             "2026-09-01T08:30:00Z"
           ]

    assert attr(doc, ~s(meta[property="article:section"]), "content") == ["Engineering"]

    schema = json_ld(doc)

    assert %{
             "headline" => "Ash in production",
             "author" => [%{"@type" => "Person", "name" => "Shahryar"}],
             "publisher" => %{"@id" => org_id},
             "mainEntityOfPage" => ^url
           } = Enum.find(schema, &(&1["@type"] == "BlogPosting"))

    assert String.ends_with?(org_id, "/#organization")

    assert %{"@id" => ^org_id, "name" => "The Studio"} =
             Enum.find(schema, &(&1["@type"] == "Organization"))

    assert %{"itemListElement" => [_home, _blog, %{"item" => ^url}]} =
             Enum.find(schema, &(&1["@type"] == "BreadcrumbList"))

    refute Enum.any?(schema, &(&1["@type"] == "WebPage"))
  end

  test "a card drawn after the post's save is in its head on the first visit", %{
    url_mode: url_mode,
    site: site,
    conn: conn
  } do
    dir = Path.join(System.tmp_dir!(), "post_cards_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    post = post!(site)
    target = MishkaBlog.ShareCards.target(post)
    :ok = ShareCard.refresh(site.id, target)

    [look] =
      all_enqueued(worker: ShareCardRefreshWorker, args: %{target: %{"record" => "blog:post"}})

    :ok = perform_job(ShareCardRefreshWorker, look.args)
    assert [draw] = all_enqueued(worker: ShareCard)
    assert draw.args["card"]["eyebrow"] == "Engineering"
    assert [%{"name" => "Shahryar"}] = draw.args["card"]["people"]
    :ok = perform_job(ShareCard, draw.args)

    doc =
      conn
      |> get(english(url_mode, "/blog/#{post.slug}"))
      |> html_response(200)
      |> LazyHTML.from_document()

    assert attr(doc, ~s(meta[property="og:image"]), "content") ==
             [Seo.base(site.host) <> ShareCard.url(site.id, draw.args["key"])]

    assert all_enqueued(worker: ShareCard) == [draw]
  end

  test "what the post page sets wins over the post's own, and names the post's variables", %{
    url_mode: url_mode,
    site: site,
    conn: conn
  } do
    post =
      post!(site,
        seo_tags: [
          %{
            tag: "meta",
            attrs: %{"property" => "og:title"},
            content: "The post's own share title"
          },
          %{tag: "meta", attrs: %{"name" => "description"}, content: "The post's own description"}
        ]
      )

    base = Seo.base(site.host)

    {:ok, page} =
      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site.id and path == ^Provision.item_paths().post)
      |> Ash.read_one()

    page
    |> Ash.Changeset.for_update(
      :master_update,
      %{
        description: "{{post.excerpt}} By {{post.author}}.",
        seo_tags: [
          %{tag: "title", attrs: %{}, content: "{{post.title}} | {{site.name}}"},
          %{tag: "meta", attrs: %{"name" => "author"}, content: "The {{site.name}} team"}
        ],
        schema: [%{"@type" => "Article", "headline" => "{{post.title}}"}]
      },
      authorize?: false
    )
    |> Ash.update!()

    doc =
      conn
      |> get(english(url_mode, "/blog/#{post.slug}"))
      |> html_response(200)
      |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() ==
             "Ash in production | The Studio"

    assert attr(doc, ~s(meta[property="og:title"]), "content") == [
             "Ash in production | The Studio"
           ]

    assert attr(doc, ~s(meta[name="description"]), "content") == [
             "What a year of Ash taught us. By Shahryar."
           ]

    assert attr(doc, ~s(meta[name="author"]), "content") == ["The The Studio team"]
    assert attr(doc, ~s(meta[property="og:image"]), "content") == [base <> "/media/cover.png"]
    assert [%{"@type" => "Article", "headline" => "Ash in production"}] = json_ld(doc)

    {:ok, view, _html} = live(conn, english(url_mode, "/blog/#{post.slug}"))
    assert page_title(view) == "Ash in production | The Studio"
  end

  test "a live visit is titled by the post", %{url_mode: url_mode, site: site, conn: conn} do
    post = post!(site)

    {:ok, view, _html} = live(conn, english(url_mode, "/blog/#{post.slug}"))
    assert page_title(view) == "Ash in production"
  end

  test "another blog page keeps its own head", %{url_mode: url_mode, conn: conn} do
    doc =
      conn |> get(english(url_mode, "/blog")) |> html_response(200) |> LazyHTML.from_document()

    assert attr(doc, ~s(meta[property="og:type"]), "content") == ["website"]

    assert [%{"@type" => "WebPage"}, %{"@type" => "WebSite"}, %{"@type" => "Organization"}] =
             json_ld(doc)
  end
end
