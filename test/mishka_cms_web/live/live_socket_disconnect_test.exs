# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.LiveSocketDisconnectTest do
  @moduledoc """
  A live socket does not outlive the authorization it was opened with.

  A signed-in visitor's sockets are named `users_sessions:<user id>`, written into the session at
  sign-in, and a `"disconnect"` broadcast on that name shuts every one of them down — the mechanism
  the LiveView security guide describes. What fires it is
  `MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets`, at the resource layer, so the admin form,
  a JSON:API request and in-app code all reach it.

  These tests assert the contract: the name is in the session after a sign-in, and the broadcast
  goes out for every write that can shrink what a user may do or end their being signed in. The
  shutdown itself belongs to `Phoenix.Socket`, which `Phoenix.LiveViewTest` does not run — what is
  testable here is that the right topic is told, which is the whole of this application's part.

  `async: false` — the install flag and `SiteState` are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{LiveSockets, Permission, User}
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"

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

    %{site: site}
  end

  # The site's sign-in pages, for the tests that sign in through them.
  defp sign_in_pages(%{site: site}) do
    seed_auth_pages!(site)
    :ok
  end

  describe "the name a visitor's sockets answer to" do
    setup :sign_in_pages

    test "is written into the session by a sign-in", %{site: site} do
      user = member!(site, [])

      assert Plug.Conn.get_session(sign_in(user), "live_socket_id") ==
               LiveSockets.live_socket_id(user)
    end

    test "is one name for the account, whichever way it is asked for", %{site: site} do
      user = member!(site, [])

      assert LiveSockets.live_socket_id(user) == LiveSockets.live_socket_id(user.id)
      assert LiveSockets.live_socket_id(user) == "users_sessions:#{user.id}"
    end
  end

  describe "signing out" do
    setup :sign_in_pages

    test "cuts the sockets of the session that asked", %{site: site} do
      user = member!(site, [])
      watch(user)

      conn = user |> sign_in() |> Phoenix.ConnTest.recycle() |> with_host()

      assert redirected_to(delete(conn, "/auth/sign-out")) == "/"
      assert_disconnected(user)
    end

    test "leaves the session with nothing to reconnect under", %{site: site} do
      conn =
        site
        |> member!([])
        |> sign_in()
        |> Phoenix.ConnTest.recycle()
        |> with_host()
        |> delete("/auth/sign-out")

      assert Plug.Conn.get_session(conn, "live_socket_id") == nil
    end

    test "cuts nobody's when nobody was signed in" do
      MishkaCmsWeb.Endpoint.subscribe("users_sessions:anonymous")

      assert redirected_to(delete(on_site(), "/auth/sign-out")) == "/"
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
    end
  end

  describe "the API sign-out" do
    test "cuts the sockets of the account whose token it revokes", %{site: site} do
      user = member!(site, [])
      watch(user)

      log_out!(user, site)

      assert_disconnected(user)
    end

    # The action is open to anyone, so what it is asked with is the whole of its evidence: a token
    # this application has already revoked, or never signed, names nobody — otherwise a stranger
    # could keep an account reconnecting by handing over a string with its id in it.
    test "cuts nobody's a second time, with the token it already revoked", %{site: site} do
      user = member!(site, [])
      watch(user)

      log_out!(user, site)
      assert_disconnected(user)

      log_out!(user, site)
      refute_disconnected(user)
    end

    test "cuts nobody's for a token this application did not sign", %{site: site} do
      user = member!(site, [])
      watch(user)

      MishkaCmsCore.Accounts.User
      |> Ash.ActionInput.for_action(:logout, %{token: "user?id=#{user.id}"},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.run_action!()

      refute_disconnected(user)
    end

    # THE TOKEN NAMES THE ACCOUNT, NOT THE REQUEST. `POST /logout` sits in the router's `:api`
    # pipeline, which sets an actor from the caller's own bearer token, and the action is open to
    # anyone — so the token a caller hands over and the account it is acting as routinely differ.
    # Revoking one account's token while cutting another's sockets is the hole this whole file is
    # about, pointed the wrong way.
    test "cuts the sockets of the token's account, not the caller's", %{site: site} do
      caller = member!(site, [])
      holder = member!(site, [])
      watch(caller)
      watch(holder)

      User
      |> Ash.ActionInput.for_action(:logout, %{token: holder.__metadata__.token},
        authorize?: false,
        actor: caller,
        tenant: site.id
      )
      |> Ash.run_action!()

      assert_disconnected(holder)
      refute_disconnected(caller)
    end

    # The site a token was issued for is a claim of the token, so the request does not have to carry
    # it — and `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` deliberately gives none for a master
    # host or for `x-no-tenant`. The token was revoked either way; the sockets have to go with it.
    test "cuts them for a tenant user when the request carries no tenant", %{site: site} do
      user = member!(site, [])
      watch(user)

      User
      |> Ash.ActionInput.for_action(:logout, %{token: user.__metadata__.token}, authorize?: false)
      |> Ash.run_action!()

      assert_disconnected(user)
    end
  end

  describe "a write that changes what a user may reach" do
    test "cuts their sockets when a permission is taken away", %{site: site} do
      user = member!(site, ["members:read"])
      watch(user)

      user
      |> Ash.Changeset.for_update(
        :remove_permission,
        %{permission_id: permission!("members:read").id},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

      assert_disconnected(user)
    end

    test "cuts their sockets when a permission is added", %{site: site} do
      user = member!(site, [])
      watch(user)

      user
      |> Ash.Changeset.for_update(
        :add_permission,
        %{permission_id: permission!("members:read").id},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

      assert_disconnected(user)
    end

    test "cuts their sockets when the whole list is replaced", %{site: site} do
      user = member!(site, ["members:read"])
      watch(user)

      grant!(user, ["staff:*"], site)

      assert_disconnected(user)
    end

    test "cuts the sockets of everyone holding a permission that is deleted", %{site: site} do
      holder = member!(site, ["members:read"])
      other = member!(site, ["staff:*"])
      watch(holder)
      watch(other)

      permission!("members:read")
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      assert_disconnected(holder)
      refute_disconnected(other)
    end

    test "cuts the sockets of everyone holding a permission that is renamed", %{site: site} do
      holder = member!(site, ["members:read"])
      watch(holder)

      permission!("members:read")
      |> Ash.Changeset.for_update(:update, %{name: "members:write"}, authorize?: false)
      |> Ash.update!()

      assert_disconnected(holder)
    end
  end

  describe "a write that ends a user's being signed in" do
    test "cuts their sockets when the password changes", %{site: site} do
      user = member!(site, [])
      watch(user)

      user
      |> Ash.Changeset.for_update(
        :change_password,
        %{
          current_password: @password,
          password: "AnotherPassword1!",
          password_confirmation: "AnotherPassword1!"
        },
        authorize?: false,
        actor: user,
        tenant: site.id
      )
      |> Ash.update!()

      assert_disconnected(user)
    end

    test "cuts their sockets when the account is deleted", %{site: site} do
      user = member!(site, [])
      watch(user)

      user
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false, tenant: site.id)
      |> Ash.destroy!()

      assert_disconnected(user)
    end
  end

  describe "a write that cannot be read" do
    # An update is judged by the attributes its changeset wrote, and a notification that carries no
    # changeset leaves nothing to judge by. Cutting is the answer that cannot be wrong: the sockets
    # entitled to be there come straight back.
    test "cuts the sockets of a user whose update says nothing about itself", %{site: site} do
      user = member!(site, [])
      watch(user)

      :ok =
        MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets.notify(%Ash.Notifier.Notification{
          resource: User,
          action: %{type: :update},
          data: %{id: user.id}
        })

      assert_disconnected(user)
    end
  end

  describe "a write that changes neither" do
    test "leaves the sockets of a user whose address was corrected", %{site: site} do
      user = member!(site, ["admin:dashboard:*"])
      watch(user)

      user
      |> Ash.Changeset.for_update(
        :update,
        %{email: "renamed-#{System.unique_integer([:positive])}@example.com"},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

      refute_disconnected(user)
    end

    test "leaves the sockets of a user whose permissions were written again unchanged", %{
      site: site
    } do
      user = member!(site, ["admin:dashboard:*"])
      watch(user)

      grant!(user, ["admin:dashboard:*"], site)

      refute_disconnected(user)
    end

    # `MishkaCmsCore.Accounts.Checks.AccessPermissions` reads nothing of a permission but its name, so
    # a description cannot take anybody's access away — and a permission held by every signed-in
    # account would otherwise cost a read of every grant row and a reconnect for every holder, from a
    # typo fix.
    test "leaves the sockets of a permission's holders when only its description changes", %{
      site: site
    } do
      holder = member!(site, ["members:read"])
      watch(holder)

      permission!("members:read")
      |> Ash.Changeset.for_update(:update, %{description: "A note about this permission"},
        authorize?: false
      )
      |> Ash.update!()

      refute_disconnected(holder)
    end

    test "leaves the sockets of everyone else when one user's permissions change", %{site: site} do
      changed = member!(site, ["members:read"])
      bystander = member!(site, ["admin:dashboard:*"])
      watch(bystander)

      grant!(changed, [], site)

      refute_disconnected(bystander)
    end
  end

  defp watch(user), do: MishkaCmsWeb.Endpoint.subscribe(LiveSockets.live_socket_id(user))

  defp log_out!(user, site) do
    User
    |> Ash.ActionInput.for_action(:logout, %{token: user.__metadata__.token},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.run_action!()
  end

  defp assert_disconnected(user) do
    topic = LiveSockets.live_socket_id(user)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  defp refute_disconnected(user) do
    topic = LiveSockets.live_socket_id(user)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 300
  end

  defp member!(site, permissions) do
    user = create_user!(site_id: site.id)
    grant!(user, permissions, site)
    user
  end

  defp grant!(user, permissions, site) do
    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(permissions, &permission!(&1).id)},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  # A real sign-in through the site's sign-in page and the controller, because putting
  # `live_socket_id` in the session is the controller's job and storing a token by hand would skip it.
  defp sign_in(%User{} = user) do
    {:ok, view, _html} = live(on_site(), "/auth")

    {:error, {:redirect, %{to: handoff}}} =
      view
      |> form("#auth-sign-in-form", user: %{email: to_string(user.email), password: @password})
      |> render_submit()

    get(on_site(), handoff)
  end

  defp on_site, do: with_host(Phoenix.ConnTest.build_conn())

  defp with_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
