defmodule MishkaCmsWeb.Router do
  use MishkaCmsWeb, :router

  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]

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

  # Needs [] permissions
  scope "/", MishkaCmsWeb do
    pipe_through :browser

    extension_routes(:public)

    live_session :authenticated_routes do
      live "/*path", RuntimeLive
    end
  end
end
