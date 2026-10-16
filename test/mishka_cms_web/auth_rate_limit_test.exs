# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.AuthRateLimitTest do
  @moduledoc """
  How often someone may sign in, ask for a password reset, ask for a sign-in link and try their
  current password to change it, through the whole endpoint: the JSON:API routes, the browser's
  `/api/auth` routes and the forms of the site's sign-in pages, `/auth…`, which
  `MishkaCmsCore.Install.StarterContent.ensure_auth!/1` writes and `MishkaCmsWeb.RuntimeLive` serves.

  Each is counted by its action, per address and per account, into buckets the three share — see
  `MishkaCmsCore.Accounts.AuthRateLimit`. The one asked for too often gets a `429` with
  `retry-after` — in JSON:API's error shape on the API, as a page in the browser, and as a message on
  the sign-in card — before any password is checked or mail is sent. The reset itself is not
  limited: its token is spent once.

  The suite's `limit:` override is lifted and the settings set low, two tries per account and five
  per address, and every test comes from an address and uses accounts and a site of its own, so no
  test spends another's allowance.

  `async: false` — the application environment, the settings cache, the install flag, `SiteState`
  and the mailbox are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.{AuthRateLimit, User}
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}

  @password "Password123!"
  @auth "/api/json/v1/auth/user"

  setup do
    previous = Application.fetch_env(:mishka_cms_core, AuthRateLimit)
    Application.delete_env(:mishka_cms_core, AuthRateLimit)
    snapshot = SettingsState.snapshot()

    for action <- ~w(sign_in reset_request magic_link),
        {scope, limit} <- [account: 2, ip: 5],
        do: SettingsState.put(nil, "security.#{action}_per_#{scope}", %{"value" => limit})

    SettingsState.put(nil, "security.change_password_per_account", %{"value" => 2})

    Install.mark_installed!()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    on_exit(fn ->
      with {:ok, env} <- previous, do: Application.put_env(:mishka_cms_core, AuthRateLimit, env)
      SettingsState.restore(snapshot)
      :persistent_term.erase(:mishka_installed)
    end)

    {:ok, site: site!(), ip: address!()}
  end

  # A site in the site cache, the way both lookups read it, with the origin its frontend runs on.
  defp site! do
    host = "rate-limit-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        frontend_domain: "front." <> host
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  # A private address unless `first` says otherwise: a proxy's, or a client nothing stands in front
  # of.
  defp address!(first \\ 10) do
    n = System.unique_integer([:positive])
    {first, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  defp email!, do: "someone-#{System.unique_integer([:positive])}@example.com"

  defp user!(site), do: create_user!(site_id: site.id, email: email!())

  defp written(ip), do: ip |> :inet.ntoa() |> to_string()

  # A request to `site` from `ip`, as the endpoint receives one: the Host header names the site, and
  # the address is both the conn's and, for a LiveView, its socket's peer.
  defp from(site, ip, headers \\ []) do
    conn =
      build_conn()
      |> Map.put(:host, site.host)
      |> Map.put(:remote_ip, ip)
      |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.put_peer_data(%{address: ip, port: 4000, ssl_cert: nil})

    Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
  end

  defp json_api(conn) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  # A wrong password is answered 403, so a 403 is a sign-in that was let through to be checked.
  defp api_sign_in(site, ip, email, password \\ "not-the-password", headers \\ []) do
    body = %{data: %{type: "user", attributes: %{email: email, password: password}}}
    site |> from(ip, headers) |> json_api() |> post("#{@auth}/sign-in", Jason.encode!(body))
  end

  defp api_reset_request(site, ip, email) do
    site
    |> from(ip)
    |> json_api()
    |> post("#{@auth}/reset-request", Jason.encode!(%{data: %{email: email}}))
  end

  # A reset that is refused for its confirmation, so the token stays unspent.
  defp api_reset(site, ip, token) do
    body = %{
      data: %{
        type: "user",
        attributes: %{
          reset_token: token,
          password: "NewPassword123!",
          password_confirmation: "Different123!"
        }
      }
    }

    site |> from(ip) |> json_api() |> post("#{@auth}/reset-password", Jason.encode!(body))
  end

  # A signed-in user's password change, with its bearer token.
  defp api_change_password(site, ip, token, current) do
    body = %{
      data: %{
        type: "user",
        attributes: %{
          current_password: current,
          password: "NewPassword123!",
          password_confirmation: "NewPassword123!"
        }
      }
    }

    site
    |> from(ip, [{"authorization", "Bearer " <> token}])
    |> json_api()
    |> patch("#{@auth}/change-password", Jason.encode!(body))
  end

  defp api_token!(site, ip, user) do
    conn = api_sign_in(site, ip, to_string(user.email), @password)
    assert conn.status == 201
    Jason.decode!(conn.resp_body)["meta"]["token"]
  end

  defp reset_token!(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
    token
  end

  defp browser_sign_in(site, ip, email, headers \\ []) do
    site
    |> from(ip, headers)
    |> post("/api/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => "not-the-password"}
    })
  end

  defp limited?(conn), do: conn.status == 429

  # The mails with `subject` that have reached this test so far, taken out of its mailbox.
  defp mails(subject) do
    receive do
      {:email, %{subject: ^subject}} -> 1 + mails(subject)
    after
      0 -> 0
    end
  end

  # The site's sign-in page, from `ip`, as its socket's peer and any `headers` say.
  defp auth_page(site, ip, headers \\ []) do
    {:ok, view, _html} = site |> from(ip, headers) |> live("/auth")
    view
  end

  # The sign-in page's `link` followed, from the same address, to the page it opens.
  defp auth_card(site, ip, link) do
    {:ok, view, _html} =
      site
      |> auth_page(ip)
      |> element("##{link}")
      |> render_click()
      |> follow_redirect(from(site, ip))

    view
  end

  defp live_sign_in(view, email, password \\ "not-the-password") do
    view
    |> form("#auth-sign-in-form", user: %{email: email, password: password})
    |> render_submit()
  end

  defp throttled?(view), do: has_element?(view, "#auth-rate-limited")

  # `config/runtime.exs` as production reads it, given the variables it cannot start without and
  # `variables`, and nothing else it reads for who is asking.
  defp production_config(variables) do
    variables =
      Map.merge(
        %{
          "DATABASE_URL" => "ecto://user:pass@localhost/mishka_cms",
          "SECRET_KEY_BASE" => String.duplicate("a", 64),
          "TOKEN_SIGNING_SECRET" => String.duplicate("b", 64),
          "TRUSTED_PROXY_RANGES" => nil
        },
        variables
      )

    previous = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)
    put_variables(variables)
    on_exit(fn -> put_variables(previous) end)

    Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :prod)
  end

  defp put_variables(variables) do
    Enum.each(variables, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp behind(proxies) do
    previous = Application.fetch_env(:mishka_cms_core, :trusted_proxies)
    Application.put_env(:mishka_cms_core, :trusted_proxies, proxies)

    on_exit(fn ->
      case previous do
        {:ok, proxies} -> Application.put_env(:mishka_cms_core, :trusted_proxies, proxies)
        :error -> Application.delete_env(:mishka_cms_core, :trusted_proxies)
      end
    end)
  end

  describe "the JSON:API sign-in" do
    test "answers an account's third try with a 429 in JSON:API's error shape, saying when to come back",
         %{site: site, ip: ip} do
      email = email!()

      for _try <- 1..2, do: assert(api_sign_in(site, ip, email).status == 403)

      conn = api_sign_in(site, ip, email)

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 800..900
      assert get_resp_header(conn, "x-error-code") == ["rate_limited"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

      assert %{
               "errors" => [
                 %{
                   "status" => "429",
                   "code" => "rate_limited",
                   "title" => "Too many sign-in attempts",
                   "detail" => "Too many sign-in attempts. Try again in 15 minutes.",
                   "meta" => %{
                     "retry_after" => seconds,
                     "action" => "sign_in",
                     "limited_by" => "account"
                   }
                 }
               ],
               "jsonapi" => %{"version" => "1.0"}
             } = Jason.decode!(conn.resp_body)

      assert Integer.to_string(seconds) == retry_after
    end

    test "refuses the right password too, once an account's tries are spent", %{
      site: site,
      ip: ip
    } do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()

      for _try <- 1..2, do: api_sign_in(site, ip, email)
      conn = api_sign_in(site, ip, email, @password)

      assert limited?(conn)
      refute conn.resp_body =~ "token"
    end

    test "follows an account to every address, and leaves the address its other accounts", %{
      site: site,
      ip: ip
    } do
      email = email!()
      for _try <- 1..3, do: api_sign_in(site, ip, email)

      assert site |> api_sign_in(address!(), email) |> limited?()
      assert api_sign_in(site, ip, email!()).status == 403
    end

    test "refuses an address that tries account after account", %{site: site, ip: ip} do
      for _account <- 1..5, do: assert(api_sign_in(site, ip, email!()).status == 403)

      assert site |> api_sign_in(ip, email!()) |> limited?()
      assert api_sign_in(site, address!(), email!()).status == 403
    end

    test "counts every site apart: an account and an address spent on one are fresh on another",
         %{
           site: site,
           ip: ip
         } do
      email = email!()
      for _try <- 1..3, do: api_sign_in(site, ip, email)
      for _account <- 1..3, do: api_sign_in(site, ip, email!())
      assert site |> api_sign_in(ip, email!()) |> limited?()

      other = site!()
      assert api_sign_in(other, ip, email).status == 403
      assert api_sign_in(other, ip, email!()).status == 403
    end

    test "sends the refusal with headers a frontend on an origin the site allows can read", %{
      site: site,
      ip: ip
    } do
      email = email!()
      origin = "https://front." <> site.host
      for _try <- 1..2, do: api_sign_in(site, ip, email)

      conn = api_sign_in(site, ip, email, "not-the-password", [{"origin", origin}])

      assert limited?(conn)
      assert get_resp_header(conn, "access-control-allow-origin") == [origin]

      assert get_resp_header(conn, "access-control-expose-headers") == [
               "retry-after, x-error-code"
             ]
    end

    test "counts the account the query string names, which is the one the action signs in", %{
      site: site
    } do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()

      sign_in = fn password ->
        body = %{data: %{type: "user", attributes: %{email: email!(), password: password}}}

        site
        |> from(address!())
        |> json_api()
        |> post("#{@auth}/sign-in?#{URI.encode_query(%{email: email})}", Jason.encode!(body))
      end

      for _try <- 1..2, do: assert(sign_in.("not-the-password").status == 403)

      conn = sign_in.(@password)

      assert limited?(conn)
      refute conn.resp_body =~ "token"
    end
  end

  describe "the JSON:API password reset" do
    test "answers an email's third reset request with a 429, and mails it nothing", %{site: site} do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()
      mails("Reset your password")

      for _request <- 1..2, do: assert(api_reset_request(site, address!(), email).status == 201)
      assert mails("Reset your password") == 2

      conn = api_reset_request(site, address!(), email)

      assert limited?(conn)

      assert [%{"title" => "Too many password reset requests"}] =
               Jason.decode!(conn.resp_body)["errors"]

      assert mails("Reset your password") == 0
    end

    test "never limits the reset itself, whose token is spent once", %{site: site, ip: ip} do
      token = site |> user!() |> reset_token!()

      for _try <- 1..6, do: refute(site |> api_reset(ip, token) |> limited?())
    end
  end

  describe "the JSON:API password change" do
    test "answers an account's third try with a 429, the right current password too, and changes nothing",
         %{site: site, ip: ip} do
      user = user!(site)
      token = api_token!(site, ip, user)

      hashed = fn ->
        User
        |> Ash.get!(user.id, tenant: site.id, authorize?: false)
        |> Map.fetch!(:hashed_password)
      end

      before = hashed.()

      for _try <- 1..2,
          do: assert(api_change_password(site, ip, token, "not-the-password").status == 403)

      conn = api_change_password(site, ip, token, @password)

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 800..900
      assert get_resp_header(conn, "x-error-code") == ["rate_limited"]

      assert [
               %{
                 "code" => "rate_limited",
                 "title" => "Too many password change attempts",
                 "meta" => %{"action" => "change_password", "limited_by" => "account"}
               }
             ] = Jason.decode!(conn.resp_body)["errors"]

      assert hashed.() == before
    end
  end

  describe "the browser's routes" do
    test "sign-in, the reset request and the magic-link request each answer a third try with a page saying how long to wait",
         %{site: site, ip: ip} do
      email = email!()

      routes = [
        {"/api/auth/user/password/sign_in",
         %{"user" => %{"email" => email, "password" => "not-the-password"}},
         "Too many sign-in attempts"},
        {"/api/auth/user/password/reset_request", %{"user" => %{"email" => email}},
         "Too many password reset requests"},
        {"/api/auth/user/magic_link/request", %{"user" => %{"email" => email}},
         "Too many sign-in link requests"}
      ]

      for {path, params, title} <- routes do
        for _try <- 1..2,
            do: assert(site |> from(ip) |> post(path, params) |> redirected_to() == "/auth", path)

        conn = site |> from(ip) |> post(path, params)

        assert limited?(conn), "#{path} answered #{conn.status}"
        assert [_seconds] = get_resp_header(conn, "retry-after")
        assert get_resp_header(conn, "x-error-code") == ["rate_limited"]
        assert [html | _] = get_resp_header(conn, "content-type")
        assert html =~ "text/html"

        page = LazyHTML.from_document(conn.resp_body)
        assert page |> LazyHTML.query("#auth-rate-limited h1") |> LazyHTML.text() == title
        assert page |> LazyHTML.query("#auth-rate-limited a[href='/auth']") |> Enum.count() == 1
      end
    end

    test "spend the allowance the API spends", %{site: site, ip: ip} do
      email = email!()
      for _try <- 1..2, do: assert(api_sign_in(site, address!(), email).status == 403)

      assert site |> browser_sign_in(ip, email) |> limited?()
    end

    test "never limit the reset itself, whose token is spent once", %{site: site, ip: ip} do
      for _account <- 1..6 do
        params = %{
          "user" => %{
            "reset_token" => site |> user!() |> reset_token!(),
            "password" => "NewPassword123!",
            "password_confirmation" => "NewPassword123!"
          }
        }

        conn = site |> from(ip) |> post("/api/auth/user/password/reset", params)
        assert redirected_to(conn) == "/"
      end
    end
  end

  describe "the sign-in pages" do
    setup %{site: site} do
      seed_auth_pages!(site)
      :ok
    end

    test "says how long to wait on an account's third sign-in, and signs nobody in", %{
      site: site,
      ip: ip
    } do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()
      view = auth_page(site, ip)

      for _try <- 1..2 do
        live_sign_in(view, email)
        refute throttled?(view)
        assert has_element?(view, "#auth-alert", "Invalid email or password")
      end

      assert is_binary(live_sign_in(view, email, @password))
      assert has_element?(view, "#auth-rate-limited", "Too many sign-in attempts")
      assert has_element?(view, "#auth-rate-limited", "Try again in 15 minutes.")
    end

    test "refuses an email's third reset request, keeps the form and mails it nothing", %{
      site: site,
      ip: ip
    } do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()
      mails("Reset your password")

      for _request <- 1..2 do
        view = auth_card(site, ip, "auth-go-forgot")
        view |> form("#auth-reset-form", user: %{email: email}) |> render_submit()
        refute throttled?(view)
      end

      assert mails("Reset your password") == 2

      view = auth_card(site, ip, "auth-go-forgot")
      view |> form("#auth-reset-form", user: %{email: email}) |> render_submit()

      assert has_element?(view, "#auth-rate-limited", "Too many password reset requests")
      assert has_element?(view, "#auth-reset-form")
      assert mails("Reset your password") == 0
    end

    test "refuses an email's third magic link, and mails it nothing", %{site: site, ip: ip} do
      email = site |> user!() |> Map.fetch!(:email) |> to_string()
      mails("Your login link")

      for _request <- 1..2 do
        view = auth_card(site, ip, "auth-go-magic")
        view |> form("#auth-magic-form", user: %{email: email}) |> render_submit()
        refute throttled?(view)
      end

      assert mails("Your login link") == 2

      view = auth_card(site, ip, "auth-go-magic")
      view |> form("#auth-magic-form", user: %{email: email}) |> render_submit()

      assert has_element?(view, "#auth-rate-limited", "Too many sign-in link requests")
      assert has_element?(view, "#auth-magic-form")
      assert mails("Your login link") == 0
    end

    test "spends the same allowance as the API", %{site: site, ip: ip} do
      email = email!()
      view = auth_page(site, ip)

      refute site |> api_sign_in(ip, email) |> limited?()
      live_sign_in(view, email)
      refute throttled?(view)

      assert site |> api_sign_in(ip, email) |> limited?()
      live_sign_in(view, email)
      assert throttled?(view)
    end

    test "counts by the address its socket came from", %{site: site, ip: ip} do
      for _account <- 1..5, do: api_sign_in(site, ip, email!())

      here = auth_page(site, ip)
      live_sign_in(here, email!())
      assert throttled?(here)

      elsewhere = auth_page(site, address!())
      live_sign_in(elsewhere, email!())
      refute throttled?(elsewhere)
    end

    test "is told its peer's address and forwarded headers by the endpoint's /live socket" do
      {"/live", Phoenix.LiveView.Socket, opts} =
        Enum.find(MishkaCmsWeb.Endpoint.__sockets__(), &match?({"/live", _, _}, &1))

      for transport <- [:websocket, :longpoll] do
        assert :peer_data in opts[transport][:connect_info]
        assert :x_headers in opts[transport][:connect_info]
      end
    end
  end

  # Behind proxies every request arrives from one of them. `plug RemoteIp` in the endpoint, the
  # sign-in pages' socket and the browser's routes all read the client from `x-forwarded-for`, right
  # to left, past private addresses and the trusted proxies.
  describe "behind proxies" do
    setup do
      behind(["203.0.113.0/24"])
      {:ok, proxy: address!(), client: written(address!(198))}
    end

    test "the API counts the client a proxy forwarded, not the proxy", %{
      site: site,
      proxy: proxy,
      client: client
    } do
      forwarded = [{"x-forwarded-for", client}]
      for _account <- 1..5, do: api_sign_in(site, proxy, email!(), "x", forwarded)

      assert site |> api_sign_in(proxy, email!(), "x", forwarded) |> limited?()

      another = [{"x-forwarded-for", written(address!(198))}]
      assert api_sign_in(site, proxy, email!(), "x", another).status == 403
    end

    test "a trusted proxy's own entry is passed over, and what a client writes left of its own is not believed",
         %{site: site, proxy: proxy, client: client} do
      for edge <- 1..5 do
        chain = [{"x-forwarded-for", "192.0.2.#{edge}, #{client}, 203.0.113.#{edge}"}]
        api_sign_in(site, proxy, email!(), "x", chain)
      end

      assert site
             |> api_sign_in(proxy, email!(), "x", [{"x-forwarded-for", client}])
             |> limited?()
    end

    test "the browser's routes count the client a proxy forwarded", %{
      site: site,
      proxy: proxy,
      client: client
    } do
      forwarded = [{"x-forwarded-for", client}]
      for _account <- 1..5, do: api_sign_in(site, proxy, email!(), "x", forwarded)

      assert site |> browser_sign_in(proxy, email!(), forwarded) |> limited?()

      another = [{"x-forwarded-for", written(address!(198))}]
      assert site |> browser_sign_in(proxy, email!(), another) |> redirected_to() == "/auth"
    end

    test "the sign-in page counts the client a proxy forwarded", %{
      site: site,
      proxy: proxy,
      client: client
    } do
      seed_auth_pages!(site)
      forwarded = [{"x-forwarded-for", client}]
      for _account <- 1..5, do: api_sign_in(site, proxy, email!(), "x", forwarded)

      here = auth_page(site, proxy, forwarded)
      live_sign_in(here, email!())
      assert throttled?(here)

      elsewhere = auth_page(site, proxy, [{"x-forwarded-for", written(address!(198))}])
      live_sign_in(elsewhere, email!())
      refute throttled?(elsewhere)
    end

    test "a Cloudflare Worker is counted as itself, whatever x-forwarded-for it writes", %{
      site: site,
      proxy: coolify
    } do
      behind(production_config(%{})[:mishka_cms_core][:trusted_proxies])

      worker = fn edge ->
        [{"x-forwarded-for", "#{written(address!(198))}, 2a06:98c0:3600::103, 172.64.0.#{edge}"}]
      end

      for edge <- 1..5, do: api_sign_in(site, coolify, email!(), "x", worker.(edge))

      assert site |> api_sign_in(coolify, email!(), "x", worker.(9)) |> limited?()
    end

    test "a TRUSTED_PROXY_RANGES entry that is no IP or CIDR range stops the boot, naming it" do
      behind(["203.0.113.0/24", "10.0.0.0/8;"])

      assert_raise ArgumentError, ~r{"10\.0\.0\.0/8;"}, fn ->
        MishkaCms.Application.start(:normal, [])
      end
    end

    test "production passes over Cloudflare's addresses unless told which proxies stand in front",
         %{site: site, proxy: coolify, client: visitor} do
      cloudflare = production_config(%{})[:mishka_cms_core][:trusted_proxies]
      assert "172.64.0.0/13" in cloudflare
      assert "2606:4700::/32" in cloudflare
      behind(cloudflare)

      for edge <- 1..5 do
        chain = [{"x-forwarded-for", "#{visitor}, 172.64.0.#{edge}"}]
        api_sign_in(site, coolify, email!(), "x", chain)
      end

      assert site
             |> api_sign_in(coolify, email!(), "x", [
               {"x-forwarded-for", visitor <> ", 172.64.9.9"}
             ])
             |> limited?()

      assert production_config(%{"TRUSTED_PROXY_RANGES" => "198.18.0.0/15, 192.0.2.1"})[
               :mishka_cms_core
             ][:trusted_proxies] == ["198.18.0.0/15", "192.0.2.1"]
    end
  end

  # A site owner's plugin that answers a refused request its own way, and says what it heard. On the
  # API the answer is written by then, so it rewrites it; on a browser route it sends its own.
  defmodule OwnersAnswer do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "auth:request:rate_limited"

    @impl true
    def call(%Plug.Conn{state: :set} = conn, meta) do
      send(self(), {:rate_limited, meta})
      {:reply, Plug.Conn.resp(conn, 429, "The owner's own answer")}
    end

    def call(conn, meta) do
      send(self(), {:rate_limited, meta})
      {:reply, conn |> Plug.Conn.send_resp(429, "The owner's own page") |> Plug.Conn.halt()}
    end
  end

  # A site owner's plugin that sends a refused sign-in page to a help page of its own.
  defmodule OwnersPage do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "auth:live:rate_limited"

    @impl true
    def call(socket, meta),
      do: {:reply, Phoenix.LiveView.redirect(socket, to: "/help?action=#{meta.action}")}
  end

  defp plugin!(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  describe "events" do
    test "a plugin on auth:request:rate_limited hears an API refusal and may rewrite its answer",
         %{
           site: site,
           ip: ip
         } do
      plugin!(OwnersAnswer, "auth:request:rate_limited")
      email = email!()
      for _try <- 1..2, do: api_sign_in(site, ip, email)

      conn = api_sign_in(site, ip, email)

      assert conn.status == 429
      assert conn.resp_body == "The owner's own answer"
      site_id = site.id

      assert_received {:rate_limited,
                       %{
                         action: :sign_in,
                         key: :account,
                         retry_after: seconds,
                         site: %{id: ^site_id}
                       }}

      assert seconds in 800..900
    end

    test "a plugin on auth:request:rate_limited may answer a browser route's refusal instead", %{
      site: site,
      ip: ip
    } do
      plugin!(OwnersAnswer, "auth:request:rate_limited")
      for _account <- 1..5, do: browser_sign_in(site, ip, email!())

      conn = browser_sign_in(site, ip, email!())

      assert conn.resp_body == "The owner's own page"
      assert get_resp_header(conn, "retry-after") == []
      assert_received {:rate_limited, %{action: :sign_in, key: :ip}}
    end

    test "a plugin on auth:live:rate_limited may send the page elsewhere", %{site: site, ip: ip} do
      seed_auth_pages!(site)
      plugin!(OwnersPage, "auth:live:rate_limited")
      email = email!()
      view = auth_page(site, ip)
      for _try <- 1..2, do: live_sign_in(view, email)

      assert {:error, {:redirect, %{to: "/help?action=sign_in"}}} = live_sign_in(view, email)
    end
  end
end
