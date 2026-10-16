# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageStateTest do
  @moduledoc """
  A database page starts with the assigns it declares in `Page.state`, through `RuntimeLive`.

  The page module has no `mount/3` of its own, so `RuntimeLive` puts the state on the socket: in
  `mount/3` for the first page, in `handle_params/3` when a patch lands on ANOTHER page in the same
  process — whose state replaces the last one's, with what only the last page declared cleared — and
  when the page is edited while it is open, where only the keys the edit added are given their first
  value. These drive each of those through the real LiveView.

  `async: false` — `SiteState`, the routing table and the install flag are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  @moduletag :integration

  @counter ~S"""
  <div>
    <span data-role="count">{@count}</span>
    <span data-role="only-a">{inspect(@only_a)}</span>
    <button id="inc" phx-click="inc">+</button>
  </div>
  """

  @other ~S"""
  <div>
    <span data-role="count">{@count}</span>
    <span data-role="only-a">{inspect(assigns[:only_a])}</span>
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

    a =
      published!(site, @counter,
        state: [%{name: "count", code: "0"}, %{name: "only_a", code: ":a"}],
        events: [
          %{name: "inc", code: "{:noreply, assign(socket, :count, socket.assigns.count + 1)}"}
        ]
      )

    b = published!(site, @other, state: [%{name: "count", code: "100"}])

    %{conn: on_site(), site: site, a: a, b: b}
  end

  defp published!(site, template, attrs) do
    path = "/state-#{System.unique_integer([:positive])}"
    page = create_page!([site_id: site.id, path: path, template: template] ++ attrs)

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

    page
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp read(html_or_view, role) do
    html = if is_binary(html_or_view), do: html_or_view, else: render(html_or_view)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="#{role}"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    |> List.first()
  end

  test "a page reads its state on the first render, before anything has happened", %{
    conn: conn,
    a: a
  } do
    {:ok, view, html} = live(conn, a.path)

    assert read(html, "count") == "0"
    assert read(view, "count") == "0"
    assert read(view, "only-a") == ":a"
  end

  test "a handler moves it from there", %{conn: conn, a: a} do
    {:ok, view, _html} = live(conn, a.path)

    view |> element("#inc") |> render_click()
    view |> element("#inc") |> render_click()

    assert read(view, "count") == "2"
  end

  test "the same page asked again keeps the visitor's values", %{conn: conn, a: a} do
    {:ok, view, _html} = live(conn, a.path)
    view |> element("#inc") |> render_click()

    render_patch(view, a.path <> "?again=1")

    assert read(view, "count") == "1"
  end

  test "another page in the same process starts from its own state, and nothing travels", %{
    conn: conn,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(conn, a.path)
    view |> element("#inc") |> render_click()

    render_patch(view, b.path)

    assert read(view, "count") == "100"
    assert read(view, "only-a") == "nil"

    render_patch(view, a.path)

    assert read(view, "count") == "0", "coming back is a fresh start, not the last visit"
  end

  test "an edit that adds a value reaches an open page without losing the visitor's", %{
    conn: conn,
    a: a
  } do
    {:ok, view, _html} = live(conn, a.path)
    view |> element("#inc") |> render_click()

    a
    |> Ash.Changeset.for_update(
      :master_update,
      %{
        template:
          String.replace(@counter, "</div>", ~S|<span data-role="label">{@label}</span></div>|),
        state: [
          %{name: "count", code: "0"},
          %{name: "only_a", code: ":a"},
          %{name: "label", code: ~S|"fresh"|}
        ]
      },
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.update!()

    assert read(view, "label") == "fresh"
    assert read(view, "count") == "1"
  end

  test "a page that declares no state is served as before", %{conn: conn, site: site} do
    plain = published!(site, ~S|<p data-role="plain">plain</p>|, [])

    {:ok, view, _html} = live(conn, plain.path)

    assert read(view, "plain") == "plain"
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns, :count)
  end

  test "the stored state survives a read of the row", %{a: a} do
    stored = Ash.get!(Page, a.id, action: :master_get, authorize?: false)

    assert Enum.map(stored.state, & &1.name) == ["count", "only_a"]
  end
end
