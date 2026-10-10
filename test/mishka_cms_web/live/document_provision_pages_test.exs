defmodule MishkaCmsWeb.DocumentProvisionPagesTest do
  @moduledoc """
  The pages `MishkaDocument.Provision` creates, visited the way a reader visits them.

  Here rather than in the extension's own suite because it takes both halves at once: the
  extension's components and sample pages, and this application's router, site resolution and
  runtime compilers. `MishkaDocument.ProvisionTest` asserts which rows are written and which are
  left alone; this asserts that what was written is documentation somebody can read.

  ## What is actually at risk

  A sample page is markup in a string in an Elixir module. It compiles at creation — `Page
  :master_create` runs `Validations.PageCodeCompiles` — so a syntax error fails long before here.
  What does not show up until a real request is everything about the ASSIGNS, and everything about
  the four blocks AGREEING: a template reading `@current_user` on a page nobody is signed into, an
  attribute a component does not declare, a pager writing the page's own pattern into a URL, a table
  of contents whose anchors name ids the page beside it never drew. Each of those is a page that
  renders as the runtime's red refusal box, or renders wrongly, and every one of them is invisible
  to a test that only counts rows.

  `async: false` — the install flag, `SiteState`, the routing table and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory
  import MishkaDocument.Dev.Generator, only: [note: 2]
  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.Snippet
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Provision

  require Ash.Query

  @moduletag :integration

  # EVERY READ OF A RENDERED PAGE WAITS FOR THE BLOCKS ON IT, because most of them now read in the
  # background: a connected socket takes the `start_async/3` branch, so the first render is the
  # skeleton and the rows arrive in the message after it. `render_async/2` waits on the tasks
  # themselves — it is not a sleep, and a block that never starts one is answered immediately.
  @async 5_000

  # A UNIQUE SITE NAME PER TEST, for the reason `MishkaDocument.LiveComponentsRenderTest` gives: a
  # component's module is named from a hash of its own name and its SITE's, and carries that site's
  # id — so a reused name renders the previous test's module against a site that test rolled back,
  # and every list comes back empty with nothing to say why.
  setup %{url_mode: url_mode} do
    SiteState.clear()
    name = "docpages#{System.unique_integer([:positive])}"
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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SiteState.clear()
    end)

    %{site: site, conn: on_site(site)}
  end

  # Provisioning writes rows; the routing table is what a request is matched against, and only a
  # running CMS keeps the two in step. Every provisioned page is registered here, so the URLs below
  # are the URLs a reader would have.
  defp provision!(site) do
    Provision.ensure!(site)
    register_routes!(site)
  end

  defp register_routes!(site) do
    for page <- pages(site) do
      :ok =
        WebRunTimeMetaDataState.save(%{
          id: page.id,
          site: site.name,
          path: page.path,
          title: page.name,
          created_at: DateTime.utc_now(),
          # The routing table's own kind — Page, Layout, ErrorPage — not the page's `section`
          # attribute, which is "document" on every one of these.
          section: "Page",
          priority: 0
        })
    end

    :ok
  end

  # THE SNIPPET AS IT WAS SAVED, read back rather than repeated here — it is what an author is
  # offered in the page editor, and a copy in this file would go on passing after the real one
  # changed.
  defp snippet_source(site) do
    name = Provision.snippet_name()

    Snippet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and name == ^name and is_nil(document_id))
    |> Ash.read!(page: [limit: 10])
    |> then(& &1.results)
    |> hd()
    |> Map.fetch!(:source)
  end

  defp pages(site) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
  end

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp texts(html, selector),
    do:
      html
      |> doc()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp attributes(html, selector, name),
    do:
      html
      |> doc()
      |> LazyHTML.query(selector)
      |> Enum.flat_map(&LazyHTML.attribute(&1, name))

  # Every `href` and `src` on the page whose path still holds a `:capture` segment. Split on `/`
  # first, so a scheme keeps its colon — `https://x` and `mailto:a@b` hold no capture — and only a
  # segment that BEGINS with one is a name the runtime was supposed to fill in.
  defp captures_left(html) do
    document = doc(html)

    for attribute <- ~w(href src),
        element <- LazyHTML.query(document, "[#{attribute}]"),
        value <- LazyHTML.attribute(element, attribute),
        Enum.any?(String.split(value, "/"), &String.starts_with?(&1, ":")),
        uniq: true,
        do: value
  end

  # The links the BLOCKS drew, which is every one carrying a `data-role`: the chrome around them is
  # hand-written markup in `MishkaDocument.Provision` and tags none of its own.
  defp block_links(html) do
    html
    |> doc()
    |> LazyHTML.query("a[data-role]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))
  end

  # Every way a page can fail to draw a component, in one assertion: the runtime's refusal box, the
  # canvas's error marker, and the placeholder a missing component falls back to.
  defp assert_drew!(html, path) do
    refute html =~ "failed to render",
           "#{path} drew the runtime's placeholder instead of a component"

    refute html =~ "data-render-error", "#{path} drew a refusal instead of a component"
    html
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp document!(site, overrides) do
    create_workspace!(
      Keyword.merge(
        [site_id: site.id, status: :active, language: "en", skip_version: true],
        overrides
      )
    )
  end

  defp version!(site, document, overrides) do
    create_workspace_version!(
      Keyword.merge(
        [
          site_id: site.id,
          workspace_id: document.id,
          status: :stable,
          is_latest_for_version: true,
          published_at: ~U[2026-01-01 00:00:00Z]
        ],
        overrides
      )
    )
  end

  defp section!(site, version, overrides) do
    create_section!(
      Keyword.merge(
        [
          site_id: site.id,
          workspace_version_id: version.id,
          content_review_status: :approved,
          technical_review_status: :approved,
          language: "en",
          content: "<p>Body</p>"
        ],
        overrides
      )
    )
  end

  # One document with a published version and three pages in reading order — what most of the cases
  # below want. "Appendix" is last and sorts first on purpose, so a block ignoring `order_position`
  # cannot pass an ordering assertion by accident.
  defp manual!(site) do
    document =
      document!(site, name: "Mishka CMS", slug: "mishka-cms", description: "The manual.")

    version = version!(site, document, version_number: "1.0.0")

    sections =
      for {title, slug, order} <- [
            {"Getting started", "getting-started", 0},
            {"Installation", "installation", 1},
            {"Appendix", "appendix", 2}
          ] do
        section!(site, version,
          title: title,
          slug: slug,
          order_position: order,
          content: "<h2>#{title}</h2><p>Body of #{title}.</p>"
        )
      end

    %{document: document, version: version, sections: sections}
  end

  defp note!(site, section, overrides) do
    Keyword.merge(
      [
        site_id: site.id,
        section_id: section.id,
        content_review_status: :approved,
        technical_review_status: :approved,
        content: "<p>Note body</p>"
      ],
      overrides
    )
    |> note(site.id)
    |> generate()
  end

  describe "every provisioned page" do
    test "renders for a reader who is not signed in", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      manual!(site)
      provision!(site)

      urls = [
        english(url_mode, "/docs"),
        english(url_mode, "/docs/mishka-cms"),
        english(url_mode, "/docs/mishka-cms/installation")
      ]

      for url <- urls do
        assert {:ok, view, html} = live(conn, url), "#{url} did not render"
        assert_drew!(html, url)
        assert_drew!(render_async(view, @async), url)
      end
    end

    # THE ONE FAULT A RENDERED PAGE HIDES. These paths hold three captures — `lang`, `workspace` and
    # `section` — and the bases the blocks build links from keep the first of them IN them, because
    # a block fills that segment with the language of the ROW it is linking to, which is the only
    # way a link can lead to another language's edition. The whole design therefore rests on every
    # base reaching a block that fills it: one written out by hand, or handed to a block that does
    # not, puts `/:lang/docs/<slug>` in front of a reader, and nothing else in this file notices.
    # The page renders, the contents are right, and only the `href` names a path this site has no
    # page at — which is the first thing a reader clicks.
    #
    # The second assertion is what keeps the first honest: a block that dropped every link rather
    # than filling it draws no capture either, and would pass a check that only refuses one.
    test "leaves no capture in a URL it drew", %{url_mode: url_mode, site: site, conn: conn} do
      %{document: document, sections: sections} = manual!(site)
      installation = Enum.find(sections, &(&1.slug == "installation"))
      note!(site, installation, title: "Requirements", order_position: 0)

      persian =
        document!(site,
          name: "میشکا",
          slug: "mishka-cms-fa",
          language: "fa",
          language_group_id: document.language_group_id
        )

      persian_version = version!(site, persian, version_number: "0.3.0")

      section!(site, persian_version,
        title: "نصب",
        slug: "nasb",
        order_position: 0,
        language: "fa",
        language_group_id: installation.language_group_id
      )

      provision!(site)

      read_at = %{
        "en" => [
          english(url_mode, "/docs"),
          english(url_mode, "/docs/mishka-cms"),
          english(url_mode, "/docs/mishka-cms/installation")
        ],
        "fa" => ["/fa/docs", "/fa/docs/mishka-cms-fa", "/fa/docs/mishka-cms-fa/nasb"]
      }

      for {language, urls} <- read_at, url <- urls do
        assert {:ok, view, _html} = live(conn, url), "#{url} did not render"
        html = assert_drew!(render_async(view, @async), url)

        assert captures_left(html) == [], "#{url} drew a URL the runtime never filled in"

        assert Enum.any?(
                 block_links(html),
                 &String.starts_with?(&1, language_path(url_mode, language, "/docs/"))
               ),
               "#{url} drew no link into its own language's documentation, so the check above asserts nothing"
      end
    end

    test "is answered in each of the site's languages, and in no other", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      provision!(site)

      for language <- ~w(en fa) do
        assert {:ok, _view, _html} = live(conn, language_path(url_mode, language, "/docs"))
      end

      assert_raise NotFoundError, fn -> live(conn, "/xyz/docs") end
    end
  end

  # THE BUILDER'S PREVIEW IS A HARSHER RENDERER THAN THE SITE. It assigns the page, the site and an
  # empty `query_params`, and nothing else — no visitor, no captures — so a template that names
  # `@current_user` raises `KeyError` there while serving perfectly well to a reader, and a page that
  # reached `<>` with a nil capture raises `ArgumentError`. An author who cannot preview the page the
  # CMS gave them has no way to tell whether their edit worked.
  describe "the admin's Preview tab" do
    test "draws every provisioned page, with the assigns a preview has", %{site: site} do
      provision!(site)

      for page <- pages(site) do
        record = Map.put(page, :site, %{id: site.id, name: site.name})
        {html, note} = RuntimePreview.render_document(record, Page)

        assert note == nil, "#{page.path} cannot be previewed: #{note}"
        refute html =~ "Preview unavailable", "#{page.path} fell back to the preview placeholder"
        assert_drew!(html, page.path)
      end
    end
  end

  describe "the documentation index" do
    test "lists the site's published documents and links each to its own page", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      manual!(site)
      _unpublished = document!(site, name: "Not ready", slug: "not-ready", status: :draft)
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs"))
      html = render_async(view, @async)

      assert texts(html, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]

      assert has_element?(
               view,
               ~s(#doc-index a[href="#{english(url_mode, "/docs/mishka-cms")}"])
             ),
             "a document on the index did not link to its own page under this language"
    end

    # THE NAV IS BUILT FROM `@page_languages`, so it swaps the `lang` capture inside the page's own
    # pattern rather than the first segment of whatever URL this happens to be — and on THIS page
    # every other capture is absent, which is why the index is the one that carries it.
    test "offers itself in the site's other language", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      provision!(site)

      {:ok, _view, html} = live(conn, english(url_mode, "/docs"))

      assert [{"en", english(url_mode, "/docs")}, {"fa", "/fa/docs"}] ==
               html
               |> doc()
               |> LazyHTML.query("a[hreflang]")
               |> Enum.map(
                 &{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))}
               )
    end

    # A PAGER ON A PATTERN PAGE MUST NOT WRITE THE PATTERN. `@page.path` is `/:lang/docs`, so a page
    # that handed the list its own path would produce `/:lang/docs?page=2` — a URL no reader could
    # have typed, which reads like a bug to everyone who sees it.
    test "pages itself through a URL a reader could have typed", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      for index <- 1..13,
          do: document!(site, name: "Manual #{index}", slug: "manual-#{index}")

      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs"))

      assert [href] =
               attributes(render_async(view, @async), ~s([data-role="doc-list-next"]), "href")

      refute href =~ ":lang"
      assert String.starts_with?(href, english(url_mode, "/docs?"))

      assert {:ok, _second, second_html} = live(conn, href)
      assert_drew!(second_html, href)
    end
  end

  describe "one document's pages" do
    setup %{site: site} do
      {:ok, manual!(site)}
    end

    test "draws the document's own front page with its contents beside it", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs/mishka-cms"))
      html = render_async(view, @async)

      assert texts(html, ~s([data-role="doc-landing-title"])) == ["Mishka CMS"]

      assert texts(html, ~s(#doc-contents [data-role="doc-sidebar-link"])) ==
               ["Getting started", "Installation", "Appendix"]
    end

    test "draws one page, its notes under their own anchors, and the way on to the next", %{
      url_mode: url_mode,
      site: site,
      conn: conn,
      sections: sections
    } do
      installation = Enum.find(sections, &(&1.slug == "installation"))

      note!(site, installation, title: "Requirements", order_position: 0)
      note!(site, installation, title: "Troubleshooting", order_position: 1)

      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs/mishka-cms/installation"))
      html = render_async(view, @async)

      assert texts(html, ~s([data-role="doc-section-title"])) == ["Installation"]
      assert texts(html, ~s([data-role="doc-note-title"])) == ["Requirements", "Troubleshooting"]

      assert attributes(html, ~s([data-role="doc-section-next"]), "href") ==
               [english(url_mode, "/docs/mishka-cms/appendix")]

      assert attributes(html, ~s([data-role="doc-section-prev"]), "href") ==
               [english(url_mode, "/docs/mishka-cms/getting-started")]
    end

    # THE FOUR BLOCKS AGREE ABOUT NOTHING BY SHARING CODE — a stored component has nothing to share
    # it through — so the one place their agreement can be checked is a page carrying all of them.
    # A table of contents whose anchors name ids the article beside it never drew is a column of
    # links that do nothing, and it renders perfectly.
    test "and a table of contents whose every anchor is somewhere on that page", %{
      url_mode: url_mode,
      site: site,
      conn: conn,
      sections: sections
    } do
      installation = Enum.find(sections, &(&1.slug == "installation"))

      note!(site, installation, title: "Requirements", order_position: 0)
      note!(site, installation, title: "Troubleshooting", order_position: 1)

      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs/mishka-cms/installation"))
      html = render_async(view, @async)

      anchors = attributes(html, ~s(#doc-on-this-page [data-role="doc-toc-link"]), "href")

      assert length(anchors) >= 2, "the table of contents drew nothing to check"

      for "#" <> id <- anchors do
        assert has_element?(view, "##{id}"),
               "the table of contents links to ##{id}, which nothing on the page drew"
      end
    end

    # ONE DOCUMENT, ONE URL. `/:lang/docs/:workspace` is one row answering every language the site
    # publishes in, and a workspace slug belongs to ONE edition — so without the page telling the
    # blocks which language it is being read in, the English manual also answers at
    # /fa/docs/mishka-cms, inside the Persian right-to-left shell this page draws around it.
    test "are not where an edition in another language answers", %{site: site, conn: conn} do
      provision!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, "/fa/docs/mishka-cms")
      end
    end

    # AND THE SWITCH THAT TAKES A READER THERE POINTS AT THE RIGHT ONE. `@page_languages` would swap
    # the language and keep `mishka-cms` — the English edition's slug — under Persian, which is a
    # URL its own page answers as not published. This is why the document pages carry `doc-switcher`
    # instead: it maps the document AND the page being read through `language_group_id`.
    test "offer the translation at the URL that answers it", %{
      url_mode: url_mode,
      site: site,
      conn: conn,
      document: document,
      sections: sections
    } do
      installation = Enum.find(sections, &(&1.slug == "installation"))

      persian =
        document!(site,
          name: "میشکا",
          slug: "mishka-cms-fa",
          language: "fa",
          language_group_id: document.language_group_id
        )

      persian_version = version!(site, persian, version_number: "0.3.0")

      section!(site, persian_version,
        title: "نصب",
        slug: "nasb",
        order_position: 0,
        language: "fa",
        language_group_id: installation.language_group_id
      )

      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/docs/mishka-cms/installation"))

      offered =
        attributes(render_async(view, @async), ~s([data-role="doc-switcher-language"]), "href")

      assert "/fa/docs/mishka-cms-fa/nasb" in offered

      {:ok, translated, _html} = live(conn, "/fa/docs/mishka-cms-fa/nasb")

      assert texts(render_async(translated, @async), ~s([data-role="doc-section-title"])) == [
               "نصب"
             ]
    end
  end

  # THE ONE BLOCK THIS MODULE PLACES ON A PAGE IT KNOWS NOTHING ABOUT, and it is handed
  # `@page.language` exactly as the three sample pages are. `MishkaCmsCore.Runtime.PageEditions`
  # is what makes one rule enough for both: a page's language is its `:lang` capture where the path
  # has one and the page row's own where it has none, so there is no page an author can drop this on
  # whose language it would have to guess at. Left to read a `?lang=` instead, it lists the English
  # masters inside a Persian page and links them under /en, which is the one thing every other case
  # here exists to prevent.
  describe "the latest-documents snippet" do
    setup %{site: site} do
      {:ok, manual!(site)}
    end

    test "is in the language of the page an author dropped it on", %{
      url_mode: url_mode,
      site: site,
      conn: conn,
      document: document
    } do
      document!(site,
        name: "میشکا",
        slug: "mishka-cms-fa",
        language: "fa",
        language_group_id: document.language_group_id
      )

      Provision.ensure!(site)

      create_page!(
        site_id: site.id,
        name: "Document home",
        path: "/:lang/home",
        section: "document",
        template: snippet_source(site),
        active: true
      )

      register_routes!(site)

      {:ok, persian, _html} = live(conn, "/fa/home")
      persian_html = render_async(persian, @async)

      assert texts(persian_html, ~s(#doc-latest [data-role="doc-list-title"])) == ["میشکا"]

      assert attributes(persian_html, ~s(#doc-latest [data-role="doc-list-read"]), "href") ==
               ["/fa/docs/mishka-cms-fa"]

      {:ok, english, _html} = live(conn, english(url_mode, "/home"))

      assert texts(render_async(english, @async), ~s(#doc-latest [data-role="doc-list-title"])) ==
               [
                 "Mishka CMS"
               ]
    end

    # AND ON A PAGE WHOSE PATH CAPTURES NOTHING, which is the half of the rule a capture hides: with
    # no `lang` segment there, the page's language is the page ROW's own and a `?lang=` a visitor
    # appended is not it — the shell drawn around this block is `<html lang="fa" dir="rtl">` from
    # that same row, and a list of English documents inside it is the very mismatch the pattern
    # pages take `lang={@page.language}` to avoid. The base the cards are built from still names the
    # capture either way — the documentation is published nowhere but under `/:lang/docs` — so this
    # is also the case that says a base with a capture in it is filled from the ROW it leads to and
    # not from the URL the reader is on.
    test "and on one whose path captures nothing at all", %{
      site: site,
      conn: conn,
      document: document
    } do
      document!(site,
        name: "میشکا",
        slug: "mishka-cms-fa",
        language: "fa",
        language_group_id: document.language_group_id
      )

      Provision.ensure!(site)

      create_page!(
        site_id: site.id,
        name: "Document desk",
        path: "/doc-desk",
        section: "document",
        language: "fa",
        template: snippet_source(site),
        active: true
      )

      register_routes!(site)

      for url <- ["/doc-desk", "/doc-desk?lang=en"] do
        assert {:ok, view, _html} = live(conn, url), "#{url} did not render"
        html = assert_drew!(render_async(view, @async), url)

        assert captures_left(html) == [], "#{url} drew a URL the runtime never filled in"

        assert attributes(html, ~s(#doc-latest [data-role="doc-list-read"]), "href") ==
                 ["/fa/docs/mishka-cms-fa"],
               "#{url} did not list its own page's language at the address that edition answers"
      end
    end
  end
end
