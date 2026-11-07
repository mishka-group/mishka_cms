# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageFallThroughTest do
  @moduledoc """
  The addresses a WordPress site leaves behind, served by `MishkaCmsWeb.RuntimeLive`.

  When the extension that owns a pattern page finds no record for the address
  (`MishkaCmsCore.Runtime.PageSource.missing/0`), the next page that matches it is tried, so
  `/:year/:month/:slug` and a catch-all can stand side by side; when none is left the visitor gets
  the site's 404 with a 404 status, not a page saying the post is not here. A page path in Persian
  is reached however the browser spelled it.

  `async: false`: the install flag, `SiteState`, the routing table and the plugin registry are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :integration

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.{PageSource, Seo}
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaInstaller.Event.{Event, EventHandler}

  # AN EXTENSION'S SOURCE PLUGIN: a post is there only at the slug `hello`, and every other slug of
  # its kind is missing.
  defmodule ProbeSource do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:source"

    @impl true
    def call(%{record: "probe:post", params: %{"slug" => "hello"}} = given),
      do: {:reply, :halt, %{given | source: %{slug: "hello"}}}

    def call(%{record: "probe:post"} = given),
      do: {:reply, :halt, %{given | source: PageSource.missing()}}

    def call(given), do: {:reply, given}
  end

  # Its head, which says the post is open to everybody: a record no plugin answers for is locked.
  defmodule ProbeSeo do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:seo"

    @impl true
    def call(%{record: "probe:post"} = seo), do: {:reply, :halt, %{seo | type: "article"}}
    def call(seo), do: {:reply, seo}
  end

  setup do
    SiteState.clear()
    name = "fallthrough#{System.unique_integer([:positive])}"
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
    MishkaCmsCore.Settings.put("cms.offline", false)

    plugins = [{ProbeSource, PageSource.event()}, {ProbeSeo, Seo.event()}]

    for {plugin, event} <- plugins do
      {:ok, _} =
        Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

      :ok = EventHandler.do_compile(event, :start, false)
    end

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)

      for {plugin, event} <- plugins do
        Event.unregister(:name, plugin, false)
        EventHandler.do_compile(event, :start, false)
      end

      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.clear()
    end)

    %{site: site}
  end

  defp published!(site, path, said, opts \\ []) do
    page =
      create_page!(
        site_id: site.id,
        path: path,
        template: ~s(<div data-role="said">#{said}</div>),
        priority: Keyword.get(opts, :priority, 0),
        extra: Keyword.get(opts, :extra, %{})
      )

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: page.priority
      })

    page
  end

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp said(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-role="said"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a pattern page whose record is not there" do
    test "hands the address to the next page that matches it", %{site: site} do
      published!(site, "/:year/:month/:slug", "post",
        priority: 10,
        extra: %{"record" => "probe:post"}
      )

      published!(site, "/*rest", "anything")

      assert site |> on_site() |> get("/2024/05/hello") |> html_response(200) |> said() ==
               ["post"]

      assert site |> on_site() |> get("/2024/05/a-page") |> html_response(200) |> said() ==
               ["anything"]

      {:ok, view, _html} = live(on_site(site), "/2024/05/hello")
      assert view |> render_patch("/2024/05/a-page") |> said() == ["anything"]
    end

    test "answers the site's 404 with a 404 status when no page is left", %{site: site} do
      published!(site, "/:year/:month/:slug", "post", extra: %{"record" => "probe:post"})

      assert site |> on_site() |> get("/2024/05/hello") |> html_response(200) |> said() ==
               ["post"]

      assert_error_sent(404, fn -> site |> on_site() |> get("/2024/05/gone") end)
    end
  end

  describe "a page path in Persian" do
    test "is reached as typed and %-escaped", %{site: site} do
      published!(site, "/%D9%88%D8%B1%D8%AF%D9%BE%D8%B1%D8%B3", "wordpress")

      for path <- ["/وردپرس", "/%D9%88%D8%B1%D8%AF%D9%BE%D8%B1%D8%B3"] do
        assert site |> on_site() |> get(path) |> html_response(200) |> said() == ["wordpress"]
      end
    end
  end
end
