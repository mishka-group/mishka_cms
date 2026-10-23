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

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{Languages, Layout, Media, Page}
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

  # A VISITOR IS READ ONLY WHERE THE LAYOUT NAMES ONE, and the layout hands the header
  # `@current_user`, so this page loads the signed-in visitor like any page that shows one.
  describe "the header's visitor" do
    test "offers Sign in to a visitor who is not signed in", %{} do
      {:ok, _view, html} = live(on_site(), "/")

      assert html =~ ~r/<a href="\/auth"[^>]*>\s*Sign in\s*<\/a>/
      refute html =~ "site-user-menu"
      refute html =~ "site-sign-out"
    end

    test "shows a signed-in visitor their email in place of Sign in", %{site: site} do
      user = create_user!(site_id: site.id)

      {:ok, _view, html} = live(signed_in_as(user), "/")

      assert html =~ ~s(id="site-user-email")
      assert html =~ to_string(user.email)
      refute html =~ ~r/>\s*Sign in\s*</
      refute html =~ "site-admin-console"
    end

    test "the Sign out in the menu signs the visitor out", %{site: site} do
      user = create_user!(site_id: site.id)
      conn = signed_in_as(user)

      {:ok, _view, html} = live(conn, "/")
      [form] = Regex.run(~r/<form[^>]*id="site-sign-out-form"[^>]*>.*?<\/form>/s, html)

      # THE FORM THE BROWSER SUBMITS: the route, the method override and the token a form carries.
      assert form =~ ~s(action="/auth/sign-out")
      assert form =~ ~r/name="_method"[^>]*value="delete"/
      assert [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, form)

      signed_out = delete(conn, "/auth/sign-out", %{"_csrf_token" => token})

      assert redirected_to(signed_out) == "/"
      assert Plug.Conn.get_session(signed_out, "live_socket_id") == nil

      # AND THE NEXT PAGE KNOWS: the same browser is offered Sign in again.
      {:ok, _view, after_html} =
        signed_out |> Phoenix.ConnTest.recycle() |> with_site_host() |> live("/")

      assert after_html =~ ~r/<a href="\/auth"[^>]*>\s*Sign in\s*<\/a>/
      refute after_html =~ to_string(user.email)
    end

    test "offers an admin the console and their account settings", %{site: site} do
      admin = create_user!(site_id: site.id)

      admin
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [permission!("admin:dashboard:*").id]},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

      {:ok, _view, html} = live(signed_in_as(admin), "/")

      assert [console] = Regex.run(~r/<a [^>]*id="site-admin-console"[^>]*>/, html)
      assert console =~ ~s(href="/admin/dashboard")
      assert html =~ ~s(href="/admin/dashboard/settings?tab=preferences")
    end
  end

  describe "the header's language switcher" do
    test "is not there while the site publishes in one language", %{} do
      {:ok, _view, html} = live(on_site(), "/")

      refute html =~ "site-language-menu"
      refute html =~ "hreflang"
    end

    test "lists every language of a site that has two, flagged and named, the current one marked",
         %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      {:ok, _view, html} = live(on_site(), "/")

      assert html =~ "site-language-menu"
      assert html =~ ~s(href="/fa")
      assert html =~ Languages.flag("en")
      assert html =~ Languages.flag("fa")
      assert html =~ Languages.name("en")
      assert html =~ Languages.name("fa")

      assert [[english]] = Regex.scan(~r/<a [^>]*aria-current="true"[^>]*>/, html)
      assert english =~ ~s(hreflang="en")

      {:ok, _view, in_persian} = live(on_site(), "/fa")

      assert [[persian]] = Regex.scan(~r/<a [^>]*aria-current="true"[^>]*>/, in_persian)
      assert persian =~ ~s(hreflang="fa")
    end

    test "is in the navbar and not the footer", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      {:ok, _view, html} = live(on_site(), "/")

      [header, rest] = String.split(html, "</header>", parts: 2)
      [_before_footer, footer] = String.split(rest, "<footer", parts: 2)

      assert header =~ "site-language-menu"
      refute footer =~ "hreflang"
      refute footer =~ "site-language"
    end
  end

  describe "the version" do
    test "is the application's, read when the page is drawn", %{} do
      {:ok, _view, html} = live(on_site(), "/")

      version = to_string(Application.spec(:mishka_cms, :vsn))

      assert version =~ ~r/\A\d+\.\d+\.\d+/
      assert html =~ "<span>v#{version}</span>"
      refute html =~ "v1.0"
    end
  end

  defp signed_in_as(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp with_site_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
