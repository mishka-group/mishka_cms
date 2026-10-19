# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

  So this file exists to drive the addresses through `MishkaCmsWeb.Router` itself, in both of a
  site's URL modes (`MishkaCmsCore.Runtime.Languages.url_mode/1`): through the plug on a fresh load,
  through `MishkaCmsWeb.RuntimeLive` on a live navigation, and through the resolver on both.

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
    Settings.put("site.language_urls", "prefix_others", site_id: site.id)
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

  defp published!(site, path, language \\ nil, overrides \\ []) do
    page =
      create_page!(
        [
          site_id: site.id,
          name:
            "lang-#{String.replace(path, ~r/[^a-z]/, "")}-#{System.unique_integer([:positive])}",
          path: path,
          template: ~s(<div><span data-role="served-by-the-cms">#{path}</span></div>)
        ] ++ overrides
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

  defp html_lang(conn) do
    [lang] =
      Regex.run(~r/<html[^>]*\slang="([^"]*)"/, html_response(conn, 200), capture: :all_but_first)

    lang
  end

  defp prefix_all!(site),
    do: {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

  # The next request of the same browser: its cookie, and the host it asked.
  defp next(conn) do
    conn
    |> Phoenix.ConnTest.recycle()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp sign_in_page(conn) do
    conn |> redirected_to() |> String.split("?", parts: 2) |> hd()
  end

  # A SIGN-IN IS ASKED FOR IN THE LANGUAGE THE VISITOR IS READING, at the address the site's URL mode
  # gives that language: a page only a signed-in visitor opens, the dashboard. A page that needs a
  # member sends nobody to sign in: whoever may not open it gets the site's 404.
  describe "sending a visitor to sign in" do
    setup %{site: site} do
      published!(site, "/:lang/members", nil, permissions: ["members:read"])
      published!(site, "/:lang/auth/sign-out", nil, extra: %{"signed_in_only" => true})
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")
      :ok
    end

    test "keeps the reader's language, the first one unprefixed", %{site: _site} do
      assert on_site() |> get("/fa/auth/sign-out") |> sign_in_page() == "/fa/auth"
      assert on_site() |> get("/auth/sign-out") |> redirected_to() == "/auth"
    end

    test "names every language when the site prefixes them all", %{site: site} do
      prefix_all!(site)

      assert on_site() |> get("/fa/auth/sign-out") |> sign_in_page() == "/fa/auth"
      assert on_site() |> get("/en/auth/sign-out") |> sign_in_page() == "/en/auth"
    end

    test "from a live navigation, in the language of the page navigated to", %{site: _site} do
      {:ok, view, _html} = live(on_site(), "/fa/pricing")

      assert {:error, {:redirect, %{to: "/fa/auth"}}} =
               live_redirect(view, to: "/fa/auth/sign-out")
    end

    @tag :capture_log
    test "is not what a page that needs a member does: a visitor who is not signed in gets the 404",
         %{site: _site} do
      for path <- ["/members", "/fa/members"] do
        assert_error_sent(404, fn -> get(on_site(), path) end)
      end
    end

    # THE ADMIN KEEPS ITS OWN LANGUAGE, the session's `admin_language`, and the one a visitor reads
    # the site in is the last page's: the dashboard sends them to sign in in it, and changes nothing.
    test "from the dashboard, in the language the visitor was reading, which it leaves as it was",
         %{site: site} do
      prefix_all!(site)

      reading = on_site() |> get("/fa/pricing")
      assert Plug.Conn.get_session(reading, Languages.session()) == "fa"

      dashboard = reading |> next() |> get("/admin/dashboard")
      assert redirected_to(dashboard) == "/fa/auth"
      assert Plug.Conn.get_session(dashboard, Languages.session()) == "fa"

      assert dashboard |> next() |> get("/blog") |> redirected_to(302) == "/fa/blog"
    end
  end

  # THE DEFAULT: no prefix for the site's first language, and the address decides — never the
  # session, never the browser.
  describe "with no prefix for the primary language" do
    test "the root is the primary language's home, served where it stands", %{site: site} do
      published!(site, "/:lang")

      conn = on_site() |> get("/")

      assert html_response(conn, 200) =~ "served-by-the-cms"
      assert html_lang(conn) == "en"
    end

    test "an address that names no language is served in the primary one", %{site: site} do
      published!(site, "/:lang/blog")

      conn = on_site() |> get("/blog")

      assert html_response(conn, 200) =~ "served-by-the-cms"
      assert html_lang(conn) == "en"
    end

    test "an address that names another language is served in it", %{site: site} do
      published!(site, "/:lang/blog")

      conn = on_site() |> get("/fa/blog")

      assert html_response(conn, 200) =~ "served-by-the-cms"
      assert html_lang(conn) == "fa"
    end

    test "the primary language's own prefix is sent away for good, query kept", %{site: site} do
      published!(site, "/:lang/blog")
      published!(site, "/:lang")

      conn = on_site() |> get("/en/blog?page=2&q=ash")

      assert conn.status == 301
      assert redirected_to(conn, 301) == "/blog?page=2&q=ash"
      assert on_site() |> get("/en") |> redirected_to(301) == "/"
    end

    test "a literal page answers as typed, and one stored under the primary language without it",
         %{site: site} do
      published!(site, "/no-lang")
      published!(site, "/en/pricing", "en")

      assert on_site() |> get("/no-lang") |> html_response(200) =~ "served-by-the-cms"
      assert on_site() |> get("/pricing") |> html_response(200) =~ "served-by-the-cms"
      assert on_site() |> get("/en/pricing") |> redirected_to(301) == "/pricing"
    end

    test "a pattern with a capture of its own answers without the prefix", %{site: site} do
      published!(site, "/:lang/post/:slug")

      {:ok, view, _html} = live(on_site(), "/post/hello")

      assert has_element?(view, ~s([data-role="served-by-the-cms"]))
    end

    # The owner's decision: a visitor who chose Persian and asks for an address with no language is
    # given the address they asked for.
    test "a remembered language never redirects", %{site: site} do
      published!(site, "/:lang/blog")
      published!(site, "/:lang")

      for path <- ["/", "/blog"] do
        conn =
          on_site()
          |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
          |> get(path)

        assert html_response(conn, 200) =~ "served-by-the-cms", "#{path} was redirected"
        assert html_lang(conn) == "en"
      end
    end

    test "a language the page was not written in is still a 404", %{site: site} do
      published!(site, "/:lang", "en")

      assert on_site() |> get("/") |> html_response(200) =~ "served-by-the-cms"
      assert_error_sent(404, fn -> on_site() |> get("/fa") end)
    end

    test "a live navigation to the primary language's prefix lands without it", %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/fa/pricing")
      assert {:error, {:live_redirect, %{to: "/blog"}}} = live_redirect(view, to: "/en/blog")

      {:ok, view, _html} = live(on_site(), "/fa/pricing")
      assert {:ok, _view, _html} = live_redirect(view, to: "/blog")
    end

    test "the sign-in page is at /auth, query and all", %{site: site} do
      published!(site, "/:lang/auth")

      assert on_site() |> get("/auth?return_to=abc") |> html_response(200) =~ "served-by-the-cms"

      assert on_site() |> get("/en/auth?return_to=abc") |> redirected_to(301) ==
               "/auth?return_to=abc"
    end
  end

  describe "with a prefix for every language" do
    setup %{site: site} do
      prefix_all!(site)
      :ok
    end

    test "the root is sent to the site's first language", %{site: site} do
      published!(site, "/:lang")

      conn = on_site() |> get("/")

      assert redirected_to(conn, 302) == "/en"
    end

    test "a page's address is sent to the same page under a language", %{site: site} do
      published!(site, "/:lang/blog")

      assert on_site() |> get("/blog") |> redirected_to(302) == "/en/blog"
    end

    test "the query string survives the redirect", %{site: site} do
      published!(site, "/:lang/blog")

      assert on_site() |> get("/blog?page=2&q=ash") |> redirected_to(302) ==
               "/en/blog?page=2&q=ash"
    end

    test "a page stored without a language keeps its own address", %{site: site} do
      published!(site, "/no-lang")

      assert on_site() |> get("/no-lang") |> html_response(200) =~ "served-by-the-cms"
    end

    test "an address that names a language is answered where it stands", %{site: site} do
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

      assert redirected_to(conn, 302) == "/fa/blog"
    end

    # A visitor who once chose Persian and then asks for the root is not asking for Persian. Sending
    # them to a Persian home nobody wrote is a 404 that a visitor with no session at all does not get.
    test "a remembered language the page was not written in falls back to the site's first", %{
      site: site
    } do
      published!(site, "/:lang", "en")

      conn =
        on_site()
        |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
        |> get("/")

      assert redirected_to(conn, 302) == "/en"

      assert_error_sent(404, fn ->
        on_site()
        |> Plug.Test.init_test_session(%{Languages.session() => "fa"})
        |> get("/fa")
      end)
    end

    # A `<.link navigate>` inside an open socket never reaches a plug, and `mount/3` resolves the
    # address before `handle_params/3` is called — so a guard in `handle_params/3` alone was reached
    # only on a patch, and a click on an unprefixed link 404ed where a fresh load of the same href
    # redirected. `live_redirect/2` mounts the way the browser does, without the pipeline.
    test "a live navigation to an address with no language is redirected the way a fresh load is",
         %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/fa/pricing")

      assert {:error, {:live_redirect, %{to: "/fa/blog"}}} = live_redirect(view, to: "/blog")
    end

    # `q[a]=b` and `tags[]=x` arrive as a map and a list, which `URI.encode_query/1` cannot write
    # back — the redirect raised and the visitor got a 500.
    test "and keeps a nested query string the way the visitor sent it", %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/fa/pricing")

      assert {:error, {:live_redirect, %{to: to}}} =
               live_redirect(view, to: "/blog?page=2&q[a]=b&tags[]=x&tags[]=y")

      assert ["/fa/blog", query] = String.split(to, "?")

      assert Plug.Conn.Query.decode(query) ==
               %{"page" => "2", "q" => %{"a" => "b"}, "tags" => ["x", "y"]}
    end

    test "a live navigation to one that already names a language is left alone", %{site: site} do
      published!(site, "/:lang/pricing")
      published!(site, "/:lang/blog")

      {:ok, view, _html} = live(on_site(), "/en/pricing")

      assert {:ok, _view, _html} = live_redirect(view, to: "/en/blog")
    end

    # THE SIGN-IN PAGES ARE THE SITE'S OWN RUNTIME PAGES at `/:lang/auth…`, so `/auth…` is an address
    # the CMS answers, and the links that name it — a sign-in asked for with `?return_to=`, an
    # emailed token — arrive with their query.
    test "the sign-in addresses are sent to the page under the visitor's language", %{site: site} do
      published!(site, "/:lang/auth")
      published!(site, "/:lang/auth/password-reset/:token")

      assert on_site() |> get("/auth?return_to=abc") |> redirected_to(302) ==
               "/en/auth?return_to=abc"

      assert on_site() |> get("/auth/password-reset/tok?master_user=false") |> redirected_to(302) ==
               "/en/auth/password-reset/tok?master_user=false"

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
