# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.RuntimeHeadCodeTest do
  @moduledoc """
  A site's head code in the head of its public pages, as a browser gets it.

  The Plausible snippet published on every page loads with the response's nonce, and the enforced
  policy names its origin in `script-src` and `connect-src`, so nothing is refused. An entry limited
  to one page is drawn on that page alone and comes and goes with a live patch. A plugin on
  `runtime:page:head` is drawn beside the site's own. An admin page never gets any of it.

  `async: false`: the install flag, `SiteState`, the plugin registry and the routing table are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.HeadCode
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders

  @plausible ~s(<script defer data-domain="localhost" src="https://plausible.io/js/script.js"></script>)

  defmodule ExtensionHead do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:head"

    @impl true
    def call(%{items: items} = entry) do
      item = %{tag: "meta", attrs: [{"name", "extension-verify"}, {"content", "x"}], content: nil}
      {:reply, %{entry | items: items ++ [item]}}
    end
  end

  setup do
    site_snapshot = SiteState.snapshot()
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

    snapshot = SettingsState.snapshot()
    previous_policy = Application.get_env(:mishka_cms, SecurityHeaders)
    Application.put_env(:mishka_cms, SecurityHeaders, csp: :enforce)
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
      SiteState.restore(site_snapshot)

      case previous_policy do
        nil -> Application.delete_env(:mishka_cms, SecurityHeaders)
        kept -> Application.put_env(:mishka_cms, SecurityHeaders, kept)
      end
    end)

    # Core registers its own plugin on the event as it starts, and the event is rebuilt behind it;
    # the first request waits for both.
    :ok = MishkaCmsCore.Test.Installer.await([MishkaCmsCore.Runtime.SiteHeadCode])

    Settings.put("cms.offline", false)
    {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

    %{site: site, pricing: published!(site, "pricing"), about: published!(site, "about")}
  end

  test "the Plausible snippet loads with the response's nonce and its origin in the policy", %{
    site: site,
    about: about
  } do
    entry!(site, %{origins: ["https://plausible.io"]})

    conn = on_site() |> get(about.path)
    [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
    doc = conn |> html_response(200) |> LazyHTML.from_document()

    script = LazyHTML.query(doc, ~s(head script[src="https://plausible.io/js/script.js"]))
    assert LazyHTML.attribute(script, "nonce") == [nonce]
    assert [_key] = LazyHTML.attribute(script, "data-mishka-head")

    [script_src] = Regex.run(~r/script-src [^;]+/, policy)
    [connect_src] = Regex.run(~r/connect-src [^;]+/, policy)
    assert script_src =~ "https://plausible.io"
    assert connect_src =~ "https://plausible.io"
  end

  test "an entry limited to one page is drawn there alone, and follows a live patch", %{
    site: site,
    pricing: pricing,
    about: about
  } do
    entry =
      entry!(site, %{
        name: "Pricing",
        code: ~s(<meta name="pricing-pixel" content="1">),
        scope: :only,
        paths: [pricing.path]
      })

    assert pixel?(get_page(pricing.path))
    refute pixel?(get_page(about.path))

    {:ok, view, _html} = live(on_site(), about.path)

    render_patch(view, pricing.path)
    assert_push_event(view, "mishka:head", %{head_code: %{items: items, nonce: nonce}})
    assert is_binary(nonce)
    assert [%{key: key, tag: "meta"}] = items
    assert key == entry.id

    render_patch(view, about.path)
    assert_push_event(view, "mishka:head", %{head_code: %{items: []}})
  end

  test "a plugin on runtime:page:head is drawn beside the site's own", %{site: site, about: about} do
    register_plugin(ExtensionHead, "runtime:page:head")
    entry!(site, %{})

    doc = LazyHTML.from_document(get_page(about.path))

    assert Enum.count(
             LazyHTML.query(doc, ~s(head meta[name="extension-verify"][data-mishka-head]))
           ) == 1

    assert Enum.count(
             LazyHTML.query(doc, ~s(head script[src="https://plausible.io/js/script.js"]))
           ) == 1
  end

  test "an admin page and the editor carry no head code and no extra CSP origin", %{
    site: site,
    about: about
  } do
    entry!(site, %{origins: ["https://plausible.io"]})
    master = master!()

    for path <- [
          "/admin/dashboard",
          "/admin/dashboard/runtime/pages",
          "/admin/dashboard/runtime/builder/page/#{about.id}"
        ] do
      conn = master |> signed_in() |> get(path)
      html = html_response(conn, 200)
      [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")

      refute html =~ "plausible.io/js/script.js", path
      refute html =~ "data-mishka-head", path
      refute policy =~ "plausible.io", path
    end

    # The same entry does reach the site's public page, so the admin pages above are refused it.
    assert get_page(about.path) =~ "plausible.io/js/script.js"
  end

  defp master! do
    permission =
      case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
        {:ok, nil} -> create_permission!(name: "*")
        {:ok, found} -> found
      end

    [site_id: nil]
    |> create_user!()
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp signed_in(user) do
    on_site()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp entry!(site, attrs) do
    Ash.create!(
      HeadCode,
      Map.merge(%{site_id: site.id, name: "Plausible", code: @plausible, published: true}, attrs),
      action: :master_create,
      authorize?: false
    )
  end

  defp pixel?(html),
    do:
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(head meta[name="pricing-pixel"]))
      |> Enum.count() == 1

  defp published!(site, name) do
    page =
      create_page!(
        site_id: site.id,
        name: "#{name}-#{System.unique_integer([:positive])}",
        path: "/en/#{name}-#{System.unique_integer([:positive])}",
        template: ~S(<div><p>page</p></div>)
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

  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp get_page(path), do: on_site() |> get(path) |> html_response(200)
end
