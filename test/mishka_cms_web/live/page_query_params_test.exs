defmodule MishkaCmsWeb.PageQueryParamsTest do
  @moduledoc """
  A page template can read the visitor's query string, and that is how a component puts state in the
  URL.

  A live component on a published page holds its state on the server, which is right for a click and
  wrong for an address bar: page three of a post list was page three until the reader reloaded,
  shared the link, or pressed Back. Putting the number in the URL is what fixes all three, and it
  needs one thing the runtime did not have — a way for the page's template to see what the visitor
  asked for.

  `MishkaCmsWeb.RuntimeLive` now assigns `@query_params`, in `mount/3` for the first load and in
  `handle_params/3` for every `<.link patch>` after it. A page hands it down:

      <.component component_name="blog-post-list" site="localhost" id="posts"
                  page={@query_params["page"]} />

  and the component's pager is a `<.link patch>` rather than a `phx-click`, so Back works for free.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :integration

  @asked_template ~S"""
  <div><span data-role="asked">{@query_params["page"] || "none"}</span></div>
  """

  @slug_template ~S"""
  <div><span data-role="asked">{@query_params["slug"] || "none"}</span></div>
  """

  @two_template ~S"""
  <div>
    <span data-role="asked">{@query_params["category"]}/{@query_params["slug"]}</span>
  </div>
  """

  @rest_template ~S"""
  <div><span data-role="asked">{@query_params["rest"] || "none"}</span></div>
  """

  @keys_template ~S"""
  <div><span data-role="asked">{inspect(Map.keys(@query_params))}</span></div>
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

    path = "/qp-#{System.unique_integer([:positive])}"
    page = published!(site, path, @asked_template)

    %{conn: on_site(), site: site, page: page, path: path}
  end

  # A ROW IS NOT YET A ROUTE. `RuntimeLive` resolves a path through
  # `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState`, which boot fills and a test has to fill
  # itself — without this every request answers the 404 page rather than the one just created.
  defp published!(site, path, template) do
    page = create_page!(site_id: site.id, path: path, template: template)

    :ok =
      MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0
      })

    page
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp asked(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="asked"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # ONE PAGE PER POST IS NOT A CMS. A page stored at `/post/:slug` answers every post's URL, and the
  # segment the visitor asked for reaches the template the same way a query key does — so one live
  # component serves them all.
  describe "a page stored with a dynamic last segment" do
    setup %{site: site} do
      base = "/dyn-#{System.unique_integer([:positive])}"
      %{page: published!(site, base <> "/:slug", @slug_template), base: base}
    end

    test "answers a request one segment deeper", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, base <> "/hello-world")

      assert asked(view) == ["hello-world"]
    end

    test "and hands the same name a query key would", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, base <> "/from-the-path?other=1")

      assert asked(view) == ["from-the-path"]
    end

    # AN EXACT PATH IS STILL AN EXACT PATH. The dynamic lookup only ever runs after the literal one
    # misses, so a page that resolves today cannot start resolving somewhere else.
    test "never takes a request an exact page already answers", %{
      conn: conn,
      site: site,
      base: base
    } do
      _exact = published!(site, base <> "/exact", @asked_template)

      {:ok, view, _html} = live(conn, base <> "/exact")

      assert asked(view) == ["none"], "the dynamic page answered a path the exact one owns"
    end

    test "and a path it has no segment for is still not found", %{conn: conn, base: base} do
      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, base <> "/one/two")
      end
    end
  end

  # MORE THAN ONE, AND NOT ONLY AT THE END. `Validations.PathFormat` has always allowed paths with
  # "route params like `:id`, and wildcards like `*rest`"; this is what finally matches them.
  describe "a pattern with several captures" do
    test "captures each segment under its own name", %{conn: conn, site: site} do
      base = "/multi-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:category/:slug", @two_template)

      {:ok, view, _html} = live(conn, base <> "/elixir/hello-world")

      assert asked(view) == ["elixir/hello-world"]
    end

    test "and a capture in the middle of literal segments", %{conn: conn, site: site} do
      base = "/mid-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:slug/edit", @slug_template)

      {:ok, view, _html} = live(conn, base <> "/my-post/edit")

      assert asked(view) == ["my-post"]
    end

    test "a wildcard takes the whole tail", %{conn: conn, site: site} do
      base = "/star-#{System.unique_integer([:positive])}"
      published!(site, base <> "/*rest", @rest_template)

      {:ok, view, _html} = live(conn, base <> "/a/b/c")

      assert asked(view) == ["a/b/c"]
    end

    # PRECEDENCE, and it has to be the same on every run or a URL means one thing on Tuesday.
    test "the least wildcarded pattern wins when two match", %{conn: conn, site: site} do
      base = "/prec-#{System.unique_integer([:positive])}"
      published!(site, base <> "/*rest", @rest_template)
      published!(site, base <> "/:slug", @slug_template)

      {:ok, view, _html} = live(conn, base <> "/only-one")

      assert asked(view) == ["only-one"], "the wildcard beat the single capture"
    end

    test "and a literal page still beats both", %{conn: conn, site: site} do
      base = "/lit-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:slug", @slug_template)
      published!(site, base <> "/new", @asked_template)

      {:ok, view, _html} = live(conn, base <> "/new")

      assert asked(view) == ["none"], "the pattern answered a path the literal page owns"
    end

    test "a pattern does not answer a path with too few segments", %{conn: conn, site: site} do
      base = "/short-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:slug", @slug_template)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn -> live(conn, base) end
    end

    test "nor one with too many", %{conn: conn, site: site} do
      base = "/long-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:slug", @slug_template)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(conn, base <> "/one/two")
      end
    end

    # THE QUERY STRING IS THE VISITOR'S OWN WORD. A page whose pattern captures `slug` and whose URL
    # also carries `?slug=` gets the typed one, because that is the one the reader can see.
    test "a query key of the same name wins over the captured segment", %{conn: conn, site: site} do
      base = "/clash-#{System.unique_integer([:positive])}"
      published!(site, base <> "/:slug", @slug_template)

      {:ok, view, _html} = live(conn, base <> "/from-path?slug=from-query")

      assert asked(view) == ["from-query"]
    end
  end

  describe "a page template" do
    test "reads the query string it was loaded with", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path <> "?page=3")

      assert asked(view) == ["3"]
    end

    # NO QUERY STRING IS NOT A MISSING ASSIGN. `@query_params` has to exist either way or a page that
    # reads it raises for every visitor who arrived without one, which is most of them.
    test "and reads an empty map when there was none", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      assert asked(view) == ["none"]
    end

    # THE HALF THAT MAKES BACK WORK. `<.link patch>` re-runs `handle_params/3` without remounting, so
    # the assign has to be refreshed there too — not only in `mount/3`.
    test "and follows a patch to a new query string", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path <> "?page=1")

      assert asked(view) == ["1"]

      {:ok, patched, _html} = live(conn, path <> "?page=7")
      assert asked(patched) == ["7"]

      send(view.pid, {:phoenix, :send_replies, []})
      assert render_patch(view, path <> "?page=4") =~ ~s(data-role="asked")
      assert asked(view) == ["4"], "handle_params did not refresh the assign"
    end

    # THE ROUTE'S OWN WILDCARD IS NOT THE VISITOR'S. `live "/*path"` puts the matched segments under
    # "path" as a LIST, and a template rebuilding a query string from this map would hand
    # `URI.encode_query/1` a list and raise.
    test "and never sees the router's own path segments", %{conn: conn, site: site} do
      page =
        published!(
          site,
          "/qp-keys-#{System.unique_integer([:positive])}",
          @keys_template
        )

      {:ok, view, _html} = live(conn, page.path <> "?page=2")

      assert asked(view) == [~s(["page"])]
    end
  end
end
