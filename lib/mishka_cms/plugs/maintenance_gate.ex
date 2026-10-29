# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Plugs.MaintenanceGate do
  @moduledoc """
  Joomla-style "site offline" gate. When the `cms.offline` setting is on, every front-end request is
  served a maintenance page **except**: the sign-in pages and routes
  (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.sign_in_path?/2`, so an admin can still sign in), the
  installer, asset and admin dashboard routes, and requests from a **master admin**
  (`site_id == nil`) or **this site's tenant admin** (`site_id == current_site.id`) holding anything
  under `admin:dashboard` — they see the real site. An API admin does not: the pages are the
  dashboard's side.

  `MishkaCmsCore.Settings.offline?/1` answers the flag from the RAM settings cache, so this is a
  lock-free read on every request. A master switches every site off and a site switches itself off;
  the two are OR-ed, so a site cannot turn itself back on against the master's switch. It must run
  **after** `:load_from_session` (it needs `current_user`) and after `SiteLookupPlug` (it needs
  `current_site`), and **before** `LanguagePlug`, so an offline site answers every address with this
  page rather than first redirecting it to a language.

  The hard `site.active = false` kill-switch stays in `SiteLookupPlug` (a 503 with no bypass); this is
  the softer "be right back" state with an admin login bypass.

  ## The page

  A refused request is answered at the address it asked for, a 503 with `retry-after` and
  `cache-control: no-store`. The page is the site's own: the `:offline` entry of its Error Page,
  which its admin edits beside the 404 and the 500 (see `MishkaCmsWeb.ErrorHTML.offline_page/1`).
  When the site has no Error Page, no such entry, or one that does not compile or raised when it was
  drawn at compile time, the built-in page is drawn instead, with the site's
  `cms.maintenance_message`.

  A page an admin is let through to while the site is offline carries `cache-control: private,
  no-store`, so a cache in front of the site never keeps it for a visitor.

  ## Events

    * `web:request:site_unavailable` — before the page is drawn, with `%{state: :offline, site:
      site}`. A plugin may answer instead by halting the conn.
    * `web:request:offline_page` — once the page is drawn, before it is sent, with `%{site: site,
      source: :error_page}` or `%{site: site, source: :built_in, reason: reason}`. A plugin may
      change the conn, or answer instead by halting it.

  ## Open pages

  This answers HTTP requests. A live navigation, an event and a change of state on a page already
  open reach no pipeline; `MishkaCmsCore.Runtime.SiteAvailability.on_mount/4` answers those.

  See `MishkaCmsCore.Settings`.
  """
  use Gettext, backend: MishkaCmsWeb.Gettext

  import Plug.Conn

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.States.ViewerState
  alias MishkaCmsCore.Settings
  alias MishkaCmsWeb.ErrorHTML
  alias MishkaInstaller.Event.Hook

  @default_message gettext_noop(
                     "We are currently undergoing maintenance. Please check back soon."
                   )

  # Seconds a client or a crawler is asked to wait before trying again.
  @retry_after "300"

  # Signing in has to work while the site is down, or the admin the bypass exists for cannot get in
  # to turn it back on: the sign-in pages (`/<language>/auth…`, and `/auth…`) and the
  # AshAuthentication controller under `/api/auth` that mints the session pass, as
  # `SiteLookupPlug.sign_in_path?/2` names them. The dashboard passes too: it sends a signed-out
  # admin to sign in, and it is guarded by sign-in and permission, so it shows the site to nobody.
  # Whole path segments, so `/authors` or `/installation-guide` is a page like any other.
  @allowlist [["install"], ["assets"], ["admin", "dashboard"]]

  # Except the one that makes a NEW account. A site that is down is not taking sign-ups, and the
  # register route is the only part of the auth surface that is not about getting an existing admin
  # back in. `MishkaCmsCore.Accounts.Checks.RegistrationOpen` refuses the same thing at the
  # resource, which is the boundary; this only keeps the request from reaching it.
  @registration ["api", "auth", "user", "password", "register"]

  def init(opts), do: opts

  def call(conn, _opts) do
    site = conn.assigns[:current_site]
    user = conn.assigns[:current_user]
    ViewerState.remember(user)

    cond do
      !Settings.offline?(site) -> conn
      allowlisted?(conn) -> conn
      admin_bypass?(user, site) -> put_resp_header(conn, "cache-control", "private, no-store")
      true -> refuse(conn)
    end
  end

  @doc """
  Answers `conn` with the site's offline page, a 503, and halts it.

  A plugin on `web:request:site_unavailable` hears it first, with `%{state: :offline, site: site}` as
  its meta, and may answer with a page of its own by halting the conn. One on
  `web:request:offline_page` hears which page was drawn, before it is sent.
  """
  @spec refuse(Plug.Conn.t()) :: Plug.Conn.t()
  def refuse(conn) do
    site = conn.assigns[:current_site]

    conn =
      Hook.call("web:request:site_unavailable", conn, meta: %{state: :offline, site: site})

    if conn.halted, do: conn, else: conn |> answer_offline(site) |> halt()
  end

  defp allowlisted?(%Plug.Conn{path_info: path} = conn) do
    (SiteLookupPlug.sign_in_path?(path, conn.assigns[:current_site]) or
       Enum.any?(@allowlist, &List.starts_with?(path, &1))) and
      not List.starts_with?(path, @registration)
  end

  defp admin_bypass?(user, site),
    do:
      Helper.master_admin?(user, :dashboard) or
        Helper.site_admin?(user, site && site.id, :dashboard)

  # THE LANGUAGE THE VISITOR READS THE SITE IN, the session's: `LanguagePlug` runs after this gate,
  # so the page — the site's own offline entry, or the built-in one — finds it where a page would,
  # and links the sign-in page in it.
  #
  # `page` is the site's own offline entry, rendered by its compiled error page, or
  # `maintenance_html/4`, which escapes the message and builds the sign-in address from the site's
  # own languages; nothing from the request reaches it unescaped.
  # sobelow_skip ["XSS.SendResp"]
  defp answer_offline(conn, site) do
    language = Languages.remembered(get_session(conn, Languages.session()), site && site.id)

    conn =
      conn
      |> assign(:site_language, language)
      |> put_status(503)
      |> put_resp_header("retry-after", @retry_after)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/html")

    {page, meta} = offline_page(conn, site)
    conn = Hook.call("web:request:offline_page", conn, meta: Map.put(meta, :site, site))

    if conn.halted, do: conn, else: send_resp(conn, 503, page)
  end

  defp offline_page(conn, site) do
    case ErrorHTML.offline_page(conn) do
      {:ok, page} ->
        {page, %{source: :error_page}}

      {:error, reason} ->
        message = Settings.get("cms.maintenance_message", @default_message, site && site.id)

        sign_in = SiteLookupPlug.auth_address(conn.assigns.site_language, site && site.id)

        {maintenance_html(speak(message), conn.assigns[:csp_nonce], site, sign_in),
         %{source: :built_in, reason: reason}}
    end
  end

  # THE NONCE COMES OFF THE CONN, because this page is not rendered through the root layout — it is
  # a whole document written by a plug, so nothing else marks its `<style>` as ours and
  # `style-src-elem` refuses it. A maintenance page that arrives unstyled is a worse first
  # impression than the outage it is announcing.
  defp maintenance_html(message, nonce, site, sign_in_address) do
    title = Plug.HTML.html_escape(gettext("Down for Maintenance"))

    sign_in =
      gettext("Administrators of this site can %{link} to continue.",
        link:
          ~s(<a href="#{sign_in_address}?master_user=false">#{Plug.HTML.html_escape(gettext("sign in"))}</a>)
      )

    """
    <!DOCTYPE html>
    <html>
      <head>
        <title>#{title}</title>
        <style#{nonce_attr(nonce)}>
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            text-align: center;
            padding: 50px;
            background-color: #f5f5f5;
            color: #333;
          }
          .container {
            max-width: 600px;
            margin: 0 auto;
            background: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
          }
          h1 { color: #e67e22; margin-bottom: 20px; }
          p { color: #666; line-height: 1.6; }
          a { color: #2980b9; }
          .master { font-size: 13px; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>#{title}</h1>
          <p>#{Plug.HTML.html_escape(message)}</p>
          <p>#{sign_in}</p>
          #{master_sign_in(site, sign_in_address)}
        </div>
      </body>
    </html>
    """
  end

  # A MASTER SIGNS IN ON THE MASTER SITE'S OWN ADDRESS AND NOWHERE ELSE, so only that site's page
  # offers it. Any other site's page would be pointing at a sign-in that refuses them.
  defp master_sign_in(%{master: true}, sign_in_address),
    do:
      ~s(<p class="master"><a href="#{sign_in_address}?master_user=true">#{Plug.HTML.html_escape(gettext("Master sign in"))}</a></p>)

  defp master_sign_in(_site, _sign_in_address), do: ""

  defp speak(@default_message), do: Gettext.gettext(MishkaCmsWeb.Gettext, @default_message)
  defp speak(message), do: message

  defp nonce_attr(nonce) when is_binary(nonce), do: ~s( nonce="#{nonce}")
  defp nonce_attr(_absent), do: ""
end
