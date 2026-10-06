defmodule MishkaCmsWeb.AdminSurfaceTest do
  @moduledoc """
  Which surface a request comes from, and so which permission names count for it: the admin screens
  take `admin:dashboard:…`, the admin JSON:API and GraphQL take `admin:api:…`.

  The screens have a door: both admin live sessions refuse anyone holding nothing under
  `admin:dashboard`, and each page then asks for its own area (`MishkaCmsCore.Sidebar.PageGuard`). A
  refusal at the door sends the user to the site root. One at a page sends a dashboard admin back to
  Home and anyone else to the site root too, so an API admin's refusal looks the same from either
  gate, and the door is also run on its own.

  The API has no door. Every resource policy asks for its area on the surface the request came from
  (`MishkaCmsCore.Accounts.Checks.AccessPermissions`), and the `:api` and `:graphql` pipelines say it
  is the API. The context is read back from the conn the router answered with, which is what
  AshJsonApi and AshGraphql hand to the action.

  `async: false` — the install flag and `SiteState` are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @home "/admin/dashboard"
  @api %{admin_surface: :api}

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

    %{site: site}
  end

  defp on_site do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  defp holder!(site, names) do
    site_id = site && site.id

    [site_id: site_id]
    |> create_user!()
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(names, &permission!(&1).id)},
      authorize?: false,
      tenant: site_id
    )
    |> Ash.update!()
    |> Ash.load!([:permissions], authorize?: false, tenant: site_id)
  end

  defp signed_in(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The dashboard loads its widgets asynchronously and listens on PubSub; a view left running after
  # its test outlives the sandbox connection it reads with.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  describe "the screens" do
    test "an admin of one dashboard area is let in", %{site: site} do
      conn = signed_in(holder!(site, ["admin:dashboard:blog:post"]))

      assert {:ok, view, _html} = live(conn, @home)
      close(view)
    end

    test "an API admin is refused the screens, and sent to the site root", %{site: site} do
      conn = signed_in(holder!(site, ["admin:api:*"]))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, @home)
    end

    # THE BUILDER HAS A SESSION OF ITS OWN. A dashboard admin who holds no builder name passes its
    # door and is refused by the builder's page gate, which sends them to Home.
    test "the builder refuses an API admin, and lets a dashboard admin on to its page gate",
         %{site: site} do
      path = "/admin/dashboard/runtime/builder/page/#{create_page!(site_id: site.id).id}"

      assert {:error, {:redirect, %{to: "/"}}} =
               live(signed_in(holder!(site, ["admin:api:*"])), path)

      assert {:error, {:redirect, %{to: @home}}} =
               live(signed_in(holder!(site, ["admin:dashboard:blog:post"])), path)
    end
  end

  # THE DOOR ON ITS OWN: the permission hooks of the live session each route under
  # `/admin/dashboard` mounts in, run on a socket the way LiveView runs them, before any page gate.
  describe "the door" do
    defp sessions do
      for %{
            path: @home <> _rest,
            metadata: %{phoenix_live_view: {_view, _action, _opts, session}}
          } <-
            MishkaCmsWeb.Router.__routes__() do
        session
      end
      |> Enum.uniq_by(& &1.name)
    end

    defp through_door(session, user) do
      socket = %Phoenix.LiveView.Socket{
        endpoint: MishkaCmsWeb.Endpoint,
        router: MishkaCmsWeb.Router,
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      hooks =
        for %{id: {MishkaCmsCore.LiveUserAuth, {:require_permission, _required}} = id} = hook <-
              session.extra.on_mount,
            do: {id, hook.function}

      assert hooks != [], "#{session.name} has no permission hook"

      Enum.reduce_while(hooks, {:cont, socket}, fn {{_module, arg}, hook}, {:cont, socket} ->
        case hook.(arg, %{}, %{}, socket) do
          {:cont, socket} -> {:cont, {:cont, socket}}
          halted -> {:halt, halted}
        end
      end)
    end

    test "every admin route is behind one of the two admin sessions" do
      assert sessions() |> Enum.map(& &1.name) |> Enum.sort() == [
               :authenticated_admin_routes,
               :authenticated_admin_standalone_routes
             ]
    end

    test "each refuses an API admin to the site root, and lets an admin of one dashboard area in",
         %{site: site} do
      for names <- [["admin:api:*"], ["admin:api:runtime:page"]], session <- sessions() do
        assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} =
                 through_door(session, holder!(site, names)),
               "#{session.name} let #{inspect(names)} in"
      end

      for names <- [["admin:dashboard:blog:post"], ["admin:dashboard:runtime:page"]],
          session <- sessions() do
        assert {:cont, _socket} = through_door(session, holder!(site, names)),
               "#{session.name} refused #{inspect(names)}"
      end
    end
  end

  # EVERY SITE'S JOBS: a master who is a full dashboard admin, and nobody narrower. A refusal is a
  # 404, so the address is not found to exist.
  describe "Oban Web" do
    # PAST THE GATE, OBAN WEB ITSELF ANSWERS, and in the tests no Oban instance is running for it to
    # show. Its complaint about that is how far the request got.
    test "opens to a master holding admin:dashboard:*" do
      conn = signed_in(holder!(nil, ["admin:dashboard:*"]))

      assert_raise RuntimeError, ~r/no config registered for \[Oban/, fn -> get(conn, "/oban") end
    end

    test "is not found by a site's full admin, a narrower master or an API master", %{site: site} do
      for {site, names} <- [
            {site, ["admin:dashboard:*"]},
            {nil, ["admin:dashboard:runtime:site"]},
            {nil, ["admin:api:*"]}
          ] do
        conn = get(signed_in(holder!(site, names)), "/oban")

        assert conn.status == 404, "#{inspect(names)} (site #{inspect(site && site.id)}) found it"
      end
    end
  end

  describe "the API" do
    test "a JSON:API request runs as the API, beside what its pipeline put in the context before" do
      conn = get(on_site(), "/api/json/v1/tenant/admin/runtime/page")
      context = ash_context(conn)

      assert context.shared == @api
      assert %{remote_ip: _address} = context.ash_authentication_request
    end

    test "there an area is held by its API name, and not by its dashboard name", %{site: site} do
      context = on_site() |> get("/api/json/v1/tenant/admin/runtime/page") |> ash_context()

      page = [permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]]

      assert AccessPermissions.match?(holder!(site, ["admin:api:runtime:page"]), context, page)

      refute AccessPermissions.match?(
               holder!(site, ["admin:dashboard:runtime:page"]),
               context,
               page
             )

      refute AccessPermissions.match?(holder!(site, ["admin:api:runtime:layout"]), context, page)
    end

    test "a GraphQL request runs as the API" do
      conn = post(on_site(), "/gql", %{"query" => "{ sayHello }"})

      assert json_response(conn, 200)["data"]["sayHello"]
      assert conn.private.absinthe.context.context.shared == @api
    end
  end

  defp ash_context(conn), do: Ash.PlugHelpers.get_context(conn)
end
