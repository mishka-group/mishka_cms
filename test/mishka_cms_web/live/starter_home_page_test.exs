# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.StarterHomePageTest do
  @moduledoc """
  The page a first install answers `/` with, through `MishkaCmsWeb.RuntimeLive` and the real
  compiler: the `site-main` layout drawing the `site-header` and `site-footer` components around the
  home page, with the logo a file of the master site's media library that the endpoint really serves.

  `MishkaCmsCore.Install.StarterContentTest` asserts what is written; this asserts what a visitor
  gets. The installer's own run is `MishkaCmsCore.Install.BootstrapTest`'s.

  `async: false` — the install flag, `SiteState`, the settings cache and the routing table are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{Layout, Media, Page}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  setup do
    dir = Path.join(System.tmp_dir!(), "starter_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

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
    Settings.put("cms.offline", false)
    WebRunTimeMetaDataState.delete_by_site(site.name)

    # THE BRAND THE USER TYPED, as the installer hands it in.
    report = StarterContent.seed!(site, brand: "Acme Docs")

    layout = Ash.get!(Layout, report.layout_id, action: :read_any, authorize?: false)

    home =
      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site.id and path == "/:lang")
      |> Ash.read_one!(authorize?: false)

    # PUT IN THE ROUTING TABLE the way a boot does, so `/` answers through the runtime.
    routes = [{layout, "Layout"}, {home, "Page"}]

    for {record, section} <- routes do
      :ok =
        WebRunTimeMetaDataState.save(%{
          id: record.id,
          site: site.name,
          path: record.path,
          title: record.name,
          created_at: DateTime.utc_now(),
          section: section,
          priority: 0
        })
    end

    on_exit(fn ->
      for {record, section} <- routes do
        WebRunTimeMetaDataState.delete(record.id)
        module = Helpers.module_name(record.id, site.name, section)
        :code.purge(module)
        :code.delete(module)
      end

      # THE COMPONENTS ARE BUILT BY THE FIRST RENDER, and named by the site and the row.
      for name <- ["site-header", "site-footer"] do
        module = Helpers.module_name(name, site.name, "Component")
        :code.purge(module)
        :code.delete(module)
      end

      WebRunTimeMetaDataState.delete_by_site(site.name)
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    [logo] = Ash.read!(Media, tenant: site.id, authorize?: false)

    %{site: site, logo: logo}
  end

  test "answers `/` with the layout's header and footer around the home page", %{site: site} do
    {:ok, _view, html} = live(on_site(), "/")

    refute html =~ "failed to render"

    # THE HEADER AND THE FOOTER: the layout's, with the name the user typed.
    assert html =~ "<header"
    assert html =~ "Acme Docs"
    assert html =~ "<footer"
    assert html =~ "Powered by"
    assert html =~ ~s(href="https://mishka.tools/sponsor")
    assert html =~ ~s(id="site-theme-dark")
    assert html =~ ~s(id="site-theme-light")

    # THE PAGE: the design's three sections, with the site's own host.
    assert html =~ "up and running"
    assert html =~ "HOW A PAGE IS SERVED"
    assert html =~ "Three steps to replace this page."
    assert html =~ "https://#{site.host}"

    assert html =~ ~s(href="/auth")
    assert html =~ ~s(href="https://mishka.tools/cms/docs")
    refute html =~ ~s(href="#")
  end

  test "draws the media library's logo three times, and the endpoint serves it", %{
    site: site,
    logo: logo
  } do
    {:ok, _view, html} = live(on_site(), "/")

    src = ~s(src="#{logo.relative_path}")
    assert String.starts_with?(logo.relative_path, "/uploads/#{site.id}/media/")
    assert length(String.split(html, src)) - 1 == 3, "header, hero and footer"

    conn = get(on_site(), logo.relative_path)

    assert response(conn, 200)
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "image/png"
  end

  # FROM THE HEAD: the layout's `seo_tags` are drawn there by `page_head/1`, and the body carries no
  # stylesheet link of its own.
  test "links the fonts the design is set in from the head", %{} do
    {:ok, _view, html} = live(on_site(), "/")

    [head, body] = String.split(html, "</head>", parts: 2)

    assert head =~ ~s(rel="preconnect")
    assert head =~ ~s(href="https://fonts.gstatic.com")
    assert head =~ ~s(crossorigin="anonymous")

    assert head =~
             "https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&amp;family=Geist+Mono:wght@400;500&amp;display=swap"

    refute body =~ "fonts.googleapis.com"
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
