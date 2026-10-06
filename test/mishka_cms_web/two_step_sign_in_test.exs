defmodule MishkaCmsWeb.TwoStepSignInTest do
  @moduledoc """
  The sign-in page and AshAuthentication's routes for an account with an authenticator app
  (`MishkaCmsCore.Accounts.SecondFactor`), through the router as a browser meets them: the password,
  then the code as a second step on the same card — or one of its recovery codes in its place —
  then the session; a sign-in link refused. An account without one signs in with its password
  alone, as before.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"

  setup do
    Install.mark_installed!()
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    host = "two-step-#{System.unique_integer([:positive])}.test"
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
    seed_auth_pages!(site)

    {:ok, site: site}
  end

  test "an account without an authenticator signs in with its password alone", %{site: site} do
    user = user!(site)

    assert {:error, {:redirect, %{to: to}}} = sign_in(page(site), user)
    assert to =~ "/api/auth/user/password/sign_in_with_token"
  end

  test "an account with one is asked for a code after the password, then signed in", %{
    site: site
  } do
    user = user!(site)
    secret = enable!(user)
    view = page(site)

    html = sign_in(view, user)
    assert has_element?(view, "#auth-second-factor-form")
    refute has_element?(view, "#auth-sign-in-form")
    refute html =~ @password

    view |> form("#auth-second-factor-form", user: %{totp_code: "000000"}) |> render_submit()
    assert has_element?(view, "#auth-second-factor-invalid")

    later!(user)

    assert {:error, {:redirect, %{to: to}}} =
             view
             |> form("#auth-second-factor-form", user: %{totp_code: code(secret)})
             |> render_submit()

    conn = site |> on_site() |> get(to)
    assert is_binary(get_session(conn, "user_token"))
  end

  test "a recovery code signs in in place of the code, once", %{site: site} do
    user = user!(site)
    secret = enable!(user)
    later!(user)
    [recovery | _rest] = recovery_codes!(user, secret)

    view = page(site)
    sign_in(view, user)
    view |> element("#auth-second-factor-mode") |> render_click()

    assert has_element?(view, "#auth-signin-recovery")
    refute has_element?(view, "#auth-signin-code")

    assert {:error, {:redirect, %{to: to}}} =
             view
             |> form("#auth-second-factor-form", user: %{recovery_code: recovery})
             |> render_submit()

    assert is_binary(site |> on_site() |> get(to) |> get_session("user_token"))

    again = page(site)
    sign_in(again, user)
    again |> element("#auth-second-factor-mode") |> render_click()
    again |> form("#auth-second-factor-form", user: %{recovery_code: recovery}) |> render_submit()

    assert has_element?(again, "#auth-second-factor-invalid")
  end

  test "a sign-in link is refused to an account with one, and says why", %{site: site} do
    user = user!(site)
    enable!(user)
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)

    conn =
      site
      |> on_site()
      |> post("/api/auth/user/magic_link", %{"user" => %{"token" => token}})

    refute get_session(conn, "user_token")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with your password"
  end

  test "a password reset of an account with one opens no session, and asks for the code", %{
    site: site
  } do
    user = user!(site)
    enable!(user)
    strategy = AshAuthentication.Info.strategy!(User, :password)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

    conn =
      site
      |> on_site()
      |> post("/api/auth/user/password/reset", %{
        "user" => %{
          "reset_token" => token,
          "password" => @password,
          "password_confirmation" => @password
        }
      })

    refute get_session(conn, "user_token")
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "authenticator"
  end

  # ---------------------------------------------------------------------------------------------

  defp on_site(site) do
    build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp page(site) do
    {:ok, view, _html} = site |> on_site() |> live("/en/auth")
    view
  end

  defp sign_in(view, user) do
    view
    |> form("#auth-sign-in-form", user: %{email: to_string(user.email), password: @password})
    |> render_submit()
  end

  defp user!(site) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "two-step-#{System.unique_integer([:positive])}@example.com",
        password: @password,
        password_confirmation: @password
      },
      authorize?: false
    )
    |> Ash.Changeset.set_tenant(site.id)
    |> Ash.create!()
  end

  defp enable!(user) do
    started =
      user
      |> Ash.Changeset.for_update(:setup_with_totp, %{}, actor: user, tenant: user.site_id)
      |> Ash.update!()

    secret =
      started.__metadata__.totp_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

    user
    |> Ash.Changeset.for_update(
      :confirm_setup_with_totp,
      %{setup_token: started.__metadata__.setup_token, code: code(secret)},
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update!()

    secret
  end

  defp code(secret), do: NimbleTOTP.verification_code(secret)

  defp recovery_codes!(user, secret) do
    user
    |> Ash.Changeset.for_update(:generate_recovery_codes, %{code: code(secret)},
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update!()
    |> then(& &1.__metadata__.recovery_codes)
  end

  # As if the next 30-second period had come: the code that confirmed the setup is spent.
  defp later!(user) do
    User
    |> Ash.get!(user.id, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_totp_at, DateTime.add(DateTime.utc_now(), -60))
    |> Ash.update!()
  end
end
