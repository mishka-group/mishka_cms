# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.DraftPreviewController do
  @moduledoc """
  Serves the temporary, isolated CSS bundle for a runtime preview at
  `/_preview/:resource/:token/css`.

  The bundle is compiled per-draft (`MishkaCmsCore.Runtime.DraftPreviewAssets`) so brand-new Tailwind
  classes are styled without ever touching the live site bundle, and is keyed by the draft's
  `preview_token`. The preview page itself is `MishkaCmsWeb.DraftPreviewLive`, which links this URL.

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

  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, SiteAvailability}
  alias MishkaCmsCore.Runtime.States.AssetsState

  def css(conn, %{"token" => token}) do
    case preview_css(token, conn.assigns[:current_user], conn.assigns[:current_site]) do
      {:ok, css} ->
        conn
        |> put_resp_content_type("text/css")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, css)

      {:error, site_id, reason} ->
        refuse(conn, site_id, reason)
    end
  end

  defp preview_css(token, viewer, current_site) do
    with {:ok, site_id} <- DraftPreviewAssets.site(token),
         :ok <- on_its_address(site_id, current_site),
         :ok <- reachable(site_id, viewer) do
      case AssetsState.get_value(token, "css") do
        css when is_binary(css) -> {:ok, css}
        _not_compiled -> {:error, site_id, :missing}
      end
    else
      :error -> {:error, nil, :missing}
      {:refused, site_id, state} -> {:error, site_id, state}
    end
  end

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
