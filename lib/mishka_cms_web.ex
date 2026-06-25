defmodule MishkaCmsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use MishkaCmsWeb, :controller
      use MishkaCmsWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: MishkaCmsWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      # EVERY LiveView, not every `live_session`. Several templates render a `<style>` of their own —
      # the editor's canvas, the theme builder's live preview — and `style-src-elem` refuses one
      # without a nonce. Attaching this to the `live_session`s missed the routes declared outside
      # any, which is how `/theme-builder` came back as a 500. Here it reaches all of them, and
      # `assign_new` makes it harmless where a session already supplied the value.
      on_mount MishkaCmsCore.Runtime.CspNonce

      # Same reason, second rule: a live navigation runs no pipeline, so `MaintenanceGate` as a plug
      # only ever sees the first render of a page load. This sees every navigation, every event, and
      # the moment the site's state changes, so a tab left open stops being served at once.
      on_mount MishkaCmsCore.Runtime.SiteAvailability

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: MishkaCmsWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import MishkaCmsWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias MishkaCmsWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MishkaCmsWeb.Endpoint,
        router: MishkaCmsWeb.Router,
        statics: MishkaCmsWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
