defmodule MishkaCmsWeb.GraphqlSocket do
  @moduledoc """
  The socket GraphQL subscriptions run on, at `/ws/gql`, bound to the site of the address it is
  opened on.

  A connect is refused where the `/gql` pipeline would refuse a request, and in the same order: a
  switched-off site to everyone, masters included, before its mode or any token is read; an address
  no site has and a site whose mode closes its API; and an offline site to anyone but its own API
  admins and the API's masters: a user of that site, or a master, holding anything under
  `admin:api` (`MishkaCmsCore.Runtime.SiteAvailability.allowed_in?/4` on `:api`). An admin of the
  screens alone is refused.

  ## The refusal

  A WebSocket connect refused for the site's state gets the answer `/gql` gives, from
  `MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug.send_refusal/4` through `handle_error/2`, the
  endpoint's `:error_handler` for this socket: a `503` with `x-error-code: site_offline` (or
  `website_unavailable` for a switched-off site), `cache-control: no-store` and GraphQL's error shape
  with the site's maintenance message. An address no site has, a site whose mode closes its API
  and a connect with no address get Phoenix's bare `403`.

  Long polling answers every refused connect `{"status": 403}`: Phoenix's long-poll server takes no
  error handler.

  ## Signing in

  A bearer token comes as Phoenix's socket auth token — `new Socket("/ws/gql", {authToken: token})`
  — so it travels in a header and never in the address. It is read as `:load_from_bearer` reads the
  `Authorization` header: it names the actor, and is what lets an admin in while the site is offline.

  The `"no_tenant"` param set to `"true"` loads that token's user with no tenant, as the
  `x-no-tenant` header does over HTTP; a master's token needs it. Only the master site's address
  honours it: any other site binds the socket to itself, so a master's token names nobody there. A
  token issued with no site names nobody either unless its user has no site, as
  `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug.confirm_bearer_tenant/2` rules over HTTP.

  The actor, the tenant and the admin surface become the Absinthe context, as `AshGraphql.Plug` sets
  them over HTTP. The surface is the API's (`MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug`), so a
  subscription's policies hold an area by its `admin:api:` name, as `/gql`'s do.

  ## Disconnecting

  `id/1` is `MishkaCmsCore.Runtime.SiteAvailability.socket_id/1` of the site, so every socket of a
  site is disconnected when it goes offline or is switched off; a client that reconnects is asked
  again.

  ## Events

  - `api:socket:site_unavailable` — `%{site: site, state: :offline | :inactive, actor: user}` when a
    connect to a closed site is refused; `actor` is `nil` for a switched-off site, whose token is
    never read, and `site` is `nil` too for an address no site has, announced as `:inactive`.
  - `api:socket:no_tenant_refused` — `%{site: site}` when a site that is not the master site is
    asked for `no_tenant` and ignores it.
  """
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: MishkaCmsWeb.GraphqlSchema

  alias MishkaCmsCore.Runtime.Plugs.{AdminSurfacePlug, ApiAvailabilityPlug, ApiTenantLookupPlug}
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.SiteState

  @impl true
  def connect(params, socket, %{uri: %URI{host: host}} = connect_info) when is_binary(host) do
    case SiteState.get_by_host(host) do
      {:ok, site} ->
        connect_to(site, SiteAvailability.state(site.id), params, socket, connect_info)

      # AN ADDRESS NO SITE HAS is announced as a switched-off site, as `SiteAvailability` counts one,
      # and answered with Phoenix's bare `403`: there is no site whose refusal it could send.
      {:error, :not_found} ->
        announce(nil, :inactive, nil)
        :error
    end
  end

  def connect(_params, _socket, _no_host), do: :error

  @impl true
  def id(%{assigns: %{site_id: site_id}}), do: SiteAvailability.socket_id(site_id)

  @doc """
  The WebSocket transport's `:error_handler`: answers a connect refused for its site's state as
  `/gql` answers a request, and anything else with Phoenix's bare `403`.

      socket "/ws/gql", MishkaCmsWeb.GraphqlSocket,
        websocket: [
          connect_info: [:uri],
          error_handler: {MishkaCmsWeb.GraphqlSocket, :handle_error, []}
        ]
  """
  @spec handle_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle_error(conn, {state, site}) when state in [:offline, :inactive],
    do: ApiAvailabilityPlug.send_refusal(conn, state, site, :graphql)

  def handle_error(conn, _reason), do: Plug.Conn.send_resp(conn, 403, "")

  # AS ApiTenantLookupPlug: a switched-off site is refused to everyone, masters included, before its
  # mode and any token are read.
  defp connect_to(site, :inactive, _params, _socket, _connect_info),
    do: refuse(site, :inactive, nil)

  defp connect_to(%{mode: :phoenix_only}, _state, _params, _socket, _connect_info), do: :error

  defp connect_to(site, state, params, socket, connect_info) do
    tenant = tenant(params, site)
    actor = actor(connect_info[:auth_token], site, tenant, socket)

    if SiteAvailability.allowed_in?(state, site.id, actor, :api),
      do: {:ok, bind(socket, site, actor, tenant)},
      else: refuse(site, state, actor)
  end

  defp refuse(site, state, actor) do
    announce(site, state, actor)
    {:error, {state, site}}
  end

  defp announce(site, state, actor) do
    MishkaInstaller.Event.Hook.call(
      "api:socket:site_unavailable",
      %{site: site, state: state, actor: actor},
      return: false
    )
  end

  defp bind(socket, site, actor, tenant) do
    socket
    |> assign(:site_id, site.id)
    |> Absinthe.Phoenix.Socket.put_options(
      context: %{actor: actor, tenant: tenant, context: AdminSurfacePlug.put(%{}, :api)}
    )
  end

  # AS ApiTenantLookupPlug: `no_tenant` is honoured on the master site's address alone.
  defp tenant(%{"no_tenant" => "true"}, %{master: true}), do: nil

  defp tenant(%{"no_tenant" => "true"}, site) do
    MishkaInstaller.Event.Hook.call("api:socket:no_tenant_refused", %{site: site}, return: false)
    site.id
  end

  defp tenant(_params, site), do: site.id

  # `AshAuthentication.Plug.Helpers.retrieve_from_bearer/3` and
  # `ApiTenantLookupPlug.confirm_bearer_tenant/2` themselves, on a conn that carries only the token,
  # the site and the tenant, so a token passes here exactly when it would pass over HTTP. Neither
  # reads the client's address, so the conn carries the unspecified one that `Plug.Conn.t()` asks for.
  defp actor(token, site, tenant, socket) when is_binary(token) do
    %Plug.Conn{remote_ip: {0, 0, 0, 0}}
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.assign(:current_site, site)
    |> Ash.PlugHelpers.set_tenant(tenant)
    |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(socket.endpoint.config(:otp_app))
    |> ApiTenantLookupPlug.confirm_bearer_tenant([])
    |> Map.fetch!(:assigns)
    |> Map.get(:current_user)
  end

  defp actor(_no_token, _site, _tenant, _socket), do: nil
end
