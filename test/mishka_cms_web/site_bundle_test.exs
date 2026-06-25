defmodule MishkaCmsWeb.SiteBundleTest do
  @moduledoc """
  A site's CSS and JS bundle, `/assets/css|js/<site>/<hash>`, as a visitor, a site admin and a master
  ask for it: on its own address while the site is up, to its admins and the masters while it is
  offline (its stylesheet to anyone, for the offline page), only at its current hash, and never as a
  200 for something that is not there.

  `async: false` — the install flag, `SiteState`, `AssetsState` and the settings cache are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  setup do
    Install.mark_installed!()
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      SettingsState.restore(snapshot)
      :persistent_term.erase(:mishka_installed)
    end)

    %{site: site!(), other: site!()}
  end

  # A site as the request pipeline and the controller read it: cached by host and name, with its
  # two bundles compiled.
  defp site!(overrides \\ []) do
    host = "bundle-#{System.unique_integer([:positive])}.test"
    site = create_site!(Keyword.merge([name: host, host: host, active: true], overrides))

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    for type <- ["css", "js"] do
      :ok =
        AssetsState.save(%{
          id: site.name,
          type: type,
          value: "/* #{site.name} #{type} */",
          hash: "h#{type}#{System.unique_integer([:positive])}",
          updated_at: DateTime.utc_now()
        })
    end

    on_exit(fn ->
      SiteState.delete(site.id)
      AssetsState.delete_by_site(site.name)
    end)

    site
  end

  defp href(site, type),
    do: "/assets/#{type}/#{site.name}/#{AssetsState.get!(site.name, type).hash}.#{type}"

  defp user!(site_id, permissions) do
    user = create_user!(site_id: site_id)

    ids =
      Enum.map(permissions, fn name ->
        case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
          {:ok, nil} -> create_permission!(name: name).id
          {:ok, permission} -> permission.id
        end
      end)

    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids},
      authorize?: false,
      tenant: site_id
    )
    |> Ash.update!()
  end

  defp on_host(host) do
    build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp as(conn, nil), do: conn

  defp as(conn, %{site_id: nil} = master) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(master)
  end

  defp as(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp fetch(site, type, opts \\ []) do
    host = Keyword.get(opts, :on, site).host
    host |> on_host() |> as(opts[:as]) |> get(opts[:path] || href(site, type))
  end

  defp refused?(conn) do
    conn.status == 404 and conn.resp_body == "" and
      get_resp_header(conn, "cache-control") == ["no-store"]
  end

  defp offline!(site), do: {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

  describe "a site that is up" do
    test "serves its bundles on its own address, cached as immutable", %{site: site} do
      for type <- ["css", "js"] do
        conn = fetch(site, type)

        assert conn.status == 200
        assert conn.resp_body == "/* #{site.name} #{type} */"
        assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      end
    end

    test "falls back to the plain bundle when a compressed one is not there", %{site: site} do
      conn =
        site.host
        |> on_host()
        |> put_req_header("accept-encoding", "br, gzip")
        |> get(href(site, "css"))

      assert conn.resp_body == "/* #{site.name} css */"
      assert get_resp_header(conn, "content-encoding") == []
    end

    test "refuses a hash that is not the current one, or a bundle that is not there", %{
      site: site
    } do
      assert fetch(site, "css", path: "/assets/css/#{site.name}/stale.css") |> refused?()
      assert fetch(site, "css", path: "/assets/css/#{site.name}/.css") |> refused?()

      AssetsState.delete(site.name, "js")
      assert fetch(site, "js", path: "/assets/js/#{site.name}/anything.js") |> refused?()
    end

    test "is not handed out on another site's address", %{site: site, other: other} do
      assert fetch(site, "css", on: other) |> refused?()
      assert fetch(site, "js", on: other, as: user!(other.id, ["*"])) |> refused?()
    end

    # A master is signed in on the master site's address and nowhere else, so that is where the
    # page builder's canvas asks for another site's bundle.
    test "is handed to a master on the master site's address, for the page builder", %{
      site: site,
      other: other
    } do
      master = user!(nil, ["*"])
      conn = fetch(site, "css", on: site!(master: true), as: master)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]

      assert fetch(site, "css", on: other, as: master) |> refused?()
    end
  end

  describe "an offline site" do
    test "keeps its script from a visitor and its plain users", %{site: site} do
      offline!(site)

      assert fetch(site, "js") |> refused?()
      assert fetch(site, "js", as: user!(site.id, [])) |> refused?()
    end

    # The offline page its visitors get links it.
    test "gives its stylesheet to a visitor, privately cached", %{site: site} do
      offline!(site)
      conn = fetch(site, "css")

      assert conn.status == 200
      assert conn.resp_body == "/* #{site.name} css */"
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    test "but not on another site's address", %{site: site, other: other} do
      offline!(site)

      assert fetch(site, "css", on: other) |> refused?()
    end

    test "gives them to its admins, privately cached", %{site: site} do
      offline!(site)
      conn = fetch(site, "js", as: user!(site.id, ["*"]))

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end
  end

  test "the shared base is served to anyone at its hash", %{site: site} do
    :ok =
      AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: "/* base */",
        hash: "base1",
        updated_at: DateTime.utc_now()
      })

    on_exit(fn -> AssetsState.delete("__shared_base__", "css") end)

    assert fetch(site, "css", path: "/assets/css/__shared_base__/base1").resp_body == "/* base */"
  end

  # A site owner's plugin that answers a refused bundle with one of its own.
  defmodule Placeholder do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "web:request:asset_unavailable"

    @impl true
    def call(conn, meta) do
      body = "/* #{meta[:reason]} #{meta[:type]} #{meta[:site]} */"
      {:reply, conn |> Plug.Conn.send_resp(200, body) |> Plug.Conn.halt()}
    end
  end

  test "a plugin on web:request:asset_unavailable may answer a refusal", %{
    site: site,
    other: other
  } do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: Placeholder,
        event: "web:request:asset_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile(
        "web:request:asset_unavailable",
        :start,
        false
      )

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, Placeholder, false) end)

    assert fetch(site, "css", on: other).resp_body == "/* address css #{site.name} */"
  end
end
