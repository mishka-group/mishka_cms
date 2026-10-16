# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PagePermissionsTest do
  @moduledoc """
  A database page that names permissions opens only for whoever holds one of them.

  `Page.permissions` was saved, copied from a draft on publish and shown in the admin form, and
  never reached the compiled module: `ModuleCompilerHandler` left it out of what it handed the
  compiler, so every page compiled with no permissions and a members-only page was public.

  `MishkaCmsWeb.RuntimeLive` now asks `AccessPermissions` — the check every admin gate uses, `*`
  included — in `mount/3` and again in `handle_params/3`. A visitor who is not signed in is sent to
  sign in with the page as `return_to`, and brought back to it; a user holding none of the
  permissions is answered as though the page were not there: the site's 404, the same exception and
  the same sentence an address nothing is stored at gets, so a refusal cannot be told from a miss.
  The refusal itself is not lost — it is a telemetry event and a log line, for whoever asks the
  system later. Both answer the first HTTP response, a `live` mount and a live navigation alike.

  The permissions are actions, and a user's own wildcards cover them the way they cover an admin
  gate's: `staff:*` on a page opens for `staff:*` or `*`, not for the narrower `staff:editor`.

  `async: false` — the install flag, `SiteState` and the routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # A refused live navigation takes its LiveView down with the 404, which is logged.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCoreWeb.ReturnTo

  @password "Password123!"

  @required ["members:read", "staff:*"]

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
      public: published!(site, []),
      members: published!(site, @required)
    }
  end

  describe "a page that names no permissions" do
    test "opens for a visitor who is not signed in", %{public: public} do
      assert has_page?(on_site() |> get(public.path) |> html_response(200))

      {:ok, view, _html} = live(on_site(), public.path)
      assert has_element?(view, "#page-body")
    end
  end

  describe "a page that names permissions" do
    test "opens for a user holding one of them", %{site: site, members: members} do
      for held <- [["members:read"], ["members:*"], ["staff:*"], ["*"]] do
        conn = signed_in(site, held)

        assert has_page?(conn |> get(members.path) |> html_response(200)),
               "#{inspect(held)} was refused #{inspect(@required)}"

        {:ok, view, _html} = live(conn, members.path)
        assert has_element?(view, "#page-body")
      end
    end

    test "answers the site's 404 to a user holding none of them", %{site: site, members: members} do
      for held <- [
            [],
            ["members:write"],
            ["staff:editor"],
            ["admin:dashboard:*"],
            ["admin:dashboard:runtime:page"],
            ["admin:api:*"]
          ] do
        conn = signed_in(site, held)

        {_status, _headers, body} = assert_error_sent(404, fn -> get(conn, members.path) end)

        refute has_page?(body), "#{inspect(held)} was shown a page needing #{inspect(@required)}"
      end
    end

    test "sends a visitor who is not signed in to sign in, with the page to come back to", %{
      members: members
    } do
      asked = members.path <> "?tab=2"

      assert returns_to(redirected_to(get(on_site(), asked))) == asked

      assert {:error, {:redirect, %{to: sign_in, flash: %{"error" => _message}}}} =
               live(on_site(), asked)

      assert returns_to(sign_in) == asked
    end

    # `mount/3` runs the page's `OnMount.AfterCompile` hook and registers its uploads before
    # `handle_params/3` is reached, so it refuses on its own rather than leaning on the check after.
    test "is refused by mount before anything after it runs", %{site: site, members: members} do
      params = %{"path" => String.split(String.trim_leading(members.path, "/"), "/")}
      session = %{"current_site" => site}

      assert {:ok, %{redirected: {:redirect, %{to: sign_in}}}, _options} =
               MishkaCmsWeb.RuntimeLive.mount(params, session, bare_socket(nil))

      assert returns_to(sign_in) == members.path

      outsider = member!(site, ["members:write"])

      assert_raise NotFoundError, fn ->
        MishkaCmsWeb.RuntimeLive.mount(params, session, bare_socket(outsider))
      end
    end
  end

  describe "a live navigation into a page that names permissions" do
    test "sends a visitor who is not signed in to sign in", %{public: public, members: members} do
      {:ok, view, _html} = live(on_site(), public.path)
      assert {:error, {:redirect, %{to: patched}}} = render_patch(view, members.path)
      assert returns_to(patched) == members.path

      {:ok, view, _html} = live(on_site(), public.path)
      assert {:error, {:redirect, %{to: navigated}}} = live_redirect(view, to: members.path)
      assert returns_to(navigated) == members.path
    end

    test "refuses a user holding none of them", %{site: site, public: public, members: members} do
      Process.flag(:trap_exit, true)
      conn = signed_in(site, ["members:write"])

      {:ok, view, _html} = live(conn, public.path)

      assert {{%NotFoundError{}, _stacktrace}, _call} =
               catch_exit(render_patch(view, members.path))
    end

    test "follows a user holding one of them", %{site: site, public: public, members: members} do
      conn = signed_in(site, ["staff:*"])

      {:ok, view, _html} = live(conn, public.path)
      render_patch(view, members.path)

      assert has_element?(view, "#page-body[data-page='#{members.path}']")
    end
  end

  describe "signing in from a page that sent the visitor there" do
    # `/auth?return_to=…` is the site's sign-in page in its first language, the query kept, and the
    # sign-in that page starts carries `return_to` to the controller.
    test "lands back on that page", %{site: site, members: members} do
      seed_auth_pages!(site)
      user = member!(site, ["members:read"])
      asked = members.path <> "?tab=2"

      "/auth?" <> _query = sign_in_page = redirected_to(get(on_site(), asked))
      assert html_response(get(on_site(), sign_in_page), 200) =~ ~s(id="auth-sign-in-form")

      {:ok, view, _html} = live(on_site(), sign_in_page)

      {:error, {:redirect, %{to: handoff}}} =
        view
        |> form("#auth-sign-in-form", user: %{email: to_string(user.email), password: @password})
        |> render_submit()

      signed_in = get(on_site(), handoff)
      assert redirected_to(signed_in) == asked

      back = signed_in |> Phoenix.ConnTest.recycle() |> with_host() |> get(asked)
      assert has_page?(html_response(back, 200))
    end
  end

  defp published!(site, permissions) do
    page =
      create_page!(
        site_id: site.id,
        path: "/members-#{System.unique_integer([:positive])}",
        template: ~S(<div id="page-body" data-page={@page.path}>page</div>),
        permissions: permissions
      )

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0
      })

    page
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

  defp signed_in(site, permissions) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(member!(site, permissions))
  end

  # A mounting socket carries its connect info — `RuntimeLive.mount/3` reads the visitor's address
  # from it — and this one's names no address.
  defp bare_socket(user) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: MishkaCmsWeb.Endpoint,
      router: MishkaCmsWeb.Router,
      assigns: %{__changed__: %{}, flash: %{}, current_user: user}
    }

    %{socket | private: Map.put(socket.private, :connect_info, %{})}
  end

  # The page to come back to is a signature, not an address, so what the sign-in URL carries is only
  # readable back through `ReturnTo` — which is exactly what the controller will do with it.
  defp returns_to("/auth?" <> query) do
    query
    |> URI.decode_query()
    |> Map.get("return_to")
    |> then(&ReturnTo.verify(@endpoint, &1))
  end

  defp has_page?(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.query("#page-body") |> Enum.any?()

  defp on_site, do: with_host(Phoenix.ConnTest.build_conn())

  defp with_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
