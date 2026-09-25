defmodule MishkaCms.Plugs.UploadsGateTest do
  @moduledoc """
  A site's uploaded files as a visitor, a site admin and a master fetch them: served while the site is
  up, and while it is down only to whoever may see the site itself.

  Anonymous requests go through the endpoint, because `Plug.Static` answering before every gate is
  what this fixes. Signed-in viewers call the plug alone, with a session cookie of its own.

  `async: false` — `SiteState`, `ViewerState` and the settings cache are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCms.Test.Factory

  alias MishkaCms.Plugs.UploadsGate
  alias MishkaCmsCore.Accounts.{LiveSockets, Permission, UserPermission}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @session [store: :cookie, key: "_uploads_gate_test", signing_salt: "uploads-gate"]
  @secret String.duplicate("k", 64)

  setup do
    SettingsState.refresh()
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  defp uploads_dir(segment),
    do: Application.app_dir(:mishka_cms, ["priv", "static", "uploads", segment])

  defp on_disk!(segment, file) do
    path = Path.join(uploads_dir(segment), file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "site file")
    on_exit(fn -> File.rm_rf!(uploads_dir(segment)) end)
    "/uploads/#{segment}/#{file}"
  end

  # A site as the gate reads it — the site cache and its offline setting — with one file on disk.
  defp site_with_file(state) do
    host = "uploads-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: state != :inactive)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active
      })

    on_exit(fn -> SiteState.delete(site.id) end)

    if state == :offline, do: {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

    Map.put(site, :file, on_disk!(site.id, "media/note.txt"))
  end

  defp refused?(conn) do
    conn.status == 404 and conn.resp_body == "" and
      get_resp_header(conn, "cache-control") == ["no-store"]
  end

  describe "through the endpoint, as a visitor" do
    test "an open site's file is served, and every reuse of it is checked first", %{conn: conn} do
      site = site_with_file(:open)

      served = get(conn, site.file)
      assert served.status == 200
      assert served.resp_body == "site file"
      assert get_resp_header(served, "cache-control") == ["no-cache"]

      versioned = get(build_conn(), site.file <> "?vsn=1")
      assert get_resp_header(versioned, "cache-control") == ["no-cache"]
    end

    test "a switched-off site's file is refused, on its own address and on another", %{conn: conn} do
      site = site_with_file(:inactive)

      for host <- [site.host, "another-site.test"] do
        assert conn |> Map.put(:host, host) |> get(site.file) |> refused?(), "served on #{host}"
      end
    end

    test "an offline site's file is refused", %{conn: conn} do
      site = site_with_file(:offline)

      assert conn |> get(site.file) |> refused?()
    end

    test "a file left behind by a site that is gone is refused", %{conn: conn} do
      file = on_disk!(Ecto.UUID.generate(), "media/left.txt")

      assert conn |> get(file) |> refused?()
    end

    # 36 bytes is a site id's length, and 16 bytes is one `Ecto.UUID.cast/1` reads as a raw id.
    test "a file outside every site's folder is served as before, a site id's length or not" do
      base = "g#{System.unique_integer([:positive])}"

      for name <- [
            String.pad_trailing(base, 12, "x") <> ".txt",
            String.pad_trailing(base, 32, "x") <> ".txt"
          ] do
        path = Path.join(uploads_dir(""), name)
        File.write!(path, "loose file")
        on_exit(fn -> File.rm(path) end)

        assert build_conn() |> get("/uploads/#{name}") |> response(200) == "loose file",
               "#{byte_size(name)}-byte name refused"
      end
    end

    test "the other static files keep their long-lived caching", %{conn: conn} do
      assert conn |> get("/favicon.ico") |> get_resp_header("cache-control") == ["public"]
    end
  end

  # A site owner's plugin that answers a closed site's file with a placeholder of its own.
  defmodule Placeholder do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "web:request:upload_unavailable"

    @impl true
    def call(conn, meta) do
      body = "placeholder #{meta[:state]} #{meta[:site_id]}"
      {:reply, conn |> Plug.Conn.send_resp(200, body) |> Plug.Conn.halt()}
    end
  end

  test "a plugin on web:request:upload_unavailable may answer instead", %{conn: conn} do
    site = site_with_file(:inactive)

    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: Placeholder,
        event: "web:request:upload_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok =
      MishkaInstaller.Event.EventHandler.do_compile(
        "web:request:upload_unavailable",
        :start,
        false
      )

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, Placeholder, false) end)

    assert conn |> get(site.file) |> response(200) == "placeholder inactive #{site.id}"
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

  # Cached the way a page load leaves them, since that is all the gate reads. `true` is an admin
  # holding `*`, `false` a user holding nothing, and a list the names the user holds.
  defp viewer!(site_id, true), do: viewer!(site_id, ["*"])
  defp viewer!(site_id, false), do: viewer!(site_id, [])

  defp viewer!(site_id, names) do
    user = create_user!(site_id: site_id)

    for name <- names do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create!(authorize?: false)
    end

    user = Ash.load!(user, [:permissions], authorize?: false)
    ViewerState.remember(user)
    on_exit(fn -> ViewerState.forget(user.id) end)
    user
  end

  defp cookie_for(user, secret \\ @secret) do
    config = Plug.Session.init(@session)
    conn = %{Plug.Test.conn(:get, "/") | secret_key_base: secret}
    session = %{"live_socket_id" => LiveSockets.live_socket_id(user)}
    config.store.put(conn, nil, session, config.store_config)
  end

  defp fetch(path, cookie) do
    conn = %{Plug.Test.conn(:get, path) | secret_key_base: @secret}
    conn = if cookie, do: Plug.Test.put_req_cookie(conn, @session[:key], cookie), else: conn
    UploadsGate.call(conn, UploadsGate.init(session: @session))
  end

  defp served?(conn), do: not conn.halted

  describe "the plug alone, as a signed-in viewer" do
    test "a switched-off site's file is a master's to see, not its own admin's" do
      site = site_with_file(:inactive)

      assert site.file |> fetch(cookie_for(viewer!(nil, true))) |> served?()
      refute site.file |> fetch(cookie_for(viewer!(site.id, true))) |> served?()
    end

    test "an offline site's file is its admins' and the masters', nobody else's" do
      site = site_with_file(:offline)
      other = create_site!(active: true)

      assert site.file |> fetch(cookie_for(viewer!(nil, true))) |> served?()
      assert site.file |> fetch(cookie_for(viewer!(site.id, true))) |> served?()
      refute site.file |> fetch(cookie_for(viewer!(other.id, true))) |> served?()
      refute site.file |> fetch(cookie_for(viewer!(site.id, false))) |> served?()
      refute site.file |> fetch(nil) |> served?()
    end

    # A SITE'S FILES ARE ITS PAGES' SIDE, as the maintenance page is: while the site is closed they go
    # to the admins of its screens, one area is enough, and not to an admin of its API alone.
    test "a closed site's file is its dashboard admins', not an API-only admin's" do
      inactive = site_with_file(:inactive)
      offline = site_with_file(:offline)

      assert inactive.file
             |> fetch(cookie_for(viewer!(nil, ["admin:dashboard:runtime:page"])))
             |> served?()

      refute inactive.file |> fetch(cookie_for(viewer!(nil, ["admin:api:*"]))) |> served?()

      for viewer <- [
            viewer!(nil, ["admin:dashboard:runtime:page"]),
            viewer!(offline.id, ["admin:dashboard:blog:post"])
          ] do
        assert offline.file |> fetch(cookie_for(viewer)) |> served?(),
               "an offline site's file refused a dashboard admin of site #{inspect(viewer.site_id)}"
      end

      for viewer <- [viewer!(nil, ["admin:api:*"]), viewer!(offline.id, ["admin:api:*"])] do
        refute offline.file |> fetch(cookie_for(viewer)) |> served?(),
               "an offline site's file went to an API admin of site #{inspect(viewer.site_id)}"
      end
    end

    test "a session whose user the cache does not know is a visitor" do
      site = site_with_file(:offline)
      admin = viewer!(site.id, true)
      ViewerState.forget(admin.id)

      refute site.file |> fetch(cookie_for(admin)) |> served?()
    end

    test "a cookie naming a master but signed with another key is a visitor" do
      site = site_with_file(:offline)
      forged = cookie_for(viewer!(nil, true), String.duplicate("f", 64))

      refute site.file |> fetch(forged) |> served?()
    end
  end
end
