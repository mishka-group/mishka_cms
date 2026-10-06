defmodule MishkaCms.Plugs.UploadsGate do
  @moduledoc """
  Serves a site's uploaded files only while that site is up.

  `Plug.Static` answers `/uploads` in the endpoint, before the session, the router and every site
  gate, so this runs just in front of it. A file under `/uploads/<site_id>/…` belongs to that site,
  on whatever address it is embedded in:

    * a site that is up — anyone, for two ETS reads and no session;
    * an inactive site, or one no longer cached because it was archived or deleted — a master only;
    * an offline site — its own admins and the masters.

  An admin here is a dashboard admin, holding anything under `admin:dashboard`
  (`MishkaCmsCore.Runtime.SiteAvailability.allowed_in?/4` on `:dashboard`), as for the site's pages. An admin of the API alone is refused.

  The viewer of a closed site's file is the user the signed session cookie names, as
  `MishkaCmsCore.Runtime.States.ViewerState` caches them, with no query. The cookie is only read:
  `Plug.Session` further down still owns the session.

  A refusal is a 404 that no cache keeps. A plugin on `web:request:upload_unavailable` hears it first,
  with `%{state: :inactive | :offline, site_id: site_id}` as its meta, and may answer instead by
  halting the conn.

  A path whose first segment is not a site id is passed on untouched.

      plug MishkaCms.Plugs.UploadsGate, session: @session_options
  """
  import Plug.Conn

  alias MishkaCmsCore.Accounts.LiveSockets
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.ViewerState

  def init(opts), do: Plug.Session.init(Keyword.fetch!(opts, :session))

  def call(%Plug.Conn{path_info: ["uploads", segment | _file]} = conn, session)
      when byte_size(segment) == 36 do
    case Ecto.UUID.cast(segment) do
      {:ok, site_id} -> gate(conn, site_id, SiteAvailability.state(site_id), session)
      :error -> conn
    end
  end

  def call(conn, _session), do: conn

  defp gate(conn, _site_id, :open, _session), do: conn

  defp gate(conn, site_id, state, session) do
    if SiteAvailability.allowed_in?(state, site_id, viewer(conn, session), :dashboard),
      do: conn,
      else: refuse(conn, state, site_id)
  end

  defp viewer(conn, %{store: store, store_config: store_config, key: key}) do
    with cookie when is_binary(cookie) <- fetch_cookies(conn).cookies[key],
         {_sid, %{"live_socket_id" => socket_id}} <- store.get(conn, cookie, store_config) do
      socket_id |> LiveSockets.user_id() |> ViewerState.get()
    else
      _signed_out -> nil
    end
  end

  defp refuse(conn, state, site_id) do
    conn =
      MishkaInstaller.Event.Hook.call("web:request:upload_unavailable", conn,
        meta: %{state: state, site_id: site_id}
      )

    if conn.halted,
      do: conn,
      else: conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "") |> halt()
  end
end
