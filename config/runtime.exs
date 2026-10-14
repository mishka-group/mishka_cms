import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mishka_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mishka_cms, MishkaCmsWeb.Endpoint, server: true
end

# AN HMAC OVER EVERY STORED SNIPPET, so Elixir that did not come through this application does not
# run. Off unless a key is set, which is what lets it be turned on for an existing database.
#
# Read in every environment rather than in the prod block below, because the case it exists for —
# a database restored from somewhere else — is one that happens to a developer's machine and to
# staging far more often than to production. A dump carries the signatures of the environment that
# made it, so on the next boot every handler and every live component's `handle_event/3` in it
# compiles to a clause that does nothing. `MishkaCmsCore.Runtime.PageBuilder.CodeAudit` counts them
# at boot and `mix mishka.resign_code` is the fix.
#
# See `MishkaCmsCore.Runtime.PageBuilder.CodeSignature`.
config :mishka_cms_core, code_signing_key: System.get_env("CODE_SIGNING_KEY")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :mishka_cms, MishkaCms.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # REMOVED PHX_HOST - Multi-tenant apps don't have a single host
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :mishka_cms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mishka_cms, MishkaCmsWeb.Endpoint,
    # URL configuration without host for multi-tenant
    url: [
      scheme: "https",
      port: 443
    ],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    # Dynamic origin checking using ETS-based site lookup
    check_origin: {MishkaCmsCore.Runtime.OriginValidator, :verify_origin?, []},
    # Session configuration for multi-tenant
    session_options: [
      key: "_mishka_cms_key",
      signing_salt: System.get_env("SESSION_SIGNING_SALT") || "default_salt",
      secure: true,
      http_only: true,
      same_site: "Lax"
    ]

  config :mishka_cms_core,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # AUTHOR-WRITTEN ELIXIR, ON OR OFF FOR THE WHOLE DEPLOYMENT.
  #
  # A page, layout, component and error page can each store Elixir — `events`, `infos`, `helpers` —
  # which compiles into the module that serves the site. `PAGE_CODE=off` closes that surface for
  # everybody, master included, in one place, rather than trusting that nobody has been granted
  # `admin:dashboard:code` or `admin:api:code`.
  #
  # It stops code being WRITTEN. It deliberately does not stop code already in the database from
  # compiling: a switch that silently broke every live page carrying a handler would be a worse
  # failure than the one it prevents. To be rid of existing code, remove it from the documents.
  #
  # See `MishkaCmsCore.Runtime.PageBuilder.CodeAccess`.
  config :mishka_cms_core,
    page_code: (System.get_env("PAGE_CODE") == "off" && :off) || :on

  # mishka_installer — persist registered events/plugins (and any installed libraries) across
  # redeploys. Point its store at a MOUNTED VOLUME via MISHKA_DATA_DIR (must be writable by the
  # release user `nobody`). Without it, data falls back to the ephemeral release dir (still works,
  # but is wiped on each redeploy).
  mishka_data = System.get_env("MISHKA_DATA_DIR") || Path.join(File.cwd!(), "mishka_data")

  config :mishka_installer,
    project_path: mishka_data,
    project_env: :prod,
    extensions_path: Path.join(mishka_data, "extensions")

  config :mishka_installer, MishkaInstaller.MnesiaRepo,
    mnesia_dir: Path.join(mishka_data, "mnesia"),
    essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

  # Every uploaded file — media under `uploads/` and `uploads_archived/`, share cards, files sent
  # through a page's form — kept across redeploys. The endpoint serves `/uploads` from this folder.
  uploads_root = Path.join(mishka_data, "static")

  config :mishka_cms_core,
    media_static_dir: uploads_root,
    page_upload_dir: Path.join(uploads_root, "uploads")

  # The CLDR data of each language a site reads, downloaded once and kept across redeploys.
  config :localize, locale_cache_dir: Path.join(mishka_data, "localize")

  # WHO IS ASKING, BEHIND THE REVERSE PROXIES. Every request reaches the CMS from a proxy, so
  # `RemoteIp` reads the visitor from `x-forwarded-for`, right to left, passing over private addresses
  # (Coolify's own network) and these: Cloudflare's, as production runs
  # (https://www.cloudflare.com/ips/), or TRUSTED_PROXY_RANGES, IPs and CIDR ranges separated by
  # commas, for other proxies in front. That is the visitor only while Coolify's proxy trusts
  # Cloudflare's addresses (its entrypoints' `forwardedHeaders.trustedIPs`); otherwise it drops what
  # Cloudflare forwarded and every visitor is counted as Coolify's address. The sign-in limits count
  # per visitor — see `MishkaCmsCore.Accounts.AuthRateLimit.remote_ip_options/0`. An entry that is
  # no IP or CIDR range stops the boot (`MishkaCms.Application`).
  cloudflare =
    "173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18," <>
      "108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17," <>
      "162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22," <>
      "2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32," <>
      "2a06:98c0::/29,2c0f:f248::/32"

  config :mishka_cms_core,
         :trusted_proxies,
         "TRUSTED_PROXY_RANGES"
         |> System.get_env(cloudflare)
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  # ## SSL Support
  #
  # SSL is handled by reverse proxy (Cloudflare/Coolify)
  # force_ssl configuration is in config/prod.exs

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :mishka_cms_core, MishkaCmsCore.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney, Req and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
