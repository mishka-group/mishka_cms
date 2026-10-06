defmodule MishkaCmsWeb.PagePermissionRecheckTest do
  @moduledoc """
  A database page keeps asking who is reading it, after the mount that let them in.

  `MishkaCmsWeb.RuntimeLive` asks a page's permissions in `mount/3` and in `handle_params/3`, and
  somebody sitting on a page runs neither. Two things now happen anyway:

  * the page's own row is watched, so an admin who closes a page to the public sends away everyone
    already on it — judged by the permissions that write left on the row, which is fresher than the
    compiled module the socket is still rendering, and the module is brought up to that row before
    anybody is sent anywhere;
  * an event is re-authorized before the page acts on it, against the visitor read again at that
    moment rather than the one the mount loaded, so the moment between a permission being taken away
    and the socket being cut cannot be used to do anything.

  Both ask `MishkaCmsCore.Accounts.Checks.AccessPermissions`, the check every other gate asks, and
  both answer a refusal by sending the browser back to the address — where `mount/3` gives the site's
  403 or the sign-in, exactly as it would to somebody arriving a second later. That is a refusal only
  because the module the mount reads has already been made to agree with the row; the request that
  answers the refusal is asserted here, not just the redirect.

  `async: false` — the install flag, `SiteState` and the routing table are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCoreWeb.ReturnTo

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

    %{site: site, public: published!(site, []), members: published!(site, ["members:read"])}
  end

  describe "a page whose permissions change while it is being read" do
    test "sends away the viewer who no longer holds one", %{site: site, members: members} do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)

      permissions!(members, ["staff:*"])

      assert_redirect(view, members.path)
    end

    test "leaves the viewer who still holds one", %{site: site, members: members} do
      {:ok, view, _html} = live(signed_in(site, ["members:read", "staff:*"]), members.path)

      permissions!(members, ["staff:*"])

      assert has_element?(view, "#page-body")
      refute_redirected(view, members.path)
    end

    test "sends away everyone on a page that stops being public", %{public: public} do
      {:ok, view, _html} = live(on_site(), public.path)

      permissions!(public, ["members:read"])

      assert_redirect(view, public.path)
    end

    # A REFUSAL THAT SENDS THE BROWSER BACK TO THE ADDRESS IS ONLY A REFUSAL IF THE REQUEST THAT
    # ANSWERS IT REFUSES TOO. `mount/3` judges by the compiled module and the write only queued the
    # recompile, so without the alignment the visitor just sent away is admitted again one request
    # later — the re-check would cost a page reload and nothing else.
    test "refuses the request that answers the refusal", %{public: public} do
      {:ok, view, _html} = live(on_site(), public.path)

      permissions!(public, ["members:read"])
      assert_redirect(view, public.path)

      assert {:error, {:redirect, %{to: sign_in}}} = live(on_site(), public.path)
      assert returns_to(sign_in) == public.path
    end

    test "gives the signed-in viewer the site's 404 on that request", %{
      site: site,
      public: public
    } do
      user = member!(site, [])
      {:ok, view, _html} = live(signed_in_as(user), public.path)

      permissions!(public, ["members:read"])
      assert_redirect(view, public.path)

      assert_raise NotFoundError, fn -> live(signed_in_as(user), public.path) end
    end

    # THE MODULE IS THE ONE SOURCE THE OTHER THREE CALLBACKS READ — `mount/3`, `handle_params/3` and
    # `handle_event/3` all ask `__page_information__/1` — so the re-check leaves it saying what the
    # row says rather than answering from a second, fresher one of its own.
    test "brings the compiled module up to the row the write left", %{
      site: site,
      members: members
    } do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)

      permissions!(members, ["staff:*"])
      assert_redirect(view, members.path)

      assert page_module(site, members).__page_information__([:acl, :permissions]) == ["staff:*"]
    end

    # AND ONLY THEN. A save that leaves the permissions alone is the common one, and it waits for the
    # queued recompile exactly as it always did.
    test "leaves the module alone when the write says the same about permissions", %{
      site: site,
      members: members
    } do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)
      watch_recompiles()

      described!(members, "A page with a new description")

      assert has_element?(view, "#page-body")
      refute_received {:page_recompiled, _metadata}
    end

    # A COLUMN LEFT NULL IS A PUBLIC PAGE — what `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler`
    # makes of it for `mount/3` — so a save that writes one must not throw a public page's readers
    # off, only for the mount that answers to let them straight back in.
    test "leaves everyone on a page whose permissions are written as null", %{public: public} do
      {:ok, view, _html} = live(on_site(), public.path)

      permissions!(public, nil)

      assert has_element?(view, "#page-body")
      refute_redirected(view, public.path)
    end

    test "leaves everyone on a page that becomes public", %{site: site, members: members} do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)

      permissions!(members, [])

      assert has_element?(view, "#page-body")
      refute_redirected(view, members.path)
    end

    test "carries the query the visitor asked with back to the address", %{
      site: site,
      members: members
    } do
      asked = members.path <> "?tab=2"
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), asked)

      permissions!(members, ["staff:*"])

      assert_redirect(view, asked)
    end

    # A WRITE THAT DOES NOT SAY WHAT THE PAGE NOW ASKS FOR is a page whose permissions could not be
    # read, which `mount/3` refuses rather than serves — so does this, even for the viewer who was
    # holding the right one a moment ago.
    test "sends away the viewer when the write does not say what the page asks for", %{
      site: site,
      members: members
    } do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)

      MishkaCmsWeb.Endpoint.broadcast(
        "page:#{site.id}:updated",
        "update",
        %Ash.Notifier.Notification{
          resource: MishkaCmsCore.Runtime.Page,
          data: %{id: members.id}
        }
      )

      assert_redirect(view, members.path)
    end

    # AND THE PAGE NEVER HEARS ABOUT IT. The subscription is the site's, so every page's writes reach
    # every socket of that site; a write about another page is dropped rather than handed on to the
    # page's own `handle_info/2`, which is what the span below would record.
    test "leaves a viewer of another page of the same site alone", %{
      public: public,
      members: members
    } do
      {:ok, view, _html} = live(on_site(), public.path)
      watch_page_infos()

      permissions!(members, ["staff:*"])

      assert has_element?(view, "#page-body")
      refute_redirected(view, public.path)
      refute_received {:page_handled_info, _metadata}
    end

    # ONLY THE SUBSCRIPTION `mount/3` MADE IS READ AS A PAGE WRITE. `MishkaCmsCore.Runtime.Page`
    # publishes `created` and `destroyed` under the same payload shape as `updated`, and a page that
    # listens for one of those — a menu of the site's pages, a plugin — must still be handed it.
    test "hands the page a page notification that arrived on another topic", %{
      site: site,
      public: public,
      members: members
    } do
      {:ok, view, _html} = live(on_site(), public.path)
      watch_page_infos()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "page:#{site.id}:created",
        event: "create",
        payload: %Ash.Notifier.Notification{
          resource: MishkaCmsCore.Runtime.Page,
          data: %{id: members.id, permissions: ["staff:*"]}
        }
      })

      assert has_element?(view, "#page-body")
      assert_received {:page_handled_info, _metadata}
    end
  end

  describe "an event on a page that names permissions" do
    test "is refused once the visitor's permission is gone", %{site: site, members: members} do
      user = member!(site, ["members:read"])
      {:ok, view, _html} = live(signed_in_as(user), members.path)

      assert has_element?(view, "#page-body")

      grant!(user, [], site)

      assert {:error, {:redirect, %{to: address}}} = render_click(view, "anything", %{})
      assert address == members.path
    end

    # The permission is untouched here: what the visitor no longer has is a session. Signing out in
    # another tab revokes the token this socket's session holds, so the visitor the re-check reads is
    # nobody — refused exactly as a visitor holding none of the permissions is.
    test "is refused once the session's token has been revoked", %{site: site, members: members} do
      user = member!(site, ["members:read"])
      {:ok, view, _html} = live(signed_in_as(user), members.path)

      assert has_element?(view, "#page-body")

      MishkaCmsCore.Accounts.User
      |> Ash.ActionInput.for_action(:logout, %{token: user.__metadata__.token},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.run_action!()

      assert {:error, {:redirect, %{to: address}}} = render_click(view, "anything", %{})
      assert address == members.path
    end

    test "is answered while the visitor still holds one", %{site: site, members: members} do
      {:ok, view, _html} = live(signed_in(site, ["members:read"]), members.path)

      assert render_click(view, "anything", %{}) =~ "page-body"
    end

    test "is answered on a page that names none", %{public: public} do
      {:ok, view, _html} = live(on_site(), public.path)

      assert render_click(view, "anything", %{}) =~ "page-body"
    end
  end

  # Every message `MishkaCmsWeb.RuntimeLive` passes on to the page it is showing runs inside this
  # span, so an absent one is a message the page was never given.
  defp watch_page_infos do
    handler = "page-infos-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms, :runtime, :handle_info, :start],
      fn _event, _measurements, metadata, _config ->
        send(test, {:page_handled_info, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A page compiled again carries this, so an absent one is a page whose module was left as it was.
  defp watch_recompiles do
    handler = "page-recompiles-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms, :runtime, :handlers, :module_compiler, :start],
      fn _event, _measurements, metadata, _config ->
        if metadata[:type] == :update, do: send(test, {:page_recompiled, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp page_module(site, page), do: Helpers.module_name(page.id, site.name, "Page")

  defp permissions!(page, permissions), do: written!(page, %{permissions: permissions})

  defp described!(page, description), do: written!(page, %{description: description})

  defp written!(page, params) do
    page
    |> Ash.Changeset.for_update(:update, params,
      authorize?: false,
      tenant: page.site_id,
      context: %{page_code: :package}
    )
    |> Ash.update!()
  end

  defp returns_to("/auth?" <> query) do
    query
    |> URI.decode_query()
    |> Map.get("return_to")
    |> then(&ReturnTo.verify(@endpoint, &1))
  end

  defp published!(site, permissions) do
    page =
      create_page!(
        site_id: site.id,
        path: "/en/members-#{System.unique_integer([:positive])}",
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

  defp signed_in(site, permissions), do: signed_in_as(member!(site, permissions))

  defp signed_in_as(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp on_site, do: with_host(Phoenix.ConnTest.build_conn())

  defp with_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
