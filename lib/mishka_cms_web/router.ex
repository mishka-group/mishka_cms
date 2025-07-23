defmodule MishkaCmsWeb.Router do
  use MishkaCmsWeb, :router

  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]
  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  alias MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug

  # Html alone, but for a route that names what else it answers — robots.txt, sitemap.xml and the
  # sitemap-00001.xml.gz… files beside it.
  pipeline :browser do
    plug :route_accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaCmsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
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

  # Needs [] permissions
  scope "/", MishkaCmsWeb do
    pipe_through :browser

    extension_routes(:public)

    live_session :authenticated_routes do
      live "/*path", RuntimeLive
    end
  end
end
