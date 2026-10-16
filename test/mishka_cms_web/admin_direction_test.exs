# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.AdminDirectionTest do
  @moduledoc """
  The dashboard is written in the direction of the language its admin reads it in
  (`MishkaCmsWeb.RuntimeLive.html_dir/1`): `<html dir="rtl">` for Persian, as a Persian page of the
  site is, and `ltr` for English.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @home "/admin/dashboard"

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

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    permission =
      case MishkaCmsCore.Accounts.Permission
           |> Ash.Query.filter(name == "admin:dashboard:*")
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} -> create_permission!(name: "admin:dashboard:*")
        {:ok, found} -> found
      end

    admin =
      [site_id: nil]
      |> create_user!()
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    %{admin: admin, site: site}
  end

  test "reads right to left in Persian, and left to right in English", %{admin: admin} do
    assert dashboard(admin, "fa") =~ ~s(<html lang="fa" dir="rtl")
    assert dashboard(admin, "en") =~ ~s(<html lang="en" dir="ltr")
  end

  # THE SIGN-OUT PAGE IS ONE OF THE SITE'S, so it is in the language its admin reads the site in —
  # not the one the dashboard is drawn in.
  test "Sign out is the site's page in the language the admin reads the site in", %{
    admin: admin,
    site: site
  } do
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)

    assert sign_out(dashboard(admin, "en", %{Languages.session() => "fa"})) == "/fa/auth/sign-out"
    assert sign_out(dashboard(admin, "fa", %{Languages.session() => "en"})) == "/auth/sign-out"
  end

  defp sign_out(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#admin-sign-out")
    |> LazyHTML.attribute("href")
    |> hd()
  end

  defp dashboard(admin, language, session \\ %{}) do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(session)
    |> Plug.Conn.put_session(:master_mode, true)
    |> Plug.Conn.put_session(Languages.admin_session(), language)
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
    |> get(@home)
    |> html_response(200)
  end
end
