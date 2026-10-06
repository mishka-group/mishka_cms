defmodule MishkaCmsWeb.LanguageRoutingTest do
  @moduledoc """
  Every address this site answers, driven through the REAL router.

  `MishkaCmsCore.Runtime.Plugs.LanguagePlug` only redirects a request the router would hand to the
  CMS, and it asks `Phoenix.Router.route_info/4` which one that is. The extension's own suite cannot
  ask that question — it has no CMS catch-all to ask it of — and a router it builds for itself
  answers in a different shape: a `live` route keeps its view in the metadata and leaves
  `:plug_opts` holding the live ACTION, so a guard written against `:plug_opts` matched nothing and
  every redirect quietly did not happen. `/` returned 404 in a browser while the unit suite was
  green.

  So this file exists to drive the addresses through `MishkaCmsWeb.Router` itself.

  `async: false` — `SiteState` and the routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

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

    Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    :persistent_term.put(:mishka_installed, true)
    Settings.put("cms.offline", false)

    # The routing table is process-global and outlives a test, so a second one asking for the same
    # address is refused `:path_already_exists` by a row the first left behind.
    WebRunTimeMetaDataState.delete_by_site(site.name)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      WebRunTimeMetaDataState.delete_by_site(site.name)
    end)

    %{site: site}
  end

  defp published!(site, path, language \\ nil) do
    page =
      create_page!(
        site_id: site.id,
        name:
          "lang-#{String.replace(path, ~r/[^a-z]/, "")}-#{System.unique_integer([:positive])}",
        path: path,
        template: ~s(<div><span data-role="served-by-the-cms">#{path}</span></div>)
      )

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0,
        language: language
      })

    page
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  describe "an address that names no language" do
    test "the root is sent to the site's first language", %{site: site} do
      published!(site, "/:lang")

      conn = on_site() |> get("/")

      assert redirected_to(conn) == "/en"
    end

    test "a page's address is sent to the same page under a language", %{site: site} do
      published!(site, "/:lang/blog")

      conn = on_site() |> get("/blog")

      assert redirected_to(conn) == "/en/blog"
    end

    test "the query string survives the redirect", %{site: site} do
      published!(site, "/:lang/blog")

      conn = on_site() |> get("/blog?page=2&q=ash")

      assert redirected_to(conn) == "/en/blog?page=2&q=ash"
    end

    test "a page stored without a language keeps its own address", %{site: site} do
      published!(site, "/no-lang")

      conn = on_site() |> get("/no-lang")

      assert html_response(conn, 200) =~ "served-by-the-cms"
    end
  end

  describe "an address that names one" do
    test "is answered where it stands", %{site: site} do
      published!(site, "/:lang/blog")

      assert on_site() |> get("/en/blog") |> html_response(200) =~ "served-by-the-cms"
    end

    test "and is remembered, so the next unprefixed address follows it", %{site: site} do
      published!(site, "/:lang/blog")
      published!(site, "/fa/pricing")

      remembered = on_site() |> get("/fa/pricing") |> Plug.Conn.get_session(Languages.session())

      assert remembered == "fa"

      conn =
        on_site()
        |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
        |> get("/blog")

      assert redirected_to(conn) == "/fa/blog"
    end

    # The rule must not paper over a page that has no edition in the language asked for. A row
    # carrying its own language answers only that one — see `MishkaCmsCore.Runtime.PageEditions`.
    test "a language the page was not written in is still a 404", %{site: site} do
      published!(site, "/:lang", "en")

      assert on_site() |> get("/en") |> html_response(200) =~ "served-by-the-cms"
      assert_error_sent(404, fn -> on_site() |> get("/fa") end)
    end
  end

  # A visitor who once chose Persian and then asks for the root is not asking for Persian. Sending
  # them to a Persian home nobody wrote is a 404 that a visitor with no session at all does not get.
  describe "a remembered language the page was not written in" do
    test "falls back to the site's first rather than a dead end", %{site: site} do
      published!(site, "/:lang", "en")

      conn =
        on_site()
        |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
        |> get("/")

      assert redirected_to(conn) == "/en"
    end

    test "but an address that names it is answered, or 404s, on its own terms", %{site: site} do
      published!(site, "/:lang", "en")

      assert_error_sent(404, fn ->
        on_site()
        |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
        |> get("/fa")
      end)
    end
  end

  # A `<.link navigate>` inside an open socket never reaches a plug, and `mount/3` resolves the
  # address before `handle_params/3` is called — so a guard in `handle_params/3` alone was reached
  # only on a patch, and a click on an unprefixed link 404ed where a fresh load of the same href
  # redirected. `live_redirect/2` mounts the way the browser does, without the pipeline.
  describe "a live navigation" do
    test "to an address with no language is redirected the way a fresh load is", %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/fa/pricing")

      assert {:error, {:live_redirect, %{to: "/fa/blog"}}} = live_redirect(view, to: "/blog")
    end

    test "to one that already names a language is left alone", %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/en/pricing")

      assert {:ok, _view, _html} = live_redirect(view, to: "/en/blog")
    end
  end

  # THE SIGN-IN PAGES ARE THE SITE'S OWN RUNTIME PAGES at `/<language>/auth…`, so `/auth…` is an
  # address the CMS answers, and the links that name it — a sign-in asked for with `?return_to=`, an
  # emailed token — arrive with their query.
  describe "the sign-in addresses" do
    test "are sent to the page under the visitor's language, query kept", %{site: site} do
      published!(site, "/:lang/auth")
      published!(site, "/:lang/auth/password-reset/:token")

      assert on_site() |> get("/auth?return_to=abc") |> redirected_to() ==
               "/en/auth?return_to=abc"

      assert on_site() |> get("/auth/password-reset/tok?master_user=false") |> redirected_to() ==
               "/en/auth/password-reset/tok?master_user=false"
    end

    test "answer in the language the address names", %{site: site} do
      published!(site, "/:lang/auth")

      {:ok, view, _html} = live(on_site(), "/fa/auth")

      assert has_element?(view, ~s([data-role="served-by-the-cms"]))
    end
  end

  describe "<html lang>" do
    test "is a database page's language, the admin's on an admin page, and English otherwise" do
      alias MishkaCmsWeb.RuntimeLive

      assert RuntimeLive.html_lang(%{runtime_page: true, page: %{language: "fa"}}) == "fa"
      assert RuntimeLive.html_lang(%{admin_language: "de"}) == "de"
      assert RuntimeLive.html_lang(%{}) == "en"
    end

    test "has a direction on a database page and an admin page, and none otherwise" do
      alias MishkaCmsWeb.RuntimeLive

      assert RuntimeLive.html_dir(%{runtime_page: true, page: %{language: "fa"}}) == "rtl"
      assert RuntimeLive.html_dir(%{admin_css: true, admin_language: "fa"}) == "rtl"
      assert RuntimeLive.html_dir(%{admin_css: true, admin_language: "en"}) == "ltr"

      assert RuntimeLive.html_dir(%{admin_css: true, live_tailwind: true, admin_language: "fa"}) ==
               nil

      assert RuntimeLive.html_dir(%{admin_language: "fa"}) == nil
      assert RuntimeLive.html_dir(%{}) == nil
    end
  end
end
