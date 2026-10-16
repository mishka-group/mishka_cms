# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ApiOfflineTest do
  @moduledoc """
  What an offline site's JSON:API and GraphQL answer, through the whole endpoint, to a visitor, the
  site's own users and admins, another site's admin and a master.

  Everyone but the site's admins and the masters gets one `503` `site_offline` in the API's own
  error shape, which a frontend on an origin the site allows can read. Signing in, the password
  reset and `me` stay open, so an admin can get a token while the site is down; registering does
  not. A switched-off site's refusal can be read the same way, and its preflight is answered.

  `async: false` — `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, UserPermission}
  alias MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"
  @posts "/api/json/v1/user/mishka-blog/post/published"
  @auth "/api/json/v1/auth/user"
  @sites "/api/json/v1/master/admin/runtime/site"
  @hello ~s({"query": "{ sayHello }"})

  setup do
    SettingsState.refresh()
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  # A site in the site cache, the way the tenant lookup reads it, with the origin its frontend runs
  # on.
  defp site!(opts \\ []) do
    host = "api-offline-#{System.unique_integer([:positive])}.test"
    active = Keyword.get(opts, :active, true)
    master = Keyword.get(opts, :master, false)
    site = create_site!(name: host, host: host, active: active, master: master)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: active,
        master: master,
        frontend_domain: "front." <> host
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp offline!(site), do: {:ok, _} = Settings.put("cms.offline", true, site_id: site && site.id)

  defp star do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  # Made while the site is still open: an offline site takes no registrations.
  defp user!(site_id, admin?) do
    user = create_user!(site_id: site_id)

    if admin?,
      do:
        UserPermission
        |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:user_id, user.id)
        |> Ash.Changeset.force_change_attribute(:permission_id, star().id)
        |> Ash.create!(authorize?: false)

    user
  end

  defp published_post!(site) do
    create_blog_post!(site_id: site.id, status: :published, published_at: DateTime.utc_now())
  end

  defp on(host, headers \\ []) do
    Enum.reduce(headers, %{build_conn() | host: host}, fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp json_api(conn) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # A bearer token from the JSON:API sign-in, the way a frontend gets one.
  defp token!(host, user, headers \\ []) do
    body = %{
      data: %{type: "user", attributes: %{email: to_string(user.email), password: @password}}
    }

    conn = host |> on(headers) |> json_api() |> post("#{@auth}/sign-in", Jason.encode!(body))
    assert conn.status == 201, "sign-in answered #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["meta"]["token"]
  end

  # A token with no tenant claim. The sign-in mints one for a master only, so this mints it as the
  # sign-in does, for a user who is not one.
  defp tenantless_token!(user) do
    {:ok, token, %{"tenant" => nil}} =
      user
      |> Ash.Resource.put_metadata(:tenant, nil)
      |> AshAuthentication.Jwt.token_for_user(%{"purpose" => "user"})

    token
  end

  # `json_response/2` knows no JSON:API media type.
  defp data(conn), do: conn |> response(200) |> Jason.decode!() |> Map.fetch!("data")

  defp graphql(conn) do
    conn |> put_req_header("content-type", "application/json") |> post("/gql", @hello)
  end

  defp site_offline?(conn) do
    conn.status == 503 and get_resp_header(conn, "x-error-code") == ["site_offline"] and
      get_resp_header(conn, "cache-control") == ["no-store"]
  end

  describe "the JSON:API of an offline site" do
    test "answers a visitor with site_offline in JSON:API's own error shape" do
      site = site!()
      published_post!(site)
      assert [_post] = site.host |> on() |> json_api() |> get(@posts) |> data()

      offline!(site)
      conn = site.host |> on() |> json_api() |> get(@posts)

      assert site_offline?(conn)
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

      assert %{
               "errors" => [%{"status" => "503", "code" => "site_offline", "title" => _}],
               "jsonapi" => %{"version" => "1.0"}
             } = Jason.decode!(conn.resp_body)
    end

    test "says what the site's own maintenance message says" do
      site = site!()
      {:ok, _} = Settings.put("cms.maintenance_message", "Back at noon", site_id: site.id)
      offline!(site)

      conn = site.host |> on() |> json_api() |> get(@posts)

      assert [%{"detail" => "Back at noon"}] = Jason.decode!(conn.resp_body)["errors"]
    end

    test "closes every route of every domain but signing in, the reset and me" do
      site = site!()
      offline!(site)
      open = ~w(sign-in reset-request reset-password me logout)

      routes =
        for domain <- MishkaCmsWeb.AshJsonApiRouter.domains(),
            route <- AshJsonApi.Domain.Info.routes(domain),
            do: {route.method, String.replace(route.route, ~r/:[a-z_]+/, Ecto.UUID.generate())}

      assert length(routes) > 50

      for {method, path} <- Enum.uniq(routes) do
        conn = site.host |> on() |> json_api() |> dispatch(@endpoint, method, "/api/json" <> path)

        if Path.dirname(path) == "/v1/auth/user" and Path.basename(path) in open,
          do: refute(site_offline?(conn), "#{method} #{path} was closed"),
          else: assert(site_offline?(conn), "#{method} #{path} answered #{conn.status}")
      end
    end

    test "lets a path that only starts like a sign-in route no further than any other" do
      site = site!()
      offline!(site)

      assert site.host
             |> on()
             |> json_api()
             |> post("#{@auth}/sign-in/x", "{}")
             |> site_offline?()

      assert site.host |> on() |> json_api() |> get("#{@auth}/sign-in") |> site_offline?()
    end

    test "lets the site's admin sign in and read everything" do
      site = site!()
      published_post!(site)
      admin = user!(site.id, true)
      offline!(site)

      token = token!(site.host, admin)
      conn = site.host |> on() |> json_api() |> bearer(token) |> get(@posts)

      assert [_post] = data(conn)

      assert site.host
             |> on()
             |> json_api()
             |> bearer(token)
             |> get("#{@auth}/me")
             |> response(200)
    end

    # MASTERS ARE KNOWN ON THE MASTER SITE'S ADDRESS ALONE: any other site ignores x-no-tenant, and a
    # master's token names nobody there.
    test "lets a master in with a master token, on the master site's address" do
      site = site!(master: true)
      other = site!()
      master = user!(nil, true)
      offline!(site)
      offline!(other)

      no_tenant = [{"x-no-tenant", "true"}]
      token = token!(site.host, master, no_tenant)
      conn = site.host |> on(no_tenant) |> json_api() |> bearer(token)

      assert conn |> get(@sites) |> data() |> is_list()
      assert site.host |> on(no_tenant) |> json_api() |> get(@sites) |> site_offline?()

      assert other.host
             |> on(no_tenant)
             |> json_api()
             |> bearer(token)
             |> get(@sites)
             |> site_offline?()
    end

    test "signs the site's other users in, and answers them site_offline past me" do
      site = site!()
      member = user!(site.id, false)
      offline!(site)

      token = token!(site.host, member)
      conn = site.host |> on() |> json_api() |> bearer(token)

      assert conn |> get("#{@auth}/me") |> response(200)
      assert conn |> get(@posts) |> site_offline?()
    end

    test "counts another site's admin as a visitor" do
      site = site!()
      other = site!()
      others_admin = user!(other.id, true)
      token = token!(other.host, others_admin)
      offline!(site)

      assert site.host |> on() |> json_api() |> bearer(token) |> get(@posts) |> site_offline?()
    end

    # A TOKEN ISSUED WITH NO SITE DOES NOT MAKE ITS HOLDER A MASTER: only a user with no site is one.
    test "refuses another site's admin holding a token issued with no site, on any address" do
      master_site = site!(master: true)
      site = site!()
      other = site!()
      others_admin = user!(other.id, true)
      offline!(site)

      for host <- [site.host, master_site.host] do
        conn =
          host
          |> on([{"x-no-tenant", "true"}])
          |> json_api()
          |> bearer(tenantless_token!(others_admin))

        assert conn |> get("#{@auth}/me") |> response(403)
      end

      assert site.host
             |> on([{"x-no-tenant", "true"}])
             |> json_api()
             |> bearer(tenantless_token!(others_admin))
             |> get(@posts)
             |> site_offline?()
    end

    test "keeps registering closed" do
      site = site!()
      offline!(site)

      body = %{
        data: %{
          type: "user",
          attributes: %{
            email: "new-#{System.unique_integer([:positive])}@example.com",
            password: @password,
            password_confirmation: @password
          }
        }
      }

      conn = site.host |> on() |> json_api() |> post("#{@auth}/register", Jason.encode!(body))

      assert site_offline?(conn)
    end

    test "is closed by the global switch too, and the site's admin still passes" do
      site = site!()
      admin = user!(site.id, true)
      offline!(nil)

      assert site.host |> on() |> json_api() |> get(@posts) |> site_offline?()

      token = token!(site.host, admin)
      assert site.host |> on() |> json_api() |> bearer(token) |> get(@posts) |> response(200)
    end

    test "sends the refusal with the CORS headers of an origin the site allows" do
      site = site!()
      offline!(site)
      origin = "https://front." <> site.host

      conn = site.host |> on([{"origin", origin}]) |> json_api() |> get(@posts)

      assert site_offline?(conn)
      assert get_resp_header(conn, "access-control-allow-origin") == [origin]
    end
  end

  describe "GraphQL over HTTP" do
    test "answers the site's own tenant, and a visitor while the site is up" do
      site = site!()
      conn = site.host |> on() |> graphql()

      assert json_response(conn, 200) == %{"data" => %{"sayHello" => "Hello from AshGraphql!"}}
      assert get_resp_header(conn, "x-tenant-id") == [site.id]
    end

    test "answers a visitor of an offline site with site_offline in GraphQL's own error shape" do
      site = site!()
      offline!(site)
      conn = site.host |> on() |> graphql()

      assert site_offline?(conn)

      assert %{"errors" => [%{"message" => _, "extensions" => %{"code" => "site_offline"}}]} =
               Jason.decode!(conn.resp_body)
    end

    test "lets the offline site's admin in" do
      site = site!()
      admin = user!(site.id, true)
      offline!(site)

      token = token!(site.host, admin)
      conn = site.host |> on() |> bearer(token) |> graphql()

      assert json_response(conn, 200)["data"] == %{"sayHello" => "Hello from AshGraphql!"}
    end

    test "refuses an address no site has, and a switched-off site" do
      assert "nobody-#{System.unique_integer([:positive])}.test"
             |> on()
             |> graphql()
             |> response(404)

      inactive = site!(active: false)
      conn = inactive.host |> on() |> graphql()

      assert response(conn, 503)
      assert get_resp_header(conn, "x-error-code") == ["website_unavailable"]
    end

    test "answers an origin the site allows, and not another" do
      site = site!()
      origin = "https://front." <> site.host

      allowed = site.host |> on([{"origin", origin}]) |> graphql()
      other = site.host |> on([{"origin", "https://elsewhere.test"}]) |> graphql()

      assert get_resp_header(allowed, "access-control-allow-origin") == [origin]
      assert get_resp_header(other, "access-control-allow-origin") == []
    end
  end

  describe "a switched-off site's API" do
    test "sends its refusal with the CORS headers of an origin it allows, never cached" do
      site = site!(active: false)
      origin = "https://front." <> site.host

      conn = site.host |> on([{"origin", origin}]) |> json_api() |> get(@posts)

      assert response(conn, 503)
      assert get_resp_header(conn, "x-error-code") == ["website_unavailable"]
      assert get_resp_header(conn, "access-control-allow-origin") == [origin]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "answers a preflight, so the request behind it can read the refusal" do
      site = site!(active: false)
      origin = "https://front." <> site.host

      conn =
        site.host
        |> on([{"origin", origin}, {"access-control-request-method", "GET"}])
        |> options(@posts)

      assert response(conn, 204) == ""
      assert get_resp_header(conn, "access-control-allow-origin") == [origin]
    end
  end

  # A site owner's plugin that answers a closed site's API with a body of its own.
  defmodule OwnersAnswer do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "api:request:site_unavailable"

    @impl true
    def call(conn, meta) do
      body = "owner #{meta[:state]} #{meta[:site].id}"
      {:reply, conn |> Plug.Conn.send_resp(200, body) |> Plug.Conn.halt()}
    end
  end

  test "a plugin on api:request:site_unavailable may answer an offline or switched-off site" do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: OwnersAnswer,
        event: "api:request:site_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile("api:request:site_unavailable", :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, OwnersAnswer, false) end)

    offline = site!()
    offline!(offline)
    inactive = site!(active: false)

    assert offline.host |> on() |> json_api() |> get(@posts) |> response(200) ==
             "owner offline #{offline.id}"

    assert inactive.host |> on() |> json_api() |> get(@posts) |> response(200) ==
             "owner inactive #{inactive.id}"
  end

  # The plug alone, on the site and the user the pipeline before it resolved.
  defp through_plug(site, user) do
    Plug.Test.conn(:get, "/api/json/anything")
    |> Plug.Conn.assign(:current_site, site)
    |> Plug.Conn.assign(:current_user, user)
    |> ApiAvailabilityPlug.call(ApiAvailabilityPlug.init(api: :json_api))
  end

  # An admin as `:load_from_bearer` hands them over, with the permissions they were loaded with.
  defp admin!(site_id), do: Ash.load!(user!(site_id, true), [:permissions], authorize?: false)

  describe "with no site resolved" do
    test "only the global switch closes the API, and to all but the masters" do
      refute through_plug(nil, nil).halted

      offline!(nil)

      assert through_plug(nil, nil) |> site_offline?()
      refute through_plug(nil, admin!(nil)).halted
    end
  end

  describe "the plug alone, on an offline site" do
    test "refuses another site's admin, and passes the site's own" do
      site = site!()
      own_admin = admin!(site.id)
      others_admin = admin!(site!().id)
      offline!(site)

      assert through_plug(site, others_admin) |> site_offline?()
      refute through_plug(site, own_admin).halted
    end
  end

  describe "a site switched off after the tenant lookup" do
    test "is refused to a master too, with website_unavailable" do
      site = site!(active: false)
      conn = through_plug(site, admin!(nil))

      assert conn.halted
      assert conn.status == 503
      assert get_resp_header(conn, "x-error-code") == ["website_unavailable"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end
end
