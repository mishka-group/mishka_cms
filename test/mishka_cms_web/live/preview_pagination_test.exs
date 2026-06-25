defmodule MishkaCmsWeb.PreviewPaginationTest do
  @moduledoc """
  A page that keeps its state in the URL pages INSIDE its preview.

  The reported shape: a draft of a blog list, opened at `/_preview/page/:token`. Its pager is built
  from `base={@page.path}` and `params={@query_params}`, and the preview handed the template the
  PUBLISHED path and an empty query. So "Next" pointed at `/test-blog-posts?page=2` — a different
  route, which LiveView answers by leaving for the live page — and `/_preview/page/:token?page=2`
  typed by hand still drew page one.

  See `MishkaCmsWeb.DraftPreviewLive.handle_params/3` and
  `MishkaCmsCore.Runtime.RuntimePreview.inner_html/6`.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.States.SiteState

  # The pager of `blog-post-list`, reduced to what it reads: the page's own path and the query.
  @template ~S"""
  <div>
    <span id="asked">{@query_params["page"] || "none"}</span>
    <span id="kept">{@query_params["sort"] || "none"}</span>
    <.link id="next" patch={@page.path <> "?" <> URI.encode_query(Map.put(@query_params, "page", "2"))}>
      Next
    </.link>
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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    MishkaCmsCore.Settings.put("cms.offline", false)

    page = create_page!(site_id: site.id, path: "/listing", template: @template)

    draft =
      PageDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: page.name,
          title: page.title,
          path: page.path,
          template: @template,
          source_page_id: page.id
        },
        tenant: site.id
      )
      |> Ash.create!(authorize?: false)

    %{draft: draft, page: page}
  end

  defp on_localhost do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> strip()

  defp strip(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> hd()
  end

  describe "a draft's preview" do
    test "reads the page asked for in its own address", %{draft: draft} do
      {:ok, view, _html} = live(on_localhost(), "/_preview/page/#{draft.preview_token}?page=3")

      assert text(view, "#asked") == "3", "the preview drew page one whatever the address said"
    end

    test "builds the pager on the preview's path, not the published one", %{draft: draft} do
      preview = "/_preview/page/#{draft.preview_token}"
      {:ok, view, _html} = live(on_localhost(), preview)

      assert href(view, "#next") == preview <> "?page=2",
             "Next points away from the preview, at the published page"
    end

    test "and a click on it pages here, keeping the rest of the query", %{draft: draft} do
      preview = "/_preview/page/#{draft.preview_token}"
      {:ok, view, _html} = live(on_localhost(), preview <> "?sort=oldest")

      view |> element("#next") |> render_click()

      assert_patch(view, preview <> "?page=2&sort=oldest")
      assert text(view, "#asked") == "2"
      assert text(view, "#kept") == "oldest"
    end

    test "does not hand the route's own keys to the template as a query", %{draft: draft} do
      {:ok, view, _html} = live(on_localhost(), "/_preview/page/#{draft.preview_token}")

      refute href(view, "#next") =~ "token=", "the token leaked into the page's query string"
      refute href(view, "#next") =~ "resource="
    end
  end

  # THE SAME ROUTE SERVES THE LIVE ORIGINAL, through the same code, so it pages the same way.
  test "a published page's preview pages inside the preview too", %{page: page} do
    preview = "/_preview/page/#{page.preview_token}"
    {:ok, view, _html} = live(on_localhost(), preview <> "?page=4")

    assert text(view, "#asked") == "4"
    assert href(view, "#next") == preview <> "?page=2"
  end
end
