# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PreviewLeavingLinksTest do
  @moduledoc """
  A link that leaves a preview opens the published page in a new tab — and only a preview does that.

  The reported shape: a draft of a blog list, where each post's title is a `<.link navigate>` to the
  published post. Followed in the preview's tab, the draft was replaced by the live site and nothing
  said so. Which draft of the post page to show instead cannot be known — a page may have many — so
  the link opens published, elsewhere, and the draft stays where it was.

  The click itself is `assets/js/preview.js` and is tested there (`preview.test.js`). What is asserted
  here is the half that lives in this project's markup: the `:preview` layout loads that script, the
  layout a visitor gets does not, and the draft says what its links do.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  @script ~s(script[src="/assets/js/preview.js"])

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

    template = ~s(<.link id="post" navigate="/listing/post/hello">Hello</.link>)
    path = "/listing-#{System.unique_integer([:positive])}"
    page = create_page!(site_id: site.id, path: path, template: template)

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

    draft =
      PageDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: page.name,
          title: page.title,
          path: page.path,
          template: template,
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

  defp document(path),
    do: on_localhost() |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  test "a draft's preview loads the script that sends those links to a new tab", %{draft: draft} do
    doc = document("/_preview/page/#{draft.preview_token}")

    assert count(doc, @script) == 1, "the preview page does not load assets/js/preview.js"
    assert count(doc, "#post") == 1
  end

  test "so does the published original's preview, which is the same route", %{page: page} do
    doc = document("/_preview/page/#{page.preview_token}")

    assert count(doc, @script) == 1
  end

  test "and the draft says so, where it already says it is a draft", %{draft: draft} do
    banner =
      "/_preview/page/#{draft.preview_token}"
      |> document()
      |> LazyHTML.query("#mishka-draft-banner")
      |> LazyHTML.text()

    assert banner =~ "Links to other pages open the published site in a new tab."
  end

  test "the published page does NOT load it — a visitor's links stay ordinary links", %{
    page: page
  } do
    doc = document(page.path)

    assert count(doc, "#post") == 1, "the published page did not render, so this proves nothing"
    assert count(doc, @script) == 0, "a visitor's page was given the preview's link handling"
  end
end
