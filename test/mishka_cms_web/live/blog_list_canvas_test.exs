# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.BlogListCanvasTest do
  @moduledoc """
  The blog's live list on the page builder's canvas: its real posts, and its properties edited from
  the Inspector.

  Here rather than in the blog's own suite because it needs both halves at once — the builder, with
  everything an open editing session holds, and the blog's rows and kit.

  ## What the canvas draws, and why that is the right picture

  `CanvasLive` draws a live component cold, through `LiveViewHelpers.static_component/1` — the kit's
  `mount/1`, its `update/2`, then `render/1`. `blog-post-list`'s `update/2` is where it reads the
  site's posts, so the frame shows the first page of the real list rather than a placeholder standing
  in for it. `MishkaCmsCoreWeb.Test.StatefulCanvasTest` pins that path with a toy counter; this is
  the component an author actually drops, against real rows.

  The page binds `base={@page.path}` and `params={@query_params}`, which the canvas does not evaluate.
  So it draws the list's no-base pager, and always page one — the same list, not the same links.

  ## Why a property edit is asserted in the frame

  An edit in the Inspector writes the page's tree; the canvas redraws from a session broadcast and
  runs the kit's own read again. A count of cards is the one thing that proves `per_page` reached
  `update/2`, rather than that a panel showed a number.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @moduletag :integration

  @password "Password123!"

  # A UNIQUE SITE NAME PER TEST, for the reason `MishkaBlog.LiveComponentsRenderTest` gives: a
  # component's module is named from its site's NAME and carries the site's ID, and a reused name
  # renders the previous test's module against a site that test rolled back.
  setup %{conn: conn} do
    SiteState.clear()
    admin_site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    name = "canvastown#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    for cached <- [admin_site, site], do: cache_site(cached)

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    {:ok, _installed} = MishkaBlog.Kit.install!(site.id)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, create_admin("canvas-#{name}@example.com")), site: site}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp publish!(site, count) do
    for index <- 1..count do
      create_blog_post!(
        site_id: site.id,
        title: "Post #{index}",
        status: :published,
        published_at: DateTime.add(~U[2026-01-01 00:00:00Z], index * 86_400, :second)
      )
    end
  end

  defp list_page!(site) do
    create_page!(
      site_id: site.id,
      path: "/posts",
      template:
        ~s(<section id="posts-section"><.component component_name="blog-post-list" site="#{site.name}" id="posts" per_page={6} base={@page.path} params={@query_params} /></section>)
    )
  end

  # AN EXPLICIT BOUND, not the suite's default. What is being waited for is the editor's `start_async`
  # record fetch — a real database read — and on a machine running the rest of this suite beside it
  # that takes longer than a second, which failed this test from a line that was asserting something
  # else. A longer wait only ever delays a failure; it never slows a passing run.
  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    _settled = render_async(view, 5_000)
    view
  end

  # The editor session the builder opened, read off the canvas frame it points at.
  defp token(view) do
    [_all, token] = Regex.run(~r{/runtime/builder-canvas/([^"/]+)"}, render(view))
    token
  end

  defp canvas(conn, view) do
    {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
    canvas
  end

  defp list_node(view) do
    {:ok, editor} = EditorSession.fetch(token(view))

    editor.tree
    |> Tree.walk()
    |> Enum.find(&(Node.component_name(&1) == "blog-post-list"))
  end

  defp texts(canvas, selector) do
    canvas
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  describe "blog-post-list on the canvas" do
    test "draws the site's first page of real posts", %{conn: conn, site: site} do
      publish!(site, 7)
      view = open_builder(conn, list_page!(site))
      canvas = canvas(conn, view)

      assert has_element?(canvas, ~s([data-node-id][data-pb-live="blog-post-list"])),
             "the live list is not marked for the canvas's live chip"

      assert length(texts(canvas, ~s([data-role="blog-list-item"]))) == 6
      assert texts(canvas, ~s([data-role="blog-list-position"])) == ["1 / 2"]
      assert hd(texts(canvas, ~s([data-role="blog-list-title"]))) == "Post 7"
      assert texts(canvas, ~s([data-role="blog-list-heading"])) == ["Latest posts"]

      refute has_element?(canvas, "[data-render-error]"),
             "the canvas drew the refusal instead of the component"

      refute has_element?(canvas, ".text-red-600", "failed to render"),
             "a component the list draws itself with fell back to the runtime's placeholder"
    end

    test "redraws with what the Inspector sets", %{conn: conn, site: site} do
      publish!(site, 7)
      view = open_builder(conn, list_page!(site))
      canvas = canvas(conn, view)
      node = list_node(view)

      render_click(view, "select", %{"id" => node.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      view
      |> form("#pb-attr-form-#{node.id}-per_page", %{"value" => "3"})
      |> render_change()

      assert length(texts(canvas, ~s([data-role="blog-list-item"]))) == 3,
             "per_page did not reach the component's own read"

      assert texts(canvas, ~s([data-role="blog-list-position"])) == ["1 / 3"]

      view
      |> form("#pb-attr-form-#{node.id}-heading", %{"value" => "From the desk"})
      |> render_change()

      assert texts(canvas, ~s([data-role="blog-list-heading"])) == ["From the desk"]
    end
  end
end
