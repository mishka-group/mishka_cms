# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.CssAudienceTest do
  @moduledoc """
  Which stylesheet each kind of page gets, pinned per audience.

  There are three, and they have nothing to do with each other:

    * `admin.css` — the dashboard and the page builder shell. Compiled at build time from
      templates, because those classes cannot change without a deploy.
    * `public.css` — the host's own marketing pages. Same reason, different source tree.
    * `/assets/css/<site>/<hash>.css` — a site's runtime bundle, compiled from database rows. The
      sign-in pages, `/<lang>/auth…`, are database pages and take it too.

  Every one of those used to be the same 2.4 MB file. A visitor reading an "About" page downloaded
  the entire admin dashboard, the Gervaz table library and the marketing site to render six classes;
  publishing a page invalidated the marketing cache; and the admin carried every component of every
  installed kit, which it never renders.

  Nothing errors when this regresses — the page still renders, just after a megabyte it did not
  need, or (the other direction) unstyled because its sheet was gated away. Both are invisible to a
  suite that only asserts on content, so the gating is asserted here directly.

  The gates live in `root.html.heex`, which the HOST owns: `MishkaCmsCore`'s isolated harness
  supplies a deliberately bare root layout, so this can only be proven from here.

  `async: false` — the install flag and `SiteState` are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}

  require Ash.Query

  @admin_sheet ~s|href="/assets/css/admin.css"|
  @public_sheet ~s|href="/assets/css/public.css"|
  @site_sheet ~s|href="/assets/css/|

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

    # `cms.offline` is a process-global RAM setting and the maintenance page has a `<head>` of its
    # own, so a leak from another file would make every assertion here fail for an unrelated reason.
    MishkaCmsCore.Settings.put("cms.offline", false)

    %{site: site}
  end

  defp page(path, conn \\ Phoenix.ConnTest.build_conn()) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> get(path)
    |> html_response(200)
  end

  # The dashboard's home, as a master holding the whole dashboard opens it.
  defp dashboard do
    permission =
      case Permission
           |> Ash.Query.filter(name == "admin:dashboard:*")
           |> Ash.read_one!(authorize?: false) do
        nil -> create_permission!(name: "admin:dashboard:*")
        held -> held
      end

    master =
      [site_id: nil]
      |> create_user!()
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(master)

    page("/admin/dashboard", conn)
  end

  # `<head>` only. A stylesheet path also appears in the body of pages that talk ABOUT the CMS, and
  # matching those would make every assertion here pass for the wrong reason.
  defp head(html), do: html |> String.split("</head>", parts: 2) |> hd()

  describe "the admin audience" do
    test "the dashboard takes the compiled admin sheet" do
      assert head(dashboard()) =~ @admin_sheet
    end

    test "the dashboard's fonts are served by this app, not a font CDN" do
      head = head(dashboard())

      assert head =~ ~s|href="/fonts/fonts.css"|

      refute head =~ "fonts.googleapis.com",
             "a third-party font request blocks first paint and leaks the visitor's IP"
    end

    test "the dashboard does not ship the browser Tailwind build" do
      refute head(dashboard()) =~ "tailwind",
             "its classes are in templates and compiled at build time; only the canvas needs the JIT"
    end

    test "an admin page takes no site bundle and no marketing sheet" do
      head = head(dashboard())

      refute head =~ @public_sheet
      refute head =~ ~s|id="mishka-runtime-css"|
    end
  end

  # A DATABASE PAGE LIKE ANY OTHER: the site's own sign-in page, `StarterContent.ensure_auth!/1`'s.
  describe "the sign-in page" do
    setup %{site: site} do
      seed_auth_pages!(site)

      for type <- ["css", "js"] do
        :ok =
          AssetsState.save(%{
            id: site.name,
            type: type,
            value: "",
            hash: "signin#{type}",
            updated_at: DateTime.utc_now()
          })
      end

      on_exit(fn -> AssetsState.delete_by_site(site.name) end)
      :ok
    end

    test "takes the site's own bundle" do
      head = head(page("/auth"))

      assert head =~ ~s|href="/assets/css/localhost/signincss.css"|
      assert head =~ ~s|id="mishka-runtime-css"|
      assert head =~ ~s|src="/assets/js/localhost/signinjs.js"|
    end

    test "its fonts are served by this app, not a font CDN" do
      head = head(page("/auth"))

      assert head =~ ~s|href="/fonts/fonts.css"|

      refute head =~ "fonts.googleapis.com",
             "a third-party font request blocks first paint and leaks the visitor's IP"
    end

    test "takes neither the admin sheet nor the marketing one, nor the browser Tailwind build" do
      head = head(page("/auth"))

      refute head =~ @admin_sheet
      refute head =~ @public_sheet
      refute head =~ "tailwind"
    end
  end

  # The site audience is asserted on the LAYOUT rather than through a request, because reaching
  # `RuntimeLive` needs the whole compile pipeline warm — routing state, a compiled page module, a
  # compiled bundle. That pipeline has its own tests; what is at stake here is one boolean, and the
  # layout is where it is read.
  #
  # `runtime_page` is the marker `RuntimeLive.mount/3` sets. Everything public on this host that is
  # NOT a database page is a marketing LiveView, so the layout branches on the one rather than
  # annotating the other 44.
  describe "the site audience" do
    setup %{site: site} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: site.name,
        type: "css",
        value: "",
        hash: "deadbeef",
        updated_at: DateTime.utc_now()
      })

      on_exit(fn -> AssetsState.delete_by_site(site.name) end)
      :ok
    end

    defp layout(assigns) do
      assigns
      |> Map.merge(%{inner_content: {:safe, ""}, current_site: %{name: "localhost"}})
      |> MishkaCmsWeb.Layouts.root()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> head()
    end

    test "a database page takes the site's own bundle" do
      html = layout(%{runtime_page: true})

      assert html =~ @site_sheet
      assert html =~ ~s|id="mishka-runtime-css"|
    end

    test "a database page takes neither the admin sheet nor the marketing one" do
      html = layout(%{runtime_page: true})

      refute html =~ @admin_sheet
      refute html =~ @public_sheet
    end

    # A PAGE ASKED FOR WHILE THE SITE'S FIRST COMPILE IS STILL RUNNING. The hash is not there yet,
    # and the link used to be written anyway — `/assets/css/localhost/.css`, a 404 the browser
    # refused as a stylesheet. Now there is no link until there is a sheet; the socket delivers it.
    test "before the site's first compile a database page takes no stylesheet and no script" do
      AssetsState.delete_by_site("localhost")

      html = layout(%{runtime_page: true})

      refute html =~ ~s|id="mishka-runtime-css"|
      refute html =~ "/assets/css/localhost/"
      refute html =~ "/assets/js/localhost/"
    end

    test "once both bundles exist the page takes each by its hash" do
      AssetsState.save(%{id: "localhost", type: "js", value: "", hash: "cafe", updated_at: nil})

      html = layout(%{runtime_page: true})

      assert html =~ ~s|href="/assets/css/localhost/deadbeef.css"|
      assert html =~ ~s|src="/assets/js/localhost/cafe.js"|
    end

    # The canvas takes the site's own link off and links ONE bundle of its own above the generator,
    # under the id the `phx:mishka:css-updated` swap (`css_swap.js`) follows — so an open frame moves
    # to a rebuilt bundle the way a live page does. Never a marketing sheet that was never part of it.
    test "the builder canvas links its own bundle once, under the id the swap follows" do
      html =
        layout(%{
          runtime_page: true,
          suppress_site_css: true,
          canvas_css_hrefs: ["/assets/css/localhost/#{String.duplicate("a", 32)}.css"]
        })

      assert [_one] = Regex.scan(~r|id="mishka-runtime-css"|, html)
      assert html =~ ~s|href="/assets/css/localhost/#{String.duplicate("a", 32)}.css"|
      refute html =~ "/assets/css/localhost/deadbeef.css", "the site's own link was not taken off"
      refute html =~ @public_sheet
    end

    # Drawn before anything compiled, the frame inlines what there is; the empty link keeps the
    # bundle's place above the generator for the swap to put the first one in.
    test "a canvas with nothing to link yet keeps an empty link in the bundle's place" do
      html = layout(%{runtime_page: true, suppress_site_css: true, canvas_css_hrefs: []})

      assert [link] = Regex.scan(~r|<link[^>]*id="mishka-runtime-css"[^>]*>|, html)
      refute hd(link) =~ "href="
      refute html =~ @public_sheet
    end

    test "a page that is not the canvas takes no empty link" do
      html = layout(%{runtime_page: true, suppress_site_css: true})

      refute html =~ ~s|id="mishka-runtime-css"|
    end
  end
end
