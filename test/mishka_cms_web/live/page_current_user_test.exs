# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageCurrentUserTest do
  @moduledoc """
  A runtime page loads and verifies the signed-in user only where it has a use for one.

  Every database page is answered by one `live "/*path"`, and the live session that wrapped it
  loaded the user on every mount of every one of them — a token-row read and a user read that a
  brochure page which never mentions a visitor had no use for.

  `MishkaCmsCore.Runtime.Compilers.UserClosure` now answers, when a page or a layout is compiled,
  whether anything it draws can read `current_user` — its own markup and code, and whether it hands
  a component the assigns one would have to be handed to see. The page and its layout answer
  separately, into their own modules, because a layout edit rebuilds the layout module and no page
  under it. `MishkaCmsWeb.RuntimeLive` puts the two back together and, with the page's permissions,
  decides whether to ask `MishkaCmsCore.LiveUserAuth.load_current_user/1` for a user — which makes
  exactly the checks the live session made: the session's token, its row in the token resource, then
  the subject.

  So the two halves this pins are: a page with no use for a visitor never looks one up, and a page
  with a use for one gets a user no less verified than before — on the first render, on a live
  navigation and on a `<.link patch>` from a page that had loaded nobody.

  `async: false` — the install flag, `SiteState` and the routing table are process-global, and the
  query counter below reads telemetry every process emits.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # A refused live navigation takes its LiveView down with the 403, which is logged.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCoreWeb.ReturnTo

  # Nothing in it names the visitor, which is the point of every page built from it.
  @silent ~S(<div id="page-body" data-page={@page.path}>page</div>)

  @reads ~S(<div id="page-body" data-page={@page.path}>{if assigns[:current_user], do: "in", else: "out"}</div>)

  # THE LAYOUT IS DRAWN WITH THE LIVEVIEW'S OWN ASSIGNS, so this reads the visitor exactly as a
  # page's own markup does — and it is the form the builder's "Visitor is signed in" condition
  # writes. See `MishkaCmsCore.Runtime.PageBuilder.Conditions`.
  @reads_layout ~S(<div id="layout-body">{if assigns[:current_user], do: "in", else: "out"}{@inner_content}</div>)

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)
    MishkaCmsCore.Settings.put("cms.offline", false)

    %{
      site: site,
      silent: published!(site, template: @silent),
      members: published!(site, template: @silent, permissions: ["members:read"])
    }
  end

  describe "a page that names the visitor nowhere" do
    test "is compiled knowing it has no use for one", %{silent: silent} do
      assert information(silent, [:private, :reads_user]) == false
    end

    test "mounts for a signed-in visitor without loading one", %{site: site, silent: silent} do
      {:ok, view, _html} = live(signed_in(site, []), silent.path)

      refute Map.has_key?(assigns(view), :current_user)
      assert has_element?(view, "#page-body")
    end

    # The dead render is taken first and not measured: the `:browser` pipeline's `:load_from_session`
    # loads the user for every HTTP request on this host, page or no page. What this pins is the
    # CONNECTED mount, which runs no pipeline and is where the live session used to spend its reads.
    # The counter is read against a page that DOES want the visitor in the same breath, so an
    # assertion that passes because nothing was measured at all fails here instead.
    test "reads neither users nor tokens on its connected mount", %{site: site, silent: silent} do
      user = member!(site, [])
      reader = published!(site, template: @reads)

      silent_conn = get(signed_in_as(user), silent.path)
      reader_conn = get(signed_in_as(user), reader.path)

      silent_tables = tables_read(fn -> {:ok, _view, _html} = live(silent_conn) end)
      reader_tables = tables_read(fn -> {:ok, _view, _html} = live(reader_conn) end)

      assert "users" in reader_tables and "tokens" in reader_tables,
             "the counter saw nothing on a page that loads the visitor: #{inspect(reader_tables)}"

      assert "users" not in silent_tables and "tokens" not in silent_tables,
             "a public page's mount read #{inspect(silent_tables)}"
    end

    test "still says nobody is signed in to a visitor who is not", %{silent: silent} do
      {:ok, view, _html} = live(on_site(), silent.path)
      assert has_element?(view, "#page-body")
    end

    # THE ONE ASSIGN THE REPLACED HOOK MADE THAT IS NOT ABOUT THE USER.
    # `AshAuthentication.Phoenix.LiveSession`'s own hook assigned `:current_tenant` from the session
    # whenever one was there, whether or not the page had any use for a user, and something drawn on
    # a runtime page may read it. It is still assigned, and still without loading anybody.
    test "keeps the tenant the session carries", %{site: site, silent: silent} do
      conn = Ash.PlugHelpers.set_tenant(signed_in(site, []), site.id)

      {:ok, view, _html} = live(conn, silent.path)

      assert assigns(view).current_tenant == site.id
      refute Map.has_key?(assigns(view), :current_user)
    end
  end

  describe "a page that can read the visitor" do
    test "gets one from its own markup", %{site: site} do
      user = member!(site, [])
      page = published!(site, template: @reads)

      assert information(page, [:private, :reads_user]) == true

      {:ok, view, html} = live(signed_in_as(user), page.path)

      assert assigns(view).current_user.id == user.id
      assert html =~ "in"
    end

    # THE LAYOUT ANSWERS FOR ITSELF, into its own module, and the page's own answer stays `false` —
    # see the test below for the reason the two are kept apart.
    test "gets one from its layout's markup", %{site: site} do
      layout = drawn!(site, @reads_layout)
      user = member!(site, [])
      page = published!(site, template: @silent, layout_id: layout.id)

      assert information(page, [:private, :reads_user]) == false
      assert layout_information(layout, site, [:private, :reads_user]) == true

      {:ok, view, html} = live(signed_in_as(user), page.path)

      assert assigns(view).current_user.id == user.id
      assert html =~ "in"
    end

    # A LAYOUT EDIT REBUILDS THE LAYOUT MODULE AND NO PAGE UNDER IT. So an answer about the layout,
    # baked into the pages, would be wrong from the moment an author drops the builder's own
    # "Visitor is signed in" condition on a site header: every page already compiled would go on
    # saying nobody is signed in, silently, for the life of the node. The page below is compiled
    # under a layout that names nobody, the layout then learns to read the visitor, and only the
    # LAYOUT module is rebuilt — the way `RuntimeCompilerWorker` rebuilds one.
    test "gets one from a layout that learned to read the visitor after it was compiled", %{
      site: site
    } do
      layout = drawn!(site, ~S(<div id="layout-body">nobody{@inner_content}</div>))
      page = published!(site, template: @silent, layout_id: layout.id)

      assert information(page, [:private, :reads_user]) == false

      edit!(layout, site, @reads_layout)

      user = member!(site, [])
      {:ok, view, html} = live(signed_in_as(user), page.path)

      assert assigns(view).current_user.id == user.id
      assert html =~ "in"
    end

    test "gets one from a helper nothing else mentions it in", %{site: site} do
      user = member!(site, [])

      page =
        published!(site,
          template: ~S|<div id="page-body">{greeting(assigns)}</div>|,
          helpers: [
            %{name: "greeting", args: "assigns", code: ~S|assigns[:current_user] && "hi"|}
          ]
        )

      assert information(page, [:private, :reads_user]) == true

      {:ok, view, _html} = live(signed_in_as(user), page.path)
      assert assigns(view).current_user.id == user.id
    end

    test "gets one from an event handler", %{site: site} do
      user = member!(site, [])

      page =
        published!(site,
          template: @silent,
          events: [
            %{
              name: "ping",
              code: ~S|{:noreply, assign(socket, :who, socket.assigns[:current_user])}|
            }
          ]
        )

      assert information(page, [:private, :reads_user]) == true

      {:ok, view, _html} = live(signed_in_as(user), page.path)
      assert assigns(view).current_user.id == user.id
    end

    # A COMPONENT IS HANDED ONLY THE ASSIGNS ITS CALL SITE WRITES, so the one way it can reach the
    # visitor is the page handing it the whole bag — and that is written in the PAGE's markup, which
    # is rebuilt when the page is. The component below is blind when the page is compiled and learns
    # to read the visitor afterwards, with only the COMPONENT module rebuilt: the answer holds,
    # because it was never an answer about the component.
    test "gets one for a component it hands its own assigns to", %{site: site} do
      user = member!(site, [])

      component =
        create_component!(
          site_id: site.id,
          name: "bagged-#{System.unique_integer([:positive])}",
          template: ~S(<div id="inner">nobody</div>)
        )

      page =
        published!(site,
          template:
            ~s(<div id="page-body"><.component component_name="#{component.name}" site="localhost" bag={assigns} /></div>)
        )

      assert information(page, [:private, :reads_user]) == true

      edit!(
        component,
        site,
        ~S|<div id="inner">{if @bag[:current_user], do: "in", else: "out"}</div>|
      )

      {:ok, view, html} = live(signed_in_as(user), page.path)

      assert assigns(view).current_user.id == user.id
      assert html =~ "in"
    end

    # A SPREAD IS A MAP BUILT WHILE THE PAGE RENDERS, and the page's own assigns can be inside it, so
    # a tag carrying one is read as handing over anything at all.
    test "gets one when a component spreads a map of attributes", %{site: site} do
      user = member!(site, [])

      blind =
        create_component!(
          site_id: site.id,
          name: "spread-#{System.unique_integer([:positive])}",
          template: ~S(<div id="inner">nobody</div>)
        )

      page =
        published!(site,
          template:
            ~s|<div id="page-body"><.component component_name="#{blind.name}" site="localhost" {%{padding: "small"}} /></div>|
        )

      assert information(page, [:private, :reads_user]) == true

      {:ok, view, _html} = live(signed_in_as(user), page.path)
      assert assigns(view).current_user.id == user.id
    end

    # THE OTHER SIDE OF THE SAME BOUNDARY: a tag handed nothing but literals and expressions of its
    # own reaches no visitor, whatever the component it draws turns out to say, so the page is served
    # without a lookup.
    test "a component handed nothing of the page's costs the visitor nothing", %{site: site} do
      loud =
        create_component!(
          site_id: site.id,
          name: "loud-#{System.unique_integer([:positive])}",
          template: ~S(<div id="inner">{assigns[:current_user] && "in"}</div>)
        )

      page =
        published!(site,
          template:
            ~s(<div id="page-body"><.component component_name="#{loud.name}" site="localhost" title={@page.title} /></div>)
        )

      assert information(page, [:private, :reads_user]) == false

      {:ok, view, _html} = live(signed_in(site, []), page.path)
      refute Map.has_key?(assigns(view), :current_user)
    end

    test "gets the user with its site loaded, as the live session did", %{site: site} do
      user = member!(site, [])
      page = published!(site, template: @reads)

      {:ok, view, _html} = live(signed_in_as(user), page.path)

      assert assigns(view).current_user.site.id == site.id
    end
  end

  describe "a page that names permissions" do
    test "loads a user although its markup names none", %{site: site, members: members} do
      assert information(members, [:private, :reads_user]) == false

      user = member!(site, ["members:read"])
      {:ok, view, _html} = live(signed_in_as(user), members.path)

      assert assigns(view).current_user.id == user.id
      assert has_element?(view, "#page-body")
    end

    test "refuses a token whose stored row is gone", %{site: site, members: members} do
      user = member!(site, ["members:read"])
      conn = signed_in_as(user)
      revoke!(user)

      assert {:error, {:redirect, %{to: sign_in}}} = live(conn, members.path)
      assert returns_to(sign_in) == members.path
    end

    # The socket is already open on a page that loaded nobody, so the only thing that can answer
    # this navigation is a verification made now — against a token the browser still holds and the
    # token resource no longer has.
    test "refuses a revoked token on a patch from a page that loaded nobody", %{
      site: site,
      silent: silent,
      members: members
    } do
      user = member!(site, ["members:read"])
      conn = signed_in_as(user)

      {:ok, view, _html} = live(conn, silent.path)
      refute Map.has_key?(assigns(view), :current_user)

      revoke!(user)

      assert {:error, {:redirect, %{to: sign_in}}} = render_patch(view, members.path)
      assert returns_to(sign_in) == members.path
    end
  end

  describe "arriving from a page that loaded nobody" do
    test "a patch into a protected page verifies the visitor then", %{
      site: site,
      silent: silent,
      members: members
    } do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), silent.path)
      refute Map.has_key?(assigns(view), :current_user)

      render_patch(view, members.path)

      assert has_element?(view, "#page-body[data-page='#{members.path}']")
      assert assigns(view).current_user
    end

    test "a patch into a protected page still refuses whoever holds nothing", %{
      site: site,
      silent: silent,
      members: members
    } do
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(signed_in(site, ["members:write"]), silent.path)

      assert {{%NotFoundError{}, _stacktrace}, _call} =
               catch_exit(render_patch(view, members.path))
    end

    test "a navigation into a page that reads the visitor loads one", %{
      site: site,
      silent: silent
    } do
      user = member!(site, [])
      reader = published!(site, template: @reads)

      {:ok, view, _html} = live(signed_in_as(user), silent.path)
      refute Map.has_key?(assigns(view), :current_user)

      assert {:ok, view, html} = live_redirect(view, to: reader.path)

      assert assigns(view).current_user.id == user.id
      assert html =~ "in"
    end
  end

  # WHO THE VISITOR IS COMES FROM THEIR OWN TOKEN, through the host's real `:browser` pipeline. The
  # setup's `localhost` is the master site: a master's token, issued with no site, signs them in
  # there without any flag, and a site's user holding such a token is nobody, whatever the session's
  # `master_mode` says — a token issued with no site does not make its holder a master.
  describe "who the master site's pages read" do
    test "a master is the visitor", %{site: site} do
      master = create_user!()
      page = published!(site, template: @reads)

      {:ok, view, _html} = live(signed_in_as(master), page.path)

      assert assigns(view).current_user.id == master.id
      assert has_element?(view, "#page-body", "in")
    end

    test "a site's user holding a token issued with no site is nobody", %{site: site} do
      {:ok, user} =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "moved-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!"
          },
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:site_id, site.id)
        |> Ash.create()

      page = published!(site, template: @reads)

      conn =
        on_site()
        |> Plug.Test.init_test_session(%{master_mode: true})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)
        |> get(page.path)

      assert conn.assigns.current_user == nil
      refute Plug.Conn.get_session(conn, "user_token")

      {:ok, view, _html} = live(conn)

      assert assigns(view)[:current_user] == nil
      assert has_element?(view, "#page-body", "out")
    end
  end

  defp published!(site, overrides) do
    page =
      create_page!(
        [
          site_id: site.id,
          path: "/lazy-#{System.unique_integer([:positive])}"
        ] ++ overrides
      )

    :ok = WebRunTimeMetaDataState.save(route(page, site, "Page"))
    page
  end

  # A layout with its routing entry, which is what a page resolves its layout module through.
  defp drawn!(site, template) do
    layout =
      create_layout!(
        site_id: site.id,
        path: "/layouts/user-#{System.unique_integer([:positive])}",
        template: template
      )

    :ok = WebRunTimeMetaDataState.save(route(layout, site, "Layout"))
    layout
  end

  # A SAVE, AND THEN THE ONE MODULE THAT SAVE REBUILDS — its own, and nothing else's.
  # `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker` does exactly this off an Oban job; here it
  # is done in line, because what these tests pin is which modules a save leaves untouched.
  defp edit!(%MishkaCmsCore.Runtime.Layout{} = layout, site, template) do
    saved!(layout, site, template, %{})
    recompiled!(Helpers.module_name(layout.id, site.name, "Layout"), layout.path, site)
  end

  defp edit!(%MishkaCmsCore.Runtime.Component{} = component, site, template) do
    saved!(component, site, template, %{page_code: :package})
    recompiled!(Helpers.module_name(component.name, site.name, "Component"), component.name, site)
  end

  defp saved!(record, site, template, context) do
    record
    |> Ash.Changeset.for_update(:update, %{template: template},
      authorize?: false,
      tenant: site.id,
      context: context
    )
    |> Ash.update!()
  end

  defp recompiled!(module, identifier, site) do
    {:ok, _module} =
      ModuleCompilerHandler.compile_or_return_module(
        module,
        identifier,
        site.name,
        site.id,
        :update
      )

    :ok
  end

  # A ROW IS NOT YET A ROUTE: boot fills `WebRunTimeMetaDataState`, and a test fills it itself.
  defp route(record, site, section) do
    %{
      id: record.id,
      site: site.name,
      path: record.path,
      title: record.name,
      created_at: DateTime.utc_now(),
      section: section,
      priority: 0
    }
  end

  # The compiled module's own answer, built the way a request builds it.
  defp information(page, keys) do
    module = Helpers.module_name(page.id, "localhost", "Page")
    site = Ash.get!(MishkaCmsCore.Runtime.Site, page.site_id, authorize?: false)

    {:ok, _module} =
      ModuleCompilerHandler.compile_or_return_module(module, page.path, site.name, site.id)

    module.__page_information__(keys)
  end

  defp layout_information(layout, site, keys) do
    module = Helpers.module_name(layout.id, site.name, "Layout")

    {:ok, _module} =
      ModuleCompilerHandler.compile_or_return_module(module, layout.path, site.name, site.id)

    module.__layout_information__(keys)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # THE TABLES A BLOCK OF WORK READ. Ecto names the source of every query it runs, and the
  # LiveView's own process emits them like any other, so "did this mount look the visitor up" is
  # answerable exactly rather than by timing or by counting.
  defp tables_read(fun) do
    ref = make_ref()
    owner = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:mishka_cms, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(owner, {ref, metadata[:source]})
      end,
      nil
    )

    try do
      fun.()
      drain(ref, [])
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  defp drain(ref, seen) do
    receive do
      {^ref, source} -> drain(ref, [source | seen])
    after
      0 -> Enum.uniq(seen)
    end
  end

  # WHAT AN OPERATOR'S REVOCATION LEAVES BEHIND: `revoke_all_stored_for_subject` rewrites every
  # stored token for a subject to `purpose: "revocation"`, so the `"user"` row the session check
  # looks for is gone while the cookie the browser holds is untouched.
  defp revoke!(user) do
    subject = AshAuthentication.user_to_subject(user)

    MishkaCmsCore.Accounts.Token
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn token ->
      token
      |> Ash.Changeset.for_update(:revoke_all_stored_for_subject, %{subject: subject},
        authorize?: false
      )
      |> Ash.update!()
    end)
  end

  defp member!(site, permissions) do
    user = create_user!(site_id: site.id)

    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(permissions, &permission!(&1).id)},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp signed_in(site, permissions), do: signed_in_as(member!(site, permissions))

  defp signed_in_as(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The page to come back to is a signature, not an address, so what the sign-in URL carries is only
  # readable back through `ReturnTo` — which is exactly what the controller will do with it.
  defp returns_to("/auth?" <> query) do
    query
    |> URI.decode_query()
    |> Map.get("return_to")
    |> then(&ReturnTo.verify(@endpoint, &1))
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
