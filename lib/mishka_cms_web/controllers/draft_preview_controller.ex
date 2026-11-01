# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.DraftPreviewController do
  @moduledoc """
  Serves the temporary, isolated CSS bundle for a runtime preview at
  `/_preview/:resource/:token/css`.

  COMPILED FOR EACH REQUEST, KEPT NOWHERE. The record the token names is read as it is now and
  compiled by `MishkaCmsCore.Runtime.DraftPreviewAssets.css/2`: the saved stylesheets, Tailwind over
  its own markup (so brand-new classes are styled) and a draft's own Custom CSS, without ever
  touching the live site bundle. The preview page, `MishkaCmsWeb.DraftPreviewLive`, links this URL
  after its "Building preview…" overlay, and the bundle ends with the rule that hides it
  (`DraftPreviewLive.ready_css/0`) — or, when it could not be compiled, with the rules that say so
  on it (`DraftPreviewLive.failed_css/0`), still a 200, since a browser applies no stylesheet from
  an error response.

  It is served from this app's own origin as `text/css`, so the preview's policy needs nothing but
  `'self'` for it: no inline style without a nonce, and no script.

  Only under a token a preview was opened with, on an address that may show it
  (`MishkaCmsCore.Runtime.DraftPreviewAssets.served_on?/2`: its site's own or the master site's), and
  by its record's site's state, as the preview page itself: while that site is switched off, to a
  master, and while it is offline to its own admins too. An admin here holds anything under `admin:dashboard`
  (`MishkaCmsCore.Runtime.SiteAvailability.allowed_in?/4` on `:dashboard`); an admin of the API alone is refused.

  Anything else is a 404 that no cache keeps. A plugin on `web:request:preview_unavailable` hears it
  first, with `%{site_id: site_id | nil, reason: :missing | :offline | :inactive | :other_site}` as its meta, and
  may answer instead by halting the conn.
  """
  use MishkaCmsWeb, :controller

  require Logger

  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, SiteAvailability}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsWeb.DraftPreviewLive

  def css(conn, %{"resource" => resource, "token" => token}) do
    case preview_css(resource, token, conn.assigns[:current_user], conn.assigns[:current_site]) do
      {:ok, css} ->
        conn
        |> put_resp_content_type("text/css")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, css)

      {:error, site_id, reason} ->
        refuse(conn, site_id, reason)
    end
  end

  defp preview_css(resource, token, viewer, current_site) do
    with {:ok, site_id} <- DraftPreviewAssets.site(token),
         :ok <- on_its_address(site_id, current_site),
         :ok <- reachable(site_id, viewer),
         {:ok, record, _module} <- found(DraftPreviewLive.record(resource, token), site_id) do
      {:ok, built(compile(record, asset_site(record, site_id)), token)}
    else
      :error -> {:error, nil, :missing}
      {:refused, site_id, state} -> {:error, site_id, state}
    end
  end

  defp found({:ok, _record, _module} = found, _site_id), do: found
  defp found(:error, site_id), do: {:refused, site_id, :missing}

  # THE SITE IT IS COMPILED AGAINST is the record's own, or for a global record the one the preview
  # was opened on, which `DraftPreviewAssets.remember_site/2` kept under the token.
  defp asset_site(%{site: %{name: _name} = site}, _site_id), do: site

  defp asset_site(_global, site_id) when is_binary(site_id) do
    case SiteState.get(site_id) do
      {:ok, site} -> site
      {:error, :not_found} -> nil
    end
  end

  defp asset_site(_global, _no_site), do: nil

  defp built({:ok, css}, _token), do: css <> DraftPreviewLive.ready_css()

  defp built(:error, token) do
    Logger.warning("[DraftPreviewController] the preview stylesheet of #{token} did not compile")
    DraftPreviewLive.failed_css()
  end

  # mishka_cms_core 0.0.5 compiles the stylesheet and keeps it nowhere (`DraftPreviewAssets.css/2`).
  # Until it is on Hex the host builds against 0.0.4, which has no `css/2`: there it is compiled again
  # with `refresh_css/2` and read back from where that keeps it. Called through `apply/3` so this
  # compiles against either.
  defp compile(record, asset_site) do
    args = [record, asset_site]

    case Code.ensure_loaded?(DraftPreviewAssets) and
           function_exported?(DraftPreviewAssets, :css, 2) do
      true -> apply(DraftPreviewAssets, :css, args)
      false -> refreshed(apply(DraftPreviewAssets, :refresh_css, args), record)
    end
  end

  defp refreshed(:ok, %{preview_token: token}) do
    case AssetsState.get_value(token, "css") do
      css when is_binary(css) -> {:ok, css}
      _not_compiled -> :error
    end
  end

  defp refreshed(_error, _record), do: :error

  defp on_its_address(site_id, current_site) do
    if DraftPreviewAssets.served_on?(site_id, current_site),
      do: :ok,
      else: {:refused, site_id, :other_site}
  end

  defp reachable(nil, _viewer), do: :ok

  defp reachable(site_id, viewer) do
    case SiteAvailability.state(site_id) do
      :open ->
        :ok

      state ->
        if SiteAvailability.allowed_in?(state, site_id, viewer, :dashboard),
          do: :ok,
          else: {:refused, site_id, state}
    end
  end

  defp refuse(conn, site_id, reason) do
    conn =
      MishkaInstaller.Event.Hook.call("web:request:preview_unavailable", conn,
        meta: %{site_id: site_id, reason: reason}
      )

    if conn.halted,
      do: conn,
      else: conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "") |> halt()
  end
end
