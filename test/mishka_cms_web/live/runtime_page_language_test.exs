# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RuntimePageLanguageTest do
  @moduledoc """
  A database page says which language it is in, and where it is in every other one.

  Two ways to translate a page reach the same place. A literal path per language (`/about`,
  `/fa/about`) is one row per edition, sharing a `language_group_id`; one pattern (`/:lang/about`) is
  one row whose template branches on the language it was asked for. Either way:

    * `<html lang dir>` is the response's language — the captured one on a pattern page — and `rtl`
      for a language written right to left;
    * the head carries a `<link rel="alternate" hreflang>` at the absolute address of each language
      the page answers in, in the order the site lists its languages, and an `x-default` at the
      site's primary language's, while a template reads the same list as `@page_languages`, with
      `@page.language` beside it (`MishkaCmsCore.Runtime.SiteLayout`);
    * a `lang` capture answers only the site's languages, in whichever segment of the pattern it
      sits, so `/xyz/about` is not a page written in `xyz`;
    * the query string cannot hand a template a language the path was refused.

  Every URL a pattern page makes in another language is its own pattern with only the `lang` capture
  swapped, so these tests put the capture first, in the middle and last.

  A marketing page's `<html lang="en">` is pinned byte for byte by `MishkaCmsWeb.RuntimeHeadTest`,
  whose fixture is the whole document up to `</head>`.

  `async: false` — the install flag, `SiteState`, the routing table and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  # A pattern page written in one language answers that one alone; one carrying this mark reads the
  # captured language and answers every one the site has — see `PageProvision.routing_language/1`.
  @every_language %{"serves_all_languages" => true}

  @template ~S"""
  <div>
    <span data-role="language">{@page.language}</span>
    <span data-role="asked">{@query_params["lang"]}</span>
    <a :for={edition <- @page_languages} data-role="edition" hreflang={edition.language} href={edition.path}>
      {edition.language}
    </a>
  </div>
  """

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

    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)

    %{site: site, n: System.unique_integer([:positive])}
  end

  describe "a page with an edition per language" do
    setup %{site: site, n: n} do
      master = published!(site, name: "about-#{n}", path: "/about-#{n}")

      fa =
        published!(site,
          name: "about-#{n}-fa",
          path: "/fa/about-#{n}",
          language: "fa",
          language_group_id: master.id
        )

      published!(site,
        name: "about-#{n}-ar",
        path: "/ar/about-#{n}",
        language: "ar",
        language_group_id: master.id,
        active: false
      )

      %{master: master, fa: fa}
    end

    test "is in its own language, and right to left where that is", %{master: master, fa: fa} do
      assert html_attrs(get_page(master.path)) == {["en"], ["ltr"]}
      assert html_attrs(get_page(fa.path)) == {["fa"], ["rtl"]}
    end

    test "links every active edition from each of them", %{master: master, fa: fa} do
      expected = absolute([{"en", master.path}, {"fa", fa.path}])

      for page <- [master, fa] do
        doc = LazyHTML.from_document(get_page(page.path))

        assert alternates(doc) == expected,
               "#{page.path} did not link its editions, or linked the inactive one"

        assert x_default(doc) == [base() <> master.path],
               "#{page.path} did not name the primary language's edition as x-default"
      end
    end

    test "hands a template its language and its editions", %{master: master, fa: fa} do
      {:ok, view, _html} = live(on_site(), fa.path)
      doc = LazyHTML.from_fragment(render(view))

      assert texts(doc, ~s([data-role="language"])) == ["fa"]
      assert editions(doc) == [{"en", master.path}, {"fa", fa.path}]
    end
  end

  describe "a pattern page" do
    test "is in the language it was asked for, wherever the capture sits", %{site: site, n: n} do
      published!(site, path: "/:lang/guide-#{n}", extra: @every_language)
      published!(site, path: "/docs-#{n}/:lang/:section", extra: @every_language)
      published!(site, path: "/shop-#{n}/:category/:lang", extra: @every_language)

      for {path, language, direction} <- [
            {"/fa/guide-#{n}", "fa", "rtl"},
            {"/docs-#{n}/ar/setup", "ar", "rtl"},
            {"/shop-#{n}/books/en", "en", "ltr"}
          ] do
        html = get_page(path)

        assert html_attrs(html) == {[language], [direction]}, "#{path} is not in #{language}"
        assert texts(LazyHTML.from_document(html), ~s([data-role="language"])) == [language]
      end
    end

    test "links the same page in each of the site's languages", %{site: site, n: n} do
      published!(site, path: "/docs-#{n}/:lang", extra: @every_language)

      doc = LazyHTML.from_document(get_page("/docs-#{n}/fa"))
      expected = for language <- ~w(en fa ar), do: {language, "/docs-#{n}/#{language}"}

      assert alternates(doc) == absolute(expected)
      assert x_default(doc) == ["#{base()}/docs-#{n}/en"]
      assert editions(doc) == expected
    end

    test "offers no language it would have to invent a slug for", %{site: site, n: n} do
      published!(site, path: "/:lang/blog-#{n}/:slug", extra: @every_language)

      doc = LazyHTML.from_document(get_page("/fa/blog-#{n}/an-article"))

      assert alternates(doc) == []
      assert x_default(doc) == []
      assert editions(doc) == []
    end

    test "answers only the site's languages", %{site: site, n: n} do
      published!(site, path: "/:lang/guide-#{n}", extra: @every_language)
      published!(site, path: "/shop-#{n}/:category/:lang", extra: @every_language)

      for path <- ["/xyz/guide-#{n}", "/shop-#{n}/books/xyz", "/FA/guide-#{n}"] do
        assert_raise NotFoundError, fn -> live(on_site(), path) end
      end
    end

    test "leaves the language to the path, whatever the query string says", %{site: site, n: n} do
      published!(site, path: "/:lang/guide-#{n}", extra: @every_language)

      {:ok, view, _html} = live(on_site(), "/fa/guide-#{n}?lang=xyz")
      doc = LazyHTML.from_fragment(render(view))

      assert texts(doc, ~s([data-role="asked"])) == ["fa"]
    end

    test "gives way to a literal edition for its language", %{site: site, n: n} do
      master =
        published!(site, name: "guide-#{n}", path: "/:lang/guide-#{n}", extra: @every_language)

      published!(site,
        name: "guide-#{n}-fa",
        path: "/fa/rahnama-#{n}",
        language: "fa",
        language_group_id: master.id
      )

      doc = LazyHTML.from_document(get_page("/guide-#{n}"))

      assert alternates(doc) ==
               absolute([
                 {"en", "/guide-#{n}"},
                 {"fa", "/fa/rahnama-#{n}"},
                 {"ar", "/ar/guide-#{n}"}
               ])
    end
  end

  # `/:lang/about` WRITTEN IN ENGLISH ANSWERS `/about` AND NOTHING ELSE — the resolver 404s
  # `/fa/about` for it — so neither the head nor a language switcher may offer that address.
  describe "a pattern page written in one language" do
    test "offers no language it does not answer", %{site: site, n: n} do
      published!(site, path: "/:lang/about-#{n}")

      doc = LazyHTML.from_document(get_page("/about-#{n}"))

      assert alternates(doc) == []
      assert editions(doc) == []
      assert_raise NotFoundError, fn -> live(on_site(), "/fa/about-#{n}") end
    end

    test "offers its literal translation, and no language it has none in", %{site: site, n: n} do
      master = published!(site, name: "about-#{n}", path: "/:lang/about-#{n}")

      published!(site,
        name: "about-#{n}-fa",
        path: "/fa/about-#{n}",
        language: "fa",
        language_group_id: master.id
      )

      expected = [{"en", "/about-#{n}"}, {"fa", "/fa/about-#{n}"}]

      for path <- ["/about-#{n}", "/fa/about-#{n}"] do
        doc = LazyHTML.from_document(get_page(path))

        assert alternates(doc) == absolute(expected), "#{path} offered a language nothing answers"
        assert editions(doc) == expected
      end

      assert_raise NotFoundError, fn -> live(on_site(), "/ar/about-#{n}") end
    end
  end

  # ONE STORED PATH, TWO PUBLIC FORMS: the head names each edition at the address the site's URL
  # mode gives it, and `x-default` once, at the primary language's.
  describe "in either URL mode" do
    setup %{site: site, n: n} do
      master =
        published!(site, name: "home-#{n}", path: "/:lang/home-#{n}", extra: @every_language)

      on_exit(fn -> SettingsState.delete(site.id, "site.language_urls") end)
      %{master: master}
    end

    test "the primary language has no prefix by default", %{n: n} do
      for path <- ["/home-#{n}", "/fa/home-#{n}"] do
        doc = LazyHTML.from_document(get_page(path))

        assert alternates(doc) ==
                 absolute([
                   {"en", "/home-#{n}"},
                   {"fa", "/fa/home-#{n}"},
                   {"ar", "/ar/home-#{n}"}
                 ])

        assert x_default(doc) == [base() <> "/home-#{n}"]

        assert editions(doc) == [
                 {"en", "/home-#{n}"},
                 {"fa", "/fa/home-#{n}"},
                 {"ar", "/ar/home-#{n}"}
               ]
      end
    end

    test "every language is prefixed in prefix_all", %{site: site, n: n} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      doc = LazyHTML.from_document(get_page("/fa/home-#{n}"))

      assert alternates(doc) ==
               absolute([
                 {"en", "/en/home-#{n}"},
                 {"fa", "/fa/home-#{n}"},
                 {"ar", "/ar/home-#{n}"}
               ])

      assert x_default(doc) == [base() <> "/en/home-#{n}"]
    end

    test "x-default follows the site's first language", %{site: site, n: n} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en", "ar"], site_id: site.id)

      doc = LazyHTML.from_document(get_page("/en/home-#{n}"))

      assert x_default(doc) == [base() <> "/home-#{n}"]
      assert {"fa", base() <> "/home-#{n}"} in alternates(doc)
    end
  end

  describe "a page in one language" do
    test "has no alternates", %{site: site, n: n} do
      page = published!(site, path: "/alone-#{n}")
      doc = LazyHTML.from_document(get_page(page.path))

      assert alternates(doc) == []
      assert editions(doc) == []
    end
  end

  # A PAGE'S OWN SEO TAGS WIN, as they win over its layout's: an author who wrote an alternate for a
  # language meant that URL, not the edition's.
  describe "a page that names an alternate itself" do
    test "keeps it in place of its edition's", %{site: site, n: n} do
      master =
        published!(site,
          name: "team-#{n}",
          path: "/team-#{n}",
          seo_tags: [
            %{
              tag: "link",
              attrs: %{"rel" => "alternate", "hreflang" => "fa", "href" => "/custom"}
            }
          ]
        )

      published!(site,
        name: "team-#{n}-fa",
        path: "/fa/team-#{n}",
        language: "fa",
        language_group_id: master.id
      )

      doc = LazyHTML.from_document(get_page(master.path))

      assert alternates(doc) == [{"en", base() <> master.path}, {"fa", base() <> "/custom"}]
    end
  end

  # EVERY PAGE IS IN A GROUP, if only its own, so a query for its editions would run for every page
  # there is. `MishkaCmsCore.Runtime.PageEditions.editions/2` reads them from `SiteState` instead,
  # which every write of a page keeps: the HTTP render, the connect and a patch ask the database for
  # none of them.
  describe "reading a page's editions" do
    test "is no query, for the render of a page or a patch to it", %{site: site, n: n} do
      page = published!(site, path: "/counted-#{n}")
      reads = count_edition_reads()

      conn = get(on_site(), page.path)
      assert reads.() == 0, "the HTTP render read the page's editions from the database"

      {:ok, view, _html} = live(conn)
      assert reads.() == 0, "the connect read the page's editions from the database"

      render_patch(view, page.path <> "?tab=2")
      assert reads.() == 0, "a patch to the same page read its editions from the database"
    end
  end

  describe "the site's language list" do
    test "is English alone when it cannot be read", %{site: site, n: n} do
      {:ok, _} = Settings.put("site.languages", "en, fa", site_id: site.id)
      published!(site, path: "/:lang/notes-#{n}", extra: @every_language)

      assert html_attrs(get_page("/notes-#{n}")) == {["en"], ["ltr"]}
      assert_raise NotFoundError, fn -> live(on_site(), "/fa/notes-#{n}") end
    end
  end

  # The routing row the compile worker writes, language included: without it every pattern page
  # answered every language, which no published page does.
  defp published!(site, overrides) do
    page = create_page!([site_id: site.id, template: @template] ++ overrides)

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0,
        language: PageProvision.routing_language(page)
      })

    page
  end

  # Counts, from here on, the reads of a page group's editions — a query on `pages` FILTERED by
  # `language_group_id`, which is not the same as one naming the column: a compile's read of the page
  # selects it too — wherever they run. Each call answers how many arrived since the last.
  defp count_edition_reads do
    test = self()
    handler = "edition-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mishka_cms, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if source == "pages" and query =~ ~r/WHERE \(p0\."language_group_id"/,
          do: send(test, {handler, :read})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fn -> drain(handler, 0) end
  end

  defp drain(handler, count) do
    receive do
      {^handler, :read} -> drain(handler, count + 1)
    after
      0 -> count
    end
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp get_page(path), do: on_site() |> get(path) |> html_response(200)

  defp html_attrs(html) do
    root = html |> LazyHTML.from_document() |> LazyHTML.query("html")
    {LazyHTML.attribute(root, "lang"), LazyHTML.attribute(root, "dir")}
  end

  defp alternates(doc) do
    doc
    |> LazyHTML.query(~s|head link[rel="alternate"]:not([hreflang="x-default"])|)
    |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})
  end

  defp x_default(doc),
    do: LazyHTML.attribute(LazyHTML.query(doc, ~s(head link[hreflang="x-default"])), "href")

  defp absolute(editions),
    do: Enum.map(editions, fn {language, path} -> {language, base() <> path} end)

  # The site's address, which every alternate in the head is written on — the sitemap's.
  defp base, do: MishkaCmsCore.Helpers.site_url("localhost", "")

  defp editions(doc) do
    doc
    |> LazyHTML.query(~s([data-role="edition"]))
    |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})
  end

  defp texts(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
end
