# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PagePreviewRouteTest do
  @moduledoc """
  `/_preview/page/:token` serves a LIVE page, not only a draft — and it answers on whatever host the
  admin is reached at.

  That second half is the whole reason this exists. The inspector's Preview tab used to frame a
  page at its own site's URL, and a site's domain is not necessarily the machine you are editing on:
  in this project `api.mishka.tools` resolves to a public IP while the record lives on the
  developer's build. The frame was refused by the admin's `frame-src 'self'`, and relaxing that
  policy would have made it worse — an empty frame at least does not pretend to be the page.

  The route resolves the record from its TOKEN, so the Host header is not part of the answer. The
  test asserts exactly that by asking for a page owned by one site over a *different* site's host,
  which is also the shape of "a master administering site A previews site B".

  See `MishkaCmsWeb.DraftPreviewLive` and
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.frame_url/1`.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # Over thirty seconds on its own: left out of a pull request, see test/test_helper.exs.
  @moduletag :slow

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCms.Test.EventCannotRun
  alias MishkaCmsCore.Accounts.{LiveSockets, Permission}
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, Page, PageDraft}
  alias MishkaCmsCore.Runtime.Resources.Embeddeds.Helper
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  setup do
    SiteState.clear()

    admin = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other = create_site!(name: "elsewhere", host: "elsewhere.test", active: true)
    third = create_site!(name: "third", host: "third.test", active: true)

    for site <- [admin, other, third] do
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })
    end

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    MishkaCmsCore.Settings.put("cms.offline", false)

    %{admin: admin, other: other, third: third}
  end

  defp on_host(host) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  describe "a live page's preview token" do
    test "is minted on create, so every page has a preview route", %{other: site} do
      page = create_page!(site_id: site.id, template: "<b>x</b>")

      assert page.preview_token =~ ~r/\A[A-Za-z0-9_-]+\z/, "not url-safe base64"

      assert byte_size(page.preview_token) == 43,
             "not 32 random bytes of url-safe base64 — the shape the other resources use"
    end

    test "and two pages never share one", %{other: site} do
      a = create_page!(site_id: site.id)
      b = create_page!(site_id: site.id)

      assert a.preview_token != b.preview_token
    end
  end

  describe "GET /_preview/page/:token" do
    test "renders the page's own template", %{other: site} do
      page = create_page!(site_id: site.id, template: ~s(<b class="preview-probe">rendered</b>))

      {:ok, _view, html} = live(on_host("elsewhere.test"), "/_preview/page/#{page.preview_token}")

      assert html =~ "preview-probe"
      assert html =~ "rendered"
    end

    # AN INTERACTION IS THE ONE INSPECTOR FEATURE THAT DOES NOTHING IN THE EDITOR. The canvas is a
    # rendering of the document, not the document running — so "On click → toggle a class" can only
    # be judged where the page actually runs, and until now nothing checked that it survived the
    # trip. The preview route IS that place, and it is the URL the Preview tab opens.
    test "an on-click interaction survives into the preview and is a real command", %{other: site} do
      page =
        create_page!(
          site_id: site.id,
          template: """
          <button class="pb-7f3a91b2" phx-click={Phoenix.LiveView.JS.toggle_class("is-open", to: ".pb-7f3a91b2")}>
            Open
          </button>
          """
        )

      {:ok, _view, html} = live(on_host("elsewhere.test"), "/_preview/page/#{page.preview_token}")

      # Rendered as a real `phx-click`, carrying the command LiveView's client executes — not as the
      # literal text of the expression, which is what a template that failed to compile would show.
      assert html =~ "phx-click="
      assert html =~ "toggle_class"
      assert html =~ "is-open"
      assert html =~ "pb-7f3a91b2"
      refute html =~ "JS.toggle_class", "the expression was printed instead of evaluated"
    end

    # AND THE WORDS OF A MESSAGE ARE THE RISKIEST THING THE EDITOR WRITES. "Show a message" puts an
    # author's own sentence into generated source inside a quoted string, and that source is compiled
    # by `Phoenix.LiveView.TagEngine` when the page is rendered — so a quote, a backslash or a `\#{`
    # in it is not a curiosity. This renders one through a real page.
    #
    # What the preview cannot show is the message itself: a page's server-side handlers never run
    # here, which is why a form does nothing on this route either. See this module's own note, and
    # `MishkaCmsCore.Runtime.PageMessage` for where the flash is answered.
    test "a message with everything in it compiles and renders as a real command", %{other: site} do
      said = ~S[She said "yes" \ twice] <> " — " <> <<35>> <> "{cost}"

      page =
        create_page!(
          site_id: site.id,
          template: """
          <button id="say-hello" phx-click={#{MishkaCmsCore.Runtime.PageBuilder.Interactions.source("say", "pb-7f3a91b2", %{kind: "info", message: said})}}>
            Send
          </button>
          """
        )

      {:ok, _view, html} = live(on_host("elsewhere.test"), "/_preview/page/#{page.preview_token}")

      assert html =~ ~s(phx-click=), "the expression did not compile into a command"
      assert html =~ "pb:say"
      refute html =~ "JS.push", "the expression was printed instead of evaluated"

      assert html =~ <<35>> <> "{cost}",
             "the interpolation was evaluated instead of being carried as characters"
    end

    # A MASTER PREVIEWING SOMEBODY ELSE'S SITE MUST GET THAT SITE'S ASSETS. The record is resolved by
    # its token, so the Host header plays no part — and the site the assets come from has to be the
    # RECORD'S, not the host's and not the master's own. Get that wrong and the page renders with a
    # stranger's stylesheet and a stranger's hooks: every `phx-hook` on it is then a name the socket
    # was never given, which the browser reports as `unknown hook found for "…"` and nothing else.
    #
    # This is the shape that was reported — master, on the admin's host, previewing `elsewhere`.
    test "the assets come from the record's site, not the host's", %{admin: admin, other: site} do
      # BOTH SITES HAVE A BUNDLE, so choosing the wrong one is visible. With only one in the table
      # the assertion would pass on an empty answer and prove nothing.
      for {s, hash} <- [{admin, "aaaaaaaa"}, {site, "bbbbbbbb"}] do
        AssetsState.save(%{
          id: s.name,
          type: "js",
          value: %{js: "// #{s.name}"},
          hash: hash,
          updated_at: DateTime.utc_now()
        })
      end

      page = create_page!(site_id: site.id, template: ~s(<b>x</b>))

      {:ok, _view, html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      # The per-draft stylesheet, compiled from this record — never a site bundle, never public.css.
      assert html =~ "/_preview/page/#{page.preview_token}/css"

      # And the JS, which is where the hooks come from, is the RECORD's site's.
      js = preview_site_js(html)

      assert js == "/assets/js/#{site.name}/bbbbbbbb.js?preview=#{page.preview_token}",
             "the preview served #{inspect(js)} rather than #{site.name}'s bundle"

      refute js =~ "/assets/js/#{admin.name}/",
             "the preview served the HOST's bundle, so every hook on the page would be unknown"
    end

    # AND THE HOOK, which is the other half of the same question: a `phx-hook` is inert unless the
    # element also carries an id, and a preview that drops either gives the author a page that looks
    # right and does nothing.
    test "a JS hook reaches the preview with the id it needs", %{other: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="probe-hook" phx-hook="LocalhostClipboard" data-clipboard-text="x">C</div>)
        )

      {:ok, _view, html} = live(on_host("elsewhere.test"), "/_preview/page/#{page.preview_token}")

      assert html =~ ~s(phx-hook="LocalhostClipboard")
      assert html =~ ~s(id="probe-hook")
      assert html =~ ~s(data-clipboard-text="x")
    end

    # THE POINT. The page belongs to `elsewhere.test`; the request arrives on the admin's own host.
    # If the Host header were part of resolving the record this would 404 — and the Preview tab,
    # which now frames exactly this URL, would show nothing.
    test "answers over a DIFFERENT site's host, because the token resolves the record", %{
      other: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<i class="cross-origin-probe">ok</i>))

      {:ok, _view, html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      assert html =~ "cross-origin-probe",
             "a page could not be previewed from the admin's host — cross-site preview is broken"
    end

    # A PREVIEW OF SITE A IS NEVER SHOWN ON SITE B. The master site's address and the record's own
    # serve it; another site's is refused like an unknown token, and its stylesheet with it.
    test "but not over a third site's host", %{other: site} do
      page = create_page!(site_id: site.id, template: ~s(<i class="third-probe">ok</i>))
      token = page.preview_token
      on_exit(fn -> DraftPreviewAssets.purge(page) end)

      {:ok, _view, _html} = live(on_host("elsewhere.test"), "/_preview/page/#{token}")

      assert_raise NotFoundError, fn -> live(on_host("third.test"), "/_preview/page/#{token}") end

      :ok =
        AssetsState.save(%{
          id: token,
          type: "css",
          value: "/* preview */",
          hash: "p",
          updated_at: DateTime.utc_now()
        })

      assert ("third.test" |> on_host() |> get("/_preview/page/#{token}/css")).status == 404
      assert "elsewhere.test" |> on_host() |> get("/_preview/page/#{token}/css") |> response(200)
      assert "localhost" |> on_host() |> get("/_preview/page/#{token}/css") |> response(200)
    end

    test "while a global record is shown on any site's host" do
      layout =
        create_layout!(template: ~s(<main class="global-third-probe">{@inner_content}</main>))

      on_exit(fn -> DraftPreviewAssets.purge(layout) end)

      for host <- ["third.test", "localhost"] do
        {:ok, _view, html} = live(on_host(host), "/_preview/layout/#{layout.preview_token}")
        assert html =~ "global-third-probe", host
      end
    end

    test "and an unknown token is not found", %{admin: _admin} do
      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        live(on_host("localhost"), "/_preview/page/definitely-not-a-token")
      end
    end

    test "and an unknown token's stylesheet is not found while web:request:preview_unavailable cannot run" do
      EventCannotRun.stub!("web:request:preview_unavailable")

      refused = "localhost" |> on_host() |> get("/_preview/page/definitely-not-a-token/css")

      assert refused.status == 404
      assert get_resp_header(refused, "cache-control") == ["no-store"]
    end

    # A live page carries no draft banner — there is nothing temporary about it. The banner's CSS
    # RULE rides along on every preview (one nonced `<style>` serves both cases), so the element is
    # what to look for, not the name.
    test "a draft whose page changed after it was made says so in its banner", %{other: site} do
      page = create_page!(site_id: site.id, template: "<b>live</b>")

      draft =
        PageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: page.name,
            title: page.title,
            path: page.path,
            template: "<b>draft</b>",
            source_page_id: page.id
          },
          tenant: site.id
        )
        |> Ash.Changeset.force_change_attribute(
          :source_hash,
          MishkaCmsCore.Runtime.PageBuilder.Drafts.hash("page", page)
        )
        |> Ash.create!(authorize?: false)

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{draft.preview_token}")
      assert has_element?(view, "#mishka-draft-banner")
      refute has_element?(view, "#mishka-draft-original-changed")

      page
      |> Ash.Changeset.for_update(:update, %{title: "Changed elsewhere"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{draft.preview_token}")
      assert has_element?(view, "#mishka-draft-original-changed")
    end

    test "a live page is not labelled a draft", %{other: site} do
      page = create_page!(site_id: site.id, template: "<b>x</b>")

      {:ok, _view, html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      refute html =~ ~s(id="mishka-draft-banner")
    end
  end

  describe "a page or a layout is drawn by its compiled module" do
    test "a page calling its own helper renders, where a template alone could not call it", %{
      other: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~S|<p id="helper-probe">{shout("hi")}</p>|,
          helpers: [%Helper{name: "shout", args: "word", code: "String.upcase(word)"}]
        )

      {:ok, view, html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      assert has_element?(view, "#helper-probe", "HI")
      refute html =~ "Preview unavailable"
    end

    test "a page that declares an upload draws its file input", %{other: site} do
      page =
        create_page!(
          site_id: site.id,
          uploads: [%{name: "attachment", accept: "image/*", max_entries: 2}],
          template:
            ~S|<form id="up" phx-change="v"><.live_file_input upload={@uploads.attachment} /></form>|
        )

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      assert has_element?(view, "#up input[type=file]")
    end

    test "a layout calling its own helper renders around its example", %{other: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~S|<main id="layout-probe"><b>{mark()}</b>{@inner_content}</main>|,
          helpers: [%Helper{name: "mark", args: "", code: ~S|"*"|}],
          example: ~s(<i id="example-probe">page</i>)
        )

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/layout/#{layout.preview_token}")

      assert has_element?(view, "#layout-probe b", "*")
      assert has_element?(view, "#layout-probe #example-probe", "page")
    end

    test "a page is drawn inside its layout, as a visitor gets it", %{other: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~S|<header id="layout-probe">{mark()}</header><main>{@inner_content}</main>|,
          helpers: [%Helper{name: "mark", args: "", code: ~S|"Shell"|}]
        )

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<p id="page-probe">Page</p>),
          layout_id: layout.id
        )

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      assert has_element?(view, "#layout-probe", "Shell")
      assert has_element?(view, "main #page-probe", "Page")
    end

    test "the sign-in pages render with their own helpers and Ash's live components", %{
      other: site
    } do
      seed_auth_pages!(site)

      for name <- ["auth-sign-in", "auth-password-reset", "auth-register", "auth-magic-link"] do
        page =
          Page
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(site_id == ^site.id and name == ^name)
          |> Ash.read_one!(authorize?: false)

        {:ok, _view, html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

        refute html =~ "Preview unavailable", "#{name} did not render: #{html}"
        assert html =~ "<form", "#{name} drew no form"
      end
    end

    test "the page's handlers never run, so a form submits nothing", %{other: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~S"""
          <form id="probe-form" phx-submit="save"><b id="saved">{assigns[:saved] || "no"}</b></form>
          """,
          events: [%{name: "save", code: "{:noreply, assign(socket, :saved, \"yes\")}"}]
        )

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")

      render_submit(view |> element("#probe-form"), %{})

      assert has_element?(view, "#saved", "no")
    end

    test "closing the preview unloads its module", %{other: site} do
      page = create_page!(site_id: site.id, template: "<b>x</b>")

      {:ok, view, _html} = live(on_host("localhost"), "/_preview/page/#{page.preview_token}")
      %{value: module} = AssetsState.get!(page.preview_token, "module")
      assert :erlang.module_loaded(module)

      Process.unlink(view.pid)
      GenServer.stop(view.pid)

      refute :erlang.module_loaded(module)
    end
  end

  # A site that can be switched off or taken offline, with admins and users of its own. The preview
  # reads who is looking from the viewer cache a page load leaves, so that is what these write; the
  # stylesheet route reads the signed-in user, so `signed_in/2` signs them in for real.
  describe "the record's site decides who may preview it" do
    setup do
      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)

      closed = create_site!(name: "closed", host: "closed.test", active: true)
      cache!(closed, true)

      %{
        closed: closed,
        page: create_page!(site_id: closed.id, template: ~s(<i class="kept">x</i>))
      }
    end

    defp cache!(site, active?) do
      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: active?
        })
    end

    defp offline!(site), do: {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

    defp user!(site_id, permissions) do
      ids =
        Enum.map(permissions, fn name ->
          case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
            {:ok, nil} -> create_permission!(name: name).id
            {:ok, permission} -> permission.id
          end
        end)

      create_user!(site_id: site_id)
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids},
        authorize?: false,
        tenant: site_id
      )
      |> Ash.update!()
      |> Ash.load!([:permissions], authorize?: false, tenant: site_id)
    end

    defp as_viewer(conn, nil), do: conn

    defp as_viewer(conn, user) do
      ViewerState.remember(user)
      on_exit(fn -> ViewerState.forget(user.id) end)
      Plug.Test.init_test_session(conn, %{"live_socket_id" => LiveSockets.live_socket_id(user)})
    end

    defp signed_in(conn, %{site_id: nil} = master) do
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(master)
    end

    # A stylesheet saved under the token a preview of `page` was opened with, while its site is up.
    defp preview_css!(page) do
      {:ok, _view, _html} = preview(page, nil)

      :ok =
        AssetsState.save(%{
          id: page.preview_token,
          type: "css",
          value: "/* preview */",
          hash: "p",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn -> DraftPreviewAssets.purge(page) end)
      page.preview_token
    end

    defp preview(record, viewer, resource \\ "page") do
      "localhost"
      |> on_host()
      |> as_viewer(viewer)
      |> live("/_preview/#{resource}/#{record.preview_token}")
    end

    defp assert_refused(record, viewer, resource \\ "page") do
      assert_raise NotFoundError, fn -> preview(record, viewer, resource) end
    end

    test "an offline site's record is previewed by its admins and the masters only", %{
      closed: closed,
      other: other,
      page: page
    } do
      offline!(closed)

      assert_refused(page, nil)
      assert_refused(page, user!(closed.id, []))
      assert_refused(page, user!(other.id, ["*"]))
      assert {:ok, _view, html} = preview(page, user!(closed.id, ["*"]))
      assert html =~ "kept"
      assert {:ok, _view, _html} = preview(page, user!(nil, ["*"]))
    end

    test "a switched-off site's record is a master's only", %{closed: closed, page: page} do
      cache!(closed, false)

      assert_refused(page, nil)
      assert_refused(page, user!(closed.id, ["*"]))
      assert {:ok, _view, _html} = preview(page, user!(nil, ["*"]))
    end

    test "a site the cache no longer knows, archived or deleted, is a master's only", %{
      closed: closed,
      page: page
    } do
      SiteState.delete(closed.id)

      assert_refused(page, nil)
      assert {:ok, _view, _html} = preview(page, user!(nil, ["*"]))
    end

    test "a draft follows its site the same way", %{closed: closed, page: page} do
      draft =
        PageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: page.name,
            title: page.title,
            path: page.path,
            template: "<b>draft</b>",
            source_page_id: page.id
          },
          tenant: closed.id
        )
        |> Ash.create!(authorize?: false)

      offline!(closed)

      assert_refused(draft, nil)
      assert {:ok, _view, _html} = preview(draft, user!(nil, ["*"]))
    end

    test "a global layout is previewed by anyone, whatever state a site is in", %{
      closed: closed,
      page: page
    } do
      layout = create_layout!(template: ~s(<main class="global-probe">{@inner_content}</main>))
      offline!(closed)

      assert {:ok, _view, html} = preview(layout, nil, "layout")
      assert html =~ "global-probe"
      assert_refused(page, nil)
    end

    test "a refused preview compiles and remembers nothing", %{closed: closed, page: page} do
      offline!(closed)

      assert_refused(page, nil)
      assert DraftPreviewAssets.site(page.preview_token) == :error
      refute AssetsState.exists?(page.preview_token, "css")
    end

    # A site owner's plugin that hears every open view sent away.
    defmodule LeaveProbe do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "web:live:site_unavailable"

      @impl true
      def call(socket, meta) do
        send(:preview_leave_probe, {:left, meta})
        {:reply, socket}
      end
    end

    test "an open preview is sent away the moment its site goes offline, naming that site", %{
      closed: closed,
      page: page
    } do
      Process.register(self(), :preview_leave_probe)

      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: LeaveProbe,
          event: "web:live:site_unavailable",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile("web:live:site_unavailable", :start, false)

      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, LeaveProbe, false) end)

      {:ok, view, _html} = preview(page, nil)
      offline!(closed)
      closed_id = closed.id

      assert_redirect(view, "/_preview/page/#{page.preview_token}")
      assert_received {:left, %{site_id: ^closed_id}}
    end

    # THE HOST'S ADMIN IS NOT THE RECORD'S. The switch for every site reaches the view as one message
    # for every site; the host is fine for this viewer, and the record's site is not. The host is the
    # master site's, the only address besides the record's own that serves its preview.
    test "the switch for every site closes it for an admin of the host who is not the site's", %{
      admin: admin,
      page: page
    } do
      {:ok, view, _html} =
        "localhost"
        |> on_host()
        |> as_viewer(user!(admin.id, ["*"]))
        |> live("/_preview/page/#{page.preview_token}")

      {:ok, _} = Settings.put("cms.offline", true)

      assert_redirect(view, "/_preview/page/#{page.preview_token}")
    end

    # A site owner's plugin that hears every refused preview.
    defmodule RefusalProbe do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "web:live:preview_unavailable"

      @impl true
      def call(entries) do
        send(:preview_refusal_probe, {:refused, entries})
        {:reply, entries}
      end
    end

    test "a refusal is heard on web:live:preview_unavailable", %{closed: closed, page: page} do
      Process.register(self(), :preview_refusal_probe)

      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: RefusalProbe,
          event: "web:live:preview_unavailable",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          "web:live:preview_unavailable",
          :start,
          false
        )

      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, RefusalProbe, false) end)
      offline!(closed)
      closed_id = closed.id

      assert_refused(page, nil)
      assert_received {:refused, %{site_id: ^closed_id, state: :offline, resource: "page"}}
    end

    test "its stylesheet follows the site too, and only under a token a preview was opened with",
         %{
           closed: closed,
           page: page
         } do
      {:ok, _view, _html} = preview(page, nil)
      token = page.preview_token

      :ok =
        AssetsState.save(%{
          id: token,
          type: "css",
          value: "/* preview */",
          hash: "p",
          updated_at: DateTime.utc_now()
        })

      :ok =
        AssetsState.save(%{
          id: closed.name,
          type: "css",
          value: "/* the site's live bundle */",
          hash: "s",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn ->
        DraftPreviewAssets.purge(page)
        AssetsState.delete(closed.name, "css")
      end)

      assert "localhost" |> on_host() |> get("/_preview/page/#{token}/css") |> response(200) ==
               "/* preview */"

      assert ("localhost" |> on_host() |> get("/_preview/page/#{closed.name}/css")).status == 404,
             "a site's name read as a token handed out its live bundle"

      offline!(closed)
      css = fn conn -> get(conn, "/_preview/page/#{token}/css") end
      refused = "localhost" |> on_host() |> then(css)

      assert refused.status == 404
      assert get_resp_header(refused, "cache-control") == ["no-store"]

      assert "localhost"
             |> on_host()
             |> signed_in(user!(nil, ["*"]))
             |> then(css)
             |> response(200) ==
               "/* preview */"
    end

    # A PREVIEW IS THE PAGES' SIDE, as the site's files are: while its site is closed, its stylesheet
    # goes to a master who holds anything under `admin:dashboard`, and not to one who holds only API
    # names.
    test "a closed site's preview stylesheet is a dashboard master's, not an API-only master's",
         %{
           closed: closed,
           page: page
         } do
      token = preview_css!(page)
      dashboard = user!(nil, ["admin:dashboard:runtime:page"])
      api = user!(nil, ["admin:api:*"])

      css = fn user ->
        "localhost" |> on_host() |> signed_in(user) |> get("/_preview/page/#{token}/css")
      end

      for {state, close} <- [
            offline: fn -> offline!(closed) end,
            inactive: fn -> cache!(closed, false) end
          ] do
        close.()

        assert css.(dashboard) |> response(200) == "/* preview */",
               "#{state}: a dashboard master was refused the stylesheet"

        assert css.(api).status == 404, "#{state}: an API-only master was given the stylesheet"
      end
    end

    # A SITE'S OWN USER reaches its preview stylesheet on that site's address alone, where the offline
    # page answers first, so the action is asked here directly, with the user a sign-in leaves.
    test "an offline site's preview stylesheet is its dashboard admins', not its API-only admins'",
         %{closed: closed, page: page} do
      token = preview_css!(page)
      dashboard = user!(closed.id, ["admin:dashboard:blog:post"])
      api = user!(closed.id, ["admin:api:*"])
      offline!(closed)

      css = fn user ->
        build_conn()
        |> Plug.Conn.assign(:current_site, closed)
        |> Plug.Conn.assign(:current_user, user)
        |> MishkaCmsWeb.DraftPreviewController.css(%{"token" => token})
      end

      assert css.(dashboard) |> response(200) == "/* preview */"
      assert css.(api).status == 404
    end

    # A GLOBAL LAYOUT HAS NO SITE, but its CSS is compiled against the host it is opened on, that
    # site's stylesheets included — so that is the site its stylesheet follows.
    test "a global layout's stylesheet follows the site it was compiled against", %{
      admin: admin,
      closed: closed
    } do
      layout = create_layout!(template: ~s(<main>{@inner_content}</main>))
      token = layout.preview_token
      on_exit(fn -> DraftPreviewAssets.purge(layout) end)

      {:ok, _view, _html} = "closed.test" |> on_host() |> live("/_preview/layout/#{token}")

      :ok =
        AssetsState.save(%{
          id: token,
          type: "css",
          value: "/* compiled against closed */",
          hash: "c",
          updated_at: DateTime.utc_now()
        })

      offline!(closed)
      css = fn conn -> get(conn, "/_preview/layout/#{token}/css") end

      assert ("localhost" |> on_host() |> then(css)).status == 404

      assert "localhost"
             |> on_host()
             |> signed_in(user!(nil, ["*"]))
             |> then(css)
             |> response(200) ==
               "/* compiled against closed */"

      {:ok, _view, _html} = "localhost" |> on_host() |> live("/_preview/layout/#{token}")

      assert DraftPreviewAssets.site(token) == {:ok, admin.id}
      refute ("localhost" |> on_host() |> then(css)).resp_body == "/* compiled against closed */"
    end

    # A site owner's plugin that answers a refused preview stylesheet with one of its own.
    defmodule PlaceholderCss do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "web:request:preview_unavailable"

      @impl true
      def call(conn, meta) do
        body = "/* #{meta[:reason]} #{meta[:site_id]} */"
        {:reply, conn |> Plug.Conn.send_resp(200, body) |> Plug.Conn.halt()}
      end
    end

    test "a plugin on web:request:preview_unavailable may answer a refused stylesheet", %{
      closed: closed,
      page: page
    } do
      {:ok, _view, _html} = preview(page, nil)
      on_exit(fn -> DraftPreviewAssets.purge(page) end)

      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: PlaceholderCss,
          event: "web:request:preview_unavailable",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          "web:request:preview_unavailable",
          :start,
          false
        )

      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, PlaceholderCss, false) end)
      offline!(closed)

      assert "localhost"
             |> on_host()
             |> get("/_preview/page/#{page.preview_token}/css")
             |> response(200) == "/* offline #{closed.id} */"
    end
  end
end
