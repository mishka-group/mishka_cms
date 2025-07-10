defmodule MishkaCmsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use MishkaCmsWeb, :html
  require Logger
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Translations
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

        page_module =
          "#{error_data.path}"
          |> WebRunTimeMetaDataState.find_by_path_and_site!(error_data.site.name, "ErrorPage")
          |> then(&Helpers.module_name(&1.id, &1.site, "ErrorPage"))

        result =
          ModuleCompilerHandler.compile_or_return_module(
            page_module,
            error_data.path,
            error_data.site.name,
            error_data.site.id
          )
          |> case do
            {:ok, _result} ->
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

            {:error, reason} ->
              %{
                error: reason,
                template: template,
                fallback: status_message(template)
              }
              |> then(&Hook.call("ErrorHTML.Render.CompileError", &1))
              |> Map.get(:fallback)
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

      %{
        error: error,
        template: template,
        fallback: status_message(template)
      }
      |> then(&Hook.call("ErrorHTML.Render.CompileError", &1))
      |> Map.get(:fallback)
  end

  def render(template, _assigns) do
    Logger.warning(
      "could not find an error page for #{template}, fallbacking to default Phoenix error page"
    )

    status_message(template)
  end

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
end
