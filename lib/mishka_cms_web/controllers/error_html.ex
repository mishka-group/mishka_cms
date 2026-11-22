# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  It draws the site's own Error Page for the status. The site is `:current_site`, or, for an error
  raised before `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` ran (a bad CSRF token, an address no
  route matches), the active site the request's host names, found by
  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.site_for/1` from ETS. A site with no Error Page gets
  Phoenix's plain status message and one warning in the log; a host that names no active site gets
  the message alone.

  See config/config.exs.
  """
  use MishkaCmsWeb, :html
  require Logger
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, Helpers}
  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorStatus, Translations}
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaInstaller.Event.Hook

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/mishka_cms_web/controllers/error_html/404.html.heex
  #   * lib/mishka_cms_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################
  def render(<<status_code::binary-size(3), _rest::binary>> = template, %{conn: conn} = _assigns) do
    case with_site(conn) do
      {:ok, conn} -> site_page(conn, template, status_code)
      :error -> status_message(template)
    end
  end

  def render(template, _assigns) do
    Logger.warning(
      "could not find an error page for #{template}, fallbacking to default Phoenix error page"
    )

    status_message(template)
  end

  # An error raised before `SiteLookupPlug` ran, such as a bad CSRF token or an address no route
  # matches, has no `:current_site`, so the site is found from the host the way the plug finds it.
  # A switched-off site's own pages are not served, so it gets the default page.
  defp with_site(%Plug.Conn{assigns: %{current_site: %{name: _name}}} = conn), do: {:ok, conn}

  defp with_site(conn) do
    case SiteLookupPlug.site_for(conn.host) do
      {:ok, %{active: true} = site} -> {:ok, Plug.Conn.assign(conn, :current_site, site)}
      _no_site -> :error
    end
  end

  defp site_page(conn, template, status_code) do
    # Emit counter for error page renders
    :telemetry.execute(
      [:mishka_cms, :error_page, :render],
      %{count: 1},
      %{status_code: status_code, site: conn.assigns.current_site.name}
    )

    :telemetry.span(
      [:mishka_cms, :error_page, :render],
      %{
        status_code: status_code,
        path: conn.request_path,
        site: conn.assigns.current_site.name
      },
      fn ->
        conn =
          %{conn: conn, status_code: status_code, template: template}
          |> then(&Hook.call("ErrorHTML.Render.BeforeRender", &1))
          |> Map.get(:conn)

        site = conn.assigns.current_site

        # THE ERROR PAGE RENDERS FOR THE SITE THE VISITOR ASKED, so it draws that site's components
        # and the global ones — see `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` — and `t/1`
        # reads that site's words. An error raised before any page named the site, a draft
        # preview's unknown token among them, would otherwise draw none of the site's own.
        :ok = Translations.put_site(site.id)
        error_path = MishkaCmsCore.Runtime.ErrorAddress.path(site.name)

        error_data =
          %{path: error_path, site: site, status_code: status_code}
          |> then(&Hook.call("ErrorHTML.Render.BeforeCompile", &1))

        result =
          case error_module(error_data.path, error_data.site) do
            {:ok, page_module} ->
              conn
              |> Plug.Conn.assign(:page_module, page_module)
              |> Plug.Conn.assign(:page_data, page_module.__error_information__())
              |> then(
                &%{
                  conn: &1,
                  content: page_module.render(&1, String.to_integer(error_data.status_code))
                }
              )
              |> then(&Hook.call("ErrorHTML.Render.AfterCompile", &1))
              |> Map.get(:content)

            {:error, {:compile, reason}} ->
              fallback(reason, template)

            {:error, :no_error_page} ->
              Logger.warning(
                "site #{error_data.site.name} has no error page for #{template}, fallbacking to default Phoenix error page"
              )

              fallback(:no_error_page, template)
          end

        {result, %{}}
      end
    )
  rescue
    error ->
      # Error text is from Beacon project
      Logger.warning("""
      failed to render error page for #{template}, fallbacking to default Phoenix error page

      Got:

      #{inspect(error)}
      """)

      fallback(error, template)
  end

  defp fallback(error, template) do
    %{error: error, template: template, fallback: status_message(template)}
    |> then(&Hook.call("ErrorHTML.Render.CompileError", &1))
    |> Map.get(:fallback)
  end

  # One clause per status: each message is a literal `gettext/1`, which `mix gettext.extract` reads.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp status_message(template) do
    case template |> String.split(".", parts: 2) |> hd() do
      "400" -> gettext("Bad Request")
      "401" -> gettext("Unauthorized")
      "403" -> gettext("Forbidden")
      "404" -> gettext("Not Found")
      "405" -> gettext("Method Not Allowed")
      "406" -> gettext("Not Acceptable")
      "408" -> gettext("Request Timeout")
      "409" -> gettext("Conflict")
      "410" -> gettext("Gone")
      "413" -> gettext("Request Entity Too Large")
      "415" -> gettext("Unsupported Media Type")
      "422" -> gettext("Unprocessable Content")
      "429" -> gettext("Too Many Requests")
      "500" -> gettext("Internal Server Error")
      "501" -> gettext("Not Implemented")
      "502" -> gettext("Bad Gateway")
      "503" -> gettext("Service Unavailable")
      "504" -> gettext("Gateway Timeout")
      _other -> other_status_message(template)
    end
  end

  defp other_status_message(template) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> then(&Gettext.gettext(MishkaCmsWeb.Gettext, &1))
  end

  @doc """
  The site's own offline page, the `:offline` entry of its Error Page, as HTML.

  `MishkaCms.Plugs.MaintenanceGate` answers an offline site with it, and with its built-in page on
  `{:error, reason}`: `:no_error_page` when the site has none, `:no_offline_entry` when its Error
  Page does not hold one, `{:compile, reason}` when it does not compile, `{:render, reason}` when
  the entry raised as it was drawn at compile time.

  The Error Page is found in `WebRunTimeMetaDataState` and its module is compiled once, as for a
  404, so after the first request this reads ETS only. The template is handed `@status` as
  `:offline` and `@conn` as it is, so set the conn's status first.
  """
  @spec offline_page(Plug.Conn.t()) :: {:ok, iodata()} | {:error, term()}
  def offline_page(%Plug.Conn{assigns: %{current_site: %{name: name} = site}} = conn)
      when is_binary(name) do
    path = ErrorAddress.path(name)

    with {:ok, module} <- error_module(path, site),
         :ok <- offline_entry(module) do
      {:ok, ErrorCompiler.render_page(module, conn, ErrorStatus.offline())}
    end
  end

  def offline_page(_conn), do: {:error, :no_error_page}

  defp error_module(path, site) do
    case WebRunTimeMetaDataState.find_by_path_and_site(path, site.name) do
      {:ok, %{section: "ErrorPage"} = entry} ->
        module = Helpers.module_name(entry.id, entry.site, "ErrorPage")

        case ModuleCompilerHandler.compile_or_return_module(module, path, site.name, site.id) do
          {:ok, _compiled} -> {:ok, module}
          {:error, reason} -> {:error, {:compile, reason}}
        end

      _no_error_page ->
        {:error, :no_error_page}
    end
  end

  # `ModuleCompilerHandler` draws the entry once when it compiles the module, and keeps a raise
  # under `{module, :offline}`.
  defp offline_entry(module) do
    if ErrorCompiler.offline_entry?(module),
      do: drawn(CompileFailureState.reason({module, :offline})),
      else: {:error, :no_offline_entry}
  end

  defp drawn(nil), do: :ok
  defp drawn(reason), do: {:error, {:render, reason}}
end
