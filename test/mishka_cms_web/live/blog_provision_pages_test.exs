# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogProvisionPagesTest do
  @moduledoc """
  The pages `MishkaBlog.Provision` creates, visited the way a reader visits them.

  Here rather than in the blog's own suite because it takes both halves at once: the extension's
  components and sample pages, and this application's router, site resolution and runtime compilers.
  `MishkaBlog.ProvisionTest` asserts which rows are written and which are left alone; this asserts
  that what was written is a site somebody can read.

  ## What is actually at risk

  A sample page is markup in a string in an Elixir module. It compiles at creation — `Page
  :master_create` runs `Validations.PageCodeCompiles` — so a syntax error fails long before here.
  What does not show up until a real request is everything about the ASSIGNS: a template reading
  `@current_user` on a page nobody is signed into, `@query_params["slug"]` reaching `<>` as nil, an
  attribute a component does not declare, a live component under an id another one on the page also
  has. Each of those is a page that renders as the runtime's red refusal box, or raises, and every
  one of them is invisible to a test that only counts rows.

  `async: false` — the install flag, `SiteState`, the routing table and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  import MishkaBlog.Dev.Generator,
    only: [tag: 2, post_collection: 1, post_tag: 1, comment: 2, blogger: 2, team: 2]

  import Ash.Generator, only: [generate: 1]

  alias MishkaBlog.Provision
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsBuilder.Snippet
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @moduletag :integration
  # Over thirty seconds on its own: left out of a pull request, see test/test_helper.exs.
  @moduletag :slow

  # EVERY READ OF A RENDERED PAGE WAITS FOR THE BLOCKS ON IT, because most of them now read in the
  # background: a connected socket takes the `start_async/3` branch, so the first render is the
  # skeleton and the rows arrive in the message after it. `render_async/2` waits on the tasks
  # themselves — it is not a sleep, and a block that never starts one is answered immediately.
  @async 5_000

  # The category chip over the list that marks where the reader is.
  @chip_marked ~s([data-role="blog-list-chip"][data-selected="true"])

  # A UNIQUE SITE NAME PER TEST, for the reason `MishkaBlog.LiveComponentsRenderTest` gives: a
  # component's module is named from a hash of its own name and its SITE's, and carries that site's
  # id — so a reused name renders the previous test's module against a site that test rolled back,
  # and every list comes back empty with nothing to say why.
  setup %{url_mode: url_mode} do
    SiteState.clear()
    name = "blogpages#{System.unique_integer([:positive])}"
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
          # attribute, which is "blog" on every one of these.
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

  defp publish!(site, title, overrides \\ []) do
    create_blog_post!(
      [
        site_id: site.id,
        title: title,
        status: :published,
        published_at: DateTime.utc_now()
      ] ++ overrides
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp texts(html, selector),
    do:
      html
      |> doc()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  # The same, with the whitespace inside each one closed up.
  defp words(html, selector),
    do: html |> texts(selector) |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))

  # A category and a tag under one slug, each with a published post so both are shown — what a
  # category's page and a tag's are told apart by. The category comes back, for the test that files
  # the article the reader is on under it.
  defp both_named!(site, slug) do
    category = create_collection!(site_id: site.id, status: :active, name: "Cat", slug: slug)
    tag = [name: "Tag", slug: slug] |> tag(site.id) |> generate()

    filed = publish!(site, "Filed under #{slug}")
    [post_id: filed.id, collection_id: category.id] |> post_collection() |> generate()

    tagged = publish!(site, "Tagged #{slug}")
    [post_id: tagged.id, tag_id: tag.id] |> post_tag() |> generate()

    category
  end

  # THE LANGUAGES A PAGE OFFERS, as the header's switcher lists them, the edition being read among
  # them: the layout's is the only switcher a page has (`MishkaCmsCore.Runtime.SiteLayout`), so a
  # test reading it draws the page on the site's layout (`seed_site_layout!/1`).
  defp offered(html) do
    html
    |> doc()
    |> LazyHTML.query("#site-language-menu a[hreflang]")
    |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})
  end

  # And the languages the head names in its `hreflang` links, which are built from the same list.
  defp head_languages(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|link[rel="alternate"][hreflang]:not([hreflang="x-default"])|)
    |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})
  end

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

  # The links the COMPONENTS drew, which is every one carrying a `data-role`: the chrome around them
  # is hand-written markup in `MishkaBlog.Provision` and tags none of its own.
  defp component_links(html) do
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

  # One record of each kind the provisioned pages read, and every page's address.
  defp every_page!(site, url_mode) do
    post = publish!(site, "Ash in production")
    collection = create_collection!(site_id: site.id, status: :active)
    tag = [] |> tag(site.id) |> generate()
    user = create_user!(site_id: site.id)
    blogger = [site_id: site.id, user_id: user.id] |> blogger(site.id) |> generate()
    team = [site_id: site.id, status: :active] |> team(site.id) |> generate()
    provision!(site)

    [
      english(url_mode, "/blog"),
      english(url_mode, "/blog/#{post.slug}"),
      english(url_mode, "/blog/category/#{collection.slug}"),
      english(url_mode, "/blog/tag/#{tag.slug}"),
      english(url_mode, "/blog/categories"),
      english(url_mode, "/blog/tags"),
      english(url_mode, "/blog/author/#{blogger.slug}"),
      english(url_mode, "/blog/team/#{team.slug}"),
      english(url_mode, "/blog/people")
    ]
  end

  describe "every provisioned page" do
    test "renders for a reader who is not signed in", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      for url <- every_page!(site, url_mode) do
        assert {:ok, view, html} = live(conn, url), "#{url} did not render"
        assert_drew!(html, url)
        assert_drew!(render_async(view, @async), url)
      end
    end

    # `?q[a]=b` arrives as a map and `?tags[]=x` as a list. A key named like a capture never replaces
    # the captured segment, so `?slug[a]=b` on a post still reads the post by its slug — before, it
    # handed the read a map and the page answered 500.
    test "renders when the query string nests a value, under a capture's name too", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      queries = ["?slug[a]=b&category[a]=b&tag[a]=b", "?page[a]=1&q[a]=b&tags[]=x&tags[]=y"]

      for url <- every_page!(site, url_mode), query <- queries do
        assert {:ok, view, html} = live(conn, url <> query), "#{url <> query} did not render"
        assert_drew!(html, url <> query)
        assert_drew!(render_async(view, @async), url <> query)
      end
    end

    # THE ONE FAULT A RENDERED PAGE HIDES. Every base these templates hand a component keeps the
    # `:lang` capture IN it — `post_base="/:lang/blog"` — because the component fills that segment
    # with the language of the ROW it is linking to, which is the only way a link can lead to
    # another language's edition. The whole design therefore rests on every base reaching a block
    # that fills it: one written out by hand, or handed to a block that does not, puts
    # `/:lang/blog/<slug>` in front of a reader, and nothing else in this file notices. The page
    # renders, the list holds the right posts, and only the `href` names a path this site has no
    # page at — which is the first thing a reader clicks.
    #
    # The second assertion is what keeps the first honest: a component that dropped every link
    # rather than filling it draws no capture either, and would pass a check that only refuses one.
    test "leaves no capture in a URL it drew", %{url_mode: url_mode, site: site, conn: conn} do
      # ONE POST IN TWO LANGUAGES, not two posts that share nothing, ON THE SITE'S LAYOUT. The
      # header's language switcher is the only link on any of these pages built under a language
      # that is NOT the page's own — and a post with no edition beside it draws no switcher at all,
      # leaving that link outside the guard.
      english = publish!(site, "Post en")

      persian =
        publish!(site, "Post fa",
          language: "fa",
          language_group_id: english.language_group_id
        )

      published =
        for {language, post} <- %{"en" => english, "fa" => persian}, into: %{} do
          category =
            create_collection!(
              site_id: site.id,
              status: :active,
              name: "Cat #{language}",
              slug: "cat-#{language}",
              language: language
            )

          tag =
            [name: "Tag #{language}", slug: "tag-#{language}", language: language]
            |> tag(site.id)
            |> generate()

          [post_id: post.id, collection_id: category.id] |> post_collection() |> generate()
          [post_id: post.id, tag_id: tag.id] |> post_tag() |> generate()

          {language, %{post: post, category: category, tag: tag}}
        end

      seed_site_layout!(site)
      provision!(site)

      for {language, %{post: post, category: category, tag: tag}} <- published,
          url <- [
            language_path(url_mode, language, "/blog"),
            language_path(url_mode, language, "/blog/#{post.slug}"),
            language_path(url_mode, language, "/blog/category/#{category.slug}"),
            language_path(url_mode, language, "/blog/tag/#{tag.slug}"),
            language_path(url_mode, language, "/blog/categories"),
            language_path(url_mode, language, "/blog/tags")
          ] do
        assert {:ok, view, _html} = live(conn, url), "#{url} did not render"
        html = assert_drew!(render_async(view, @async), url)

        assert captures_left(html) == [],
               "#{url} drew a URL the runtime never filled in"

        assert Enum.any?(
                 component_links(html),
                 &String.starts_with?(&1, language_path(url_mode, language, "/blog/"))
               ),
               "#{url} drew no link into its own language's blog, so the check above asserts nothing"
      end

      # AND THE LINK UNDER ANOTHER LANGUAGE WAS REALLY DRAWN. A page with no switcher holds no
      # capture either, so without this the one link built under another language is asserted by
      # nothing above it.
      for {url, translated} <- [
            {english(url_mode, "/blog/#{english.slug}"), "/fa/blog/#{persian.slug}"},
            {"/fa/blog/#{persian.slug}", english(url_mode, "/blog/#{english.slug}")}
          ] do
        assert {:ok, view, _html} = live(conn, url)

        assert [translated] ==
                 view
                 |> render_async(@async)
                 |> offered()
                 |> Enum.map(&elem(&1, 1))
                 |> List.delete(url),
               "#{url} offered no other edition, so no link under another language was checked"
      end
    end

    test "is answered in each of the site's languages, and in no other", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      provision!(site)

      for language <- ~w(en fa) do
        assert {:ok, _view, _html} = live(conn, language_path(url_mode, language, "/blog"))
      end

      assert_raise NotFoundError, fn -> live(conn, "/xyz/blog") end
    end
  end

  describe "the blog home" do
    test "lists the site's published posts and links each to its own page", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      published = publish!(site, "Ash in production")
      _draft = create_blog_post!(site_id: site.id, title: "Not ready yet", status: :draft)
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog"))
      html = render_async(view, @async)

      assert "Ash in production" in texts(html, ~s([data-role="blog-list-title"]))
      refute "Not ready yet" in texts(html, ~s([data-role="blog-list-title"]))

      assert has_element?(view, ~s(a[href="#{english(url_mode, "/blog/#{published.slug}")}"])),
             "a post on the list did not link to its own page under this language"
    end

    # THE SWITCHER IS BUILT FROM `@page_languages`, so it swaps the `lang` capture inside the page's
    # own pattern rather than the first segment of whatever URL this happens to be. It is the
    # header's, the layout's only one.
    test "offers the same page in the site's other language", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      seed_site_layout!(site)
      provision!(site)

      {:ok, _view, html} = live(conn, english(url_mode, "/blog"))

      assert [{"en", english(url_mode, "/blog")}, {"fa", "/fa/blog"}] == offered(html)
    end

    # A PAGER ON A PATTERN PAGE MUST NOT WRITE THE PATTERN. `@page.path` is `/:lang/blog`, so a page
    # that handed the list its own path would produce `/:lang/blog?page=2` — a URL no reader could
    # have typed, which reads like a bug to everyone who sees it.
    test "pages itself through a URL a reader could have typed", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      for index <- 1..12, do: publish!(site, "Post #{index}")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog"))

      assert [href] =
               render_async(view, @async)
               |> doc()
               |> LazyHTML.query(~s([data-role="blog-list-next"]))
               |> Enum.map(&hd(LazyHTML.attribute(&1, "href")))

      refute href =~ ":lang"
      assert String.starts_with?(href, english(url_mode, "/blog?"))

      assert {:ok, _second, second_html} = live(conn, href)
      assert_drew!(second_html, href)
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

  describe "one post's page" do
    # A SLUG THE URL NAMED AND NOTHING ANSWERS IS A MISSING PAGE. It drew a notice inside the blog
    # page and answered 200, so a reader who followed a stale link, and every crawler, was told the
    # address was fine.
    test "shows the post the URL named, and is missing for a slug that is not", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      post = publish!(site, "Ash in production")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/#{post.slug}"))

      assert texts(render_async(view, @async), ~s([data-role="blog-detail-title"])) == [
               "Ash in production"
             ]

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, english(url_mode, "/blog/nothing-like-this"))
      end
    end

    test "asks a reader who is not signed in to sign in before commenting", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      post = publish!(site, "Ash in production")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/#{post.slug}"))

      # THE CONVERSATION IS READ IN THE BACKGROUND, so the way in appears with it rather than with
      # the first paint. `has_element?/2` renders without waiting; this waits, and answers with the
      # markup the reader ends up looking at.
      assert render_async(view, @async) =~ ~s(data-role="blog-comments-login")
    end

    # ONE ARTICLE, ONE URL. `/:lang/blog/:slug` is one row answering every language the site
    # publishes in, and a slug belongs to one edition — so without the page telling the component
    # which language it is being read in, the English article also answers at /fa/blog/<its slug>,
    # inside the Persian shell this page draws around it: `<html lang="fa" dir="rtl">`, a Persian
    # bar, Persian marked current in the header's switcher. Nothing about that URL is true.
    test "is not the place an edition in another language answers", %{site: site, conn: conn} do
      english = publish!(site, "English post")
      provision!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, "/fa/blog/#{english.slug}")
      end
    end

    # AND THE CONVERSATION UNDERNEATH IT ANSWERS IN THE SAME PLACE. The detail block and the
    # comments block resolve the one `:slug` capture, and a page that told only the first of them
    # which language it is being read in published the English article's comments beneath the
    # message saying that article is not here — with a box, for a signed-in reader, that writes onto
    # the English post from a Persian URL.
    test "and neither is it where that edition's comments are published", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      english = publish!(site, "English post")

      [post_id: english.id, content: "Well put.", status: :approved]
      |> comment(site.id)
      |> generate()

      provision!(site)

      # NOTHING IS PUBLISHED UNDER THAT URL BECAUSE THE URL IS NOT THERE. The question this test
      # asks — whether the English article's conversation answers beneath a Persian address — is
      # answered more completely by the address not answering at all.
      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, "/fa/blog/#{english.slug}")
      end

      {:ok, english_url, _html} = live(conn, english(url_mode, "/blog/#{english.slug}"))

      assert texts(render_async(english_url, @async), ~s([data-role="blog-comment-body"])) == [
               "Well put."
             ]
    end

    # AND THE LINK THAT TAKES A READER THERE POINTS AT THE RIGHT ONE. A base with the page's own
    # language written into it offers every other edition under the language the reader is leaving —
    # /en/blog/<fa slug>, an hreflang="fa" on a path under English, answered by the English page,
    # which does not have that post.
    test "offers each translation at the URL that answers it", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      english = publish!(site, "English post")

      persian =
        publish!(site, "نوشته فارسی",
          language: "fa",
          language_group_id: english.language_group_id
        )

      lonely = publish!(site, "Only in English")

      seed_site_layout!(site)
      provision!(site)

      english_url = english(url_mode, "/blog/#{english.slug}")
      persian_url = "/fa/blog/#{persian.slug}"

      {:ok, view, html} = live(conn, english_url)

      assert [{"en", english_url}, {"fa", persian_url}] == offered(render_async(view, @async))

      # THE HEAD NAMES THE SAME TWO, each at the absolute address of its own edition.
      assert [{"en", english_href}, {"fa", persian_href}] = head_languages(html)
      assert String.ends_with?(english_href, english_url)
      assert String.ends_with?(persian_href, persian_url)

      {:ok, translated, _html} = live(conn, persian_url)

      assert texts(render_async(translated, @async), ~s([data-role="blog-detail-title"])) == [
               "نوشته فارسی"
             ]

      # A POST WITH NO EDITION BESIDE IT offers no other language, so the header draws no switcher.
      {:ok, alone, _html} = live(conn, english(url_mode, "/blog/#{lonely.slug}"))

      assert offered(render_async(alone, @async)) == [],
             "a post with no Persian edition was offered in Persian"
    end
  end

  # THE PAGE CALLED "EVERY CATEGORY OF THE BLOG". `parent` left at its default lists the roots,
  # which is what the sidebar's menu wants — on this page it means a site with a nested taxonomy has
  # categories that appear nowhere at all, and a description that says otherwise.
  describe "the categories page" do
    test "lists a category filed under another one as well as the roots", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      parent = create_collection!(site_id: site.id, status: :active, name: "Parent")

      child =
        create_collection!(
          site_id: site.id,
          status: :active,
          name: "Child",
          parent_collection_id: parent.id
        )

      for category <- [parent, child] do
        post = publish!(site, "Filed under #{category.name}")
        [post_id: post.id, collection_id: category.id] |> post_collection() |> generate()
      end

      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/categories"))
      names = texts(render_async(view, @async), ~s([data-role="blog-category-name"]))

      assert "Parent" in names
      assert "Child" in names, "a nested category is on no provisioned page at all"
    end
  end

  # ONE CAPTURE, FOUR MEANINGS. `:slug` is a category on one of these pages, a tag on another and a
  # post on a third, and a block that marks where the reader is reads it under one name. A page that
  # handed the capture to every block would mark whatever happens to share that slug — and a blog
  # with a category and a tag both called "Elixir" is the ordinary case.
  #
  # The design draws no sidebar on the blog's pages (it is only a snippet now), so the place the
  # reader is in is marked by the list's category chips and its tag chip.
  describe "the place the reader is in" do
    test "is the category they are on, and not the tag that shares its slug", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      both_named!(site, "elixir")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/category/elixir"))
      html = render_async(view, @async)

      assert texts(html, @chip_marked) == ["Cat"]
      assert texts(html, ~s([data-role="blog-list-tag-chip"])) == [], "the page marked a tag"
      assert texts(html, ~s(#blog-posts [data-role="blog-list-title"])) == ["Filed under elixir"]
    end

    test "and the tag they are on, and not the category that shares its slug", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      both_named!(site, "elixir")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/tag/elixir"))
      html = render_async(view, @async)

      assert words(html, ~s([data-role="blog-list-tag-clear"])) == ["#Tag ×"]

      assert texts(html, @chip_marked) == ["All"],
             "the page marked a category the reader is not on"

      assert texts(html, ~s(#blog-posts [data-role="blog-list-title"])) == ["Tagged elixir"]
    end

    # THE ARTICLE THE READER ALREADY HAS OPEN is the one link in "what else there is to read" that
    # cannot be useful. It takes the slug the category and the tag share: on a post page the capture
    # is a post's slug, which is neither a category's nor a tag's.
    test "keeps the post they have open out of what else there is to read", %{
      url_mode: url_mode,
      site: site,
      conn: conn
    } do
      category = both_named!(site, "elixir")
      open_one = publish!(site, "Open", slug: "elixir")
      [post_id: open_one.id, collection_id: category.id] |> post_collection() |> generate()
      _other = publish!(site, "Another")
      provision!(site)

      {:ok, view, _html} = live(conn, english(url_mode, "/blog/elixir"))
      html = render_async(view, @async)

      next = texts(html, ~s(#blog-post-related [data-role="blog-list-title"]))

      refute "Open" in next, "the page offered the reader the post they are already reading"

      assert hd(next) == "Filed under elixir",
             "the post filed under the open one's category was not offered first"

      assert "Another" in next
    end
  end

  # THE ONE BLOCK THIS MODULE PLACES ON A PAGE IT KNOWS NOTHING ABOUT. The six sample pages capture
  # `lang` and are read in the language the URL names; an author drops the sidebar wherever they
  # like, including on a page with no capture in its path at all, where the language is the page
  # ROW's own and a `?lang=` a visitor appended is not it — see `MishkaCmsCore.Runtime.PageEditions`.
  # The bases it carries are the blog's real addresses either way, so the links it writes have to
  # come out the same on both kinds of page.
  describe "the sidebar snippet on a page of the author's own" do
    setup %{site: site} do
      persian = publish!(site, "نوشته فارسی", language: "fa")

      category =
        create_collection!(
          site_id: site.id,
          status: :active,
          name: "دسته",
          slug: "daste",
          language: "fa"
        )

      [post_id: persian.id, collection_id: category.id] |> post_collection() |> generate()

      %{persian: persian}
    end

    test "is read in that page's own language, whatever the query string says", %{
      site: site,
      conn: conn,
      persian: persian
    } do
      provision!(site)

      create_page!(
        site_id: site.id,
        name: "Blog desk",
        path: "/blog-desk",
        section: "blog",
        language: "fa",
        template: snippet_source(site),
        active: true
      )

      register_routes!(site)

      for url <- ["/blog-desk", "/blog-desk?lang=en"] do
        assert {:ok, view, _html} = live(conn, url), "#{url} did not render"
        html = assert_drew!(render_async(view, @async), url)

        assert captures_left(html) == [], "#{url} drew a URL the runtime never filled in"

        assert "/fa/blog/#{persian.slug}" in component_links(html),
               "#{url} did not link the post in its own page's language"
      end
    end
  end
end
