defmodule MishkaCmsWeb.GraphqlSocketTest do
  @moduledoc """
  Who may open the GraphQL socket at `/ws/gql`, and what closes it again.

  A connect is bound to the site of the address it is opened on and refused where that site's API
  would be: an address no site has, a switched-off site, and an offline site to all but its own API
  admins and the API's masters. A WebSocket connect refused for the site's state is answered with the
  `503` `/gql` gives. Every socket of a site is disconnected when the site goes down, so one opened
  while the site was up does not keep running once it is down; an edit that leaves it up keeps them.

  `async: false` — `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  require Phoenix.ChannelTest

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.{Permission, UserPermission}
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsWeb.GraphqlSocket
  alias Phoenix.Socket.Broadcast

  require Ash.Query

  @password "Password123!"
  @api %{shared: %{admin_surface: :api}}

  setup do
    SettingsState.refresh()
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  defp site!(opts \\ []) do
    host = "gql-socket-#{System.unique_integer([:positive])}.test"
    active = Keyword.get(opts, :active, true)
    master = Keyword.get(opts, :master, false)
    site = create_site!(name: host, host: host, active: active, master: master)
    save!(site, active, Keyword.get(opts, :mode, :hybrid))
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp save!(site, active, mode \\ :hybrid) do
    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: active,
        mode: mode,
        master: site.master
      })
  end

  defp offline!(site), do: {:ok, _} = Settings.put("cms.offline", true, site_id: site && site.id)

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  # Made while the site is still open: an offline site takes no registrations. `true` is an admin
  # holding `*`, `false` a user holding nothing, and a list the names the user holds.
  defp user!(site_id, true), do: user!(site_id, ["*"])
  defp user!(site_id, false), do: user!(site_id, [])

  defp user!(site_id, names) do
    user = create_user!(site_id: site_id)

    for name <- names do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  # A bearer token from the JSON:API sign-in, the way a frontend gets one.
  defp token!(host, user, headers \\ []) do
    body = %{
      data: %{type: "user", attributes: %{email: to_string(user.email), password: @password}}
    }

    conn =
      Enum.reduce(headers, %{build_conn() | host: host}, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> post("/api/json/v1/auth/user/sign-in", Jason.encode!(body))

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

  # What the transport hands `connect/3`: the address the socket was opened on, and the auth token
  # a client sends with `authToken`.
  defp open_socket(host, token \\ nil, params \\ %{}) do
    uri = URI.parse("http://#{host}/ws/gql/websocket")

    Phoenix.ChannelTest.connect(GraphqlSocket, params,
      connect_info: %{uri: uri, auth_token: token}
    )
  end

  describe "connecting" do
    test "a visitor connects to a site that is up, bound to it" do
      site = site!()

      assert {:ok, socket} = open_socket(site.host)
      assert socket.id == SiteAvailability.socket_id(site.id)
      assert context(socket) == %{actor: nil, tenant: site.id, context: @api}
    end

    # THE SOCKET IS THE API, as `/gql` is: an area is held there by its `admin:api:` name, and an
    # admin who holds only the dashboard's name for it does not hold it.
    test "a subscription runs as the API" do
      site = site!()
      admin = user!(site.id, true)

      assert {:ok, socket} = open_socket(site.host, token!(site.host, admin))
      assert context(socket).context == @api
      assert AccessPermissions.surface(context(socket).context) == :api
    end

    test "an address no site has, a switched-off site and one whose API is closed are refused" do
      assert open_socket("nobody-#{System.unique_integer([:positive])}.test") == :error
      assert {:error, {:inactive, _site}} = open_socket(site!(active: false).host)
      assert open_socket(site!(mode: :phoenix_only).host) == :error
    end

    test "a switched-off site is refused as switched off, whatever its mode" do
      site = site!(mode: :phoenix_only, active: false)
      site_id = site.id

      assert {:error, {:inactive, %{id: ^site_id}}} = open_socket(site.host)
    end

    test "an offline site refuses a visitor and its other users, and lets its admin in" do
      site = site!()
      admin = user!(site.id, true)
      member = user!(site.id, false)
      offline!(site)

      assert {:error, {:offline, _site}} = open_socket(site.host)
      assert {:error, {:offline, _site}} = open_socket(site.host, token!(site.host, member))

      assert {:ok, socket} = open_socket(site.host, token!(site.host, admin))
      assert context(socket).actor.id == admin.id
    end

    # THE SOCKET IS THE API, so an offline site lets in the admins of its API: whoever holds anything
    # under `admin:api`, one area or all of them, and not an admin of its screens alone.
    test "an offline site lets in its API admins, and not its dashboard-only admins" do
      site = site!()
      one_area = user!(site.id, ["admin:api:runtime:layout"])
      full = user!(site.id, ["admin:api:*"])
      screens = user!(site.id, ["admin:dashboard:*"])
      tokens = Map.new([one_area, full, screens], &{&1.id, token!(site.host, &1)})
      offline!(site)

      for admin <- [one_area, full] do
        assert {:ok, socket} = open_socket(site.host, tokens[admin.id])
        assert context(socket).actor.id == admin.id
      end

      assert {:error, {:offline, _site}} = open_socket(site.host, tokens[screens.id])
    end

    test "the offline master site lets in an API master, and not a dashboard-only master" do
      site = site!(master: true)
      api = user!(nil, ["admin:api:runtime:page"])
      screens = user!(nil, ["admin:dashboard:*"])
      api_token = token!(site.host, api, [{"x-no-tenant", "true"}])
      screens_token = token!(site.host, screens, [{"x-no-tenant", "true"}])
      offline!(site)

      assert {:ok, socket} = open_socket(site.host, api_token, %{"no_tenant" => "true"})
      assert context(socket).actor.id == api.id

      assert {:error, {:offline, _site}} =
               open_socket(site.host, screens_token, %{"no_tenant" => "true"})
    end

    test "the offline master site lets a master in, with a master token and no tenant" do
      site = site!(master: true)
      master = user!(nil, true)
      token = token!(site.host, master, [{"x-no-tenant", "true"}])
      offline!(site)

      assert {:ok, socket} = open_socket(site.host, token, %{"no_tenant" => "true"})
      assert %{actor: actor, tenant: nil} = context(socket)
      assert actor.id == master.id
    end

    test "a switched-off site refuses a master too, as its HTTP API does" do
      open = site!(master: true)
      master = user!(nil, true)
      token = token!(open.host, master, [{"x-no-tenant", "true"}])
      inactive = site!(active: false)

      assert {:ok, _socket} = open_socket(open.host, token, %{"no_tenant" => "true"})

      assert {:error, {:inactive, _site}} =
               open_socket(inactive.host, token, %{"no_tenant" => "true"})
    end

    # THE MASTER ACCOUNTS ANSWER ON THE MASTER SITE'S ADDRESS ALONE, as over HTTP: any other site
    # ignores `no_tenant`, binds the socket to itself, and a master's token names nobody there.
    test "a master is a master on the master site's address and nobody on any other" do
      master_site = site!(master: true)
      other = site!()
      master = user!(nil, true)
      token = token!(master_site.host, master, [{"x-no-tenant", "true"}])

      assert {:ok, socket} = open_socket(master_site.host, token, %{"no_tenant" => "true"})
      assert context(socket).actor.id == master.id

      assert {:ok, socket} = open_socket(other.host, token, %{"no_tenant" => "true"})
      assert context(socket) == %{actor: nil, tenant: other.id, context: @api}

      offline!(other)

      assert {:error, {:offline, _site}} =
               open_socket(other.host, token, %{"no_tenant" => "true"})
    end

    test "another site's admin counts as a visitor" do
      site = site!()
      other = site!()
      others_admin = user!(other.id, true)
      token = token!(other.host, others_admin)
      offline!(site)

      assert {:error, {:offline, _site}} = open_socket(site.host, token)
    end

    # A TOKEN ISSUED WITH NO SITE DOES NOT MAKE ITS HOLDER A MASTER: only a user with no site is one.
    test "a site's admin holding a token issued with no site is nobody on any site's address" do
      master_site = site!(master: true)
      site = site!()
      other = site!()
      others_admin = user!(other.id, true)
      token = tenantless_token!(others_admin)

      assert {:ok, socket} = open_socket(master_site.host, token, %{"no_tenant" => "true"})
      assert context(socket) == %{actor: nil, tenant: nil, context: @api}

      assert {:ok, socket} = open_socket(site.host, token, %{"no_tenant" => "true"})
      assert context(socket) == %{actor: nil, tenant: site.id, context: @api}

      offline!(site)

      assert {:error, {:offline, _site}} = open_socket(site.host, token, %{"no_tenant" => "true"})
    end
  end

  # The Absinthe context the socket's subscriptions run with.
  defp context(socket), do: socket.assigns.absinthe.opts[:context]

  describe "through the endpoint, over long polling" do
    # A long-poll client's first request: 410 with a session when `connect/3` takes it, 403 when not.
    defp poll(host, headers \\ []) do
      headers
      |> Enum.reduce(%{build_conn() | host: host}, fn {k, v}, c -> put_req_header(c, k, v) end)
      |> get("/ws/gql/longpoll", %{"vsn" => "2.0.0"})
      |> json_response(200)
      |> Map.fetch!("status")
    end

    test "the socket is bound to the address it is opened on" do
      open = site!()
      offline = site!()
      offline!(offline)

      assert poll(open.host) == 410
      assert poll(offline.host) == 403
    end

    test "the auth token a client sends lets the offline site's admin in" do
      site = site!()
      admin = user!(site.id, true)
      offline!(site)

      assert poll(site.host, [{"x-phoenix-authtoken", token!(site.host, admin)}]) == 410
    end
  end

  describe "through the endpoint, over WebSocket" do
    # A WebSocket client's handshake. A refused one never reaches the upgrade.
    defp handshake(host) do
      get(%{build_conn() | host: host}, "/ws/gql/websocket", %{"vsn" => "2.0.0"})
    end

    test "an offline site's refusal is the 503 site_offline /gql answers, with its message" do
      site = site!()
      {:ok, _} = Settings.put("cms.maintenance_message", "Back at noon", site_id: site.id)
      offline!(site)

      conn = handshake(site.host)

      assert conn.status == 503
      assert get_resp_header(conn, "x-error-code") == ["site_offline"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "errors" => [
                 %{
                   "message" => "Back at noon",
                   "extensions" => %{"code" => "site_offline", "status" => 503}
                 }
               ]
             } = json_response(conn, 503)
    end

    test "a switched-off site's is website_unavailable, and an unknown address gets a bare 403" do
      conn = handshake(site!(active: false).host)

      assert conn.status == 503
      assert get_resp_header(conn, "x-error-code") == ["website_unavailable"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert handshake("nobody-#{System.unique_integer([:positive])}.test") |> response(403) == ""
    end
  end

  describe "disconnecting" do
    # What a socket's transport does with its id: subscribe to it, and close on "disconnect" there.
    defp listen!(site) do
      {:ok, socket} = open_socket(site.host)
      :ok = MishkaCmsWeb.Endpoint.subscribe(socket.id)
      socket.id
    end

    test "a site's sockets are disconnected when it goes offline" do
      site = site!()
      id = listen!(site)

      offline!(site)

      assert_receive %Broadcast{topic: ^id, event: "disconnect"}
    end

    test "every site's sockets are disconnected by the global switch" do
      site = site!()
      id = listen!(site)

      offline!(nil)

      assert_receive %Broadcast{topic: ^id, event: "disconnect"}
    end

    test "a site's sockets are disconnected when it is switched off, and no other site's are" do
      site = site!()
      other = site!()
      id = listen!(site)
      other_id = listen!(other)

      save!(site, false)

      assert_receive %Broadcast{topic: ^id, event: "disconnect"}
      refute_received %Broadcast{topic: ^other_id}
    end

    # `SiteState.save/1` broadcasts in the caller, so a disconnect would already be here.
    test "a site that stays up keeps its sockets when it is edited" do
      site = site!()
      id = listen!(site)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority + 1,
          active: true,
          mode: :hybrid
        })

      refute_received %Broadcast{topic: ^id, event: "disconnect"}
    end
  end

  # A site owner's plugin that reports each refused connect.
  defmodule Refused do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "api:socket:site_unavailable"

    @impl true
    def call(data, _meta) do
      send(:graphql_socket_test, {:refused, data.site && data.site.id, data.state})
      {:reply, data}
    end
  end

  defp listen_for_refusals! do
    Process.register(self(), :graphql_socket_test)

    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: Refused,
        event: "api:socket:site_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile("api:socket:site_unavailable", :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, Refused, false) end)
  end

  test "a refused connect is announced on api:socket:site_unavailable" do
    listen_for_refusals!()

    offline = site!()
    offline!(offline)
    inactive = site!(active: false)

    assert {:error, _reason} = open_socket(offline.host)
    assert {:error, _reason} = open_socket(inactive.host)

    offline_id = offline.id
    inactive_id = inactive.id
    assert_receive {:refused, ^offline_id, :offline}
    assert_receive {:refused, ^inactive_id, :inactive}
  end

  # A site owner's plugin that reports each site that ignored the master accounts' switch.
  defmodule NoTenantRefused do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "api:socket:no_tenant_refused"

    @impl true
    def call(data, _meta) do
      send(:graphql_socket_test, {:no_tenant_refused, data.site.id})
      {:reply, data}
    end
  end

  test "the master accounts' switch ignored is announced on api:socket:no_tenant_refused" do
    Process.register(self(), :graphql_socket_test)

    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: NoTenantRefused,
        event: "api:socket:no_tenant_refused",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile("api:socket:no_tenant_refused", :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, NoTenantRefused, false) end)

    master_site = site!(master: true)
    site = site!()
    site_id = site.id

    assert {:ok, _socket} = open_socket(site.host, nil, %{"no_tenant" => "true"})
    assert_receive {:no_tenant_refused, ^site_id}

    assert {:ok, _socket} = open_socket(site.host)
    assert {:ok, _socket} = open_socket(master_site.host, nil, %{"no_tenant" => "true"})
    refute_receive {:no_tenant_refused, _site_id}, 200
  end

  test "an address no site has is announced as a switched-off site, with no site" do
    listen_for_refusals!()

    assert open_socket("nobody-#{System.unique_integer([:positive])}.test") == :error
    assert_receive {:refused, nil, :inactive}
  end

  test "a switched-off site whose mode closes its API is announced as switched off" do
    listen_for_refusals!()

    site = site!(mode: :phoenix_only, active: false)
    site_id = site.id

    assert {:error, _reason} = open_socket(site.host)
    assert_receive {:refused, ^site_id, :inactive}
  end
end
