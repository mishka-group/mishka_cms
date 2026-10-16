# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ComponentSiteScopeTest do
  @moduledoc """
  What a visitor of one site is shown when that site's markup names another site's component,
  driven through the REAL router with the host a visitor sends.

  A component reads as its own site, so `<.component component_name="…" site="another">` on a page
  drew the other site's template — and, for a kit component, its published posts and tags — to this
  site's visitors, whether the other site was switched off, offline or up. Now a page reaches only
  its own site's components and the global ones, and draws nothing where another's was named:

    * a published page, on its first HTTP render and once its socket connects;
    * the global layout around it, which reaches the components of the site it is drawn on;
    * the site's own error page, including one answered before any page named the site;
    * a draft preview.

  See `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`.

  `async: false` — `SiteState`, the routing table and the settings cache are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    n = System.unique_integer([:positive])
    other = create_site!(name: "neighbour-#{n}", host: "neighbour-#{n}.test", active: true)

    for s <- [site, other] do
      :ok = SiteState.save(Map.take(s, [:id, :name, :host, :priority, :active, :master]))
    end

    put_setting!("site.languages", ["en"], site.id)
    put_setting!("cms.offline", false, nil)
    :persistent_term.put(:mishka_installed, true)
    WebRunTimeMetaDataState.delete_by_site(site.name)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.clear()
    end)

    %{
      site: site,
      other: other,
      own: component!(site, "own"),
      foreign: component!(other, "foreign"),
      shared: component!(nil, "shared")
    }
  end

  describe "a published page" do
    test "draws its own site's components and the global ones, and not another site's", ctx do
      slug = published!(ctx.site, tags(ctx))

      html = on_site() |> get("/#{slug}") |> html_response(200)
      page = LazyHTML.from_document(html)

      assert drawn?(page, "own")
      assert drawn?(page, "shared")
      refute drawn?(page, "foreign")
      refute html =~ "failed to render"
    end

    # THE SOCKET IS ANOTHER PROCESS, and the site a render may reach is kept in the process. Named
    # only where the HTTP render ran, the first diff after connecting would refuse the page's own.
    test "draws the same once its socket connects", ctx do
      slug = published!(ctx.site, tags(ctx))

      {:ok, view, _html} = live(on_site(), "/#{slug}")
      page = view |> render() |> LazyHTML.from_fragment()

      assert drawn?(page, "own")
      assert drawn?(page, "shared")
      refute drawn?(page, "foreign")
    end

    # A GLOBAL LAYOUT IS ONE MODULE FOR EVERY SITE. It is drawn on this site, so it reaches this
    # site's components — and still not the neighbour's, whatever its markup names.
    test "the global layout around it reaches this site's components, not another's", ctx do
      layout =
        create_layout!(
          path: "/layouts/scope-#{System.unique_integer([:positive])}",
          template: """
          <div>
            <header>#{tag(ctx.own, ctx.site)}#{tag(ctx.foreign, ctx.other)}</header>
            {@inner_content}
          </div>
          """
        )

      :ok = WebRunTimeMetaDataState.save(route(layout, "Global", "Layout"))
      on_exit(fn -> WebRunTimeMetaDataState.delete(layout.id) end)
      slug = published!(ctx.site, "<p data-role=\"body\">body</p>", layout_id: layout.id)

      page = served("/#{slug}")

      assert drawn?(page, "own")
      refute drawn?(page, "foreign")
      assert page |> LazyHTML.query(~s([data-role="body"])) |> Enum.any?()
    end
  end

  describe "the site's error page" do
    # A DRAFT PREVIEW'S UNKNOWN TOKEN IS REFUSED BEFORE ANY PAGE NAMES THE SITE, so the error page is
    # the first thing in this request to render for it.
    test "draws its own site's components and not another site's", ctx do
      error_page!(ctx.site, tags(ctx))

      {404, _headers, body} =
        assert_error_sent(404, fn -> get(on_site(), "/_preview/page/no-such-token") end)

      page = LazyHTML.from_document(body)

      assert drawn?(page, "own")
      assert drawn?(page, "shared")
      refute drawn?(page, "foreign")
    end
  end

  describe "a draft preview" do
    test "draws its own site's components and not another site's", ctx do
      page = create_page!(site_id: ctx.site.id, template: "<div>#{tags(ctx)}</div>")

      {:ok, _view, html} = live(on_site(), "/_preview/page/#{page.preview_token}")
      page = LazyHTML.from_document(html)

      assert drawn?(page, "own")
      assert drawn?(page, "shared")
      refute drawn?(page, "foreign")
    end
  end

  defp tags(ctx) do
    tag(ctx.own, ctx.site) <> tag(ctx.foreign, ctx.other) <> tag(ctx.shared, nil)
  end

  defp tag(component, nil),
    do: ~s(<.component component_name="#{component.name}" site="Global" />)

  defp tag(component, site),
    do: ~s(<.component component_name="#{component.name}" site="#{site.name}" />)

  defp component!(site, role) do
    component =
      create_component!(
        site_id: site && site.id,
        name: "scope-#{role}-#{System.unique_integer([:positive])}",
        template: ~s(<span data-role="#{role}">#{role}</span>)
      )

    module = Helpers.module_name(component.name, site && site.name, "Component")
    on_exit(fn -> ModuleCompiler.unload(module) end)
    component
  end

  defp published!(site, template, overrides \\ []) do
    slug = "scope-#{System.unique_integer([:positive])}"

    page =
      create_page!(
        [
          site_id: site.id,
          name: slug,
          path: "/:lang/#{slug}",
          template: "<div>#{template}</div>"
        ] ++ overrides
      )

    :ok = WebRunTimeMetaDataState.save(Map.put(route(page, site.name, "Page"), :language, nil))
    slug
  end

  defp error_page!(site, template) do
    error_page =
      ErrorPage
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Errors",
          root_layout_template: nil,
          format: :heex,
          priority: 0,
          error_pages: [%{"status" => 404, "template" => "<div>#{template}</div>"}],
          helpers: [],
          active: true,
          precompile: false
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    :ok = WebRunTimeMetaDataState.save(route(error_page, site.name, "ErrorPage"))

    module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
    on_exit(fn -> ModuleCompiler.unload(module) end)
    error_page
  end

  defp route(record, site_name, section) do
    %{
      id: record.id,
      site: site_name,
      path: record.path,
      title: record.name,
      created_at: DateTime.utc_now(),
      section: section,
      priority: 0
    }
  end

  defp put_setting!(key, value, site_id) do
    prior = if site_id, do: :unset, else: SettingsState.get(nil, key, :unset)
    {:ok, _} = Settings.put(key, value, site_id: site_id)

    on_exit({SettingsState, site_id, key}, fn ->
      if prior == :unset,
        do: SettingsState.delete(site_id, key),
        else: SettingsState.put(site_id, key, prior)
    end)
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp served(path),
    do: on_site() |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp drawn?(page, role),
    do: page |> LazyHTML.query(~s([data-role="#{role}"])) |> Enum.any?()
end
