# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RuntimeBarePageTest do
  @moduledoc """
  A database page with no layout is drawn bare, like a full-width canvas template: exactly the markup
  its author wrote, with the flash group after it and no `main`, width or padding around it.

  `MishkaCmsWeb.RuntimeLive.default_layout/1` used to put such a page in `MishkaCmsWeb.Layouts.app/1`,
  a padded `max-w-4xl` column the author could neither see nor change from the admin, while the
  editor's canvas drew the page edge to edge. Now the canvas, the draft preview (see
  `MishkaCmsWeb.PagePreviewRouteTest`) and the published page all draw it bare, and the author sets
  a width by wrapping the content in a section, for example `max-w-4xl mx-auto`.

  `async: false`: the install flag, `SiteState` and the routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsWeb.RuntimeLive

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

    %{site: site}
  end

  # A row is not yet a route: `RuntimeLive` resolves a path through `WebRunTimeMetaDataState`, which
  # boot fills and a test fills itself.
  defp published!(site, template) do
    page =
      create_page!(
        site_id: site.id,
        path: "/bare-#{System.unique_integer([:positive])}",
        template: template
      )

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

  describe "a published page with no layout" do
    test "is drawn bare, with the flash group after it", %{site: site} do
      page = published!(site, ~s(<p id="bare-probe">Bare</p>))

      {:ok, view, _html} = live(on_site(), page.path)

      assert has_element?(view, "#bare-probe", "Bare")
      refute has_element?(view, "main #bare-probe")
      refute has_element?(view, ".max-w-4xl #bare-probe")
      assert has_element?(view, "#flash-group")
    end

    test "keeps the width its author gives it with a section of its own", %{site: site} do
      page =
        published!(
          site,
          ~s(<section id="centered" class="mx-auto max-w-4xl"><p id="bare-probe">Bare</p></section>)
        )

      {:ok, view, _html} = live(on_site(), page.path)

      assert has_element?(view, "section#centered.mx-auto.max-w-4xl > #bare-probe", "Bare")
      refute has_element?(view, "main #centered")
    end
  end

  describe "default_layout/1" do
    test "draws the page as written and keeps its flash messages" do
      html =
        %{
          inner_content: Phoenix.HTML.raw(~s(<p id="bare-probe">Bare</p>)),
          flash: %{"info" => "Saved the page"}
        }
        |> RuntimeLive.default_layout()
        |> rendered_to_string()

      assert html =~ ~r/\A\s*<p id="bare-probe">Bare<\/p>/
      assert html =~ ~s(id="flash-group")
      assert html =~ "Saved the page"
      refute html =~ "<main"
    end
  end
end
