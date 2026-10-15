defmodule MishkaCmsWeb.RuntimeHeadTest do
  @moduledoc """
  A database page's title, SEO tags and schema reach `<head>`, and a marketing page's head does not
  move by a byte.

  `Page.seo_tags`, `Page.schema` and `Layout.seo_tags` were stored and compiled into every page
  module, and nothing rendered them: `RuntimeLive` assigned no `:page_title` and no template wrote a
  tag, so a crawler read every database page as "MishkaCms · Phoenix Framework".

  The fix is in `root.html.heex`, which the marketing LiveViews share and whose output for them is
  kept exactly as it is. So their head is pinned against `fixtures/static_page_head.html`, a copy
  taken before the change, byte for byte — a blank line fails it. Only four values are masked: the
  session's CSRF token and CSP nonce, the site's JS bundle hash and the page's own title, which is
  masked only where it is the LiveView's `:page_title` — a tab reading anything else fails it too. A
  marketing head that is meant to change takes a new fixture in the same commit.

  The marketing pages are read from the router, not listed: they are the LiveViews routed outside
  every `live_session`, less the one that draws database components — see
  `@draws_database_components`.

  A database page's head is `MishkaCmsCore.Runtime.Seo`'s, resolved in `handle_params/3`: the
  default tags with nothing filled in and with the page's fields filled in, a stored tag replacing a
  default, a page that needs a permission kept out of an index, the default `WebPage` JSON-LD against
  a stored schema, and a plugin on `runtime:page:seo` setting a record's own head.

  `async: false` — the install flag, `SiteState`, the settings cache, the plugin registry and the
  routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  # A plugin that gives each record of `/:lang/record-…/:slug` its own head.
  defmodule RecordSeo do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:seo"

    @impl true
    def call(%{params: %{"slug" => slug}, page: %{path: "/:lang/record-" <> _}} = seo) do
      {:reply,
       %{
         seo
         | title: "Record #{slug}",
           description: "All about #{slug}.",
           image: "/uploads/#{slug}.png",
           type: "article",
           vars: %{"record.slug" => slug},
           var_docs: [%{key: "record.slug", label: "Record slug"}],
           tags: [%{tag: "meta", attrs: %{"name" => "author"}, content: "Plugin"}]
       }}
    end

    def call(seo), do: {:reply, seo}
  end

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

    snapshot = SettingsState.snapshot()
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
    end)

    Settings.put("cms.offline", false)
    {:ok, _} = Settings.put("site.title", "The Studio", site_id: site.id)
    # The addresses below name every language, English included.
    {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

    %{site: site}
  end

  describe "a database page's head" do
    setup %{site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          path: "/layouts/head-#{System.unique_integer([:positive])}",
          template: ~S(<div><main>{@inner_content}</main></div>),
          seo_tags: [
            meta("description", "The layout's description"),
            %{tag: "meta", attrs: %{"property" => "og:site_name"}, content: "Layout Site"},
            %{tag: "link", attrs: %{"rel" => "canonical", "href" => "/layout-canonical"}}
          ]
        )

      :ok = WebRunTimeMetaDataState.save(route(layout, site, "Layout"))

      page =
        published!(site,
          name: "About the studio",
          title: "About the studio",
          layout_id: layout.id,
          seo_tags: [
            meta("description", ~s(The page's "own" <description>)),
            %{tag: "meta", attrs: %{"property" => "og:image"}, content: "/images/about.png"},
            %{tag: "link", attrs: %{"rel" => "canonical", "href" => "/en/about"}},
            %{
              tag: "link",
              attrs: %{"rel" => "alternate", "hreflang" => "fa", "href" => "/fa/about"}
            },
            %{tag: "script", attrs: %{"src" => "/evil.js"}, content: "alert(1)"},
            %{
              tag: "meta",
              attrs: %{
                "name" => "robots",
                "onload" => "alert(1)",
                "data-x onclick" => "alert(2)"
              },
              content: "index"
            }
          ],
          schema: [
            %{
              "@context" => "https://schema.org",
              "@type" => "AboutPage",
              "name" => "</script><script>alert(3)</script><!--"
            }
          ]
        )

      %{page: page}
    end

    # A PAGE'S TITLE IS ITS `title`, WHICH IS NEVER SLUGIFIED — the page created as "About the
    # studio" is titled that, while its `name` beside it is stored as "about-the-studio". The two
    # are asserted together here because the whole point of the field is that they differ.
    test "is titled by the page alone", %{page: page} do
      title = LazyHTML.query(LazyHTML.from_document(get_page(page.path)), "title")

      assert String.trim(LazyHTML.text(title)) == "About the studio"
      assert page.name == "about-the-studio"
      assert LazyHTML.attribute(title, "data-suffix") == []
    end

    test "renders the page's tags, and the layout's where the page has none", %{page: page} do
      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[name="description"]), "content") == [
               ~s(The page's "own" <description>)
             ]

      # A stored address that is a path is written on the site's https address.
      assert attr(doc, ~s(meta[property="og:image"]), "content") == [
               base() <> "/images/about.png"
             ]

      assert attr(doc, ~s(meta[property="og:site_name"]), "content") == ["Layout Site"]
      assert attr(doc, ~s(link[rel="canonical"]), "href") == [base() <> "/en/about"]

      assert attr(doc, ~s(link[rel="alternate"][hreflang="fa"]), "href") == [
               base() <> "/fa/about"
             ]

      assert attr(doc, ~s(meta[name="robots"]), "content") == ["index"]
    end

    test "renders no tag but a meta or a link, and no event handler", %{page: page} do
      doc = LazyHTML.from_document(get_page(page.path))

      assert Enum.empty?(LazyHTML.query(doc, ~s(script[src="/evil.js"])))
      assert Enum.empty?(LazyHTML.query(doc, "[onload]"))
      assert Enum.empty?(LazyHTML.query(doc, "[onclick]"))
    end

    test "renders the schema as JSON-LD that no value can close", %{page: page} do
      doc = LazyHTML.from_document(get_page(page.path))
      schema = LazyHTML.query(doc, ~s(script[type="application/ld+json"]))

      assert [nonce] = LazyHTML.attribute(schema, "nonce"),
             "the stored schema did not replace the default WebPage"

      assert nonce != ""

      assert %{"@type" => "AboutPage", "name" => "</script><script>alert(3)</script><!--"} =
               Jason.decode!(LazyHTML.text(schema))

      refute Enum.any?(LazyHTML.query(doc, "script"), &(LazyHTML.text(&1) == "alert(3)")),
             "a schema value closed its script element and opened one of its own"
    end

    test "follows a live navigation to another page's title", %{site: site, page: page} do
      other = published!(site, name: "Contact the studio", title: "Contact the studio")

      {:ok, view, _html} = live(on_site(), page.path)
      assert page_title(view) == "About the studio"

      render_patch(view, other.path)
      assert page_title(view) == "Contact the studio"
    end

    # The layout is stored but not routed, so it can be neither found nor compiled.
    @tag :capture_log
    test "leaves out a layout it cannot find, and keeps its own tags", %{site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          path: "/layouts/unrouted-#{System.unique_integer([:positive])}",
          template: ~S(<div>{@inner_content}</div>),
          seo_tags: [%{tag: "meta", attrs: %{"property" => "og:site_name"}, content: "Layout"}]
        )

      page =
        published!(site,
          layout_id: layout.id,
          description: nil,
          seo_tags: [meta("description", "own")]
        )

      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[name="description"]), "content") == ["own"]
      assert attr(doc, ~s(meta[property="og:site_name"]), "content") == ["The Studio"]
    end

    test "renders a number or a flag, and leaves out a value with no attribute form", %{
      site: site
    } do
      link = %{
        tag: "link",
        attrs: %{
          "rel" => "preload",
          "href" => "/font.woff2",
          "crossorigin" => true,
          "data-weight" => 400,
          "media" => %{"min-width" => "40rem"}
        }
      }

      page = published!(site, seo_tags: [link])
      doc = LazyHTML.from_document(get_page(page.path))

      preload = LazyHTML.query(doc, ~s(link[rel="preload"]))

      assert LazyHTML.attribute(preload, "crossorigin") == [""]
      assert LazyHTML.attribute(preload, "data-weight") == ["400"]
      assert LazyHTML.attribute(preload, "media") == []
    end
  end

  describe "a database page's default head" do
    test "with nothing filled in, holds every default that has a value", %{site: site} do
      page = published!(site, title: "Plain page", description: nil)
      doc = LazyHTML.from_document(get_page(page.path))
      site_url = base()
      url = site_url <> page.path

      assert attr(doc, ~s(link[rel="canonical"]), "href") == [url]

      assert attr(doc, ~s(meta[name="robots"]), "content") == [
               "index, follow, max-image-preview:large"
             ]

      assert attr(doc, ~s(meta[property="og:type"]), "content") == ["website"]
      assert attr(doc, ~s(meta[property="og:title"]), "content") == ["Plain page"]
      assert attr(doc, ~s(meta[property="og:url"]), "content") == [url]
      assert attr(doc, ~s(meta[property="og:site_name"]), "content") == ["The Studio"]
      assert attr(doc, ~s(meta[property="og:locale"]), "content") == ["en_US"]
      assert attr(doc, ~s(meta[name="twitter:card"]), "content") == ["summary"]
      assert attr(doc, ~s(meta[name="twitter:title"]), "content") == ["Plain page"]

      for absent <- ~w(meta[name="description"] meta[property="og:description"]
                       meta[property="og:image"] meta[name="twitter:image"] link[rel="alternate"]) do
        assert Enum.empty?(LazyHTML.query(doc, absent)), "#{absent} was emitted with no value"
      end

      website = site_url <> "/#website"
      organization = site_url <> "/#organization"

      assert [
               %{
                 "@context" => "https://schema.org",
                 "@type" => "WebPage",
                 "name" => "Plain page",
                 "url" => ^url,
                 "inLanguage" => "en",
                 "isPartOf" => %{"@id" => ^website}
               } = web_page,
               %{
                 "@type" => "WebSite",
                 "@id" => ^website,
                 "name" => "The Studio",
                 "url" => ^site_url,
                 "publisher" => %{"@id" => ^organization}
               },
               %{
                 "@type" => "Organization",
                 "@id" => ^organization,
                 "name" => "The Studio",
                 "url" => ^site_url
               }
             ] = json_ld(doc)

      refute Map.has_key?(web_page, "description")
    end

    test "with its fields filled in, carries them into every tag that reads them", %{site: site} do
      page =
        published!(site,
          title: "About the studio",
          description: "What the studio does.",
          seo_tags: [%{tag: "meta", attrs: %{"property" => "og:image"}, content: "/img/a.png"}]
        )

      doc = LazyHTML.from_document(get_page(page.path))
      image = base() <> "/img/a.png"

      for selector <- ~w(meta[name="description"] meta[property="og:description"]
                         meta[name="twitter:description"]) do
        assert attr(doc, selector, "content") == ["What the studio does."], selector
      end

      assert attr(doc, ~s(meta[property="og:image"]), "content") == [image]
      assert attr(doc, ~s(meta[name="twitter:image"]), "content") == [image]
      assert attr(doc, ~s(meta[property="og:image:alt"]), "content") == ["About the studio"]
      assert attr(doc, ~s(meta[name="twitter:card"]), "content") == ["summary_large_image"]

      assert [%{"description" => "What the studio does.", "image" => ^image}, _site, _publisher] =
               json_ld(doc)
    end

    test "gives way to a stored tag with the same name", %{site: site} do
      page =
        published!(site,
          title: "About the studio",
          seo_tags: [%{tag: "meta", attrs: %{"property" => "og:title"}, content: "Custom"}]
        )

      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[property="og:title"]), "content") == ["Custom"]
      assert attr(doc, ~s(meta[name="twitter:title"]), "content") == ["About the studio"]
    end

    test "fills a variable in a stored tag", %{site: site} do
      page =
        published!(site,
          title: "About the studio",
          seo_tags: [
            %{
              tag: "meta",
              attrs: %{"property" => "og:title"},
              content: "{{page.title}} | {{site.name}}"
            },
            %{tag: "meta", attrs: %{"name" => "author"}, content: "{{post.author}}"}
          ]
        )

      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[property="og:title"]), "content") == [
               "About the studio | The Studio"
             ]

      assert Enum.empty?(LazyHTML.query(doc, ~s(meta[name="author"])))
    end

    test "is canonical at the address a pattern page was asked at", %{site: site} do
      n = System.unique_integer([:positive])
      published!(site, path: "/:lang/guide-#{n}/:slug")

      doc = LazyHTML.from_document(get_page("/en/guide-#{n}/an-article/?tab=2"))

      assert attr(doc, ~s(link[rel="canonical"]), "href") == [
               "#{base()}/en/guide-#{n}/an-article"
             ]
    end

    # The sitemap and robots.txt name the site on the endpoint's scheme and port, and so does this.
    test "is on the address the sitemap writes", %{site: site} do
      page = published!(site, title: "Plain page")
      doc = LazyHTML.from_document(get_page(page.path))
      url = MishkaCmsCore.Helpers.site_url(site.host, page.path)

      assert attr(doc, ~s(link[rel="canonical"]), "href") == [url]
      assert attr(doc, ~s(meta[property="og:url"]), "content") == [url]
    end

    test "keeps a sign-in page out of an index", %{site: site} do
      for extra <- [%{"visitors_only" => true}, %{"auth_role" => "sign_in"}] do
        page = published!(site, extra: extra)
        doc = LazyHTML.from_document(get_page(page.path))

        assert attr(doc, ~s(meta[name="robots"]), "content") == ["noindex, nofollow"],
               inspect(extra)
      end
    end

    test "lets a sign-in page's stored robots tag decide", %{site: site} do
      page =
        published!(site,
          extra: %{"auth_role" => "sign_in", "visitors_only" => true},
          seo_tags: [meta("robots", "index, follow")]
        )

      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[name="robots"]), "content") == ["index, follow"]
    end

    test "keeps a page that needs a permission out of an index", %{site: site} do
      page = published!(site, permissions: ["members:read"])

      html = site |> signed_in(["members:read"]) |> get(page.path) |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert attr(doc, ~s(meta[name="robots"]), "content") == ["noindex, nofollow"]
    end
  end

  # `RuntimeLive` asks for it (`Seo.resolve(card: true)`); `MishkaCmsCore.Runtime.ShareCard` draws it
  # in its job, never in the request.
  describe "a database page's share card" do
    setup do
      dir = Path.join(System.tmp_dir!(), "head_cards_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)
    end

    test "is queued by the first visit and shown once drawn", %{site: site} do
      page = published!(site, title: "Shared page", description: "Worth a link.")

      doc = LazyHTML.from_document(get_page(page.path))
      assert Enum.empty?(LazyHTML.query(doc, ~s(meta[property="og:image"])))
      assert [job] = all_enqueued(worker: ShareCard)
      assert job.args["card"]["title"] == "Shared page"
      assert job.args["card"]["site"] == "The Studio"

      :ok = perform_job(ShareCard, job.args)
      doc = LazyHTML.from_document(get_page(page.path))
      card = base() <> ShareCard.url(site.id, job.args["key"])

      assert attr(doc, ~s(meta[property="og:image"]), "content") == [card]
      assert attr(doc, ~s(meta[property="og:image:width"]), "content") == ["1200"]
      assert attr(doc, ~s(meta[property="og:image:height"]), "content") == ["630"]
      assert attr(doc, ~s(meta[name="twitter:card"]), "content") == ["summary_large_image"]
      assert attr(doc, ~s(meta[name="twitter:image"]), "content") == [card]
    end

    test "drawn after the page's save, is in its head on the first visit", %{site: site} do
      page = published!(site, title: "Saved page", description: "Ready before anyone looks.")

      :ok = ShareCard.refresh(site.id, {:page, page.id})

      [look] =
        all_enqueued(worker: ShareCardRefreshWorker, args: %{target: %{"page" => page.id}})

      :ok = perform_job(ShareCardRefreshWorker, look.args)
      assert [draw] = all_enqueued(worker: ShareCard)
      :ok = perform_job(ShareCard, draw.args)

      doc = LazyHTML.from_document(get_page(page.path))

      assert attr(doc, ~s(meta[property="og:image"]), "content") ==
               [base() <> ShareCard.url(site.id, draw.args["key"])]

      assert all_enqueued(worker: ShareCard) == [draw]
    end

    test "is not asked for a page that needs a permission", %{site: site} do
      page = published!(site, permissions: ["members:read"])

      site |> signed_in(["members:read"]) |> get(page.path) |> html_response(200)

      assert all_enqueued(worker: ShareCard) == []
    end
  end

  describe "a plugin on runtime:page:seo" do
    setup do
      register_plugin(RecordSeo, "runtime:page:seo")
    end

    test "gives each record of a pattern page its own head", %{site: site} do
      n = System.unique_integer([:positive])

      published!(site,
        path: "/:lang/record-#{n}/:slug",
        title: "Record",
        description: nil,
        seo_tags: [
          %{tag: "meta", attrs: %{"name" => "author"}, content: "Page"},
          %{tag: "meta", attrs: %{"name" => "keywords"}, content: "{{record.slug}}, records"}
        ]
      )

      path = "/en/record-#{n}/first"
      doc = LazyHTML.from_document(get_page(path))
      image = base() <> "/uploads/first.png"

      assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() == "Record first"
      assert attr(doc, ~s(meta[property="og:title"]), "content") == ["Record first"]
      assert attr(doc, ~s(meta[name="description"]), "content") == ["All about first."]
      assert attr(doc, ~s(meta[property="og:type"]), "content") == ["article"]
      assert attr(doc, ~s(meta[property="og:image"]), "content") == [image]
      assert attr(doc, ~s(meta[name="twitter:card"]), "content") == ["summary_large_image"]
      # The plugin's are defaults: a tag the page stores wins.
      assert attr(doc, ~s(meta[name="author"]), "content") == ["Page"]
      assert attr(doc, ~s(meta[name="keywords"]), "content") == ["first, records"]
      assert attr(doc, ~s(link[rel="canonical"]), "href") == [base() <> path]

      assert [
               %{"@type" => "WebPage", "name" => "Record first", "image" => ^image},
               %{"@type" => "WebSite"},
               %{"@type" => "Organization"}
             ] = json_ld(doc)
    end

    test "is asked again on a live patch to another record", %{site: site} do
      n = System.unique_integer([:positive])
      published!(site, path: "/:lang/record-#{n}/:slug", title: "Record")

      {:ok, view, _html} = live(on_site(), "/en/record-#{n}/first")
      assert page_title(view) == "Record first"

      render_patch(view, "/en/record-#{n}/second")
      assert page_title(view) == "Record second"
    end
  end

  defp published!(site, overrides) do
    page =
      create_page!(
        [
          site_id: site.id,
          path: "/en/head-#{System.unique_integer([:positive])}",
          template: ~S(<div><p>page</p></div>)
        ] ++ overrides
      )

    :ok = WebRunTimeMetaDataState.save(route(page, site, "Page"))
    page
  end

  # A ROW IS NOT YET A ROUTE: boot fills `WebRunTimeMetaDataState`, and a test fills it itself.
  defp route(record, site, section) do
    %{
      id: record.id,
      site: site.name,
      path: record.path,
      title: record.name,
      created_at: DateTime.utc_now(),
      section: section,
      priority: 0
    }
  end

  defp meta(name, content), do: %{tag: "meta", attrs: %{"name" => name}, content: content}

  defp attr(doc, selector, name), do: LazyHTML.attribute(LazyHTML.query(doc, selector), name)

  defp json_ld(doc) do
    doc
    |> LazyHTML.query(~s(script[type="application/ld+json"]))
    |> Enum.map(&Jason.decode!(LazyHTML.text(&1)))
  end

  defp register_plugin(module, event) do
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

    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp get_page(path), do: on_site() |> get(path) |> html_response(200)

  defp base, do: MishkaCmsCore.Helpers.site_url("localhost", "")
end
