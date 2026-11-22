# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  It draws the site's own Error Page for the status. The site is `:current_site`, or, for an error
  raised before `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` ran (a bad CSRF token, an address no
  route matches), the site the request's `Host` header names, read as that plug reads it
  (`MishkaCmsCore.Runtime.OriginValidator.host_name/1`,
  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.site_for/1`), while that site is open and serves
  pages. Its page is then drawn in its first language. The plug's `web:request:before_site_resolve`
  event is not called: a plugin on it may answer the request, which is being answered here.

  ## The plain status message

  The answer is Phoenix's plain message for the status, sent with the status the request had, when
  there is no page to draw or it cannot be drawn.

  | the request's site | in the log |
  |--------------------|------------|
  | has no Error Page, or none with an entry for the status | one warning |
  | has one that does not compile | one warning |
  | has one that raises, exits or throws as it is drawn | one short warning with what it was |
  | has a plugin on one of the first three events that answers something else than its payload | one warning |
  | cannot be read: a process that keeps sites, settings or routes is restarting | one warning |
  | is offline, switched off or API only, before the pipeline named it | nothing |
  | does not exist: no site has the host | nothing |

  The last two are what `SiteLookupPlug` and `MishkaCms.Plugs.MaintenanceGate` answer unlogged on
  any other address, so a scanner cannot fill the log here either.

  The template is the admin's and may fail for one visitor alone, so it is drawn inside the one
  boundary of this module, and what it failed with is kept in
  `MishkaCmsCore.Runtime.States.CompileFailureState` for the status of the Error Page, once for a
  compiled module. A page that draws writes nothing.

  ## Events

    * `ErrorHTML.Render.BeforeRender` - `%{conn: conn, status_code: "404", template: "404.html"}`.
    * `ErrorHTML.Render.BeforeCompile` - `%{path: path, site: site, status_code: "404"}`, the Error
      Page looked for.
    * `ErrorHTML.Render.AfterCompile` - `%{conn: conn, content: content}`, what the page's module
      rendered, drawn once every plugin has had it.
    * `ErrorHTML.Render.CompileError` - `%{error: error, template: template, fallback: message}`
      for every plain message but that of a page with no entry for the status. A plugin may answer
      another `:fallback`. `error` is `:no_error_page`, the reason the page did not compile, what was
      raised, `{:event, name}` for a plugin's answer, `:not_ready`, or why no site answers:
      `:not_found`, `:inactive`, `:offline` or `:api_only`.

  A plugin that raises is logged by `MishkaInstaller.Event.Hook.call/3`, which answers what it was
  handed; one that exits or throws on the first three events ends the request, as on any event of it.

  ## Telemetry

    * `[:mishka_cms, :error_page, :render]` - `%{count: 1}` with `%{status_code: "404", site: name}`.
    * `[:mishka_cms, :error_page, :render, :start | :stop]` - the span of it, with `:path` at the
      start and `:outcome` at the stop: `:drawn`, or why the plain message was answered instead:
      `:no_error_page`, `:not_compiled`, `:not_drawn`, `:event_answer` or `:not_ready`.

  See config/config.exs.
  """
  use MishkaCmsWeb, :html
  require Logger
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, Helpers}
  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorStatus, Languages, Translations}
  alias MishkaCmsCore.Runtime.{OriginValidator, SiteAvailability}
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaInstaller.Event.Hook

  # A process that keeps tables makes and loses them together, so one of each is asked for.
  @sites :mishka_sites_host_index
  @settings :mishka_cms_settings
  @routes :mishka_web_run_time_meta_data

  @plain "fallbacking to default Phoenix error page"

  defguardp is_site(site)
            when is_map(site) and is_binary(site.id) and is_binary(site.name)

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
  def render(<<a, b, c, ?., _format::binary>> = template, %{conn: %Plug.Conn{} = conn})
      when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 do
    case with_site(conn) do
      {:ok, conn} ->
        site_page(conn, template, <<a, b, c>>)

      {:error, reason} ->
        warn(reason, template)
        fallback(reason, template)
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
  # A site closed to its visitors shows none of its own pages, so it gets the default page.
  defp with_site(%Plug.Conn{assigns: %{current_site: site}} = conn) when is_site(site),
    do: {:ok, conn}

  defp with_site(conn) do
    host = conn |> Plug.Conn.get_req_header("host") |> List.first() |> OriginValidator.host_name()

    with :ok <- readable(@sites),
         :ok <- readable(@settings),
         {:ok, site} <- SiteLookupPlug.site_for(host),
         :ok <- open(site) do
      Gettext.put_locale(Languages.primary(site.id))
      conn = Plug.Conn.assign(conn, :current_site, site)
      {:ok, conn}
    end
  end

  defp open(%{active: true, mode: :api_only}), do: {:error, :api_only}

  defp open(%{id: id}) do
    case SiteAvailability.state(id) do
      :open -> :ok
      closed -> {:error, closed}
    end
  end

  # A table is away while the process that keeps it restarts, and a read of it would raise.
  defp readable(table) do
    case :ets.whereis(table) do
      :undefined -> {:error, :not_ready}
      _table -> :ok
    end
  end

  defp site_page(conn, template, status_code) do
    %{name: site} = conn.assigns.current_site
    metadata = %{status_code: status_code, site: site}

    # Emit counter for error page renders
    :telemetry.execute([:mishka_cms, :error_page, :render], %{count: 1}, metadata)

    :telemetry.span(
      [:mishka_cms, :error_page, :render],
      Map.put(metadata, :path, conn.request_path),
      fn ->
        {outcome, content} = answer(conn, template, status_code)
        {content, Map.put(metadata, :outcome, outcome)}
      end
    )
  end

  defp answer(conn, template, status_code) do
    with {:ok, conn} <- before_render(conn, template, status_code),
         {:ok, path, site, code} <- before_compile(conn, status_code),
         {:ok, module} <- error_module(path, site),
         {:ok, content} <- page(module, conn, code) do
      {:drawn, content}
    else
      {:error, reason} ->
        warn(reason, template, conn.assigns.current_site)
        {outcome(reason), reason |> error() |> fallback(template)}
    end
  end

  defp before_render(conn, template, status_code) do
    event = "ErrorHTML.Render.BeforeRender"

    case Hook.call(event, %{conn: conn, status_code: status_code, template: template}) do
      %{conn: %Plug.Conn{assigns: %{current_site: site}} = conn} when is_site(site) -> {:ok, conn}
      _not_its_payload -> {:error, {:event, event}}
    end
  end

  # THE ERROR PAGE RENDERS FOR THE SITE THE VISITOR ASKED, so it draws that site's components
  # and the global ones — see `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` — and `t/1`
  # reads that site's words. An error raised before any page named the site, a draft
  # preview's unknown token among them, would otherwise draw none of the site's own.
  defp before_compile(conn, status_code) do
    event = "ErrorHTML.Render.BeforeCompile"
    site = conn.assigns.current_site
    :ok = Translations.put_site(site.id)

    with %{path: path, site: site, status_code: status_code}
         when is_binary(path) and is_site(site) and is_binary(status_code) <-
           Hook.call(event, %{
             path: ErrorAddress.path(site.name),
             site: site,
             status_code: status_code
           }),
         {code, ""} <- Integer.parse(status_code) do
      {:ok, path, site, code}
    else
      _not_its_payload -> {:error, {:event, event}}
    end
  end

  # What the page raised is kept for the status of the Error Page
  # (`MishkaCmsCore.Runtime.RuntimeStatus`) the first time, until its module is compiled again.
  defp page(module, conn, code) do
    with {:ok, page_data} <- attempt(&module.__error_information__/0),
         {:error, {:drawing, kind, error}} = failed <- draw(module, conn, page_data, code) do
      keep(module, page_data, code, {kind, error})
      failed
    end
  end

  defp draw(module, conn, page_data, code) do
    conn =
      conn
      |> Plug.Conn.assign(:page_module, module)
      |> Plug.Conn.assign(:page_data, page_data)

    with {:ok, content} <- attempt(fn -> module.render(conn, code) end),
         {:ok, content} <- after_compile(conn, content) do
      attempt(fn -> html(content) end)
    end
  end

  defp after_compile(conn, content) do
    event = "ErrorHTML.Render.AfterCompile"

    case Hook.call(event, %{conn: conn, content: content}) do
      %{content: content} -> {:ok, content}
      _not_its_payload -> {:error, {:event, event}}
    end
  end

  # The one boundary here: what runs in it is the admin's template, or the plugin with the last answer,
  # and after either nothing else answers. `catch`, as a component's call to a process exits: Bandit
  # sends an empty 500 for an exit.
  defp attempt(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      {:error, {:drawing, kind, Exception.normalize(kind, reason, __STACKTRACE__)}}
  end

  # Drawn here, where a raise still has a plain message to answer with: Phoenix draws what
  # `render/2` answers after it has returned. Text is left to Phoenix, which escapes it.
  defp html(content) when is_binary(content), do: content
  defp html(content), do: {:safe, Phoenix.HTML.Engine.encode_to_iodata!(content)}

  # Once for a module: not for each request that fails, and not for the module compiled since.
  defp keep(module, page_data, code, failure) do
    if not CompileFailureState.failed?({module, code}) and
         function_exported?(module, :__error_information__, 0) and
         module.__error_information__() == page_data,
       do: CompileFailureState.record({module, code}, :binary.copy(cause(failure)))
  end

  defp fallback(error, template) do
    message = status_message(template)

    case attempt(fn -> plugin_fallback(error, template, message) end) do
      {:ok, fallback} ->
        fallback

      {:error, reason} ->
        warn(reason, template)
        message
    end
  end

  defp plugin_fallback(error, template, message) do
    data = %{error: error, template: template, fallback: message}

    case Hook.call("ErrorHTML.Render.CompileError", data) do
      %{fallback: fallback} -> html(fallback)
      _not_its_payload -> message
    end
  end

  defp error({:drawing, _kind, error}), do: error
  defp error({:compile, reason}), do: reason
  defp error(reason), do: reason

  defp outcome({:drawing, _kind, _error}), do: :not_drawn
  defp outcome({:compile, _reason}), do: :not_compiled
  defp outcome({:event, _event}), do: :event_answer
  defp outcome(reason), do: reason

  defp warn(:not_ready, template),
    do:
      Logger.warning("the sites are not loaded to draw an error page for #{template}, #{@plain}")

  defp warn({:drawing, kind, error}, template) do
    Logger.warning(
      "failed to render error page for #{template}, #{@plain}: #{cause({kind, error})}"
    )
  end

  defp warn(_closed_or_no_site, _template), do: :ok

  defp warn({:compile, _reason}, template, site) do
    Logger.warning(
      "the error page of site #{site.name} for #{template} does not compile, #{@plain}"
    )
  end

  defp warn(:no_error_page, template, site),
    do: Logger.warning("site #{site.name} has no error page for #{template}, #{@plain}")

  defp warn({:event, event}, template, _site) do
    Logger.warning(
      "a plugin on #{event} did not answer its payload for the error page of #{template}, #{@plain}"
    )
  end

  defp warn(reason, template, _site), do: warn(reason, template)

  # One short line that holds nothing of the request: a `KeyError`'s message is every assign of the
  # conn, a `MatchError`'s is the value, and an exit's is what the process was called with. An error of
  # an Erlang function says which argument it was below its first line, which is the same for all.
  defp cause({:error, %KeyError{key: key, message: nil}}),
    do: short("** (KeyError) key #{inspect(key)} not found")

  defp cause({:error, %ArgumentError{message: "errors were found at" <> _rest = message}}) do
    message |> String.split() |> Enum.join(" ") |> then(&short("** (ArgumentError) #{&1}"))
  end

  defp cause({:error, %error{message: message}}) when is_binary(message),
    do: short("** (#{inspect(error)}) #{message}")

  defp cause({:error, %error{} = exception})
       when error in [UndefinedFunctionError, FunctionClauseError],
       do: short("** (#{inspect(error)}) #{Exception.message(exception)}")

  defp cause({:error, %error{}}), do: "** (#{inspect(error)})"

  defp cause({kind, {reason, {module, function, args}}})
       when is_atom(reason) and is_atom(module) and is_atom(function) and is_list(args),
       do: "** (#{kind}) #{reason} in #{Exception.format_mfa(module, function, length(args))}"

  defp cause({kind, reason}) when is_atom(reason), do: "** (#{kind}) #{inspect(reason)}"
  defp cause({kind, _value}), do: "** (#{kind})"

  defp short(text) do
    [line | _rest] = String.split(text, "\n", parts: 2)

    for <<char::utf8 <- String.slice(line, 0, 200)>>,
        char > 31 and char not in 127..159 and char not in [0x2028, 0x2029],
        into: "",
        do: <<char::utf8>>
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
  the entry raised as it was drawn, at compile time or for this visitor, `:not_ready` while the
  process that keeps the routes is restarting.

  The Error Page is found in `WebRunTimeMetaDataState` and its module is compiled once, as for a
  404, so after the first request this reads ETS only. The template is handed `@status` as
  `:offline` and `@conn` as it is, so set the conn's status first.
  """
  @spec offline_page(Plug.Conn.t()) :: {:ok, iodata()} | {:error, term()}
  def offline_page(%Plug.Conn{assigns: %{current_site: site}} = conn) when is_site(site) do
    path = ErrorAddress.path(site.name)

    with {:ok, module} <- error_module(path, site),
         :ok <- offline_entry(module),
         {:error, {:drawing, kind, error}} <- draw_offline(module, conn) do
      Logger.warning(
        "failed to render the offline page of site #{site.name}, fallbacking to the built-in page: #{cause({kind, error})}"
      )

      {:error, {:render, error}}
    end
  end

  def offline_page(_conn), do: {:error, :no_error_page}

  # An entry that raises for everyone is known from the compile (`offline_entry/1`). One visitor it
  # raises for alone, or one who asks while a new module is loaded and not yet drawn, gets the built-in
  # page.
  defp draw_offline(module, conn),
    do: attempt(fn -> ErrorCompiler.render_page(module, conn, ErrorStatus.offline()) end)

  # Its address is a literal one, so a path no row is stored at is not matched against the site's
  # patterns.
  defp error_module(path, site) do
    with :ok <- readable(@routes),
         true <- WebRunTimeMetaDataState.path_exists?(path, site.name),
         {:ok, %{section: "ErrorPage"} = entry} <-
           WebRunTimeMetaDataState.find_by_path_and_site(path, site.name) do
      entry.id
      |> Helpers.module_name(entry.site, "ErrorPage")
      |> compiled(path, site)
    else
      {:error, :not_ready} -> {:error, :not_ready}
      _no_error_page -> {:error, :no_error_page}
    end
  end

  defp compiled(module, path, site) do
    case Helpers.loaded?(module) ||
           ModuleCompilerHandler.compile_or_return_module(module, path, site.name, site.id) do
      {:error, reason} -> {:error, {:compile, reason}}
      _loaded -> {:ok, module}
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
