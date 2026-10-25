# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogPageQueriesTest do
  @moduledoc """
  Every page of the blog asks the database for each of its rows once per request: the head, the
  frame and the page's blocks share the one read the page made of its record
  (`MishkaCmsCore.Runtime.PageSource`, `MishkaBlog.PageSource`), and two blocks on one page that
  show the same rows — the front page's search box and list, its featured strip and the list that
  leaves the strip's posts out, a post's article and its next reads — share it too.

  Each test counts the queries the repo runs during one request, through its telemetry events, for
  the HTTP render and again for the connected mount, which renders the page anew: no two of them
  read the same table with the same filter and the same values, and there are no more of them than
  the page needs. The counts, as a guest on the site `records!/1` seeds — in two languages, with a
  locked category, so a card's lock is worked out from the categories: the front page 8, a post 12,
  a category 8, a tag 8, a blogger 6, a team 6, and the categories, tags and people pages 3, 2 and 4.
  Each is at or under what the release before read on the sample data: the front page 12, a post 26,
  a category and a tag 12, the categories page 2 (with no posts under its cards; its 3 now are the
  categories with their counts and one read of the newest posts under every one of them).

  Here rather than in the blog's suite because only this application has the router, the runtime
  LiveView and the hooks a request runs.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  repo's telemetry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  import MishkaBlog.Dev.Generator,
    only: [
      tag: 2,
      post_collection: 1,
      post_tag: 1,
      blogger: 2,
      team: 2,
      team_member: 1,
      post_blogger: 1
    ]

  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  # WHAT EACH PAGE NEEDS, AND NO MORE. Every page starts with the site's own editions of the page
  # (core).
  #
  #   * A post: the post with its rating and its count of comments and, loaded with it, its
  #     categories, its tags, its authors and their teams, its other editions, and its lock, worked
  #     out from the categories (two); the address of the authors' page for the head; the
  #     conversation; and the next reads, in one statement with the category each card names.
  #   * The front page: the count of its posts and which ones its strip draws; then the strip's
  #     cards and the first page of its list in one read, each with its first category, then their
  #     people and their lock (two), loaded once for both; and the row of categories by the list.
  #   * A category and a tag: the row with its count and its other editions, then the first page of
  #     its list as the front page reads its own, and the row of categories.
  #   * The page of categories: the categories with their counts, and the newest posts under every
  #     one of them in one read — the same however many categories there are.
  @budgets %{
    home: 8,
    post: 12,
    category: 8,
    tag: 8,
    categories: 3,
    tags: 2,
    people: 4,
    author: 6,
    team: 6
  }

  # ONE SITE FOR THE WHOLE MODULE, set up once. Provisioning compiles every page of the site, which
  # was nearly all that this setup cost each test, and the tests below only add to the site and ask
  # for it: what a test adds or changes is taken back by the savepoint that
  # `MishkaCms.DataCase.setup_module_sandbox/0` gives it, and the cache by the snapshot it takes of
  # it. The name is unique per module: a component's module is named from its site's name, so a
  # reused one renders the previous module's pages against a site that module rolled back.
  setup_all do
    context = MishkaCms.DataCase.setup_module_sandbox()

    SiteState.clear()
    name = "blogqueries#{System.unique_integer([:positive])}"
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
    records = records!(site)
    MishkaBlog.Provision.ensure!(site)
    register_routes!(site)

    context |> Map.put(:site, site) |> Map.put(:records, records)
  end

  for {page, label} <- [
        home: "the blog's front page, its featured strip and its list",
        post: "a post, its conversation and its next reads",
        category: "a category's page",
        tag: "a tag's page",
        categories: "the page of categories",
        tags: "the page of tags",
        people: "the page of people",
        author: "a blogger's page",
        team: "a team's page"
      ] do
    test "#{label} reads each of its rows once", %{site: site, records: records} do
      path = address_of(unquote(page), records)
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

  # ONE READ FOR THE POSTS UNDER EVERY CATEGORY, NOT ONE PER CATEGORY. The page of categories draws
  # each with its count and its newest posts; three more categories, each with a post, cost it no
  # query more.
  test "the page of categories reads as much for five categories as for two", %{site: site} do
    path = "/blog/categories"
    _built = get(on_site(site), path)

    {conn, before} = queries(fn -> get(on_site(site), path) end)
    assert conn.status == 200

    for name <- ~w(Alpha Beta Gamma) do
      file!(post!(site, "In #{name}", "en", []), category!(site, name, []))
    end

    {conn, after_more} = queries(fn -> get(on_site(site), path) end)
    assert conn.status == 200
    assert conn.resp_body =~ "In Gamma"

    assert length(after_more) == length(before),
           "#{length(before)} queries for the categories before, #{length(after_more)} after three more"
  end

  defp address_of(:home, _records), do: "/blog"
  defp address_of(:post, records), do: "/blog/#{records.post.slug}"
  defp address_of(:category, records), do: "/blog/category/#{records.category.slug}"
  defp address_of(:tag, records), do: "/blog/tag/#{records.tag.slug}"
  defp address_of(:categories, _records), do: "/blog/categories"
  defp address_of(:tags, _records), do: "/blog/tags"
  defp address_of(:people, _records), do: "/blog/people"
  defp address_of(:author, records), do: "/blog/author/#{records.blogger.slug}"
  defp address_of(:team, records), do: "/blog/team/#{records.team.slug}"

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
    handler = "blog-page-queries-#{System.unique_integer([:positive])}"

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

  # A category and a post in two languages each, two featured posts among five of the category, a
  # tag in two languages on two of them, and their blogger in a team; beside them a second category
  # with a post of its own, and a locked one holding a post of its own and one of the five — so a
  # card's lock is worked out from the categories, as on a site that locks any.
  defp records!(site) do
    category =
      create_collection!(
        site_id: site.id,
        status: :active,
        name: "News",
        slug: "news",
        language: "en"
      )

    guides = category!(site, "Guides", [])
    members = category!(site, "Members", ["members:read"])

    create_collection!(
      site_id: site.id,
      status: :active,
      name: "Akhbar",
      slug: "akhbar",
      language: "fa",
      language_group_id: category.language_group_id || category.id
    )

    post = post!(site, "First", "en", featured: true)
    post!(site, "Avval", "fa", language_group_id: post.language_group_id || post.id)
    second = post!(site, "Second", "en", featured: true)
    others = for title <- ~w(Third Fourth Fifth), do: post!(site, title, "en", [])

    for filed <- [post, second | others] do
      [post_id: filed.id, collection_id: category.id] |> post_collection() |> generate()
    end

    file!(post!(site, "A guide", "en", []), guides)
    file!(post!(site, "Behind the lock", "en", []), members)
    file!(List.last(others), members)

    tag = [name: "elixir", slug: "elixir", language: "en"] |> tag(site.id) |> generate()

    [
      name: "iksir",
      slug: "iksir",
      language: "fa",
      language_group_id: tag.language_group_id || tag.id
    ]
    |> tag(site.id)
    |> generate()

    [post_id: post.id, tag_id: tag.id] |> post_tag() |> generate()
    [post_id: second.id, tag_id: tag.id] |> post_tag() |> generate()

    user = create_user!(site_id: site.id)
    blogger = [site_id: site.id, user_id: user.id] |> blogger(site.id) |> generate()
    team = [site_id: site.id, status: :active] |> team(site.id) |> generate()
    [team_id: team.id, blogger_id: blogger.id] |> team_member() |> generate()
    [post_id: post.id, blogger_id: blogger.id] |> post_blogger() |> generate()
    [post_id: second.id, blogger_id: blogger.id] |> post_blogger() |> generate()

    %{post: post, category: category, tag: tag, blogger: blogger, team: team}
  end

  defp category!(site, name, permissions) do
    create_collection!(
      site_id: site.id,
      status: :active,
      name: name,
      slug: String.downcase(name),
      language: "en",
      permissions: permissions
    )
  end

  defp file!(post, category),
    do: [post_id: post.id, collection_id: category.id] |> post_collection() |> generate()

  defp post!(site, title, language, overrides) do
    create_blog_post!(
      [
        site_id: site.id,
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

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end
end
