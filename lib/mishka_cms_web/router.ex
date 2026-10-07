defmodule MishkaCmsWeb.Router do
  use MishkaCmsWeb, :router

  import Oban.Web.Router
  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]
  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.{AdminSurfacePlug, LanguagePlug}

  # Html alone, but for a route that names what else it answers — robots.txt, sitemap.xml and the
  # sitemap-00001.xml.gz… files beside it.
  pipeline :browser do
    plug :route_accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaCmsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    plug MishkaCms.Plugs.InstallGate
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
    plug MishkaCms.Plugs.MaintenanceGate

    plug LanguagePlug,
      router: __MODULE__,
      live_view: MishkaCmsWeb.RuntimeLive
  end

  # Like :browser but without SiteLookupPlug — a fresh deploy has no site to resolve, so the
  # host-not-found 503 must not shadow the installer. InstallGate keeps it reachable only while
  # the CMS is uninstalled (404 afterwards).
  pipeline :installer do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaCmsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    plug MishkaCms.Plugs.InstallGate
    plug :forget_site
  end

  pipeline :oban_admin do
    plug :require_oban_admin
  end

  # The tenant lookup refuses a switched-off site before anybody is known; the availability plug
  # closes an offline one to all but its admins and the masters, once the bearer token has named the
  # caller, and keeps the sign-in routes open so an admin can get a token. Signing in and the reset
  # request are limited per address and per account by their actions; the rate-limit plug hands
  # them the address and gives a refusal its headers, after CORS so a frontend can read them. Every
  # request is the API's, so a resource policy asking for an area asks for its `admin:api:` name.
  pipeline :api do
    plug :accepts, ["json"]
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
    plug MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
    plug AdminSurfacePlug, surface: :api
    plug MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug, api: :json_api
  end

  # Gate for the two schema-introspection UIs: any API admin, someone holding anything under
  # `admin:api`. The bearer token is already resolved into an actor by the `:api` / `:graphql`
  # pipelines that run first.
  pipeline :api_docs do
    plug MishkaCmsWeb.Runtime.Plugs.RequirePermission,
      permissions: [{:under, "admin:api"}],
      on_denied: :json
  end

  # The `:api` pipeline with GraphQL's answers: a /gql request runs with the tenant of its host's
  # site, as the API, answers only the origins that site allows, and is refused while the site is
  # switched off or offline to its caller. The surface is named before `AshGraphql.Plug`, which
  # copies the context as it stands. The `/ws/gql` socket asks the same on connect — see
  # `MishkaCmsWeb.GraphqlSocket`.
  pipeline :graphql do
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
    plug AdminSurfacePlug, surface: :api
    plug MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug, api: :graphql
    plug AshGraphql.Plug
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:mishka_cms, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    # LiveDashboard has no auth of its own — full node/ETS/process introspection to anyone who can
    # reach it. That is acceptable only because of the `if` below: it does not exist outside dev.
    # Mounting it in any other environment requires the `:oban_admin` pipeline in the same change.
    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MishkaCmsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Oban Web has no per-tenant scoping, so it is open only to a master who is a full dashboard admin
  # (`MishkaCmsCore.Accounts.Helper.oban_admin?/1`), in every environment.
  scope "/" do
    pipe_through [:browser, :oban_admin]

    oban_dashboard("/oban")
  end

  # The interactive spec browser is separated from the API itself: it publishes every route, filter
  # and field of every resource, so it is gated on an API permission while `/api/json/*` stays open to
  # any bearer token (the resource policies are what authorize each call).
  scope "/api/json" do
    pipe_through [:api, :api_docs]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    # The SPEC, not just the browser for it. SwaggerUI is a client-side shell that fetches this URL,
    # so gating the shell alone changed nothing a `curl` could not walk around. It is mounted here
    # instead of being left to AshJsonApiRouter because that router answers under `:api` alone.
    forward "/open_api", AshJsonApi.Controllers.OpenApi,
      domains: MishkaCmsWeb.AshJsonApiRouter.domains(),
      modify_open_api: {MishkaCmsWeb.AshJsonApiRouter, :modify_open_api_spec, []}
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/", MishkaCmsWeb.AshJsonApiRouter
  end

  # Same reasoning as `/api/json/swaggerui`: GraphiQL is schema introspection, not the API.
  scope "/gql" do
    pipe_through [:graphql, :api_docs]

    forward "/playground", Absinthe.Plug.GraphiQL,
      schema: Module.concat(["MishkaCmsWeb.GraphqlSchema"]),
      socket: Module.concat(["MishkaCmsWeb.GraphqlSocket"]),
      interface: :simple
  end

  scope "/gql" do
    pipe_through [:graphql]

    forward "/", Absinthe.Plug, schema: Module.concat(["MishkaCmsWeb.GraphqlSchema"])
  end

  # THE DOOR: anyone holding anything under `admin:dashboard`. Each page then asks for its own area
  # (`MishkaCmsCore.Sidebar.PageGuard`); an API admin holds nothing here and is sent to the site root.
  scope "/admin/dashboard", MishkaCmsWeb.Admin do
    pipe_through [:browser]

    ash_authentication_live_session :authenticated_admin_routes,
      session: [{MishkaCmsCore.Runtime.CspNonce, :session, []}],
      on_mount: [
        {MishkaCmsCore.LiveUserAuth, :live_user_required},
        {MishkaCmsCore.LiveUserAuth, {:require_permission, [{:under, "admin:dashboard"}]}}
      ] do
      # Extension routes (compile-time, alias: false prevents MishkaCmsWeb.Admin prefix)
      extension_routes(:admin)
    end

    # A SECOND SESSION, SO ENTERING THESE PAGES IS A FRESH DOCUMENT. Same pipeline, same guards, same
    # hooks — the only thing this boundary buys is that LiveView will not live-navigate across it,
    # and a full page load is the one thing that re-renders the root layout.
    #
    # `root.html.heex` decides what goes in `<head>` from the LiveView's own assigns, and a live
    # navigation never re-renders it: the destination runs inside the document the source built. The
    # page builder is the one place where that matters, because it is the only admin page whose head
    # is not the admin's usual head — it carries the in-browser Tailwind JIT and, above it, the shim
    # that marks every `<style>` those libraries create with the CSP nonce.
    #
    # Reached by `<.link navigate={…}>` from a list page, the builder therefore ran inside the LIST's
    # document: no JIT, and no shim, so CodeMirror's own stylesheet was refused by `style-src-elem`
    # and the code drawer opened onto an unstyled column of text. Reloading fixed it, because that is
    # a dead render. Ten links led there and four more lead from one document to another INSIDE the
    # builder, where live navigation is right and fast — a rule nobody can be expected to apply by
    # hand at each `<.link>`, so the router applies it instead.
    #
    # It works in the other direction too: leaving the builder now sheds the JIT and the patched
    # `document.createElement` rather than carrying them onto every admin page for the rest of the
    # tab's life.
    ash_authentication_live_session :authenticated_admin_standalone_routes,
      session: [{MishkaCmsCore.Runtime.CspNonce, :session, []}],
      on_mount: [
        {MishkaCmsCore.LiveUserAuth, :live_user_required},
        {MishkaCmsCore.LiveUserAuth, {:require_permission, [{:under, "admin:dashboard"}]}}
      ] do
      extension_routes(:admin_standalone)
    end
  end

  # The visual editor is the native LiveView one, declared by `MishkaCmsCoreWeb.Routes` inside the
  # admin `live_session` above. Nothing is routed here any more: the Inertia `template_creator` GETs
  # matched the same paths and were shadowed the moment those LiveView routes landed, and
  # `POST /render` was the React editor's server-render endpoint — an ungated `Code.eval_quoted/3`
  # over client-supplied JSON, which the new canvas has no use for because it renders by calling
  # already-compiled modules.

  # First-run installer — reachable only while uninstalled (InstallGate 404s it afterwards).
  # Declared before the `/*path` catch-all below so it wins the match.
  scope "/install", MishkaCmsWeb do
    pipe_through :installer

    live_session :install, session: {MishkaCmsCore.Runtime.CspNonce, :session, []} do
      live "/", InstallLive
    end
  end

  # Needs [] permissions
  scope "/", MishkaCmsWeb do
    pipe_through :browser

    extension_routes(:public)

    # Shareable runtime preview — token-gated, must precede the `/*path` catch-all below. Served as
    # a real LiveView (full lifecycle: per-site JS bundle + hooks) with its own temporary CSS bundle.
    get "/_preview/:resource/:token/css", DraftPreviewController, :css

    live_session :draft_preview,
      root_layout: {MishkaCmsWeb.Layouts, :preview},
      session: {MishkaCmsCore.Runtime.CspNonce, :session, []} do
      live "/_preview/:resource/:token", DraftPreviewLive
    end

    # `alias: false` — the /auth surface lives in `mishka_cms_core`, so these must NOT pick up this
    # scope's `MishkaCmsWeb` alias.
    #
    # The sign-in pages themselves are each site's runtime pages at `/<language>/auth…`, answered
    # by `RuntimeLive` below; `/auth…` reaches them through `LanguagePlug`'s redirect. The sign-out
    # page's form posts its DELETE here.
    scope "/", alias: false do
      auth_routes MishkaCmsCoreWeb.AuthController, MishkaCmsCore.Accounts.User, path: "/api/auth"

      delete "/auth/sign-out", MishkaCmsCoreWeb.AuthController, :sign_out, as: :auth
    end

    # THE SESSION AshAuthentication WOULD GENERATE, WITHOUT THE HOOK THAT SPENDS IT.
    # `ash_authentication_live_session` adds `AshAuthentication.Phoenix.LiveSession`'s own
    # `on_mount`, which verifies the token and loads the user before any of these pages has even
    # been resolved — two queries per mount and per live navigation, on every brochure page that
    # never mentions a visitor. The `:session` below is the one that macro would have built, so the
    # token still travels; `MishkaCmsCore.LiveUserAuth.load_current_user/1` makes exactly the same
    # checks, at the moment `MishkaCmsWeb.RuntimeLive` finds a page that needs a user.
    live_session :authenticated_routes,
      session: {__MODULE__, :runtime_session, []},
      on_mount: {MishkaCmsCore.LiveUserAuth, :live_user_lazy} do
      live "/*path", RuntimeLive
    end
  end

  # Helpers

  @doc """
  The session a runtime page's socket is opened with: the one `AshAuthentication` would have built,
  plus the language the response is being answered in and its CSP nonce — see
  `MishkaCmsCore.Runtime.CspNonce.session/1`.

  A page whose own address names a language reads it out of the address. A page at `/no-lang`, and
  every hand-written page under `mish-`, has no address to read — this is how their socket learns
  which language the visitor is in, and it is the same value
  `MishkaCmsCore.Runtime.Plugs.LanguagePlug` put in the session and in Gettext.
  """
  @spec runtime_session(Plug.Conn.t()) :: map()
  def runtime_session(conn) do
    conn
    |> AshAuthentication.Phoenix.LiveSession.generate_session(nil, [])
    |> Map.put(Languages.session(), LanguagePlug.spoken(conn))
    |> Map.merge(MishkaCmsCore.Runtime.CspNonce.session(conn))
  end

  # Only runs before the CMS is installed: afterwards `/install` is a 404. There is no site yet, but
  # a browser that visited before (a database reset, say) still has its old site in the cookie.
  # Forget it, or the site check every LiveView runs (`SiteAvailability`) finds that site missing,
  # treats it as closed and sends `/install` back to `/install` forever.
  defp forget_site(conn, _opts), do: delete_session(conn, :current_site)

  # 404 (not redirect) so the route isn't discoverable.
  defp require_oban_admin(conn, _opts) do
    if Helper.oban_admin?(conn.assigns[:current_user]),
      do: conn,
      else: conn |> send_resp(404, "Not found") |> halt()
  end
end
