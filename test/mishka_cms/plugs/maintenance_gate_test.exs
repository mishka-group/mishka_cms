defmodule MishkaCms.Plugs.MaintenanceGateTest do
  @moduledoc """
  Real tests for the Joomla-style offline gate: it reads the `cms.offline` setting from the RAM cache
  and lets only the auth/installer/asset routes and master / this-site tenant admins through. Uses
  real users + permissions; `async: false` because the settings ETS cache is process-global.
  """
  use MishkaCms.DataCase, async: false

  alias MishkaCmsCore.Accounts.{LiveSockets, Permission, UserPermission}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings
  alias MishkaCms.Plugs.MaintenanceGate
  alias MishkaCms.Test.EventCannotRun
  alias Phoenix.LiveView.Socket

  require Ash.Query

  setup do
    SettingsState.refresh()
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  # A session, because the plug records its own verdict there for `on_mount/4` to read — the
  # `:browser` pipeline fetches one long before this plug runs.
  defp call(path, opts \\ []) do
    Plug.Test.conn(:get, path)
    |> Plug.Test.init_test_session(Keyword.get(opts, :session, %{}))
    |> Plug.Conn.assign(:current_user, Keyword.get(opts, :current_user))
    |> Plug.Conn.assign(:current_site, Keyword.get(opts, :current_site))
    |> MaintenanceGate.call(MaintenanceGate.init([]))
  end

  defp ensure_star do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp grant(user, permission) do
    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission.id)
    |> Ash.create!(authorize?: false)
  end

  defp admin(overrides) do
    user = create_user!(overrides)
    grant(user, ensure_star())
    Ash.load!(user, [:permissions], authorize?: false)
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  # A user holding exactly `names`.
  defp holder(names, overrides) do
    user = create_user!(overrides)
    Enum.each(names, &grant(user, permission!(&1)))
    Ash.load!(user, [:permissions], authorize?: false)
  end

  # The signed-in user as a live navigation sees them: the id their session names, answered from
  # `ViewerState`, where the pipeline writes it on every page load.
  defp signed_in(user) do
    ViewerState.remember(user)
    on_exit(fn -> ViewerState.forget(user.id) end)
    user
  end

  # A live navigation is answered over the socket that is already open. No HTTP request is made, so
  # no pipeline runs and `call/2` never sees it — a visitor who had a tab open when the switch was
  # thrown would otherwise keep browsing for the life of that tab.
  defp mount(opts) do
    socket = %Socket{
      transport_pid: self(),
      router: MishkaCmsWeb.Router,
      private: %{connect_params: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}}
    }

    user = Keyword.get(opts, :as)

    session =
      Map.merge(
        %{
          "current_site" => Keyword.get(opts, :current_site),
          "live_socket_id" => user && LiveSockets.live_socket_id(user)
        },
        Keyword.get(opts, :session, %{})
      )

    {:cont, socket} =
      MishkaCmsCore.Runtime.SiteAvailability.on_mount(:default, %{}, session, socket)

    # No hook at all where there is nothing to judge: no site, as in the installer.
    case socket.private.lifecycle.handle_params do
      [] -> {:cont, socket}
      [hook | _] -> hook.function.(%{}, Keyword.get(opts, :uri, "http://localhost/blog"), socket)
    end
  end

  # In the site cache as well, because the gate re-reads a site's state from there by id and treats
  # one it does not know as closed.
  defp a_site(overrides \\ %{}) do
    site = Map.merge(%{id: Ecto.UUID.generate(), active: true}, overrides)
    unique = System.unique_integer([:positive])

    :ok =
      SiteState.save(%{
        id: site.id,
        name: "site-#{unique}",
        host: "site-#{unique}.example",
        priority: 0,
        active: site.active
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  test "passes every request through when the CMS is not offline" do
    refute call("/").halted
    refute call("/anything").halted
  end

  test "leaves an admin's page to the usual caching while the CMS is not offline" do
    conn = call("/", current_user: admin(email: "boss@example.com"))

    refute Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  describe "when cms.offline is on" do
    setup do
      {:ok, _} = Settings.put("cms.offline", true)

      # The flag lives in a process-global RAM cache, so leaving it on takes the whole front end
      # down for every `async: false` test that runs after this file.
      on_exit(fn -> Settings.put("cms.offline", false) end)

      :ok
    end

    test "an anonymous visitor gets the maintenance page" do
      conn = call("/")
      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body =~ "Down for Maintenance"
    end

    for event <- ["web:request:site_unavailable", "web:request:offline_page"] do
      @event event

      test "an anonymous visitor still gets the maintenance page while #{event} cannot run" do
        EventCannotRun.stub!(@event)

        conn = call("/")
        assert conn.halted
        assert conn.status == 503
        assert conn.resp_body =~ "Down for Maintenance"
      end
    end

    # A master signs in on the master site's own address and nowhere else, so only that site's page
    # offers the master sign-in; every other site's offers its own sign-in alone.
    test "only the master site's built-in page offers the master sign-in" do
      site_page = call("/", current_site: a_site()).resp_body
      master_page = call("/", current_site: a_site(%{master: true})).resp_body

      assert site_page =~ ~s(href="/auth?master_user=false")
      refute site_page =~ "master_user=true"
      refute site_page =~ "Master sign in"

      assert master_page =~ ~s(href="/auth?master_user=false")
      assert master_page =~ ~s(href="/auth?master_user=true")
    end

    # THE SIGN-IN IN THE LANGUAGE THE VISITOR READS THE SITE IN, the session's — this gate answers
    # before `LanguagePlug` would — at the address the site's URL mode gives it.
    test "the built-in page links the sign-in in the visitor's language" do
      site = a_site(%{master: true})
      :ok = SettingsState.put(site.id, "site.languages", %{"value" => ["en", "fa"]})
      reading_fa = call("/", current_site: site, session: %{"site_language" => "fa"}).resp_body

      assert reading_fa =~ ~s(href="/fa/auth?master_user=false")
      assert reading_fa =~ ~s(href="/fa/auth?master_user=true")
      assert call("/", current_site: site).resp_body =~ ~s(href="/auth?master_user=false")

      :ok = SettingsState.put(site.id, "site.language_urls", %{"value" => "prefix_all"})

      assert call("/", current_site: site).resp_body =~ ~s(href="/en/auth?master_user=false")
    end

    # The sign-in pages are `/<language>/auth…`, reached from `/auth…`; the request that mints the
    # session is a POST to the AshAuthentication controller under `/api/auth`. All of them have to
    # be open or an admin fills in the form, submits it, and gets the holding page.
    test "the whole sign-in path stays open, page and controller" do
      refute call("/auth").halted
      refute call("/api/auth/user/password/sign_in").halted
      refute call("/api/auth/user/magic_link").halted
      refute call("/api/auth/user/password/reset_request").halted
    end

    test "the sign-in pages under one of the site's languages stay open" do
      site = a_site()

      for path <- [
            "/en/auth",
            "/en/auth?master_user=false",
            "/en/auth/forgot-password",
            "/en/auth/password-reset/token",
            "/en/auth/sign-out"
          ] do
        refute call(path, current_site: site).halted, path
      end
    end

    test "an address that only looks like a sign-in page gets the maintenance page" do
      site = a_site()

      for path <- ["/xx/auth", "/en/authors", "/en/about/auth", "/authors"] do
        conn = call(path, current_site: site)

        assert conn.halted, path
        assert conn.status == 503, path
      end
    end

    test "but not the one that makes a new account" do
      conn = call("/api/auth/user/password/register")

      assert conn.halted
      assert conn.status == 503
    end

    test "the auth, installer and asset routes stay reachable" do
      refute call("/auth").halted
      refute call("/auth?master_user=true").halted
      refute call("/install").halted
      refute call("/assets/css/site/abc.css").halted
    end

    test "a non-admin user still gets the maintenance page" do
      user =
        create_user!(email: "nobody@example.com") |> Ash.load!([:permissions], authorize?: false)

      conn = call("/", current_user: user)
      assert conn.halted
      assert conn.status == 503
    end

    test "a master admin (site_id nil) bypasses to the real site" do
      refute call("/", current_user: admin(email: "boss@example.com")).halted
    end

    test "this site's tenant admin bypasses" do
      site = create_site!()
      user = admin(email: "site-admin@example.com", site_id: site.id)
      refute call("/", current_user: user, current_site: site).halted
    end

    # A cache in front of the site would otherwise keep the page an admin was let through to, and
    # hand it to the next visitor while the site is meant to be down.
    test "a page an admin is let through to is kept out of every cache" do
      site = create_site!()

      for user <- [
            admin(email: "boss@example.com"),
            admin(email: "site-admin@example.com", site_id: site.id)
          ] do
        conn = call("/", current_user: user, current_site: site)

        refute conn.halted
        assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
      end
    end

    # THE PAGES ARE THE DASHBOARD'S SIDE. An admin of one dashboard area is an admin of the site
    # here; an API admin is not, whether of the site or a master.
    test "an admin of one dashboard area bypasses, of this site or a master" do
      site = create_site!()

      for overrides <- [[site_id: site.id], [site_id: nil]] do
        user = holder(["admin:dashboard:blog:post"], overrides)

        refute call("/", current_user: user, current_site: site).halted,
               "#{inspect(overrides)} was shown the maintenance page"
      end
    end

    test "an API admin gets the maintenance page, of this site or a master" do
      site = create_site!()

      for overrides <- [[site_id: site.id], [site_id: nil]] do
        conn = call("/", current_user: holder(["admin:api:*"], overrides), current_site: site)

        assert conn.halted, "#{inspect(overrides)} was let through"
        assert conn.status == 503
      end
    end

    test "a tenant admin of a DIFFERENT site sees the maintenance page" do
      other = create_site!()
      current = create_site!()
      user = admin(email: "other-admin@example.com", site_id: other.id)

      conn = call("/", current_user: user, current_site: current)
      assert conn.halted
      assert conn.status == 503
    end
  end

  # The hook reads who is asking from `ViewerState` by the session's user id. If the pipeline stopped
  # writing it, the hook would refuse every admin, the admin's browser would reload, and the pipeline
  # would let them in again, once per navigation forever.
  describe "who the hook sees" do
    test "the pipeline writes the signed-in user on the way through" do
      user = admin(site_id: nil)
      on_exit(fn -> ViewerState.forget(user.id) end)

      call("/", current_user: user)

      assert %{id: id, site_id: nil, dashboard_admin?: true, api_admin?: true} =
               ViewerState.get(user.id)

      assert id == user.id
    end

    test "is nobody for a visitor" do
      refute call("/").halted
      assert ViewerState.get(nil) == nil
    end
  end

  describe "on a live navigation" do
    test "a visitor is left alone while the site is open" do
      assert {:cont, _socket} = mount(current_site: a_site())
    end

    test "nothing is judged without a site, which is the installer's case" do
      assert {:cont, _socket} = mount(current_site: nil)
    end

    test "an offline site sends the visitor back through the pipeline" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)

      assert {:halt, socket} = mount(current_site: a_site())
      assert socket.redirected == {:redirect, %{to: "/blog", status: 302}}
    end

    # A master switches every site off; a site switches only itself off. `Settings.get/3` resolves
    # the site's own value before the global one, so the same read answers both.
    test "a site's own offline setting is enough, with the global one off" do
      site = create_site!()
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      on_exit(fn -> Settings.put("cms.offline", false, site_id: site.id) end)

      assert {:halt, _socket} = mount(current_site: site)
      assert {:cont, _socket} = mount(current_site: a_site())
    end

    # `call/2` writes its own verdict into the session, so the hook never recomputes it and the two
    # can never disagree — which is also what stops a refusal from looping.
    test "an admin keeps browsing an offline site" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)

      assert {:cont, _socket} = mount(current_site: a_site(), as: signed_in(admin(site_id: nil)))
    end

    # A change to an admin's access cuts their sockets and drops their entry together, so the
    # reconnect after a demotion is refused here and reloads the page, where the pipeline decides from
    # the user as they are now.
    test "an admin whose access changed is refused on the next navigation" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)
      site = a_site()
      user = signed_in(admin(site_id: nil))

      assert {:cont, _socket} = mount(current_site: site, as: user)

      LiveSockets.disconnect(user)

      assert {:halt, _socket} = mount(current_site: site, as: user)
    end

    test "an admin nothing is cached for yet is refused until a page load writes them" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)
      user = admin(site_id: nil)

      assert {:halt, _socket} = mount(current_site: a_site(), as: user)
    end

    # Sessions from before the cache still carry the flag the pipeline used to write. It is no longer
    # read, so it cannot let anybody through.
    test "the old maintenance flag in a session lets nobody through" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)

      assert {:halt, _socket} =
               mount(current_site: a_site(), session: %{"cms_maintenance_bypass" => true})
    end

    # The struct in the session is the site as it was when the socket connected, so the flag is read
    # back from the RAM cache by id rather than trusted from the session.
    test "a site switched off since the socket connected is re-read, not trusted" do
      site = a_site()

      unique = System.unique_integer([:positive])

      :ok =
        SiteState.save(%{
          id: site.id,
          name: "gone-#{unique}",
          host: "gone-#{unique}.example",
          priority: 0,
          active: false
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      assert {:halt, socket} = mount(current_site: site)
      assert socket.redirected == {:redirect, %{to: "/blog", status: 302}}
    end

    test "an inactive site is refused even to an admin, as the pipeline refuses it" do
      site = a_site()

      unique = System.unique_integer([:positive])

      :ok =
        SiteState.save(%{
          id: site.id,
          name: "off-#{unique}",
          host: "off-#{unique}.example",
          priority: 0,
          active: false
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      assert {:halt, _socket} = mount(current_site: site, as: signed_in(admin(site_id: nil)))
    end

    # Archiving or deleting a site drops it from the site cache, so a tab still open on it is refused
    # rather than waved through.
    test "a site the site cache does not know is refused, as after archiving it" do
      site = a_site()
      SiteState.delete(site.id)

      assert {:halt, _socket} = mount(current_site: site, as: signed_in(admin(site_id: nil)))
    end

    test "the address the visitor asked for, query included, is the one reloaded" do
      {:ok, _} = Settings.put("cms.offline", true)
      on_exit(fn -> Settings.put("cms.offline", false) end)

      assert {:halt, socket} =
               mount(current_site: a_site(), uri: "http://localhost/blog/post/hello?a=1")

      assert socket.redirected == {:redirect, %{to: "/blog/post/hello?a=1", status: 302}}
    end
  end

  # The hook is useless unless it is actually attached; this is what fails if the `on_mount` line
  # goes missing from `MishkaCmsWeb.live_view/0`.
  describe "every public LiveView carries the hook" do
    test "it is in the mount lifecycle of the host's own LiveViews" do
      for view <- [MishkaCmsWeb.RuntimeLive] do
        ids = Enum.map(view.__live__().lifecycle.mount, & &1.id)

        assert {MishkaCmsCore.Runtime.SiteAvailability, :default} in ids,
               "#{inspect(view)} would keep serving an offline site across a live navigation"
      end
    end
  end
end
