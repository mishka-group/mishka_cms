defmodule MishkaCmsWeb.AuthGateTest do
  @moduledoc """
  A site closing its ways in (`MishkaCmsCore.Accounts.AuthGate`), through the whole endpoint: the
  JSON:API, the browser's `/api/auth` routes and the forms of the site's sign-in pages, and beside
  the site being offline — each refuses on its own, and only someone both let in gets in.

  `async: false` — the settings cache, the install flag, `SiteState` and the mailbox are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.{LiveSockets, User}
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"
  @auth "/api/json/v1/auth/user"

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()
    Install.mark_installed!()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    on_exit(fn ->
      SettingsState.restore(snapshot)
      :persistent_term.erase(:mishka_installed)
    end)

    {:ok, site: site!()}
  end

  defp site! do
    host = "gate-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    # The addresses below name every language, English included.
    {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
    site
  end

  defp email!, do: "someone-#{System.unique_integer([:positive])}@example.com"

  # A site's account holding `*`, which the gate lets through by default and an offline site too.
  defp everything!(site, email), do: holding!(site, email, "*")

  defp holding!(site, email, name) do
    permission =
      case MishkaCmsCore.Accounts.Permission
           |> Ash.Query.filter(name == ^name)
           |> Ash.read_one!(authorize?: false) do
        nil -> create_permission!(name: name)
        held -> held
      end

    [site_id: site.id, email: email]
    |> create_user!()
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()
  end

  defp close!(action, site),
    do: {:ok, _} = Settings.put("auth.#{action}.closed", true, site_id: site.id)

  defp from(site) do
    build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp api_sign_in(site, email) do
    body = %{data: %{type: "user", attributes: %{email: email, password: @password}}}

    site
    |> from()
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
    |> post("#{@auth}/sign-in", Jason.encode!(body))
  end

  # A token the way a sign-in hands one out, taken while sign-in is still open.
  defp token!(site, email) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: @password},
      tenant: site.id,
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.read_one!()
    |> Map.fetch!(:__metadata__)
    |> Map.fetch!(:token)
  end

  defp signed_in(site, user, token) do
    site
    |> from()
    |> init_test_session(%{
      "user_token" => token,
      "live_socket_id" => LiveSockets.live_socket_id(user)
    })
  end

  defp bearer(site, token) do
    site
    |> from()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/vnd.api+json")
    |> get("/api/json/v1/sign-out-probe")
  end

  defp sign_out_on!(site),
    do: {:ok, _} = Settings.put("auth.sign_in.sign_out", true, site_id: site.id)

  defp page(site, path) do
    seed_auth_pages!(site)
    {:ok, view, _html} = site |> from() |> live(path)
    view
  end

  test "the JSON:API answers a closed sign-in with 403 auth_closed, once the password is right",
       %{
         site: site
       } do
    email = email!()
    create_user!(site_id: site.id, email: email)
    close!(:sign_in, site)

    conn = api_sign_in(site, email)

    assert conn.status == 403

    assert [%{"code" => "auth_closed", "meta" => %{"action" => "sign_in"}}] =
             Jason.decode!(conn.resp_body)["errors"]
  end

  test "the browser's sign-in route says sign-in is closed, not that the password was wrong", %{
    site: site
  } do
    email = email!()
    create_user!(site_id: site.id, email: email)
    close!(:sign_in, site)

    conn =
      site
      |> from()
      |> post("/api/auth/user/password/sign_in", %{
        "user" => %{"email" => email, "password" => @password}
      })

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in is closed"
  end

  describe "the sign-in pages" do
    test "the sign-in card says so", %{site: site} do
      email = email!()
      create_user!(site_id: site.id, email: email)
      close!(:sign_in, site)
      view = page(site, "/en/auth")

      view
      |> form("#auth-sign-in-form", user: %{email: email, password: @password})
      |> render_submit()

      assert has_element?(view, "#auth-closed", "Sign-in is closed")
    end

    test "the register card says so", %{site: site} do
      close!(:register, site)
      view = page(site, "/en/auth/register")

      params = %{email: email!(), password: @password, password_confirmation: @password}
      view |> form("#auth-register-form", user: params) |> render_submit()

      assert has_element?(view, "#auth-closed", "Registration is closed")
    end

    test "the forgot-password card answers the same for everyone and mails no one let out", %{
      site: site
    } do
      email = email!()
      create_user!(site_id: site.id, email: email)
      close!(:reset, site)
      view = page(site, "/en/auth/forgot-password")

      view |> form("#auth-reset-form", user: %{email: email}) |> render_submit()

      assert render(view) =~ "Password reset is closed on this site."
      refute_receive {:email, %Swoosh.Email{subject: "Reset your password"}}
    end
  end

  describe "who is already signed in, once sign-out is on" do
    setup %{site: site} do
      seed_auth_pages!(site)
      email = email!()
      user = create_user!(site_id: site.id, email: email)
      %{user: user, token: token!(site, email)}
    end

    test "a page signs them out everywhere and sends them home with the reason", %{
      site: site,
      user: user,
      token: token
    } do
      MishkaCmsWeb.Endpoint.subscribe(LiveSockets.live_socket_id(user))
      close!(:sign_in, site)
      sign_out_on!(site)

      conn = site |> signed_in(user, token) |> get("/en/auth")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in is closed"
      assert get_session(conn, "user_token") == nil
      assert get_session(conn, "live_socket_id") == nil
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1000

      assert (site |> signed_in(user, token) |> get("/en/auth")).assigns.current_user == nil,
             "the token is revoked, so the old session names nobody"
    end

    test "closing sign-in alone, or being allowed, keeps them signed in", %{
      site: site,
      user: user,
      token: token
    } do
      admin_email = email!()
      admin = everything!(site, admin_email)
      admin_token = token!(site, admin_email)
      close!(:sign_in, site)

      assert (site |> signed_in(user, token) |> get("/en/auth")).assigns.current_user.id ==
               user.id

      sign_out_on!(site)

      assert (site |> signed_in(admin, admin_token) |> get("/en/auth")).assigns.current_user.id ==
               admin.id
    end

    test "an API token is revoked and names nobody, even once sign-in opens again", %{
      site: site,
      user: user,
      token: token
    } do
      assert bearer(site, token).assigns.current_user.id == user.id

      close!(:sign_in, site)
      sign_out_on!(site)
      assert bearer(site, token).assigns[:current_user] == nil

      {:ok, _} = Settings.put("auth.sign_in.closed", false, site_id: site.id)
      assert bearer(site, token).assigns[:current_user] == nil
    end

    test "an open dashboard page reloads as soon as the switch is saved", %{site: site} do
      email = email!()
      editor = holding!(site, email, "admin:dashboard:*")
      token = token!(site, email)
      close!(:sign_in, site)

      {:ok, view, _html} =
        site |> signed_in(editor, token) |> live("/admin/dashboard/settings")

      sign_out_on!(site)

      assert_redirect(view, "/admin/dashboard/settings", 1000)
    end
  end

  describe "with the site offline as well" do
    setup %{site: site} do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      close!(:sign_in, site)
      :ok
    end

    test "an admin both let through still signs in", %{site: site} do
      admin = email!()
      everything!(site, admin)

      assert api_sign_in(site, admin).status == 201
    end

    test "anyone else is refused by the gate first, as the gate", %{site: site} do
      email = email!()
      create_user!(site_id: site.id, email: email)

      assert [%{"code" => "auth_closed"}] =
               site
               |> api_sign_in(email)
               |> Map.fetch!(:resp_body)
               |> Jason.decode!()
               |> Map.fetch!("errors")
    end
  end
end
