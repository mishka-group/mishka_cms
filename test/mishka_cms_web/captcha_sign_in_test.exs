# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.CaptchaSignInTest do
  @moduledoc """
  The sign-in pages of a site that asks a captcha (`MishkaCmsCore.Captcha`), through the router as a
  browser meets them: each of the four forms draws the box only while the site asks one; a form sent
  without a token, or with one Cloudflare refuses, is answered as the captcha and asks it again; a
  passed one signs in — and an account with an authenticator is asked its code without a second
  captcha; a sign-in link is not resent past it; AshAuthentication's own routes ask it too.
  Cloudflare is a shared `Req.Test` stub, since the page answers from its own process.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @password "Password123!"

  setup do
    Install.mark_installed!()
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
      Req.Test.set_req_test_to_private()
    end)

    host = "captcha-#{System.unique_integer([:positive])}.test"
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
    seed_auth_pages!(site)

    {:ok, site: site}
  end

  describe "a site that asks no captcha" do
    test "draws no box, and signs in as before", %{site: site} do
      user = user!(site)
      view = page(site, "/en/auth")

      refute has_element?(view, "#captcha-sign_in")

      assert {:error, {:redirect, %{to: to}}} = sign_in(view, user)
      assert to =~ "/api/auth/user/password/sign_in_with_token"
    end
  end

  describe "a site that asks one" do
    setup %{site: site} do
      turnstile!(site)
      :ok
    end

    test "draws the box in each of the four forms, for the hook to fill", %{site: site} do
      for {path, id} <- [
            {"/en/auth", "#captcha-sign_in"},
            {"/en/auth/register", "#captcha-register"},
            {"/en/auth/forgot-password", "#captcha-reset_request"},
            {"/en/auth/magic-link", "#captcha-magic_link"}
          ] do
        view = page(site, path)

        assert has_element?(view, "#{id}[phx-hook=Captcha][phx-update=ignore]"), path
        assert has_element?(view, "#{id}[data-provider=turnstile]"), path
        assert has_element?(view, "#{id} input[type=hidden][name='user[captcha_token]']"), path
      end
    end

    test "refuses a form sent without the token, says so, and asks the check again", %{
      site: site
    } do
      user = user!(site)
      view = page(site, "/en/auth")

      sign_in(view, user)

      assert has_element?(view, "#auth-captcha-refused")
      refute render(view) =~ "Invalid email or password"
      assert_push_event(view, "mishka:captcha:reset", %{})
    end

    test "refuses a token Cloudflare refuses", %{site: site} do
      user = user!(site)
      view = page(site, "/en/auth")
      answer!(%{"success" => false, "error-codes" => ["invalid-input-response"]})

      sign_in(view, user, token())

      assert has_element?(view, "#auth-captcha-refused")
      assert_push_event(view, "mishka:captcha:reset", %{})
    end

    test "signs in with a token Cloudflare accepts", %{site: site} do
      user = user!(site)
      answer!(%{"success" => true, "hostname" => "localhost"})

      assert {:error, {:redirect, %{to: to}}} = sign_in(page(site, "/en/auth"), user, token())
      assert to =~ "/api/auth/user/password/sign_in_with_token"
    end

    test "asks the authenticator's code after it, without a second captcha", %{site: site} do
      user = user!(site)
      secret = enable!(user)
      later!(user)
      view = page(site, "/en/auth")
      answer!(%{"success" => true})

      sign_in(view, user, token())
      assert has_element?(view, "#auth-second-factor-form")
      refute has_element?(view, "[phx-hook=Captcha]")

      Req.Test.stub(MishkaCmsCore.Captcha, fn _conn -> flunk("Cloudflare was asked again") end)

      assert {:error, {:redirect, %{to: to}}} =
               view
               |> form("#auth-second-factor-form",
                 user: %{totp_code: NimbleTOTP.verification_code(secret)}
               )
               |> render_submit()

      assert to =~ "sign_in_with_token"
    end

    test "the code step keeps the account it was asked for: another one's password is ignored", %{
      site: site
    } do
      user = user!(site)
      enable!(user)
      other = user!(site)
      view = page(site, "/en/auth")
      answer!(%{"success" => true})

      sign_in(view, user, token())
      assert has_element?(view, "#auth-second-factor-form")

      view
      |> element("#auth-second-factor-form")
      |> render_submit(%{user: %{email: to_string(other.email), password: @password}})

      assert has_element?(view, "#auth-second-factor-form")
      refute_redirected(view)
    end

    test "registers with a token Cloudflare accepts, and not without one", %{site: site} do
      view = page(site, "/en/auth/register")
      email = "new-#{System.unique_integer([:positive])}@example.com"
      fields = %{email: email, password: @password, password_confirmation: @password}

      view |> form("#auth-register-form", user: fields) |> render_submit()
      assert has_element?(view, "#auth-captcha-refused")

      answer!(%{"success" => true})

      assert {:error, {:redirect, %{to: to}}} =
               view
               |> form("#auth-register-form", user: fields)
               |> render_submit(solved(token()))

      assert to =~ "sign_in_with_token"
    end

    test "a sign-in link is asked for with the check, and resending brings the form back", %{
      site: site
    } do
      user = user!(site)
      view = page(site, "/en/auth/magic-link")
      email = to_string(user.email)

      view |> form("#auth-magic-form", user: %{email: email}) |> render_submit()
      assert has_element?(view, "#auth-captcha-refused")

      answer!(%{"success" => true})

      view
      |> form("#auth-magic-form", user: %{email: email})
      |> render_submit(solved(token()))

      assert has_element?(view, "#auth-resend-link")

      view |> element("#auth-resend-link") |> render_click()

      assert has_element?(view, "#auth-magic-form")
      assert has_element?(view, "#captcha-magic_link")
      assert has_element?(view, "#auth-magic-email[value='#{email}']")
    end

    test "AshAuthentication's own sign-in route asks it too", %{site: site} do
      user = user!(site)

      conn =
        site
        |> on_site()
        |> post("/api/auth/user/password/sign_in", %{
          "user" => %{"email" => to_string(user.email), "password" => @password}
        })

      refute get_session(conn, "user_token")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Complete the security check"

      answer!(%{"success" => true})

      conn =
        site
        |> on_site()
        |> post("/api/auth/user/password/sign_in", %{
          "user" => %{
            "email" => to_string(user.email),
            "password" => @password,
            "captcha_token" => token()
          }
        })

      # The session's token names the user who signed in.
      assert {:ok, %{"sub" => subject}} =
               AshAuthentication.Jwt.peek(get_session(conn, "user_token"))

      assert subject == AshAuthentication.user_to_subject(user)
    end

    test "lets the browser load Cloudflare on the site's pages", %{site: site} do
      conn = site |> on_site() |> get("/en/auth")

      policies =
        get_resp_header(conn, "content-security-policy-report-only") ++
          get_resp_header(conn, "content-security-policy")

      assert Enum.any?(policies, &(&1 =~ "frame-src 'self' https://challenges.cloudflare.com"))
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp turnstile!(site) do
    for {key, value} <- [
          {"security.captcha.provider", "turnstile"},
          {"security.captcha.turnstile.site_key", "1x00000000000000000000AA"},
          {"security.captcha.turnstile.secret_key", "1x0000000000000000000000000000000AA"}
        ] do
      {:ok, _} = Settings.put(key, value, site_id: site.id)
    end
  end

  defp answer!(json), do: Req.Test.stub(MishkaCmsCore.Captcha, &Req.Test.json(&1, json))

  defp token, do: "token-#{System.unique_integer([:positive])}"

  defp on_site(site) do
    build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp page(site, path) do
    {:ok, view, _html} = site |> on_site() |> live(path)
    view
  end

  defp sign_in(view, user, captcha \\ nil) do
    view
    |> form("#auth-sign-in-form", user: %{email: to_string(user.email), password: @password})
    |> render_submit(solved(captcha))
  end

  # WHAT THE HOOK WRITES into the box's hidden input once the visitor passed the check.
  defp solved(nil), do: %{}
  defp solved(captcha), do: %{user: %{captcha_token: captcha}}

  defp user!(site) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "captcha-#{System.unique_integer([:positive])}@example.com",
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
      %{
        setup_token: started.__metadata__.setup_token,
        code: NimbleTOTP.verification_code(secret)
      },
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update!()

    secret
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
