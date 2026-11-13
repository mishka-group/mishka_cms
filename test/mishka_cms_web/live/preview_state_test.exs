# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PreviewStateTest do
  @moduledoc """
  A preview state an extension names (`MishkaCmsCore.Runtime.PreviewStates`) reaches the page as
  `@preview_state` on the preview route alone. `?preview_state=` on the published page is an
  ordinary query key, so a visitor cannot draw what only a preview may.

  See `MishkaCmsWeb.DraftPreviewLive.handle_params/3`.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}

  @template ~S"""
  <div>
    <span id="state">{assigns[:preview_state] || "none"}</span>
    <span id="query">{@query_params["preview_state"] || "none"}</span>
    <span id="language">{@page.language}</span>
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

    snapshot = SettingsState.snapshot()
    :persistent_term.put(:mishka_installed, true)
    MishkaCmsCore.Settings.put("cms.offline", false)
    MishkaCmsCore.Settings.put("site.languages", ["en", "fr"], site_id: site.id)

    page = create_page!(site_id: site.id, path: "/confirm-state", template: @template)

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

    on_exit(fn ->
      SettingsState.restore(snapshot)
      :persistent_term.erase(:mishka_installed)
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.clear()
    end)

    %{page: page}
  end

  defp on_localhost do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  test "the preview assigns the state and keeps it out of the query", %{page: page} do
    {:ok, view, _html} =
      live(on_localhost(), "/_preview/page/#{page.preview_token}?preview_state=confirmed")

    assert text(view, "#state") == "confirmed"
    assert text(view, "#query") == "none"
  end

  test "a preview with no state has none", %{page: page} do
    {:ok, view, _html} = live(on_localhost(), "/_preview/page/#{page.preview_token}")

    assert text(view, "#state") == "none"
  end

  test "the published page never has one, whatever its address says", %{page: page} do
    {:ok, view, _html} = live(on_localhost(), page.path <> "?preview_state=confirmed")

    assert text(view, "#state") == "none"
  end

  # A record sample names its language as the live route's `:lang` capture would.
  test "a sample's language draws the page in it, when the site publishes in it", %{page: page} do
    preview = "/_preview/page/#{page.preview_token}"
    {:ok, view, _html} = live(on_localhost(), preview <> "?lang=fr&slug=a-post")
    assert text(view, "#language") == "fr"

    {:ok, view, _html} = live(on_localhost(), preview <> "?lang=de")
    assert text(view, "#language") == page.language
  end
end
