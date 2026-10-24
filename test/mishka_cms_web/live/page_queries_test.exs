# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageQueriesTest do
  @moduledoc """
  A page of the documentation, and the site's home, ask the database for each of their rows once per
  request: the head, the frame and the page's blocks share the one read the page made of its
  document (`MishkaCmsCore.Runtime.PageSource`, `MishkaDocument.PageSource`).

  Each test counts the queries the repo runs during one request, through its telemetry events, for
  the HTTP render and again for the connected mount, which renders the page anew: no two of them
  read the same table with the same filter and the same values, and there are no more of them than
  the page needs. The counts, as a guest on the site `records!/1` seeds (before the page's rows were
  shared → now): a page of a document 27 → 8, a document's front page 20 → 7, the library 6 → 4.
  The blog's pages are `MishkaCmsWeb.BlogPageQueriesTest`'s.

  A page of the site's own — the home page, and a page translated into Persian — asks the database
  nothing at all once it is compiled (1 → 0 each, before its editions were kept in `SiteState`):
  its data is in its module, and the other languages it is in are read from
  `MishkaCmsCore.Runtime.States.SiteState.page_editions/2`, which every write of a page keeps — so
  an edition added or removed is offered, or no longer, on the very next request, without a restart
  and without the page being compiled again.

  Here rather than in an extension's suite because only this application has the router, the
  runtime LiveView and the hooks a request runs.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  repo's telemetry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  # WHAT EACH PAGE NEEDS, AND NO MORE. A page of a document: the site's own editions of the page
  # (core); the document with, loaded with it, its versions, its other editions and theirs; in one
  # read, the pages of every version of it — the version shown, and the others the version menu
  # offers — and of the version each other edition is on, which the frame finds the same page in;
  # and the page with its text and, loaded with it, its notes. A front page reads the summaries of
  # the pages its overview starts with in place of a page and its notes. The library counts its
  # documents, reads a page of them with, in the same statement, the version each card names and
  # the languages of its other editions, and the pages of those versions in one read — the release
  # before read 4 without the version and the pages. The home page and a translated page read
  # nothing: their editions are in `SiteState`.
  @budgets %{page: 8, front: 7, library: 4, home: 0, translated: 0}

  setup do
    SiteState.clear()
    name = "queries#{System.unique_integer([:positive])}"
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

    %{layout_id: layout_id} = seed_site_layout!(site)
    records!(site)
    {about, fa} = translated!(site, layout_id)
    MishkaDocument.Provision.ensure!(site)
    register_routes!(site)

    %{site: site, layout_id: layout_id, about: about, fa: fa}
  end

  for {page, path, label} <- [
        {:page, "/docs/guide/install",
         "a page of a document, its contents, its notes and its bar"},
        {:front, "/docs/guide", "a document's front page and its overview"},
        {:library, "/docs", "the library"},
        {:home, "/", "the home page"},
        {:translated, "/about", "a page translated into Persian"}
      ] do
    test "#{label} reads each of its rows once", %{site: site} do
      path = unquote(path)
      budget = Map.fetch!(@budgets, unquote(page))

      # THE FIRST REQUEST BUILDS the page's and its blocks' modules, which reads their rows; the
      # second is what every reader after it costs.
      _built = get(on_site(site), path)

      {conn, request} = queries(fn -> get(on_site(site), path) end)
      assert conn.status == 200, "#{path} answered #{conn.status}"

      {_view, mount} =
        queries(fn ->
          {:ok, view, _html} = live(conn)
          render_async(view, 5_000)
        end)

      for {moment, ran} <- [request: request, mount: mount] do
        assert twice(ran) == [], "#{path}, the #{moment}, read twice: #{inspect(twice(ran))}"

        assert length(ran) <= budget,
               "#{path}, the #{moment}, ran #{length(ran)} queries, more than #{budget}:\n" <>
                 Enum.map_join(ran, "\n", fn {source, sql, _values} ->
                   "  [#{source}] #{String.slice(sql, 0, 160)}"
                 end)
      end
    end
  end

  # THE HEADER'S SWITCHER AND THE HEAD'S HREFLANG LINKS FOLLOW A TRANSLATION ADDED OR TAKEN AWAY on
  # the next request: the page reads its group from `SiteState` on every render, which the write
  # itself updated, so no restart and no compile of the page stand between them — and the page still
  # reads nothing of `pages`, which its compile would.
  test "a page offers a translation from the next request, and none once it goes", %{
    site: site,
    layout_id: layout_id,
    about: about,
    fa: fa
  } do
    _built = get(on_site(site), "/about")

    assert offered(site, "/about") == {[{"en", "/about"}, {"fa", "/fa/about"}], ["en", "fa"]}

    fa
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
    |> Ash.destroy!(authorize?: false)

    assert offered(site, "/about") == {[], []},
           "/about still offered the Persian edition that was archived"

    edition!(site, layout_id,
      name: "about-fa-again",
      path: "/fa/darbare",
      language: "fa",
      language_group_id: about.id
    )

    assert offered(site, "/about") == {[{"en", "/about"}, {"fa", "/fa/darbare"}], ["en", "fa"]},
           "/about did not offer the Persian edition written after it was compiled"
  end

  # A LIVE PATCH TO ANOTHER PAGE OF THE SAME DOCUMENT reads that page, its text and its notes, and
  # nothing of the document, its versions, its editions or the version's pages again.
  test "a patch to another page of the document reads only that page", %{site: site} do
    {:ok, view, _html} = live(on_site(site), "/docs/guide/install")
    render_async(view, 5_000)

    {_html, patched} =
      queries(fn ->
        html =
          view
          |> element(~s([data-role="doc-sidebar-link"][href="/docs/guide/usage"]))
          |> render_click()

        render_async(view, 5_000)
        html
      end)

    assert has_element?(view, ~s([data-role="doc-section-title"]), "Usage")
    assert twice(patched) == []

    refute Enum.any?(patched, fn {source, _sql, _values} ->
             source in ["mishka_document_workspaces", "mishka_document_workspace_versions"]
           end),
           "the patch read the document again:\n" <>
             Enum.map_join(patched, "\n", fn {s, sql, _v} ->
               "  [#{s}] #{String.slice(sql, 0, 120)}"
             end)
  end

  # What one request for `path` offers in other languages: the header switcher's links, and the
  # languages of the head's `hreflang` links, `x-default` aside. Asserted along the way: the request
  # read no row of `pages`.
  defp offered(site, path) do
    {conn, ran} = queries(fn -> get(on_site(site), path) end)
    doc = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.filter(ran, &(elem(&1, 0) == "pages")) == [],
           "#{path} read pages: #{inspect(ran)}"

    menu =
      doc
      |> LazyHTML.query("#site-language-menu a[hreflang]")
      |> Enum.map(&{hd(LazyHTML.attribute(&1, "hreflang")), hd(LazyHTML.attribute(&1, "href"))})

    head =
      doc
      |> LazyHTML.query(~s|head link[rel="alternate"]:not([hreflang="x-default"])|)
      |> Enum.map(&hd(LazyHTML.attribute(&1, "hreflang")))

    {menu, head}
  end

  # THE QUERIES THAT READ THE SAME TABLE WITH THE SAME FILTER AND THE SAME VALUES as another of the
  # same request: the statement after its columns — the table, the joins and the conditions — and
  # what it was run with. Two reads of one row with different columns are the same read.
  defp twice(ran) do
    ran
    |> Enum.frequencies_by(fn {source, sql, values} -> {source, filter_of(sql), values} end)
    |> Enum.filter(fn {_read, times} -> times > 1 end)
    |> Enum.map(fn {{source, filter, _values}, times} ->
      {source, times, String.slice(filter, 0, 200)}
    end)
  end

  defp filter_of(sql) do
    case String.split(sql, " FROM ", parts: 2) do
      [_columns, rest] -> rest
      [whole] -> whole
    end
  end

  # Every query the repo runs while `fun` runs, from any process — a block reading in a task
  # included — as `{table, statement, values}`.
  defp queries(fun) do
    test = self()
    ref = make_ref()
    handler = "page-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mishka_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        send(test, {ref, {meta[:source] || "?", meta[:query], meta[:params]}})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A document in two languages, joined by their group of translations; the English one with an
  # older version beside its latest, two pages and a note on the first, and the Persian one with the
  # first page's translation.
  defp records!(site) do
    guide = document!(site, "Guide", "guide", "en", nil)
    latest = version!(site, guide, "1.0.0", true, ~U[2026-03-01 00:00:00Z])
    older = version!(site, guide, "0.9.0", false, ~U[2026-01-01 00:00:00Z])

    install = page!(site, latest, "install", "Install", 0, "en", nil)
    page!(site, latest, "usage", "Usage", 1, "en", nil)
    page!(site, older, "install", "Install", 0, "en", nil)

    Ash.Seed.seed!(MishkaDocument.Note, %{
      site_id: site.id,
      section_id: install.id,
      title: "Before you start",
      content: "<p>Read this first.</p>",
      order_position: 0,
      content_review_status: :approved,
      technical_review_status: :approved
    })

    rahnama = document!(site, "Rahnama", "rahnama", "fa", guide.language_group_id || guide.id)
    persian = version!(site, rahnama, "1.0.0", true, ~U[2026-03-01 00:00:00Z])
    page!(site, persian, "nasb", "Nasb", 0, "fa", install.language_group_id || install.id)

    :ok
  end

  defp document!(site, name, slug, language, group) do
    create_workspace!(
      site_id: site.id,
      skip_version: true,
      status: :active,
      name: name,
      slug: slug,
      language: language,
      language_group_id: group
    )
  end

  defp version!(site, document, number, latest?, published_at) do
    create_workspace_version!(
      site_id: site.id,
      workspace_id: document.id,
      status: :stable,
      version_number: number,
      is_latest_for_version: latest?,
      published_at: published_at
    )
  end

  defp page!(site, version, slug, title, order, language, group) do
    create_section!(
      site_id: site.id,
      workspace_version_id: version.id,
      title: title,
      slug: slug,
      order_position: order,
      language: language,
      language_group_id: group,
      content: "<h2>Part</h2><p>#{title}.</p>",
      content_review_status: :approved,
      technical_review_status: :approved
    )
  end

  # A page of the site's own in English and in Persian, two rows of one language group under the
  # site's layout — the header's switcher is the layout's.
  defp translated!(site, layout_id) do
    about = edition!(site, layout_id, name: "about", path: "/about")

    fa =
      edition!(site, layout_id,
        name: "about-fa",
        path: "/fa/about",
        language: "fa",
        language_group_id: about.id
      )

    {about, fa}
  end

  defp edition!(site, layout_id, attrs) do
    create_page!(
      [site_id: site.id, layout_id: layout_id, template: "<p>{@page.language}</p>"] ++ attrs
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

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end
end
