defmodule MishkaCmsWeb.RuntimeLive do
  @moduledoc """
  A Phoenix LiveView module that handles runtime rendering of dynamically compiled CMS pages.

  This module serves as the main LiveView controller for the MishkaCMS runtime system, responsible for
  dynamically compiling and rendering pages, layouts, and components based on database metadata. It manages
  the complete lifecycle of runtime page rendering including path resolution, module compilation, security
  validation, and error handling. The module supports multi-site configurations and provides fallback
  mechanisms for layout rendering failures.
  """
  use MishkaCmsWeb, :live_view
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.Plugs.LanguagePlug
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaInstaller.Event.Hook

  require Logger

  def mount(%{"path" => path} = params, %{"current_site" => site} = session, socket) do
    socket =
      socket
      |> speaking(session[Languages.session()], site.id)

    case language_target(socket, path, site) do
      {:redirect, to} ->
        {:ok, push_navigate(socket, to: to <> query_of_params(params))}

      {:serve, _language} ->
        :telemetry.span(
          [:mishka_cms, :runtime, :mount],
          %{path: Enum.join(path, "/"), site: site.name},
          fn ->
            _ =
              Hook.call("RuntimeLive.OnMount.BeforeMount", [params, session, socket],
                return: false
              )

            socket =
              if connected?(socket) do
                Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "site:#{site.name}:assets")
                socket
              else
                socket
              end

            joined_path =
              %{path: path, site: site}
              |> then(&Hook.call("RuntimeLive.OnMount.BeforePathTransform", &1).path)
              |> Enum.join("/")
              |> then(fn path ->
                if String.starts_with?(path, "/"), do: path, else: "/" <> path
              end)

            {found, captured} =
              WebRunTimeMetaDataState.resolve!("#{joined_path}", site.name, "Page")

            page_module = Helpers.module_name(found.id, found.site, "Page")

            new_socket =
              :telemetry.span(
                [:mishka_cms, :runtime, :compile],
                %{path: joined_path, site: site.name, module: inspect(page_module)},
                fn ->
                  compile_result =
                    page_module
                    |> ModuleCompilerHandler.compile_or_return_module(
                      found.path,
                      site.name,
                      site.id
                    )
                    |> then(&Hook.call("RuntimeLive.OnMount.AclAfterCompile", &1))
                    |> case do
                      {:ok, _result} ->
                        new_socket =
                          socket
                          |> assign(page_module: page_module)
                          |> assign(page_module.__page_information__())
                          |> assign_page_title()
                          |> assign(current_site: site)
                          |> assign(:query_params, query_params(params, captured))
                          |> MishkaCmsCore.Runtime.PageUpload.allow(page_module)

                        Hook.call("RuntimeLive.OnMount.AfterCompile", new_socket)

                      {:error, reason} ->
                        _ =
                          Hook.call("RuntimeLive.OnMount.AfterCompileError", reason,
                            return: false
                          )

                        :telemetry.execute(
                          [:mishka_cms, :runtime, :mount, :error],
                          %{count: 1},
                          %{error_reason: inspect(reason), path: joined_path, site: site.name}
                        )

                        raise MishkaCmsCore.ErrorsExceptions.ServerError,
                          message: "Sorry, unexpected error occurred. please try again later."
                    end

                  {compile_result, %{}}
                end
              )

            # A DATABASE PAGE, so it takes the site's compiled bundle. Everything else public on this host
            # is a marketing LiveView whose classes are known at build time and served by `public.css` —
            # see the root layout. Marking the one runtime surface is cheaper and safer than annotating
            # the other 44.
            new_socket = Phoenix.Component.assign(new_socket, :runtime_page, true)

            final_result =
              {:ok, new_socket, layout: {MishkaCmsWeb.Layouts, :runtime}}
              |> then(&Hook.call("RuntimeLive.OnMount.Return", &1))

            {final_result, %{}}
          end
        )
    end
  end

  def render(assigns) do
    %{
      page_module: page_module,
      page: %{path: path},
      private: %{site: site, site_id: site_id}
    } = Hook.call("RuntimeLive.OnRender.BeforeRender", assigns)

    :telemetry.span(
      [:mishka_cms, :runtime, :render],
      %{path: path, site: site},
      fn ->
        result =
          ModuleCompilerHandler.compile_or_return_module(page_module, path, site, site_id)
          |> case do
            {:ok, _result} ->
              # From beacon code to prevent overwritting site and avoid rendering a leaked page
              %{private: %{site: ^site, page_module: ^page_module}} =
                page_module.__page_information__()

              Hook.call("RuntimeLive.OnRender.AfterCompile", page_module.render(assigns))

            {:error, reason} ->
              _ = Hook.call("RuntimeLive.OnRender.AfterCompileError", reason, return: false)

              :telemetry.execute(
                [:mishka_cms, :runtime, :render, :error],
                %{count: 1},
                %{error_reason: inspect(reason), path: path, site: site}
              )

              raise MishkaCmsCore.ErrorsExceptions.ServerError,
                message: "Sorry, unexpected error occurred. please try again later."
          end

        {result, %{}}
      end
    )
  end

  def handle_params(%{"path" => path} = params, url, socket) do
    case language_target(socket, path, socket.assigns.current_site) do
      {:redirect, to} ->
        {:noreply, push_navigate(socket, to: to <> query_of(url))}

      {:serve, _language} ->
        :telemetry.span(
          [:mishka_cms, :runtime, :handle_params],
          %{path: Enum.join(path, "/"), site: socket.assigns.current_site.name},
          fn ->
            _ =
              Hook.call("RuntimeLive.HandleParams.BeforeParams", [params, url, socket],
                return: false
              )

            current_site = socket.assigns.current_site

            joined_path =
              %{path: path, site: current_site}
              |> then(&Hook.call("RuntimeLive.HandleParams.BeforePathTransform", &1).path)
              |> Enum.join("/")
              |> then(fn path ->
                if String.starts_with?(path, "/"), do: path, else: "/" <> path
              end)

            # if you use patch for navigate it shows pervious data not for this page if they are in same layout
            %{private: %{site: site_name, site_id: site_id, host: expected_host}} = socket.assigns

            uri = URI.parse(url)

            if uri.host && uri.host != expected_host,
              do:
                raise(MishkaCmsCore.ErrorsExceptions.ForbiddenError,
                  message: "Invalid host for this site"
                )

            # A PATTERN'S CAPTURES ARE THINGS THE VISITOR ASKED FOR, so they arrive beside the query
            # string rather than in a place of their own: a page stored at `/post/:category/:slug` reads
            # `@query_params["category"]` and `@query_params["slug"]`, and a component reads the same
            # name whether the value came from the path or from `?slug=`. The query string wins a
            # collision, because the visitor typed that one — except over `lang`; see `query_params/2`.
            {found, captured} = WebRunTimeMetaDataState.resolve!(joined_path, site_name, "Page")
            page_module = Helpers.module_name(found.id, found.site, "Page")

            result =
              ModuleCompilerHandler.compile_or_return_module(
                page_module,
                found.path,
                site_name,
                site_id
              )
              |> then(&Hook.call("RuntimeLive.HandleParams.AclAfterCompile", &1))
              |> case do
                {:ok, _result} ->
                  # A LIVE NAVIGATION LANDS ON A DIFFERENT PAGE, and that page's uploads are not the
                  # ones mount registered. `allow_upload/3` refuses a name already registered, so
                  # `MishkaCmsCore.Runtime.PageUpload.allow/2` skips what is there and adds what the
                  # page this navigation arrived at asks for.
                  socket
                  |> assign(page_module: page_module)
                  |> assign(page_module.__page_information__())
                  |> assign_page_language(captured)
                  |> assign(:current_path, joined_path)
                  |> assign(:query_params, query_params(params, captured))
                  |> then(fn socket ->
                    new_socket = MishkaCmsCore.Runtime.PageUpload.allow(socket, page_module)
                    {:noreply, Hook.call("RuntimeLive.HandleParams.AfterCompile", new_socket)}
                  end)

                {:error, reason} ->
                  _ =
                    Hook.call("RuntimeLive.HandleParams.AfterCompileError", reason, return: false)

                  :telemetry.execute(
                    [:mishka_cms, :runtime, :handle_params, :error],
                    %{count: 1},
                    %{error_reason: inspect(reason), path: joined_path, site: site_name}
                  )

                  raise MishkaCmsCore.ErrorsExceptions.ServerError,
                    message: "Sorry, unexpected error occurred. please try again later."
              end

            {result, %{}}
          end
        )
    end
  end

  def handle_params(params, url, socket) do
    _ =
      Hook.call("RuntimeLive.HandleParams.BeforeAllParams", [params, url, socket], return: false)

    # Catch-all for non-path params
    # TODO: We can send logger here to dev and production report
    {:noreply, socket}
  end

  def handle_event(event_name, event_params, socket) do
    %{
      page_module: page_module,
      private: %{site: site},
      page: %{path: path}
    } = Hook.call("RuntimeLive.HandleEvent.BeforeEvent", socket.assigns)

    :telemetry.span(
      [:mishka_cms, :runtime, :handle_event],
      %{event: event_name, path: path, site: site},
      fn ->
        %{private: %{site: ^site}} = page_module.__page_information__()

        result =
          apply(page_module, :handle_event, [event_name, event_params, socket])
          |> then(&Hook.call("RuntimeLive.HandleEvent.AfterCallEvent", &1))

        final_result =
          case result do
            {:noreply, %Phoenix.LiveView.Socket{} = socket} ->
              {:noreply, Hook.call("RuntimeLive.HandleEvent.ReturnCallEvent", socket)}

            other ->
              _ =
                Hook.call("RuntimeLive.HandleEvent.AfterCallEventError", other, return: false)

              :telemetry.execute(
                [:mishka_cms, :runtime, :handle_event, :error],
                %{count: 1},
                %{
                  error_reason: "Invalid return value",
                  event: event_name,
                  path: path,
                  site: site
                }
              )

              raise MishkaCmsCore.ErrorsExceptions.ServerError,
                message:
                  "handle_event for #{path} expected return of {:noreply, %Phoenix.LiveView.Socket{}}, but got #{inspect(other)}"
          end

        {final_result, %{}}
      end
    )
  end

  # A COMPONENT FOUND NOTHING AT THE ADDRESS, and only it could know — the page is `/:lang/blog/:slug`
  # and what a slug means belongs to whatever draws it. A LiveComponent has no `handle_params/3` and
  # nothing to raise into, so it says so the way the guides say to, with `send/2`, and the answer is
  # given here.
  #
  # A FULL LOAD, NOT A LIVE ONE. `redirect/2` puts the same address through the router again as an
  # ordinary request; the component raises `NotFoundError` on that render and Phoenix draws the 404
  # page with a 404 STATUS. Raising here instead would crash the view, and on a patch the client
  # remounts into the same missing subject and crashes again — a loop where the visitor wanted a
  # page. On the very first render there is no socket to redirect and the component raises outright,
  # which is the same answer without the round trip.
  def handle_info(:mishka_runtime_not_found, socket) do
    {:noreply, redirect(socket, to: socket.assigns[:current_path] || "/")}
  end

  def handle_info({:css_updated, hash}, socket) do
    site = socket.assigns.private.site

    {:noreply,
     push_event(socket, "mishka:css-updated", %{href: "/assets/css/#{site}/#{hash}.css"})}
  end

  def handle_info({:js_updated, _hash}, socket) do
    {:noreply, push_event(socket, "mishka:js-updated", %{})}
  end

  def handle_info(message, socket) do
    %{
      page_module: page_module,
      private: %{site: site},
      page: %{path: path}
    } = Hook.call("RuntimeLive.HandleInfo.BeforeInfo", socket.assigns)

    :telemetry.span(
      [:mishka_cms, :runtime, :handle_info],
      %{path: path, site: site},
      fn ->
        %{private: %{site: ^site}} = page_module.__page_information__()

        result =
          apply(page_module, :handle_info, [message, socket])
          |> then(&Hook.call("RuntimeLive.HandleInfo.AfterCallInfo", &1))

        final_result =
          case result do
            {:noreply, %Phoenix.LiveView.Socket{} = socket} ->
              {:noreply, Hook.call("RuntimeLive.HandleInfo.ReturnCallInfo", socket)}

            other ->
              _ = Hook.call("RuntimeLive.HandleInfo.AfterCallInfoError", other, return: false)

              :telemetry.execute(
                [:mishka_cms, :runtime, :handle_info, :error],
                %{count: 1},
                %{error_reason: "Invalid return value", path: path, site: site}
              )

              raise MishkaCmsCore.ErrorsExceptions.ServerError,
                message:
                  "handle_info for #{path} expected return of {:noreply, %Phoenix.LiveView.Socket{}}, but got #{inspect(other)}"
          end

        {final_result, %{}}
      end
    )
  end

  def runtime_layout(assigns) do
    _ = Hook.call("RuntimeLive.RuntimeLayout.BeforeLayout", assigns, return: false)
    layout = assigns.private.layout
    site_name = assigns.private.site

    :telemetry.span(
      [:mishka_cms, :runtime, :runtime_layout],
      %{site: site_name, has_layout: !is_nil(layout)},
      fn ->
        result =
          if !is_nil(layout) do
            {site, layout_path} = layout
            {page_module, compiled} = compile_layout(layout, assigns.private.site_id)

            case compiled do
              {:ok, _result} ->
                Hook.call("RuntimeLive.RuntimeLayout.AfterCompile", page_module.render(assigns))

              {:error, reason} ->
                _ =
                  Hook.call("RuntimeLive.RuntimeLayout.AfterCompileError", reason, return: false)

                :telemetry.execute(
                  [:mishka_cms, :runtime, :runtime_layout, :error],
                  %{count: 1},
                  %{error_reason: inspect(reason), layout_path: layout_path, site: site}
                )

                Logger.warning("""
                failed to render layout for #{layout_path}, fallback to default layout

                Got:

                #{inspect(reason)}
                """)

                default_layout(assigns)
            end
          else
            default_layout(assigns)
          end

        {result, %{}}
      end
    )
  rescue
    error ->
      Hook.call("RuntimeLive.RuntimeLayout.AfterCompileError", error, return: false)

      :telemetry.execute(
        [:mishka_cms, :runtime, :runtime_layout, :error],
        %{count: 1},
        %{error_reason: inspect(error), site: assigns.private.site}
      )

      Logger.warning("""
      failed to render layout for #{inspect(assigns.private.layout)}, fallback to default layout

      Got:

      #{inspect(error)}
      """)

      default_layout(assigns)
  end

  @doc """
  The document's `<html lang>`: the language of a database page's response, the language its admin
  reads an admin page in, and `"en"` — what the root layout has always said — for everything else.
  """
  @spec html_lang(map()) :: String.t()
  def html_lang(%{runtime_page: true, page: %{language: language}}) when is_binary(language),
    do: language

  def html_lang(%{admin_language: language}) when is_binary(language), do: language
  def html_lang(_assigns), do: "en"

  @doc """
  The document's `<html dir>`: the direction of a database page's language, and of the language its
  admin reads an admin page in (`admin_css`), so a Persian dashboard reads right to left as a
  Persian page does. The page builder and its canvas (`live_tailwind`) keep left to right: the
  builder places its panels, overlays and drops by pixel. Everything else keeps the tag it had,
  with no `dir` at all.
  """
  @spec html_dir(map()) :: String.t() | nil
  def html_dir(%{runtime_page: true} = assigns), do: Languages.direction(html_lang(assigns))
  def html_dir(%{live_tailwind: true}), do: nil

  def html_dir(%{admin_css: true, admin_language: language}) when is_binary(language),
    do: Languages.direction(language)

  def html_dir(_assigns), do: nil

  # THE LANGUAGE THIS RESPONSE IS IN, AND THE OTHERS IT COULD HAVE BEEN. A page compiled at
  # `/:lang/about` is one module for every language, so `@page.language` is overwritten with the
  # captured one — a template, its layout and `<html lang>` all read that single name, whichever way
  # the page was translated. See `MishkaCmsCore.Runtime.PageEditions`.
  #
  # ONLY IN `handle_params/3`, which runs after `mount/3` on the HTTP render and on the connect alike,
  # so a mount's own would be overwritten before anything drew it. And the editions are read ONCE PER
  # PAGE, kept under `:page_editions` beside the module they were read for: a `<.link patch>` to the
  # same page — a pager, a tab — changes its captures, which `alternates/3` builds the URLs from,
  # but not which editions it has. Every page is in a group, if only its own, so without this every
  # patch on every page cost a query.
  #
  # THE PAGE'S `extra` GOES WITH IT: whether a pattern page answers every language or only its own is
  # marked there, and an alternate the resolver would refuse is a link to a 404.
  defp assign_page_language(socket, captured) do
    %{page: page, page_module: page_module, private: %{site_id: site_id}} = socket.assigns

    editions =
      case socket.assigns[:page_editions] do
        {^page_module, editions} ->
          editions

        _another_page ->
          page
          |> Map.put(:extra, page_module.__page_information__(:extra))
          |> PageEditions.editions(site_id)
      end

    language = PageEditions.language(page, captured)

    socket
    |> speaking(language, site_id)
    |> assign(:page, Map.put(page, :language, language))
    |> assign(:page_editions, {page_module, editions})
    |> assign(:page_languages, PageEditions.alternates(editions, captured, site_id))
  end

  # THE LANGUAGE THIS SOCKET IS READING IN, kept on the socket, in Gettext and in `t/1` together.
  #
  # Gettext's locale is per-PROCESS, and a LiveView is not the process the plug ran in — so a page
  # whose strings come from `dgettext` would answer in the default locale for the whole of a
  # connected session if this were left to `MishkaCmsCore.Runtime.Plugs.LanguagePlug` alone.
  #
  # `mount/3` seeds it from the session, for the window before a page has resolved and for a page
  # whose address names no language. `assign_page_language/2` then overwrites it with the language
  # the page is actually answering in, which is the one the address asked for.
  defp speaking(socket, language, site_id) do
    language = Languages.remembered(language, site_id) || Languages.primary(site_id)
    Gettext.put_locale(language)
    MishkaCmsCore.Runtime.Translations.put_site(site_id)
    assign(socket, :site_language, language)
  end

  # THE SAME QUESTION THE PLUG ANSWERS, asked again because a live navigation never reaches one.
  # It is asked in BOTH callbacks: a `<.link navigate>` remounts, and `mount/3` resolves the address
  # before `handle_params/3` is ever called, so a guard in `handle_params/3` alone was reached only
  # on a patch — a navigation to an address with no language 404ed inside an open socket.
  # Without it a link written without a language would 404 inside an open socket, where a fresh
  # load of that same href redirects — see `MishkaCmsCore.Runtime.Plugs.LanguagePlug`.
  defp language_target(socket, path, site) do
    remembered = Languages.remembered(socket.assigns[:site_language], site.id)

    case LanguagePlug.target(path, {site.name, site.id}, remembered) do
      {:redirect, to, _language} -> {:redirect, to}
      {:serve, language} -> {:serve, language}
    end
  end

  # `mount/3` HAS NO URL, only the params the address was split into. Everything that is not the
  # path is what the query string held, and a redirect that dropped it would lose the page number a
  # reader was on.
  defp query_of_params(params) do
    case params |> Map.delete("path") |> URI.encode_query() do
      "" -> ""
      query -> "?" <> query
    end
  end

  defp query_of(url) do
    case URI.parse(url).query do
      query when query in [nil, ""] -> ""
      query -> "?" <> query
    end
  end

  # THE TAB READS WHAT THE PAGE IS CALLED. Assigned in `mount/3` for the first load.
  defp assign_page_title(socket), do: assign(socket, :page_title, socket.assigns.page.title)

  defp compile_layout({site, layout_path}, page_site_id) do
    site_id = if(site == "Global", do: nil, else: page_site_id)
    layout_meta = WebRunTimeMetaDataState.find_by_path_and_site!(layout_path, site, "Layout")
    layout_module = Helpers.module_name(layout_meta.id, layout_meta.site, "Layout")

    {layout_module,
     ModuleCompilerHandler.compile_or_return_module(layout_module, layout_path, site, site_id)}
  end

  # WHAT THE VISITOR ASKED FOR, WITHOUT THE ROUTE'S OWN WILDCARD. `live "/*path"` puts the matched
  # segments under "path" as a LIST, and a page template that rebuilds a query string from this map
  # would hand `URI.encode_query/1` a list and raise — so the one key the router owns is dropped and
  # everything the visitor typed is kept.
  #
  # This is the seam a page needs to put state in the URL: a component is handed
  # `page={@query_params["page"]}`, its pager is `<.link patch={…}>`, and the back button then works
  # because `handle_params/3` runs again and the value arrives from the address bar rather than from
  # anything the component remembered.
  #
  # A CAPTURED `lang` IS THE ONE THE QUERY STRING DOES NOT OVERRIDE. The resolver let the page answer
  # only because that value is one of the site's languages; `/fa/about?lang=xyz` handing `xyz` to the
  # template would undo the check that made `/xyz/about` a 404.
  defp query_params(params, captured) when is_map(params) and is_map(captured) do
    captured
    |> Map.merge(Map.drop(params, ["path"]))
    |> Map.merge(Map.take(captured, [Languages.capture()]))
  end

  defp query_params(_not_a_map, _captured), do: %{}

  defp default_layout(assigns) do
    ~H"""
    <Layouts.app flash={assigns[:flash] || %{}}>
      {assigns[:inner_content] || ""}
    </Layouts.app>
    """
  end
end
