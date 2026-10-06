defmodule MishkaCmsWeb.RuntimeLive do
  @moduledoc """
  A Phoenix LiveView module that handles runtime rendering of dynamically compiled CMS pages.

  This module serves as the main LiveView controller for the MishkaCMS runtime system, responsible for
  dynamically compiling and rendering pages, layouts, and components based on database metadata. It manages
  the complete lifecycle of runtime page rendering including path resolution, module compilation, security
  validation, and error handling. The module supports multi-site configurations and provides fallback
  mechanisms for layout rendering failures.

  ## What every page reads

  - `@client_request` — `%{remote_ip: String.t() | nil}`, the address the visitor's socket came
    from, read in `mount/3` and kept for every page the socket goes on to show. A page's sign-in
    forms hand it to AshAuthentication as `ash_authentication_request`, so they are rate limited
    per address as the `/api/auth` routes are (`MishkaCmsCore.Accounts.AuthRateLimit`).
  - `@current_tenant` — the site's id, or `nil` for a master and for a visitor signing in to the
    master accounts (`MishkaCmsCore.LiveUserAuth`, `:live_user_lazy`).

  ## Visitors-only and signed-in-only pages

  A page whose `extra` holds `"visitors_only" => true` — the sign-in pages — opens only for a
  visitor who is not signed in; a signed-in one is redirected to the site root. One whose `extra`
  holds `"signed_in_only" => true` — the sign-out page — opens only for a signed-in visitor; anyone
  else is redirected to the sign-in page.

  ## Sign-in pages of an offline site

  A page on a sign-in address (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.sign_in_path?/2`) stays
  open while its site is offline, and loads the app's own LiveView client in place of the site's
  bundle, which an offline site serves to its admins only.

  ## The head

  `handle_params/3` resolves the page's `<title>` and SEO head into `@page_seo` before every render,
  the HTTP one a crawler reads included, and `page_head/1` renders it — see
  `MishkaCmsCore.Runtime.Seo` for the defaults, the layers and the variables.

  ## Events

  - `runtime:page:visitors_only_redirected` — the socket of a signed-in visitor on a visitors-only
    page, before it is redirected to the site root, with `%{site_id: site_id, path: page_path}` as
    its meta. A plugin may redirect it elsewhere instead.
  - `runtime:page:signed_in_only_redirected` — the same for a visitor who is not signed in on a
    signed-in-only page, before it is redirected to the sign-in page.
  - `runtime:page:seo` — the page's head for the address asked, in every `handle_params/3`. A plugin
    is handed this map (`MishkaCmsCore.Runtime.Seo.given/2`) and returns it, changed — a page that
    serves many records (`/:lang/blog/:slug`) sets each record's own here. What it returns are
    DEFAULTS: whatever the page sets in its own SEO wins, and may name the plugin's `vars`.

      * `title` — the page's `title`. `<title>`, `og:title`, `twitter:title`, `og:image:alt` and the
        default JSON-LD's `name` read it. A stored `title` tag replaces it.
      * `description` — the page's `description`, or `nil`; used only when the page has none. The
        `description`, `og:description` and `twitter:description` tags and the JSON-LD read it;
        empty, a stored `description` meta stands in.
      * `image` — `nil`. An `http(s)://…` address, or a `/…` path on the site, which is made absolute.
        `og:image`, `twitter:image`, the `twitter:card` size and the JSON-LD read it. A stored
        `og:image` replaces it.
      * `type` — `"website"`, the `og:type`; `"article"` for a post.
      * `url` — the canonical address: the site's address (`MishkaCmsCore.Runtime.Seo.base/1`) and
        the path asked, without its query string. An `http(s)://…` address or a `/…` path.
      * `language` — the language this response is in.
      * `tags` — `[]`. Tags in the stored shape, `%{tag: "meta", attrs: %{"property" => "og:image"},
        content: "…"}`, above the defaults and under the layout's tags and the page's.
      * `schema` — the page's stored JSON-LD objects; used only when the page stores none. A
        non-empty one replaces the default `WebPage`.
      * `vars` — `%{}`. Values for `{{key}}` placeholders in stored tags and the schema,
        `%{"post.title" => "…"}`, over the core ones on the same key
        (`MishkaCmsCore.Runtime.Seo.variables/0`). Strings, or numbers.
      * `var_docs` — `[]`. The variables this plugin fills, `[%{key: "post.title", label: "Post
        title"}]`, so an editor can list them. Return them whether or not this request filled them.
      * `permissions` — `[]`. The record's own permission names. Named, the address opens only for
        whoever holds one of them, after the page's own: nobody signed in is sent to sign in, and
        somebody signed in without one gets the 404. The head says `noindex, nofollow`.
      * `page`, `site_id`, `params` — the `:page` section of `__page_information__/0`, the site, and
        `@query_params`: the path's captures (`"slug"`) and the query string. Read only. The
        visual editor asks with `params` empty, for `var_docs` and a preview, or with a sample
        record's.
      * `record` — the kind of record the page shows, `"blog:post"`, from its `extra`
        (`MishkaCmsCore.Runtime.Seo.record_of/1`); `nil` for none. Read only. A plugin answers for
        its own kinds, which it names on `runtime:page:records`.

    A key returned with the wrong type keeps the given value
    (`MishkaCmsCore.Runtime.Seo.accept/2`). Every default tag is built from the answer, so a plugin
    that sets `title`, `description` and `image` gets a complete head.
  """
  use MishkaCmsWeb, :live_view
  alias MishkaCmsCore.Accounts.AuthRateLimit
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.{Languages, Page, PageEditions, Seo, SiteAvailability}
  alias MishkaCmsCore.Runtime.Plugs.{LanguagePlug, SiteLookupPlug}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCoreWeb.ReturnTo
  alias MishkaInstaller.Event.Hook

  require Logger

  # Where `handle_params/3` leaves the address this socket is showing, which is where a visitor goes
  # when a page stops admitting them. Private rather than an assign because nothing renders it and
  # the socket's private is never part of a diff — the same reason
  # `MishkaCmsCore.LiveUserAuth` keeps its session there.
  @address :mishka_cms_runtime_address

  # Where `mount/3` leaves the name of the site-wide page topic it subscribed to. `handle_info/2`
  # matches the arriving broadcast's topic against it, so only the subscription made here is read as
  # a page write — a page that listens to `page:<site id>:created` for its own purposes keeps
  # receiving its own messages.
  @page_topic :mishka_cms_runtime_page_topic

  def mount(%{"path" => path} = params, %{"current_site" => site} = session, socket) do
    socket =
      socket
      |> speaking(session[Languages.session()], site.id)
      |> assign(:client_request, client_request(socket))

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

                # WHAT THIS SITE'S PAGES BECOME, WHILE SOMEBODY IS READING ONE. `MishkaCmsCore.Runtime.Page`
                # publishes every write to this topic through `Ash.Notifier.PubSub`; `handle_info/2` below
                # keeps the write that is about the page this socket is showing and drops the rest. One
                # subscription covers every page the socket goes on to visit, because a live navigation
                # between database pages keeps this process.
                #
                # The name is kept because `handle_info/2` answers only what arrived on it: the resource
                # publishes `created` and `destroyed` under the same payload shape, and a page listening
                # for those must still be handed them.
                page_topic = "page:#{site.id}:updated"
                Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, page_topic)
                Phoenix.LiveView.put_private(socket, @page_topic, page_topic)
              else
                socket
              end

            # NO VISITOR TRAVELS WITH THIS, and that is not an omission. Rewriting the path is CHOOSING
            # the page, and which page it is decides whether a user has to be loaded at all — so at this
            # point nobody has been, and the key this payload used to carry would be `nil` here and a
            # leftover from some earlier page in `handle_params/3`. A hook that has to know the visitor
            # is handed the whole socket by `RuntimeLive.OnMount.BeforeMount` a few lines above, and
            # `MishkaCmsCore.LiveUserAuth.load_current_user/1` verifies one from it.
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
                    |> admit(page_module, socket)
                    |> case do
                      {{:ok, _result}, socket} ->
                        new_socket =
                          socket
                          |> assign(page_module: page_module)
                          |> assign(page_module.__page_information__())
                          |> assign_page_title()
                          |> assign(current_site: site)
                          |> assign(:query_params, query_params(params, captured))
                          |> sign_in_assets(path, site)
                          |> MishkaCmsCore.Runtime.PageUpload.allow(page_module)

                        Hook.call("RuntimeLive.OnMount.AfterCompile", new_socket)

                      {:sign_in, socket} ->
                        sign_in(socket, params)

                      {:visitors_only, socket} ->
                        send_home(socket, page_module)

                      {:signed_in_only, socket} ->
                        send_to_sign_in(socket, page_module)

                      {{:error, reason}, _socket} ->
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

            # NO VISITOR TRAVELS WITH THIS EITHER, for the reason given in `mount/3`: whoever an earlier
            # page in this socket happened to need is not an answer to who is asking for this one.
            # `RuntimeLive.HandleParams.BeforeParams`, above, is handed the socket.
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

            if uri.host && not same_host?(uri.host, expected_host),
              do:
                raise(MishkaCmsCore.ErrorsExceptions.ForbiddenError,
                  message: "Invalid host for this site"
                )

            # THE ADDRESS THIS SOCKET IS ON, KEPT BEFORE ANYTHING CAN REFUSE IT. This callback runs after
            # `mount/3` on the first response and on the connect, and again on every navigation, so it is
            # the one place that always knows where the browser is — and it has run before any event or
            # message can arrive.
            socket = Phoenix.LiveView.put_private(socket, @address, address(uri))

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
              |> admit(page_module, socket)
              |> case do
                {{:ok, _result}, socket} ->
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
                  |> assign_page_seo(uri)
                  |> admit_record(page_module)
                  |> case do
                    {:ok, socket} ->
                      new_socket = MishkaCmsCore.Runtime.PageUpload.allow(socket, page_module)
                      {:noreply, Hook.call("RuntimeLive.HandleParams.AfterCompile", new_socket)}

                    {:sign_in, socket} ->
                      {:noreply, sign_in(socket, params)}
                  end

                {:sign_in, socket} ->
                  {:noreply, sign_in(socket, params)}

                {:visitors_only, socket} ->
                  {:noreply, send_home(socket, page_module)}

                {:signed_in_only, socket} ->
                  {:noreply, send_to_sign_in(socket, page_module)}

                {{:error, reason}, _socket} ->
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

        # ASKED AGAIN, OF THE VISITOR AS THEY ARE NOW, BEFORE THE PAGE ACTS. Only a socket that
        # passed `admit/3` can send here, and losing a permission cuts the socket
        # (`MishkaCmsCore.Accounts.LiveSockets`) — but between the write and the broadcast there is a
        # moment, and an event arriving in it would be answered from a user this socket read when it
        # mounted. `readmit/2` reads that user again; a page naming no permissions asks nothing and
        # pays nothing.
        #
        # WHAT THE PAGE ASKS FOR IS THE MODULE'S ANSWER, the same one `mount/3` and `handle_params/3`
        # get, and it is current: a write that changes it reaches this socket as a page notification,
        # which brings the module up to the row before anything else runs — see `align_page_module/2`.
        socket
        |> readmit(page_module.__page_information__([:acl, :permissions]))
        |> readmit_record()
        |> case do
          {:refused, socket} ->
            {{:noreply, refuse(socket)}, %{}}

          {:ok, socket} ->
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

  # THE PAGE CHANGED HANDS UNDER WHOEVER IS READING IT. Its permissions are asked in `mount/3` and in
  # `handle_params/3`, and somebody sitting on the page runs neither — so an admin who closes a page
  # to the public left everyone already on it reading it, for as long as they stayed.
  #
  # The row that arrives here is the page as it now is, which is fresher than the module this socket
  # is rendering: a write only QUEUES the recompile, so the permissions the compiled module carries
  # are still the ones from before it. That gap is closed first, by `align_page_module/2`, because
  # the refusal below is answered by asking for the address again — and a mount judging by a module
  # older than the refusal would let the same visitor straight back in.
  #
  # Whoever no longer holds a permission is sent back to the address, where `mount/3` gives them the
  # site's 403 or the sign-in it would have given them had they asked a second later. Whoever still
  # holds one notices nothing.
  #
  # Matching `topic` in both the message and this socket's own private admits only the subscription
  # `mount/3` made; the same page's `created` or `destroyed` belongs to whoever subscribed to those.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: topic,
          payload: %Ash.Notifier.Notification{resource: Page, data: %{id: id} = page}
        },
        %{private: %{@page_topic => topic}, assigns: %{private: %{id: id}}} = socket
      ) do
    required = page_permissions(page)
    align_page_module(socket, required)

    case readmit(socket, required) do
      {:ok, socket} -> {:noreply, socket}
      {:refused, socket} -> {:noreply, refuse(socket)}
    end
  end

  # ANOTHER PAGE OF THE SAME SITE. The subscription is the site's, so every page's writes arrive
  # here; the clause above keeps this socket's own and this one drops the rest rather than handing a
  # page's own `handle_info/2` a message about a page it is not.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: topic,
          payload: %Ash.Notifier.Notification{resource: Page}
        },
        %{private: %{@page_topic => topic}} = socket
      ) do
    {:noreply, socket}
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
  What a database page puts in the document's `<head>`: the tags and the JSON-LD of `@page_seo`,
  which `handle_params/3` resolved — see `MishkaCmsCore.Runtime.Seo.head/2`.

  The root layout renders this for `RuntimeLive` and nothing else, so a marketing page's head
  carries none of it. Call it there with no whitespace before it: on a line of its own it adds a
  blank line to every marketing page's head too.

  It renders once per HTTP response, which is the response a crawler reads. A live navigation to
  another database page updates `<title>` and keeps these tags.
  """
  attr :seo, :map, default: nil, doc: "`@page_seo`, with its `tags` and its `schema`"
  attr :csp_nonce, :string, default: nil

  def page_head(%{seo: %{tags: _, schema: _}} = assigns) do
    ~H"""
    <meta :for={{"meta", attrs} <- @seo.tags} {attrs} />
    <link :for={{"link", attrs} <- @seo.tags} {attrs} />
    <script :for={json <- @seo.schema} type="application/ld+json" nonce={@csp_nonce}>
      <%= raw(json) %>
    </script>
    """
  end

  def page_head(assigns), do: ~H""

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

  # THE TAB READS WHAT THE PAGE IS CALLED. Assigned in `mount/3` for the first load; `handle_params/3`
  # replaces it with the title `assign_page_seo/2` resolved, which a live navigation needs to rewrite
  # `<title>`.
  defp assign_page_title(socket), do: assign(socket, :page_title, socket.assigns.page.title)

  # The page's `<title>` and head for this address, through the plugins on `Seo.event/0`. Run after
  # `assign_page_language/2` and `:query_params`, whose editions and captures it reads.
  defp assign_page_seo(socket, %URI{path: path}) do
    %{page: page, private: private, page_languages: languages, query_params: params} =
      socket.assigns

    base = Seo.base(private[:host])

    seo =
      Seo.resolve(page,
        site_id: private[:site_id],
        url: Seo.absolute(canonical_path(path, params), base),
        params: params,
        record: Seo.record_of(socket.assigns[:extra]),
        base: base,
        languages: languages,
        restricted?: Seo.noindex?(acl_permissions(socket.assigns[:acl]), socket.assigns[:extra]),
        layers: [layout_seo_tags(private), stored_seo(page, :meta_tags)]
      )

    assign(socket, page_seo: seo, page_title: seo.title)
  end

  # The path asked for, without empty segments or a trailing slash, and the page of a list it asks
  # for past the first: `/en/blog?page=2` is not the same page as `/en/blog`.
  defp canonical_path(path, params) do
    canonical = "/" <> (path |> to_string() |> String.split("/", trim: true) |> Enum.join("/"))

    case Seo.page_number(params) do
      nil -> canonical
      number -> canonical <> "?page=#{number}"
    end
  end

  # A page whose permissions cannot be read is kept out of an index as one that names a permission.
  defp acl_permissions(%{permissions: permissions}), do: permissions
  defp acl_permissions(_unreadable), do: :unreadable

  # A PAGE THAT NAMES PERMISSIONS OPENS ONLY FOR WHOEVER HOLDS ONE OF THEM, asked of
  # `AccessPermissions` the way every admin gate asks it, so `*` and `admin:*` grant here what they
  # grant there. Nobody signed in is sent to sign in; somebody signed in without one gets the site's
  # 403.
  #
  # Asked in `mount/3` and again in `handle_params/3`, because a `<.link patch>` to another page runs
  # only the second, and the first HTTP response is refused in `mount/3` before anything is drawn.
  # Anything the module holds other than an empty list is a restriction, so a page whose permissions
  # cannot be read is refused rather than served.
  #
  # AND THIS IS WHERE THE VISITOR IS LOADED, because it is the first moment the page is known — see
  # `with_current_user/4`. The socket travels through and comes back out, so the two callers keep
  # whichever user this page needed and no other.
  #
  # A visitors-only page answers `:visitors_only` for a signed-in visitor, and a signed-in-only page
  # `:signed_in_only` for one who is not, before any permission.
  defp admit({:ok, _result} = compiled, page_module, socket) do
    required = page_module.__page_information__([:acl, :permissions])
    visitors_only = extra?(page_module, :visitors_only)
    signed_in_only = extra?(page_module, :signed_in_only)
    socket = with_current_user(socket, required, page_module, visitors_only or signed_in_only)

    case {required, socket.assigns[:current_user]} do
      {_required, %{}} when visitors_only ->
        {:visitors_only, socket}

      {_required, nil} when signed_in_only ->
        {:signed_in_only, socket}

      {[], _nobody_in_particular} ->
        {compiled, socket}

      {_required, nil} ->
        {:sign_in, socket}

      {required, user} ->
        if AccessPermissions.match?(user, %{}, permissions: required),
          do: {compiled, socket},
          else: refuse_as_missing(socket, page_module, required, user)
    end
  end

  defp admit(not_compiled, _page_module, socket), do: {not_compiled, socket}

  # A PAGE THAT SHOWS A RECORD OPENS ONLY FOR WHOEVER THE RECORD ADMITS TOO, asked after `admit/3`
  # admitted them to the page. The record's permissions are what the plugin answering for its kind
  # put in the head (`assign_page_seo/2`), read with the record itself, and they are asked the way
  # `admit/3` asks a page's: nobody signed in is sent to sign in, somebody signed in without one gets
  # the 404. A record naming none asks nothing and loads nobody.
  defp admit_record(%{assigns: %{page_seo: %{permissions: [_ | _] = required}}} = socket, page) do
    socket = MishkaCmsCore.LiveUserAuth.load_current_user(socket)

    case socket.assigns[:current_user] do
      nil ->
        {:sign_in, socket}

      user ->
        if AccessPermissions.match?(user, %{}, permissions: required),
          do: {:ok, socket},
          else: refuse_as_missing(socket, page, required, user)
    end
  end

  defp admit_record(socket, _page_module), do: {:ok, socket}

  # A PAGE SOMEBODY MAY NOT OPEN ANSWERS WHAT A PAGE THAT IS NOT THERE ANSWERS — the site's 404, with
  # the same exception, status and sentence `WebRunTimeMetaDataState.resolve!/3` raises for an address
  # nothing is stored at. A 403 tells whoever asks that the address exists and is worth asking about
  # again with another account; this repository is meant to host private client pages, so the user's
  # decision (2026-09-20) is that a refusal is indistinguishable from a miss.
  #
  # THE SYSTEM STILL KNOWS IT WAS A REFUSAL. The telemetry event carries the page, the permissions it
  # wanted and who asked, which is what the log feature will read later; nothing of that reaches the
  # visitor. A visitor who is not signed in is NOT sent here — they are redirected to sign in, because
  # a members-only page has to be reachable by signing in, and that does tell an anonymous prober the
  # address exists. Closing that needs a per-page "hide that this page exists" flag, which is its own
  # task.
  defp refuse_as_missing(socket, page_module, required, user) do
    page = page_module.__page_information__([:page]) || %{}

    :telemetry.execute(
      [:mishka_cms, :runtime, :page, :forbidden],
      %{count: 1},
      %{
        page_id: page[:id],
        path: page[:path],
        site_id: socket.assigns[:private][:site_id],
        required: required,
        actor_id: user.id
      }
    )

    Logger.info(
      "[RuntimeLive] #{user.id} may not open #{page[:path]} (wants #{Enum.join(required, ", ")}); answered as missing"
    )

    raise MishkaCmsCore.ErrorsExceptions.NotFoundError,
      message: "Sorry, the page you are looking for does not exist or has been moved."
  end

  # THE SAME QUESTION `admit/3` ASKS, ASKED OF A SOCKET THAT IS ALREADY ON THE PAGE: once because the
  # page now names permissions it did not, once before the page acts on an event. Same check,
  # `AccessPermissions`, so `*` and `admin:*` grant here what they grant everywhere.
  #
  # THE VISITOR IS READ AGAIN. `admit/3` may answer from the user this socket loaded when it mounted,
  # because a change to that user ends the socket; here the change is the thing being guarded
  # against, so the assign is exactly what must not be trusted — see
  # `MishkaCmsCore.LiveUserAuth.reload_current_user/1`. A page naming no permissions is not asked at
  # all, and pays nothing. Anything else that is not a list of permissions cannot be judged, so it is
  # refused.
  defp readmit(socket, []), do: {:ok, socket}

  defp readmit(socket, required) when is_list(required) do
    socket = MishkaCmsCore.LiveUserAuth.reload_current_user(socket)

    if AccessPermissions.match?(socket.assigns[:current_user], %{}, permissions: required),
      do: {:ok, socket},
      else: {:refused, socket}
  end

  defp readmit(socket, _unreadable), do: {:refused, socket}

  # And the record the page shows, as `admit_record/2` asked it on the way in.
  defp readmit_record({:ok, %{assigns: %{page_seo: %{permissions: required}}} = socket}),
    do: readmit(socket, required)

  defp readmit_record(answer), do: answer

  # BACK TO THE ADDRESS, AS A REQUEST RATHER THAN A NAVIGATION. Refusing here would mean writing a
  # second copy of what `mount/3` already decides — the 403 for somebody signed in, the sign-in with
  # `return_to` for somebody who is not — so the browser asks for the page again instead, and the one
  # place that answers that question answers it.
  defp refuse(socket), do: redirect(socket, to: socket.private[@address])

  # THE COMPILED MODULE IS BROUGHT UP TO THE ROW IT HAS JUST BEEN TOLD ABOUT, and only when the two
  # disagree about who may read the page — a body, a title, a description costs nothing here and
  # waits for the queued recompile as it always did.
  #
  # It has to be done from here because the module is the ONE source the other three callbacks read:
  # `mount/3`, `handle_params/3` and `handle_event/3` all ask `__page_information__/1`, and the write
  # that changed the row only enqueued the job that would change the module. Leaving them to disagree
  # is what made a refusal meaningless — the browser asked for the address again and the old module
  # admitted it. The module is the node's, so whichever socket on the page compiles first answers for
  # all of them, and the cost is a compile per write that changes a page's permissions — the one the
  # queued job was going to do anyway.
  defp align_page_module(socket, required) when is_list(required) do
    %{page_module: page_module, page: %{path: path}, private: %{site: site, site_id: site_id}} =
      socket.assigns

    if page_module.__page_information__([:acl, :permissions]) != required do
      ModuleCompilerHandler.compile_or_return_module(page_module, path, site, site_id, :update)
    end

    :ok
  end

  defp align_page_module(_socket, _unreadable), do: :ok

  # WHAT THE PAGE ASKS FOR, READ THE WAY THE COMPILER READS IT.
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` writes `permissions || []` into the module, so
  # a column left null is a public page there and has to be one here too — otherwise every save of a
  # public page would throw its readers off and `mount/3` would let them straight back in.
  #
  # Anything else is a page whose permissions could not be read, which `admit/3` refuses rather than
  # serves; `readmit/2` does the same with what this hands it.
  defp page_permissions(%{permissions: nil}), do: []
  defp page_permissions(%{permissions: permissions}), do: permissions
  defp page_permissions(_unreadable), do: :unreadable

  # What the browser has in its address bar, from the URL `handle_params/3` was given: its path and
  # its query, and nothing that would make it point at another host.
  defp address(%URI{} = uri), do: URI.to_string(%URI{path: uri.path || "/", query: uri.query})

  # LOCALHOST IS THE SITE `SiteLookupPlug` CHOSE FOR IT, the master site while no site claims
  # localhost. Compiled under the same `:env_dev?` / `:env_test?` config as that clause, so a release
  # has neither.
  if Application.compile_env(:mishka_cms_core, :env_dev?, false) or
       Application.compile_env(:mishka_cms_core, :env_test?, false) do
    defp same_host?(browser, _site) when browser in ["localhost", "127.0.0.1"], do: true
  end

  defp same_host?(browser, site), do: browser == site

  # A PAGE PAYS FOR THE VISITOR ONLY WHERE IT HAS A USE FOR ONE. Two uses: permissions, which need
  # somebody to judge, and markup or code that reads `@current_user`, which
  # `MishkaCmsCore.Runtime.Compilers.UserClosure` worked out when the page was compiled. Only the
  # page that has neither is served without a lookup.
  #
  # `MishkaCmsCore.LiveUserAuth.load_current_user/1` makes exactly the checks the live session used
  # to make on every mount, and does them again on a navigation into a page that needs one after a
  # page that did not.
  #
  # A visitors-only or signed-in-only page loads the visitor too, to send the wrong one away.
  defp with_current_user(socket, [], page_module, false) do
    if reads_user?(page_module),
      do: MishkaCmsCore.LiveUserAuth.load_current_user(socket),
      else: socket
  end

  defp with_current_user(socket, _required, _page_module, _visitors_only),
    do: MishkaCmsCore.LiveUserAuth.load_current_user(socket)

  # A page marks itself visitors-only with `extra["visitors_only"] == true`, signed-in-only with
  # `extra["signed_in_only"] == true`; the compiled `extra` holds atom or string keys, see `field/2`.
  defp extra?(page_module, key) do
    case page_module.__page_information__(:extra) do
      %{} = extra -> field(extra, key) == true
      _no_extra -> false
    end
  end

  # A signed-in visitor on a visitors-only page goes to the site root, unless a plugin on
  # `runtime:page:visitors_only_redirected` redirected the socket elsewhere first.
  defp send_home(socket, page_module) do
    socket =
      Hook.call("runtime:page:visitors_only_redirected", socket,
        meta: %{
          site_id: page_module.__page_information__([:private, :site_id]),
          path: page_module.__page_information__([:page, :path])
        }
      )

    if socket.redirected,
      do: socket,
      else: redirect(socket, to: MishkaCmsCore.Helpers.path(socket, "/"))
  end

  # A visitor who is not signed in on a signed-in-only page goes to the sign-in page — nothing there
  # to come back to — unless a plugin on `runtime:page:signed_in_only_redirected` redirected the
  # socket elsewhere first.
  defp send_to_sign_in(socket, page_module) do
    socket =
      Hook.call("runtime:page:signed_in_only_redirected", socket,
        meta: %{
          site_id: page_module.__page_information__([:private, :site_id]),
          path: page_module.__page_information__([:page, :path])
        }
      )

    if socket.redirected,
      do: socket,
      else: redirect(socket, to: MishkaCmsCore.Helpers.path(socket, "/auth"))
  end

  # The address the visitor's socket came from: `:x_headers` read the way the endpoint's
  # `plug RemoteIp` reads a request's, else `:peer_data`. Call it from `mount/3` only, the one
  # callback `get_connect_info/2` answers in; the `/live` socket must list both in `connect_info`.
  defp client_request(socket) do
    forwarded = get_connect_info(socket, :x_headers) || []

    address =
      RemoteIp.from(forwarded, AuthRateLimit.remote_ip_options()) ||
        peer(get_connect_info(socket, :peer_data))

    %{remote_ip: address && address |> :inet.ntoa() |> to_string()}
  end

  defp peer(%{address: address}), do: address
  defp peer(_undeclared), do: nil

  # A sign-in page of a site that is not open loads the app's own LiveView client and not the site's
  # bundle, which such a site serves to its admins only. Assigned in `mount/3`, the render the root
  # layout is drawn from.
  defp sign_in_assets(socket, path, site) do
    if SiteLookupPlug.sign_in_path?(path, site) and SiteAvailability.state(site.id) != :open,
      do: assign(socket, standalone_assets: true, suppress_site_js: true),
      else: socket
  end

  # THE PAGE AND ITS LAYOUT ARE ASKED SEPARATELY, and either is enough. The layout is drawn with this
  # LiveView's own assigns, so its markup reads the visitor exactly as the page's does — but its
  # answer cannot be baked into the page, because editing a layout rebuilds the layout module and no
  # page under it. Asked of the layout module instead, it is as fresh as the layout itself.
  #
  # ANYTHING BUT AN EXPLICIT `false` MEANS LOAD, so a module compiled before either answer existed
  # says `nil` here and loads, and a layout that cannot be resolved or compiled loads too.
  defp reads_user?(page_module) do
    page_module.__page_information__([:private, :reads_user]) != false or
      layout_reads_user?(page_module.__page_information__(:private))
  end

  # A PAGE WITH NO LAYOUT IS DRAWN IN `default_layout/1`, which names no visitor.
  defp layout_reads_user?(%{layout: nil}), do: false

  defp layout_reads_user?(%{layout: layout, site_id: site_id}) do
    case compile_layout(layout, site_id) do
      {layout_module, {:ok, _result}} ->
        layout_module.__layout_information__([:private, :reads_user]) != false

      {_layout_module, {:error, _reason}} ->
        true
    end
  rescue
    _unreadable -> true
  end

  # BACK TO THE PAGE THAT ASKED, once signed in: `/auth` redirects to the site's sign-in page with
  # the query kept, that page hands `return_to` on to the sign-in it starts, and
  # `MishkaCmsCoreWeb.AuthController` redirects there.
  #
  # WHAT TRAVELS IS A SIGNATURE, NOT AN ADDRESS. The address is the route this request already
  # matched, so it is this site's by construction; signing it is what lets the controller tell it
  # apart from the one a stranger would rather send people to. `~p` refuses to build an address a
  # browser would read as another origin — it raises instead — so what reaches `ReturnTo.sign/2`
  # here is always something it mints a token for.
  defp sign_in(socket, %{"path" => path} = params) do
    return_to = ReturnTo.sign(socket, ~p"/#{path}?#{query_params(params, %{})}")

    socket
    |> put_flash(:error, gettext("You must log in to access this page."))
    |> redirect(to: ~p"/auth?#{[return_to: return_to]}")
  end

  defp compile_layout({site, layout_path}, page_site_id) do
    site_id = if(site == "Global", do: nil, else: page_site_id)
    layout_meta = WebRunTimeMetaDataState.find_by_path_and_site!(layout_path, site, "Layout")
    layout_module = Helpers.module_name(layout_meta.id, layout_meta.site, "Layout")

    {layout_module,
     ModuleCompilerHandler.compile_or_return_module(layout_module, layout_path, site, site_id)}
  end

  # A LAYOUT THAT CANNOT BE FOUND OR COMPILED BRINGS NO TAGS. `runtime_layout/1` has already
  # rendered this page without it and reported why, in this same response; the head only leaves it
  # out.
  defp layout_seo_tags(%{layout: {_site, _path} = layout, site_id: site_id}) do
    case compile_layout(layout, site_id) do
      {layout_module, {:ok, _result}} ->
        layout_module.__layout_information__([:layout, :seo, :meta_tags])

      {_layout_module, {:error, _reason}} ->
        []
    end
  rescue
    _error -> []
  end

  defp layout_seo_tags(_no_layout), do: []

  defp stored_seo(%{seo: %{} = seo}, key), do: Map.get(seo, key)
  defp stored_seo(_page, _key), do: nil

  # A compiled page's keys are atoms where the atom already exists and strings where it does not —
  # see `MishkaCmsCore.Runtime.Helpers.atomize_keys/1` — so each field is read both ways.
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

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
