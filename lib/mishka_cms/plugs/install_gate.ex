defmodule MishkaCms.Plugs.InstallGate do
  @moduledoc """
  First-run install gate. While the CMS is uninstalled (no master user and no site) every
  browser request is bounced to `/install`; once installed, `/install` is no longer a distinct
  destination — the gate resolves the request's site (via `SiteLookupPlug`) and routes it
  through the app's dynamic per-site error page, the same 404 an unknown route produces, so
  `/install` is not discoverable.

  Install state is a `:persistent_term` flag computed once at boot (`MishkaCmsCore.Install`),
  so this plug is a lock-free RAM read — never a per-request database count. It is placed in
  the `:browser` pipeline BEFORE `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` so a fresh deploy
  redirects to `/install` instead of hitting the host-not-found 503, and in the `:installer`
  pipeline (which omits `SiteLookupPlug`) so `/install` itself is reachable.

  Post-install, `/install` is failed with a `Plug.Conn.WrapperError` carrying the site-resolved
  conn. This wrapping is load-bearing: a bare `NotFoundError` raised inside a pipeline is
  reraised by the generated pipeline function with the conn as it ENTERED the pipeline (before
  this plug ran), dropping `current_site` and forcing `MishkaCmsWeb.ErrorHTML` to its plain-text
  fallback; wrapping preserves the conn so `render_errors` renders the per-site page (and falls
  back gracefully to plain text when the site has no error page). If `SiteLookupPlug` cannot
  resolve the host it halts (503/403) and that halted conn is returned.

  ## Setup token

  If the `MISHKA_SETUP_TOKEN` environment variable is set, requests to `/install` must carry a
  matching `?token=` (compared with `Plug.Crypto.secure_compare/2`).

  Whether it may be left UNSET depends on `config :mishka_cms, :require_setup_token`. In dev and
  test it is false: the `installed?` gate alone protects `/install`, so a non-technical operator is
  not forced to configure one. In production it is true, because the window between deploying and
  installing is a race the operator does not control — whoever reaches `/install` first creates the
  master user. With the flag on and no token configured, `/install` refuses everyone rather than
  admitting anyone.

  See `MishkaCmsCore.Install`.
  """
  use Gettext, backend: MishkaCmsWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias MishkaCms.Plugs.MaintenanceGate
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Settings
  alias Plug.Conn.WrapperError

  @install_path "/install"

  def init(opts), do: opts

  def call(conn, _opts) do
    case MishkaCmsCore.Install.status() do
      :installed -> when_installed(conn)
      :not_installed -> when_not_installed(conn)
      :unknown -> when_unknown(conn)
    end
  end

  # The flag is computed after the endpoint has started serving — `BootHandler` is the last child of
  # the supervision tree — and in tests it is never computed at all, so `:unknown` is an ordinary
  # state and not an error. Every path carries on as if this plug were not here, except the one that
  # mints a master user: `/install` is held to the same token check an uninstalled CMS holds it to,
  # which under `require_setup_token: true` is a refusal. Left as "do nothing", that page answered
  # ungated on every cold boot until the flag landed.
  defp when_unknown(conn) do
    if on_install_path?(conn), do: check_setup_token(conn), else: conn
  end

  defp when_installed(conn) do
    if on_install_path?(conn), do: not_found(conn), else: conn
  end

  defp not_found(conn) do
    conn
    |> fetch_query_params()
    |> SiteLookupPlug.call(SiteLookupPlug.init([]))
    |> render_dynamic_not_found()
  end

  defp render_dynamic_not_found(%Plug.Conn{halted: true} = conn), do: conn

  # An offline site shows nobody its own pages, its not-found page included.
  defp render_dynamic_not_found(conn) do
    if Settings.offline?(conn.assigns[:current_site]),
      do: MaintenanceGate.refuse(conn),
      else: raise_not_found(conn)
  end

  defp raise_not_found(conn) do
    raise WrapperError,
      conn: conn,
      kind: :error,
      reason: %NotFoundError{message: "Not found"},
      stack: []
  end

  defp when_not_installed(conn) do
    if on_install_path?(conn),
      do: check_setup_token(conn),
      else: conn |> redirect(to: @install_path) |> halt()
  end

  defp on_install_path?(conn) do
    conn.request_path == @install_path or
      String.starts_with?(conn.request_path, @install_path <> "/")
  end

  defp check_setup_token(conn) do
    case {System.get_env("MISHKA_SETUP_TOKEN"), required?()} do
      {token, _} when is_binary(token) and token != "" -> verify_token(conn, token)
      {_, false} -> conn
      {_, true} -> refuse_unconfigured(conn)
    end
  end

  # Where the token is required and none is configured, `/install` admits NOBODY. That is the safe
  # direction for the one page that mints the master user: a missing token is an operator mistake
  # they will see immediately, whereas admitting everyone is a mistake nobody sees until it is used.
  defp refuse_unconfigured(conn) do
    conn
    |> send_resp(
      403,
      gettext(
        "Setup token not configured. Set MISHKA_SETUP_TOKEN and open /install?token=<value>."
      )
    )
    |> halt()
  end

  defp required?, do: Application.get_env(:mishka_cms, :require_setup_token, false)

  defp verify_token(conn, token) do
    conn = fetch_query_params(conn)

    if Plug.Crypto.secure_compare(conn.query_params["token"] || "", token),
      do: conn,
      else: conn |> send_resp(403, gettext("Invalid setup token")) |> halt()
  end
end
