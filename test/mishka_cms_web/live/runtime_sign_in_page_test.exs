# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RuntimeSignInPageTest do
  @moduledoc """
  What `MishkaCmsWeb.RuntimeLive` gives the sign-in pages, which are runtime pages like any other:
  the address the visitor's socket came from, the tenant their forms sign in to, a visitors-only
  page that sends a signed-in visitor home, a signed-in-only page (signing out) that sends anyone
  else to sign in, and an offline site's sign-in page that stays open and loads the app's own
  LiveView client.

  The pages here are minimal ones each test writes; the seeded sign-in pages are tested with the
  seeds.

  `async: false` — the install flag, `SiteState`, the settings cache, the plugin registry and the
  routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCms.Test.EventCannotRun

  alias MishkaCmsCore.Runtime.States.{
    AssetsState,
    SettingsState,
    SiteState,
    WebRunTimeMetaDataState
  }

  alias MishkaCmsCore.Settings

  defmodule SentElsewhere do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:visitors_only_redirected"

    @impl true
    def call(socket, meta) do
      query = URI.encode_query(%{"site" => meta[:site_id], "path" => meta[:path]})
      {:reply, Phoenix.LiveView.redirect(socket, to: "/welcome-back?" <> query)}
    end
  end

  defmodule SignInElsewhere do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:signed_in_only_redirected"

    @impl true
    def call(socket, meta) do
      query = URI.encode_query(%{"site" => meta[:site_id], "path" => meta[:path]})
      {:reply, Phoenix.LiveView.redirect(socket, to: "/welcome-back?" <> query)}
    end
  end

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
    Settings.put("cms.offline", false)
    # The addresses below name every language, English included.
    Settings.put("site.language_urls", "prefix_all", site_id: site.id)
    WebRunTimeMetaDataState.delete_by_site(site.name)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SettingsState.restore(snapshot)
    end)

    %{
      site: site,
      sign_in:
        published!(site, "/:lang/auth", %{"visitors_only" => true, "serves_all_languages" => true}),
      sign_out:
        published!(site, "/:lang/auth/sign-out", %{
          "signed_in_only" => true,
          "serves_all_languages" => true
        }),
      plain: published!(site, "/:lang/plain-#{System.unique_integer([:positive])}", %{})
    }
  end

  describe "the address the visitor's socket came from" do
    test "is read when a page mounts, on a sign-in page and on any other", %{plain: plain} do
      for path <- ["/en/auth", en(plain)] do
        {:ok, view, _html} = on_site() |> from({198, 51, 100, 7}) |> live(path)

        assert assigns(view).client_request == %{remote_ip: "198.51.100.7"}, path
      end
    end

    test "is the client a proxy forwarded, not the proxy" do
      {:ok, view, _html} =
        on_site()
        |> from({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "198.51.100.8")
        |> live("/en/auth")

      assert assigns(view).client_request == %{remote_ip: "198.51.100.8"}
    end

    test "is kept on a live patch, which has no connect info to read", %{plain: plain} do
      {:ok, view, _html} = on_site() |> from({198, 51, 100, 9}) |> live(en(plain))

      render_patch(view, "/en/auth?step=2")

      assert assigns(view).page.path == "/:lang/auth"
      assert assigns(view).client_request == %{remote_ip: "198.51.100.9"}
    end
  end

  describe "the tenant a page's forms sign in to" do
    test "is the site's for a visitor", %{site: site} do
      {:ok, view, _html} = live(on_site(), "/en/auth")

      assert assigns(view).current_tenant == site.id
    end

    test "is nobody's for a visitor who asked the master site for the master accounts" do
      {:ok, view, _html} = live(on_site(), "/en/auth?master_user=true")
      assert assigns(view).current_tenant == nil

      {:ok, view, _html} =
        on_site() |> Plug.Test.init_test_session(%{master_mode: true}) |> live("/en/auth")

      assert assigns(view).current_tenant == nil
    end

    test "and the site's again on any page that is not a sign-in page", %{
      site: site,
      plain: plain
    } do
      {:ok, view, _html} =
        on_site() |> Plug.Test.init_test_session(%{master_mode: true}) |> live(en(plain))

      assert assigns(view).current_tenant == site.id
    end
  end

  describe "a visitors-only page" do
    test "opens for a visitor who is not signed in" do
      {:ok, view, _html} = live(on_site(), "/en/auth")

      assert has_element?(view, "#page-body")
      assert assigns(view).current_user == nil
    end

    test "sends a signed-in visitor to the site root", %{site: site} do
      conn = signed_in_as(create_user!(site_id: site.id))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/en/auth")
    end

    test "a page without the mark opens for them", %{site: site, plain: plain} do
      conn = signed_in_as(create_user!(site_id: site.id))

      {:ok, view, _html} = live(conn, en(plain))

      assert has_element?(view, "#page-body")
    end

    test "a live patch onto it sends them away too", %{site: site, plain: plain} do
      conn = signed_in_as(create_user!(site_id: site.id))
      {:ok, view, _html} = live(conn, en(plain))

      assert {:error, {:redirect, %{to: "/"}}} = render_patch(view, "/en/auth")
    end

    test "a plugin on runtime:page:visitors_only_redirected hears it and may send them elsewhere",
         %{site: site} do
      register_plugin(SentElsewhere, "runtime:page:visitors_only_redirected")
      conn = signed_in_as(create_user!(site_id: site.id))

      assert {:error, {:redirect, %{to: to}}} = live(conn, "/en/auth")

      assert %URI{path: "/welcome-back", query: query} = URI.parse(to)
      assert URI.decode_query(query) == %{"site" => site.id, "path" => "/:lang/auth"}
    end

    test "sends them to the site root while runtime:page:visitors_only_redirected cannot run",
         %{site: site} do
      EventCannotRun.stub!("runtime:page:visitors_only_redirected")
      conn = signed_in_as(create_user!(site_id: site.id))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/en/auth")
    end
  end

  describe "a signed-in-only page" do
    test "opens for a signed-in visitor", %{site: site} do
      conn = signed_in_as(create_user!(site_id: site.id))

      {:ok, view, _html} = live(conn, "/en/auth/sign-out")

      assert has_element?(view, "#page-body")
    end

    test "sends a visitor who is not signed in to the sign-in page" do
      assert {:error, {:redirect, %{to: "/en/auth"}}} = live(on_site(), "/en/auth/sign-out")
    end

    test "a live patch onto it sends them away too", %{plain: plain} do
      {:ok, view, _html} = live(on_site(), en(plain))

      assert {:error, {:redirect, %{to: "/en/auth"}}} = render_patch(view, "/en/auth/sign-out")
    end

    test "a plugin on runtime:page:signed_in_only_redirected hears it and may send them elsewhere",
         %{site: site} do
      register_plugin(SignInElsewhere, "runtime:page:signed_in_only_redirected")

      assert {:error, {:redirect, %{to: to}}} = live(on_site(), "/en/auth/sign-out")

      assert %URI{path: "/welcome-back", query: query} = URI.parse(to)
      assert URI.decode_query(query) == %{"site" => site.id, "path" => "/:lang/auth/sign-out"}
    end

    test "sends them to the sign-in page while runtime:page:signed_in_only_redirected cannot run" do
      EventCannotRun.stub!("runtime:page:signed_in_only_redirected")

      assert {:error, {:redirect, %{to: "/en/auth"}}} = live(on_site(), "/en/auth/sign-out")
    end
  end

  describe "an offline site's sign-in page" do
    setup %{site: site} do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      :ok
    end

    test "stays open to a visitor, without sending them round in a loop", %{plain: plain} do
      {:ok, view, _html} = live(on_site(), "/en/auth")
      assert has_element?(view, "#page-body")

      assert on_site() |> get(en(plain)) |> html_response(503)
    end

    test "is closed once the visitor navigates off it", %{plain: plain} do
      {:ok, view, _html} = live(on_site(), "/en/auth")

      assert {:error, {:redirect, %{to: to}}} = render_patch(view, en(plain))
      assert to == en(plain)
    end

    test "loads the app's own client, not the bundle the site serves its admins only", %{
      site: site
    } do
      html = on_site() |> get("/en/auth") |> html_response(200)

      assert html =~ ~s(src="/assets/js/app.js")
      refute html =~ "/assets/js/#{site.name}/"
    end
  end

  # THE BUNDLE IS THE SITE'S COMPILED ONE, which no request builds: the site is given one here, as
  # its compile would.
  test "an open site's sign-in page loads the site's bundle, as every page does", %{site: site} do
    :ok =
      AssetsState.save(%{
        id: site.name,
        type: "js",
        value: "",
        hash: "signin#{System.unique_integer([:positive])}",
        updated_at: DateTime.utc_now()
      })

    on_exit(fn -> AssetsState.delete(site.name, "js") end)

    html = on_site() |> get("/en/auth") |> html_response(200)

    assert html =~ "/assets/js/#{site.name}/"
    refute html =~ ~s(src="/assets/js/app.js")
  end

  defp published!(site, path, extra) do
    page =
      create_page!(
        site_id: site.id,
        name: "sign-in-#{System.unique_integer([:positive])}",
        path: path,
        extra: extra,
        template: ~S(<div id="page-body" data-page={@page.path}>page</div>)
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

  defp en(page), do: String.replace(page.path, ":lang", "en")

  # What the sign-in form is handed (the client address, the tenant, the user) is the socket's
  # state; the form draws none of it.
  # credo:disable-for-next-line Jump.CredoChecks.AvoidSocketAssignsInTest
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  defp signed_in_as(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp from(conn, ip) do
    conn
    |> Map.put(:remote_ip, ip)
    |> Plug.Test.put_peer_data(%{address: ip, port: 4000, ssl_cert: nil})
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
