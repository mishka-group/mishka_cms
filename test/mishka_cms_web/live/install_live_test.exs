# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.InstallLiveTest do
  @moduledoc """
  Real LiveView tests for the installer wizard (config → ui-kit picker → settings → done). They drive
  the actual endpoint + router + InstallGate plug, download the kits the way a server does — the
  real Chelekom bundle, served by a `Req.Test` plug from mishka_cms_core's test fixture — and assert
  the real database side effects of `Bootstrap.run/1`. `async: false` (the install flag is
  process-global). The UI-kit install side effects are test-safe: `sync_after_bulk` is a no-op under
  `env_test?`, so the picker step's install path doesn't compile components.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # Over thirty seconds on its own: left out of a pull request, see test/test_helper.exs.
  @moduletag :slow

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Site
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @valid %{
    "email" => "owner@example.com",
    "password" => "Password123!",
    "password_confirmation" => "Password123!",
    "site_name" => "My CMS",
    "host" => "localhost"
  }

  # THE STYLED KIT ONLY, downloaded from a plug, so this suite never touches the network. The tests
  # about the release channels or a failing package configure their own sources.
  @offline_kits [
    %{
      key: :styled,
      label: "Chelekom — styled",
      file: "chelekom.json",
      tag: "test",
      url: "https://kits.test/chelekom.json"
    }
  ]

  # Chelekom's real styled bundle. Nothing ships one; this project keeps a copy for its tests.
  @chelekom Path.expand("../../fixtures/cms_ui_kits/chelekom.json", __DIR__)

  setup do
    :persistent_term.put(:mishka_installed, false)
    official = Application.fetch_env!(:mishka_cms_core, :official_ui_kits)
    Application.put_env(:mishka_cms_core, :official_ui_kits, @offline_kits)

    # EVERY TEST GETS ITS OWN, EMPTY KITS DIRECTORY, as a fresh server has: the styled kit is
    # downloaded into it when the UI-kit step opens. The headless bundle and `add_custom_kit/2`
    # write here too, and the directory goes with the test.
    kits_dir = Path.join(System.tmp_dir!(), "install_kits_#{System.unique_integer([:positive])}")
    File.mkdir_p!(kits_dir)
    configured = Application.fetch_env!(:mishka_cms_core, :ui_kits_dir)
    Application.put_env(:mishka_cms_core, :ui_kits_dir, kits_dir)
    serve_chelekom!()

    on_exit(fn ->
      Application.put_env(:mishka_cms_core, :ui_kits_dir, configured)
      File.rm_rf(kits_dir)
    end)

    System.delete_env("MISHKA_SETUP_TOKEN")
    # The settings step renders from the registry; build it so `site.title` / `mailer.from` exist.
    Settings.load_definitions()
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Application.put_env(:mishka_cms_core, :official_ui_kits, official)
      Application.delete_env(:mishka_cms_core, :ui_kit_req_options)
      :persistent_term.erase({Settings, :definitions})
      System.delete_env("MISHKA_SETUP_TOKEN")
      SettingsState.restore(snapshot)
    end)

    :ok
  end

  # The styled kit's URL answers with Chelekom's real styled bundle; any other file is not there.
  defp serve_chelekom! do
    chelekom = File.read!(@chelekom)

    Application.put_env(:mishka_cms_core, :ui_kit_req_options,
      plug: fn
        %{host: "kits.test"} = conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, chelekom)

        conn ->
          Plug.Conn.send_resp(conn, 404, "Not Found")
      end
    )
  end

  # A server that installed before already holds Chelekom: the bundle is in its kits directory and
  # is read from there, whatever the official sources say today.
  defp chelekom_downloaded! do
    File.cp!(@chelekom, Path.join(UiKitHandler.kits_dir(), "chelekom.json"))
  end

  # Chelekom's packages from a fake GitHub: the API's release list, and each attached file a bundle
  # of that name holding one component. `download:` answers every file request instead — a test
  # holding the download open, or a host where the file is missing.
  defp github_releases!(releases, opts \\ []) do
    Application.delete_env(:mishka_cms_core, :official_ui_kits)
    download = Keyword.get(opts, :download, &named_bundle/1)

    Application.put_env(:mishka_cms_core, :ui_kit_req_options,
      plug: fn conn ->
        case conn.host do
          "api.github.com" -> Req.Test.json(conn, releases)
          _download -> download.(conn)
        end
      end
    )
  end

  defp named_bundle(conn) do
    [tag, file] = conn.request_path |> String.split("/", trim: true) |> Enum.take(-2)
    name = Path.rootname(file)

    Req.Test.json(conn, %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => name,
      "version" => tag,
      "components" => [
        %{
          "name" => "#{name}-panel",
          "type" => "general",
          "template" => "<div class={@class}>panel</div>",
          "attrs" => [],
          "slots" => [],
          "helpers" => [],
          "args" => [],
          "extra" => %{}
        }
      ]
    })
  end

  defp kit_release(tag, prerelease?, files \\ ["chelekom.json", "chelekom_headless.json"]) do
    %{
      "tag_name" => tag,
      "prerelease" => prerelease?,
      "draft" => false,
      "assets" =>
        Enum.map(
          files,
          &%{"name" => &1, "browser_download_url" => "https://github.test/#{tag}/#{&1}"}
        )
    }
  end

  defp acme_release_kit,
    do: %{
      key: :acme,
      label: "Acme kit",
      file: "acme.json",
      tag: "v1.2.3",
      url: "https://github.com/acme/kit/releases/download/v1.2.3/acme.json"
    }

  # What the screen names a package's version by (`version_label/1`): the release tag it was fetched
  # at, or else the bundle's own version.
  defp shown_version(%{tag: tag}) when is_binary(tag), do: tag
  defp shown_version(%{version: version}), do: version

  defp to_ui_kit(conn, config \\ @valid) do
    {:ok, view, _html} = live(conn, "/install")
    view |> form("#install-form", install: config) |> render_submit()

    # The real Chelekom bundle is downloaded and parsed in start_async — give it room past the 100ms
    # default.
    render_async(view, 15_000)

    # The picker is collapsed by default — open it so the list + toolbar render.
    view |> element("#uikit-toggle") |> render_click()
    view
  end

  # `available_kits/0` reads whatever bundles sit beside the shipped one, so a second kit is a file
  # rather than a mock — the same path a real install of a headless kit takes.
  defp headless_bundle_path, do: Path.join(UiKitHandler.kits_dir(), "acme_headless.json")

  defp write_headless_bundle! do
    bundle = %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "acme_headless",
      "version" => "0.0.1",
      "components" => [
        %{
          "name" => "acme-headless-tree",
          "type" => "general",
          "template" => "<div class={@class}>tree</div>",
          "attrs" => [],
          "slots" => [],
          "helpers" => [],
          "args" => [],
          "extra" => %{}
        }
      ]
    }

    File.write!(headless_bundle_path(), Jason.encode!(bundle))
  end

  # THE STARTER STORES ITS LOGO in the master site's media folder: this test's own.
  defp own_media_dir! do
    dir = Path.join(System.tmp_dir!(), "install_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)
  end

  # The settings step submitted with a title and a sender, which starts the install.
  defp submit_settings(conn) do
    view = to_settings(conn)

    view
    |> form("#install-settings-form",
      settings: %{"site.title" => "Acme Docs", "mailer.from" => "hello@acme.test"}
    )
    |> render_submit()

    view
  end

  defp to_settings(conn, config \\ @valid) do
    view = to_ui_kit(conn, config)

    # One component, so commit installs just button (+ the icon every site needs).
    view |> element("#toggle-chelekom-button") |> render_click()
    view |> element("#uikit-next") |> render_click()
    view
  end

  describe "config step" do
    test "renders the configuration form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/install")

      assert has_element?(view, "#install-form")
      assert has_element?(view, "#install-form input[name='install[email]']")
      assert has_element?(view, "#install-form input[name='install[host]']")
      assert has_element?(view, "#install-next")
    end

    # THE VERSION IS THE APPLICATION'S, read when the page is drawn, not a literal in the template:
    # the rail said `v1.0` on a build whose `mix.exs` says something else.
    test "the rail names the version of the application, and writes none of its own", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/install")

      version = to_string(Application.spec(:mishka_cms, :vsn))

      assert version =~ ~r/\A\d+\.\d+\.\d+/
      assert has_element?(view, ".inst-brand-v", "SETUP WIZARD · v#{version}")
      refute has_element?(view, ".inst-brand-v", "v1.0")
      refute render(view) =~ "v1.0"
    end

    test "a browser whose cookie still names a site from before the reset reaches the form", %{
      conn: conn
    } do
      gone = %Site{id: Ecto.UUID.generate(), name: "gone", host: "localhost"}

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{current_site: gone})
        |> live("/install")

      assert has_element?(view, "#install-form")
    end

    test "mismatched passwords show an error and do NOT advance or install", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/install")

      html =
        view
        |> form("#install-form", install: %{@valid | "password_confirmation" => "different"})
        |> render_submit()

      assert html =~ "does not match"
      assert has_element?(view, "#install-form")
      refute has_element?(view, "#installer-uikit")
      refute Install.installed?()
      assert Site |> Ash.read!(authorize?: false) == []
    end
  end

  describe "standalone assets" do
    test "the dead render loads the static LiveView JS and styles itself with inline CSS", %{
      conn: conn
    } do
      html = conn |> get("/install") |> html_response(200)

      # The prebuilt static client makes the page interactive without the per-site runtime bundle.
      assert html =~ "/assets/js/app.js"
      # The page carries its own plain CSS inline — no external CDN, no Tailwind runtime.
      assert html =~ "<style"
      assert html =~ ".inst-aside"
      refute html =~ "@tailwindcss/browser"
      # The installer is the first page a user ever sees — it renders no Phoenix flash at all.
      refute html =~ "flash-group"
    end
  end

  describe "sidebar step rail" do
    test "navigates back to config and forward again to the visited picker", %{conn: conn} do
      view = to_ui_kit(conn)

      view |> element("#rail-step-0") |> render_click()
      assert has_element?(view, "#install-form")

      # Config was already validated and the bundle is cached — Components is one rail click away.
      view |> element("#rail-step-1") |> render_click()
      assert has_element?(view, "#installer-uikit")
    end

    test "steps ahead of the visited ones are not clickable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/install")

      # Nothing is navigable from a pristine config step; Install (3) never is.
      refute has_element?(view, "#rail-step-1[phx-click]")
      refute has_element?(view, "#rail-step-2[phx-click]")
      refute has_element?(view, "#rail-step-3[phx-click]")

      # Once the picker is reached (catalog loaded), Configuration and Settings open up — Install
      # never does; it is only entered by submitting the settings form.
      view = to_ui_kit(conn)
      assert has_element?(view, "#rail-step-0[phx-click]")
      assert has_element?(view, "#rail-step-2[phx-click]")
      refute has_element?(view, "#rail-step-3[phx-click]")
    end
  end

  describe "official package sources" do
    # A PACKAGE THAT CANNOT BE FETCHED IS AN ORDINARY STATE NOW, not a dead install. There are two
    # official packages, and one 404 used to raise out of `ensure_bundles!/1` and take the other —
    # and every third-party bundle on disk — with it, leaving the step with no picker at all.
    #
    # This is not hypothetical while the headless bundle has no published URL: the styled kit
    # resolves from the shipped file and the headless one 404s on every run of this suite.
    test "the picker still renders when an official package cannot be fetched", %{conn: conn} do
      view = to_ui_kit(conn)

      assert has_element?(view, "#installer-uikit")

      assert has_element?(view, "#toggle-chelekom-card"),
             "a failed package must not cost the one that resolved"
    end

    test "a package that could not be fetched is named, with its version", %{conn: conn} do
      Application.put_env(
        :mishka_cms_core,
        :official_ui_kits,
        @offline_kits ++
          [
            %{
              key: :ghost,
              label: "Ghost Kit",
              file: "install_test_ghost.json",
              tag: "v4.2",
              url: "https://127.0.0.1:1/ghost.json"
            }
          ]
      )

      view = to_ui_kit(conn)
      html = render(view)

      assert has_element?(view, "#uikit-partial"),
             "an operator must be told which package is missing, not left to wonder later"

      assert html =~ "Ghost Kit"
      assert html =~ "v4.2"

      assert has_element?(view, "#toggle-chelekom-card"),
             "a failed package must not cost the one that resolved"
    end

    # The loading line said "the Chelekom bundle" when there are two, and would go stale again the
    # moment a host edits `:official_ui_kits`.
    # I1'S ACCEPTANCE CRITERION, and it was missed the first time: the packages were pinned, the
    # config was right, the failure banners named a tag — and on the SUCCESS path, which is the one
    # an operator normally sees, no version appeared anywhere. Pinning a package is worth nothing to
    # someone who cannot see the pin.
    test "the success path names every package and its version", %{conn: conn} do
      view = to_ui_kit(conn)
      html = render(view)

      assert has_element?(view, "#uikit-versions")
      assert has_element?(view, ".inst-kit-ver")

      for source <- UiKitHandler.resolve_kits().sources do
        assert html =~ source.name
        assert html =~ shown_version(source)
      end
    end

    # A bundle a developer dropped into the kits directory was never fetched, so it has no tag —
    # showing one would be a lie. Its own `version` is what it can honestly claim.
    test "a locally placed bundle reports its own version, not a tag" do
      assert %{sources: sources} = UiKitHandler.resolve_kits()

      # The bundles that were not fetched from an official release and still name a tag.
      assert for(source <- sources, not source.official?, source.tag, do: source.name) == []
    end

    # ONE ROW A PACKAGE WHILE IT DOWNLOADS. A 12 MB kit on a slow line took minutes behind a single
    # spinner that said nothing about which package was still coming, or how far it had got.
    test "a package being fetched has its own row, and its bar fills as it downloads", %{
      conn: conn
    } do
      test = self()
      Application.put_env(:mishka_cms_core, :official_ui_kits, [acme_release_kit()])

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          send(test, {:fetching, self()})
          receive do: (:go -> :ok)
          Req.Test.json(conn, %{"$schema" => "mishka.ui_kit.bundle.v3", "name" => "acme"})
        end
      )

      {:ok, view, _html} = live(conn, "/install")
      view |> form("#install-form", install: @valid) |> render_submit()
      # The download starts in a task after the submit; on a loaded machine that takes past the
      # suite's one second.
      # credo:disable-for-next-line Jump.CredoChecks.AssertReceiveTimeout
      assert_receive {:fetching, download}, 5_000

      assert has_element?(view, "#uikit-fetch-acme", "Acme kit")
      assert has_element?(view, "#uikit-fetch-acme", "v1.2.3")
      assert has_element?(view, "#uikit-fetch-acme", "Checking…")
      refute has_element?(view, "#uikit-fetch-acme progress[value]")

      send(view.pid, {:kit_progress, :acme, {6_291_456, 12_582_912}})

      assert has_element?(view, "#uikit-fetch-acme progress[value='6291456'][max='12582912']")
      assert has_element?(view, "#uikit-fetch-acme", "6.0 / 12.0 MB")

      send(download, :go)
      render_async(view, 15_000)
      refute has_element?(view, "#uikit-loading")
    end

    # A RELEASE FILE IS NAMED BY ITS TAG. The short form was written for a raw path, whose tag is the
    # third segment; a release URL's third segment is `releases`.
    test "a release file that could not be fetched is named by its repository and tag", %{
      conn: conn
    } do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [acme_release_kit()])
      chelekom_downloaded!()

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "") end
      )

      view = to_ui_kit(conn)

      assert has_element?(view, "#uikit-fail-url-acme", "kit@v1.2.3/acme.json")
    end

    # A HOST THAT NAMES ITS KITS IN CONFIG GETS THOSE: there is no release to choose.
    test "configured kits come with no version switch", %{conn: conn} do
      view = to_ui_kit(conn)

      refute has_element?(view, "#uikit-channel")
    end

    test "the version switch fetches the chosen channel's newest release and names it", %{
      conn: conn
    } do
      github_releases!([kit_release("v2-alpha", true), kit_release("v1.9", false)])
      view = to_ui_kit(conn)

      # Arriving fetched the newest stable release.
      assert has_element?(view, "#uikit-channel-stable.on[aria-checked='true']")
      assert has_element?(view, "#uikit-channel-note", "The newest stable release, v1.9.")

      view |> element("#uikit-channel-prerelease") |> render_click()
      render_async(view, 15_000)

      assert has_element?(view, "#uikit-channel-prerelease.on[aria-checked='true']")
      assert has_element?(view, "#uikit-channel-note", "v2-alpha")
      assert has_element?(view, "#uikit-versions", "v2-alpha")

      view |> element("#uikit-channel-stable") |> render_click()
      render_async(view, 15_000)

      assert has_element?(view, "#uikit-channel-stable.on")
      assert has_element?(view, "#uikit-channel-note", "The newest stable release, v1.9.")
    end

    # TODAY'S CASE: only pre-releases attach the kits. Stable still installs, lights the channel it
    # really came from, and says what it took.
    test "stable with no stable kits takes the newest pre-release and says so", %{conn: conn} do
      github_releases!([kit_release("v2-alpha", true)])
      view = to_ui_kit(conn)

      assert has_element?(view, "#uikit-channel-prerelease.on")
      refute has_element?(view, "#uikit-channel-stable.on")

      assert has_element?(
               view,
               "#uikit-channel-fallback",
               "No stable release has the UI kits yet"
             )

      assert has_element?(view, "#uikit-channel-fallback", "v2-alpha")
    end

    test "no partial banner when every package resolved", %{conn: conn} do
      view = to_ui_kit(conn)

      assert %{failures: []} = UiKitHandler.resolve_kits()
      refute has_element?(view, "#uikit-partial")
    end
  end

  # THE DOWNLOAD BELONGS TO THE STEP. Arriving starts it — Stable first, then the newest
  # pre-release, then master — and it is drawn under the version chips, with the rest of the step
  # on the page but out of reach until it has finished.
  describe "the kit download on the UI-kit step" do
    test "arriving downloads Stable at once, its bars under the chips, the rest held", %{
      conn: conn
    } do
      test = self()

      github_releases!([kit_release("v1.9", false, ["chelekom.json"])],
        download: fn conn ->
          send(test, {:fetching, self()})
          receive do: (:go -> :ok)
          named_bundle(conn)
        end
      )

      {:ok, view, _html} = live(conn, "/install")
      view |> form("#install-form", install: @valid) |> render_submit()
      # The download starts in a task after the submit; on a loaded machine that takes past the
      # suite's one second.
      # credo:disable-for-next-line Jump.CredoChecks.AssertReceiveTimeout
      assert_receive {:fetching, download}, 5_000

      assert has_element?(view, "#uikit-channel-stable.on[disabled]")
      assert has_element?(view, "#uikit-channel-master[disabled]")
      assert has_element?(view, "#uikit-loading")

      html = render(view)

      [chips, bars, rest] =
        for id <- ~w(uikit-channel uikit-loading uikit-sections),
            do: html |> :binary.match(~s(id="#{id}")) |> elem(0)

      assert chips < bars and bars < rest,
             "the bars sit between the chips and the rest of the step"

      assert has_element?(view, "#uikit-sections[inert]")
      assert has_element?(view, "#uikit-next[disabled]")
      refute has_element?(view, "#rail-step-0.can")

      # A version cannot change under a running download.
      render_hook(view, "kit_channel", %{"channel" => "master"})
      assert has_element?(view, "#uikit-channel-stable.on")

      send(download, :go)
      render_async(view, 15_000)

      refute has_element?(view, "#uikit-loading")
      refute has_element?(view, "#uikit-sections[inert]")
      refute has_element?(view, "#uikit-next[disabled]")
      refute has_element?(view, "#uikit-channel-stable[disabled]")
      assert has_element?(view, "#uikit-channel-stable.on")
      assert has_element?(view, "#rail-step-0.can")
    end

    test "with no release holding the kits, master is fetched and says so", %{conn: conn} do
      github_releases!([kit_release("v1", false, [])])
      view = to_ui_kit(conn)

      assert has_element?(view, "#uikit-channel-master.on")
      assert has_element?(view, "#uikit-channel-fallback", "No release has the UI kits yet")
      assert has_element?(view, "#uikit-versions", "master")
    end

    test "with the kits nowhere at all, it says so and points to support", %{conn: conn} do
      github_releases!([kit_release("v1", false, [])],
        download: &Plug.Conn.send_resp(&1, 404, "Not Found")
      )

      {:ok, view, _html} = live(conn, "/install")
      view |> form("#install-form", install: @valid) |> render_submit()
      render_async(view, 15_000)

      assert has_element?(view, "#uikit-missing", "The UI-kit packages could not be found.")
      assert has_element?(view, "#uikit-missing", "its master branch does not either")
      assert has_element?(view, "#uikit-support[href='https://github.com/mishka-group']")
      assert has_element?(view, "#uikit-retry")
      refute has_element?(view, "#uikit-toggle")

      # The site still installs without them.
      refute has_element?(view, "#uikit-sections[inert]")
      refute has_element?(view, "#uikit-next[disabled]")
    end
  end

  describe "the kits when GitHub cannot be reached" do
    # NOT THE SAME AS "NOWHERE": the releases could not even be asked about, so the box says that,
    # with the reason, rather than claiming no release has them.
    test "with nothing on disk, it names the failed lookup and points to support", %{conn: conn} do
      Application.delete_env(:mishka_cms_core, :official_ui_kits)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 403, "rate limited") end
      )

      {:ok, view, _html} = live(conn, "/install")
      view |> form("#install-form", install: @valid) |> render_submit()
      render_async(view, 15_000)

      assert has_element?(
               view,
               "#uikit-missing",
               "could not be looked up: GitHub answered HTTP 403"
             )

      assert has_element?(view, "#uikit-support")
    end
  end

  describe "adding a package by URL" do
    setup do
      # The Req stub is global, so an official kit left configured would be served the custom
      # bundle too — and cached under the official kit's filename. Chelekom is on disk already.
      Application.put_env(:mishka_cms_core, :official_ui_kits, [])
      chelekom_downloaded!()
      :ok
    end

    # The whole reason I3 exists: before it, a third-party kit could only be added by placing a file
    # on disk, which an operator running a released image cannot do.
    test "the field and its disclaimer are on the step", %{conn: conn} do
      view = to_ui_kit(conn)

      assert has_element?(view, "#uikit-custom-url")
      assert has_element?(view, "#uikit-custom-add")
      assert has_element?(view, "#uikit-custom-warning")
    end

    # BEFORE the fetch, not after it succeeds — by then the components are already in their admin.
    test "the disclaimer is present before anything is fetched", %{conn: conn} do
      html = conn |> to_ui_kit() |> render()

      assert html =~ "not ours"
      assert html =~ "Mishka takes no responsibility"
    end

    test "a valid bundle joins the picker", %{conn: conn} do
      view = to_ui_kit(conn)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          Req.Test.json(conn, %{
            "$schema" => "mishka.ui_kit.bundle.v3",
            "name" => "acme_via_url",
            "components" => [
              %{
                "name" => "acme-via-url-widget",
                "template" => "<div>w</div>",
                "type" => "general"
              }
            ]
          })
        end
      )

      view
      |> form("#uikit-custom-form", url: "https://e.test/a.json")
      |> render_submit()

      render_async(view, 20_000)

      assert render(view) =~ "acme_via_url"
    end

    test "a refused package reports why and adds nothing", %{conn: conn} do
      view = to_ui_kit(conn)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, "<html>nope</html>") end
      )

      view
      |> form("#uikit-custom-form", url: "https://e.test/bad.json")
      |> render_submit()

      assert has_element?(view, "#uikit-custom-error")
      assert render(view) =~ "not valid JSON"
    end
  end

  describe "ui-kit picker step" do
    test "valid config advances to the picker with the real groups", %{conn: conn} do
      view = to_ui_kit(conn)

      assert has_element?(view, "#installer-uikit")
      assert has_element?(view, "#group-general")
      assert has_element?(view, "#toggle-chelekom-card")
    end

    test "selecting a component locks its dependency, which cannot be unchecked", %{conn: conn} do
      view = to_ui_kit(conn)

      # Start from an empty set so the lock is driven purely by selecting combobox. `scroll_area` is
      # a plain dependency — it is not one of the kit's own mandatory components, so it starts free.
      view |> element("#uikit-clear-all") |> render_click()
      refute has_element?(view, "#toggle-chelekom-scroll-area[disabled]")

      view |> element("#toggle-chelekom-combobox") |> render_click()

      assert has_element?(view, "#toggle-chelekom-scroll-area[checked][disabled]")
      assert render(view) =~ "required"
    end

    # THE KIT'S OWN MANDATORY SET, which is a different lock: 49 of Chelekom's 74 components declare
    # `icon` as a dependency, so the bundle marks it `required` and the picker may not offer it up
    # for deselection even with everything else cleared.
    test "a component the kit declares required is locked from the start", %{conn: conn} do
      view = to_ui_kit(conn)

      view |> element("#uikit-clear-all") |> render_click()

      assert has_element?(view, "#toggle-chelekom-icon[checked][disabled]")
    end

    # WHAT EVERY SITE NEEDS, AND NOTHING ELSE: the kit's own required components start ticked and
    # locked; the rest is the operator's to add, one by one or all at once.
    test "only the components every site needs start ticked", %{conn: conn} do
      view = to_ui_kit(conn)

      assert has_element?(view, "#toggle-chelekom-icon[checked][disabled]")
      refute has_element?(view, "#toggle-chelekom-button[checked]")
      refute has_element?(view, "#toggle-chelekom-card[checked]")
      assert has_element?(view, "#uikit-count", "1 of 136 chosen")
    end

    test "select all / clear update the selection", %{conn: conn} do
      view = to_ui_kit(conn)

      assert view |> element("#uikit-select-all") |> render_click() =~ "136 of 136 chosen"
      # The icon every site needs stays, and is counted.
      assert view |> element("#uikit-clear-all") |> render_click() =~ "1 of 136 chosen"
    end

    test "search filters the visible components", %{conn: conn} do
      view = to_ui_kit(conn)

      html = view |> form("#install-search-form") |> render_change(%{"query" => "accordion"})
      assert html =~ "accordion"
      refute has_element?(view, "#toggle-chelekom-button")
    end

    # Two kits in one picker is the case the whole per-kit engine exists for, and the picker is where
    # it either shows or does not: a styled button and a headless one land under the same heading
    # reading identically, so each says which kit shipped it and the chips narrow to one.
    test "a second kit on disk gets chips and per-component badges", %{conn: conn} do
      write_headless_bundle!()

      view = to_ui_kit(conn)

      assert has_element?(view, "#kit-all")
      assert has_element?(view, "#kit-chelekom")
      assert has_element?(view, "#kit-acme_headless")
      assert has_element?(view, "#toggle-acme-headless-tree")
      assert render(view) =~ "Acme Headless"
      # …and the card says what is actually installed rather than naming one kit.
      assert render(view) =~ "Acme Headless + Chelekom building blocks"

      # Narrowing to one kit hides the other's components without touching the selection.
      view |> element("#kit-acme_headless") |> render_click()
      refute has_element?(view, "#toggle-chelekom-button")
      assert has_element?(view, "#toggle-acme-headless-tree")

      view |> element("#kit-all") |> render_click()
      assert has_element?(view, "#toggle-chelekom-button")
    end

    # With one kit on disk the picker is exactly what it always was — the chips and the per-component
    # kit badges would be answering a question nobody asked.
    test "a single-kit install shows no kit chips", %{conn: conn} do
      view = to_ui_kit(conn)

      refute has_element?(view, "#kit-all")
      refute has_element?(view, ".inst-kit-tag")
      assert render(view) =~ "Chelekom building blocks"
    end

    test "re-entering the picker from config keeps the trimmed selection", %{conn: conn} do
      view = to_ui_kit(conn)
      view |> element("#uikit-clear-all") |> render_click()
      view |> element("#toggle-chelekom-button") |> render_click()

      # Back to config, then forward again — the selection survives (the bundle is not re-fetched).
      view |> element("#uikit-back") |> render_click()
      view |> form("#install-form", install: @valid) |> render_submit()

      assert has_element?(view, "#toggle-chelekom-button[checked]")
      refute has_element?(view, "#toggle-chelekom-accordion[checked]")
    end
  end

  describe "per-component variant config" do
    test "a selected component shows a variant cog that opens a config panel", %{conn: conn} do
      view = to_ui_kit(conn)
      refute has_element?(view, "#config-chelekom-button")

      # button exposes variant/color axes, so once it is selected it gets a cog.
      view |> element("#toggle-chelekom-button") |> render_click()
      assert has_element?(view, "#config-chelekom-button")
      refute has_element?(view, "#config-panel-chelekom-button")

      view |> element("#config-chelekom-button") |> render_click()

      # The panel opens and the kit-default value is rendered locked (a disabled checkbox).
      assert has_element?(view, "#config-panel-chelekom-button")
      assert has_element?(view, "#config-panel-chelekom-button input[disabled]")
    end

    test "ticking a non-default variant persists it (regression: phx-value vs native 'on')", %{
      conn: conn
    } do
      view = to_ui_kit(conn)
      view |> element("#toggle-chelekom-button") |> render_click()
      view |> element("#config-chelekom-button") |> render_click()

      view
      |> element("#config-panel-chelekom-button input[phx-value-opt='bordered']")
      |> render_click()

      assert has_element?(
               view,
               "#config-panel-chelekom-button input[phx-value-opt='bordered'][checked]"
             )
    end

    test "Reset defaults clears the component's chosen variants", %{conn: conn} do
      view = to_ui_kit(conn)
      view |> element("#toggle-chelekom-button") |> render_click()
      view |> element("#config-chelekom-button") |> render_click()

      view
      |> element("#config-panel-chelekom-button input[phx-value-opt='bordered']")
      |> render_click()

      view |> element("#config-panel-chelekom-button button.rst") |> render_click()

      refute has_element?(
               view,
               "#config-panel-chelekom-button input[phx-value-opt='bordered'][checked]"
             )
    end
  end

  describe "settings step" do
    test "the picker advances to the settings step, prefilled from the config", %{conn: conn} do
      view = to_settings(conn)

      assert has_element?(view, "#installer-settings")
      # Title defaults to the entered site name; the email "from" to noreply@<host>, with `.test`
      # after a dotless host.
      assert has_element?(view, "#install-set-site-title[value='My CMS']")
      assert has_element?(view, "#install-set-mailer-from[value='noreply@localhost.test']")
      assert has_element?(view, "#install-settings-submit")

      # ALWAYS ON. Every page of a site, an extension's included, is drawn in the starter's header
      # and footer, so the box says what the install does and offers no way out of it.
      assert has_element?(
               view,
               "#install-starter-content input[type=checkbox][checked][disabled]"
             )

      # THE COPY PROMISES WHAT IS WRITTEN, which is one home page and no longer an about, a contact
      # and a privacy page beside it, and says why it is not a choice.
      assert has_element?(view, "#install-starter-content", "Add a starter home page")
      assert has_element?(view, "#install-starter-content", "always added")
      assert has_element?(view, "#install-starter-content", "header and footer every page")
      refute has_element?(view, "#install-starter-content", "about")
      refute has_element?(view, "#install-starter-content", "contact")
      refute has_element?(view, "#install-starter-content", "privacy")
    end

    # A DISABLED BOX SUBMITS NOTHING, and the form carries no other field of that name to untick it
    # through: `MishkaCmsCore.Install.Bootstrap` writes the starter whatever arrives.
    test "the starter box cannot be unticked, there or after a trip back to the kit step", %{
      conn: conn
    } do
      view = to_settings(conn)

      refute has_element?(view, ~s(#install-settings-form [name="settings[starter_content]"]))

      view |> element("#settings-back") |> render_click()
      view |> element("#uikit-next") |> render_click()

      assert has_element?(
               view,
               "#install-starter-content input[type=checkbox][checked][disabled]"
             )
    end

    # THE DOCUMENTED LOCAL DOMAIN. `noreply@localhost` has no dot, so the step offered an address
    # its own Install button refused, and nobody could finish without typing another one.
    test "a localhost install's pre-filled from address installs as offered", %{conn: conn} do
      view = to_settings(conn)

      view |> form("#install-settings-form") |> render_submit()

      assert has_element?(view, "#install-progress")
      render_async(view, 15_000)

      assert has_element?(view, "#install-complete")
      assert Settings.get("mailer.from") == "noreply@localhost.test"
    end

    test "a real domain's pre-filled from address is noreply at that domain", %{conn: conn} do
      view = to_settings(conn, %{@valid | "host" => "acme.com"})

      assert has_element?(view, "#install-set-mailer-from[value='noreply@acme.com']")

      view |> form("#install-settings-form") |> render_submit()

      assert has_element?(view, "#install-progress")
      render_async(view, 15_000)

      assert has_element?(view, "#install-complete")
      assert Settings.get("mailer.from") == "noreply@acme.com"
    end

    test "an invalid email is rejected and does NOT install", %{conn: conn} do
      view = to_settings(conn)

      html =
        view
        |> form("#install-settings-form",
          settings: %{"site.title" => "Acme", "mailer.from" => "not-an-email"}
        )
        |> render_submit()

      assert html =~ "must be a valid email"
      assert has_element?(view, "#installer-settings")
      refute Install.installed?()
    end
  end

  describe "the languages on the settings step" do
    test "English starts as the primary, with no remove button, and a crafted remove keeps it", %{
      conn: conn
    } do
      view = to_settings(conn)

      assert has_element?(view, "#install-language-list li:first-child#install-language-en")
      assert has_element?(view, "#install-language-en.is-primary")
      refute has_element?(view, "#install-language-remove-en")
      refute has_element?(view, "#install-language-primary-en")
      refute has_element?(view, "#install-language-option-en")

      render_click(view, "remove_language", %{"code" => "en"})

      assert has_element?(view, "#install-language-en.is-primary")
    end

    test "an empty search lists every language not chosen yet", %{conn: conn} do
      view = to_settings(conn)

      assert has_element?(view, "#install-language-search-form #install-language-search")
      assert has_element?(view, "#install-language-options[role=listbox]")
      assert has_element?(view, "#install-language-option-fa[role=option][type=button]")

      assert language_options(view) ==
               Enum.sort_by(Languages.known() -- ["en"], &Languages.name/1)

      refute has_element?(view, "#install-language-none")
    end

    test "a search narrows the list by name, in any case and trimmed", %{conn: conn} do
      view = to_settings(conn)

      for query <- ["pers", "  PERS  ", "Persian"] do
        search_languages(view, query)

        assert language_options(view) == ["fa"], inspect(query)
      end
    end

    test "a search narrows the list by code", %{conn: conn} do
      view = to_settings(conn)

      for query <- ["fa", " FA "] do
        search_languages(view, query)

        assert language_options(view) == ["fa"], inspect(query)
      end
    end

    test "a search nothing matches says so instead of listing", %{conn: conn} do
      view = to_settings(conn)

      search_languages(view, "  zzz ")

      assert has_element?(view, "#install-language-none", "zzz")
      refute has_element?(view, "#install-language-options")

      search_languages(view, "")

      refute has_element?(view, "#install-language-none")
      assert has_element?(view, "#install-language-option-fa")
    end

    test "a language chosen from the list is added and the search is cleared", %{conn: conn} do
      view = to_settings(conn)

      search_languages(view, "pers")
      view |> element("#install-language-option-fa") |> render_click()

      assert has_element?(view, "#install-language-list li:first-child#install-language-en")
      assert has_element?(view, "#install-language-list li:nth-child(2)#install-language-fa")
      assert has_element?(view, "#install-language-remove-fa")
      assert has_element?(view, "#install-language-primary-fa")
      assert has_element?(view, "#install-language-search[value='']")

      assert language_options(view) ==
               Enum.sort_by(Languages.known() -- ["en", "fa"], &Languages.name/1)

      refute has_element?(view, "#install-language-error")

      view |> element("#install-language-remove-fa") |> render_click()

      refute has_element?(view, "#install-language-fa")
      assert has_element?(view, "#install-language-option-fa")
    end

    test "Enter adds the only match and does nothing else, never the install", %{conn: conn} do
      view = to_settings(conn)

      view |> form("#install-language-search-form", language_query: "an") |> render_submit()

      assert has_element?(view, "#installer-settings")
      refute has_element?(view, "#install-progress")
      refute has_element?(view, "#install-language-list li:nth-child(2)")
      assert has_element?(view, "#install-language-search[value='an']")

      view |> form("#install-language-search-form", language_query: "pers") |> render_submit()

      assert has_element?(view, "#install-language-list li:nth-child(2)#install-language-fa")
      assert has_element?(view, "#install-language-search[value='']")
      refute has_element?(view, "#install-progress")
      refute Install.installed?()
    end

    test "Make primary moves a language to the front and frees English to be removed", %{
      conn: conn
    } do
      view = to_settings(conn)

      view |> element("#install-language-option-fa") |> render_click()
      view |> element("#install-language-primary-fa") |> render_click()

      assert has_element?(view, "#install-language-list li:first-child#install-language-fa")
      assert has_element?(view, "#install-language-fa.is-primary")
      refute has_element?(view, "#install-language-remove-fa")
      refute has_element?(view, "#install-language-primary-fa")
      assert has_element?(view, "#install-language-list li:nth-child(2)#install-language-en")
      refute has_element?(view, "#install-language-en.is-primary")
      assert has_element?(view, "#install-language-primary-en")

      view |> element("#install-language-remove-en") |> render_click()

      assert has_element?(view, "#install-language-list li:first-child#install-language-fa")
      refute has_element?(view, "#install-language-en")
      refute has_element?(view, "#install-language-list li:nth-child(2)")
      assert has_element?(view, "#install-language-option-en")
    end

    test "a crafted remove of the primary or make-primary of an unchosen code changes nothing", %{
      conn: conn
    } do
      view = to_settings(conn)

      view |> element("#install-language-option-fa") |> render_click()
      view |> element("#install-language-primary-fa") |> render_click()

      render_click(view, "remove_language", %{"code" => "fa"})

      for code <- ["de", "xx", "", "FA"] do
        render_click(view, "make_primary", %{"code" => code})
      end

      assert has_element?(view, "#install-language-list li:first-child#install-language-fa")
      assert has_element?(view, "#install-language-list li:nth-child(2)#install-language-en")
      refute has_element?(view, "#install-language-list li:nth-child(3)")
      refute has_element?(view, "#install-language-de")
    end

    test "a code the list does not offer cannot be added", %{conn: conn} do
      view = to_settings(conn)

      for code <- ["xx", "Persian", "", "en", "FA", " fa"] do
        render_click(view, "add_language", %{"language" => code})

        assert has_element?(view, "#install-language-error"), inspect(code)
      end

      assert has_element?(view, "#install-language-en")
      refute has_element?(view, "#install-language-list li:nth-child(2)")

      view |> element("#install-language-option-fa") |> render_click()

      refute has_element?(view, "#install-language-error")
    end

    test "the chosen languages and their order survive a trip back to the kit step", %{
      conn: conn
    } do
      view = to_settings(conn)

      view |> element("#install-language-option-fa") |> render_click()
      view |> element("#install-language-primary-fa") |> render_click()
      view |> element("#settings-back") |> render_click()
      view |> element("#uikit-next") |> render_click()

      assert has_element?(view, "#install-language-list li:first-child#install-language-fa")
      assert has_element?(view, "#install-language-list li:nth-child(2)#install-language-en")
    end

    test "finishing the install saves them to the new site, the primary first", %{conn: conn} do
      view = to_settings(conn)

      view |> element("#install-language-option-fa") |> render_click()
      view |> element("#install-language-primary-fa") |> render_click()
      view |> form("#install-settings-form") |> render_submit()

      assert has_element?(view, "#step-languages")
      render_async(view, 15_000)
      assert has_element?(view, "#install-complete")

      assert [site] = Site |> Ash.read!(authorize?: false)
      assert Settings.get_own("site.languages", nil, site.id) == ["fa", "en"]
      assert Languages.site(site.id) == ["fa", "en"]
      assert Languages.primary(site.id) == "fa"
    end
  end

  describe "how the site's addresses name a language" do
    test "starts with no prefix for the primary language, each choice showing the site's own", %{
      conn: conn
    } do
      view = to_settings(conn)

      assert has_element?(view, "#install-language-urls-prefix_others input[checked]")
      refute has_element?(view, "#install-language-urls-prefix_all input[checked]")
      assert view |> element("#install-language-urls-prefix_others") |> render() =~ "/blog"

      view |> element("#install-language-option-fa") |> render_click()

      assert view |> element("#install-language-urls-prefix_others") |> render() =~ "/fa/blog"
      assert view |> element("#install-language-urls-prefix_all") |> render() =~ "/en/blog"
    end

    test "the choice is saved to the new site, with its languages", %{conn: conn} do
      view = to_settings(conn)

      view |> element("#install-language-option-fa") |> render_click()

      view
      |> form("#install-language-urls-form", language_urls: "prefix_all")
      |> render_change()

      assert has_element?(view, "#install-language-urls-prefix_all input[checked]")

      view |> form("#install-settings-form") |> render_submit()
      render_async(view, 15_000)
      assert has_element?(view, "#install-complete")

      assert [site] = Site |> Ash.read!(authorize?: false)
      assert Settings.get_own("site.language_urls", nil, site.id) == "prefix_all"
      assert Languages.url_mode(site.id) == "prefix_all"
    end

    test "a crafted value it does not offer changes nothing", %{conn: conn} do
      view = to_settings(conn)

      render_change(view, "language_urls", %{"language_urls" => "sideways"})

      assert has_element?(view, "#install-language-urls-prefix_others input[checked]")
    end
  end

  defp search_languages(view, query) do
    view
    |> form("#install-language-search-form", language_query: query)
    |> render_change()
  end

  defp language_options(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#install-language-options [role=option]")
    |> LazyHTML.attribute("phx-value-language")
  end

  describe "commit" do
    test "installs behind a live checklist, then shows success", %{conn: conn} do
      own_media_dir!()
      view = submit_settings(conn)

      # The install runs asynchronously behind a live progress checklist.
      assert has_element?(view, "#install-progress")
      assert has_element?(view, "#step-permissions")
      assert has_element?(view, "#step-components")
      render_async(view, 15_000)

      # Every phase finished — the all-green checklist stays up with a Continue CTA, THEN the done screen.
      assert has_element?(view, "#install-complete")
      refute has_element?(view, "#install-done")
      view |> element("#install-finish") |> render_click()

      assert has_element?(view, "#install-done")
      assert has_element?(view, "#install-go-login[href='/auth?master_user=true']")
      assert render(view) =~ "localhost"

      assert Install.installed?()
    end

    test "makes the master user and site, writes the chosen settings and the site's pages", %{
      conn: conn
    } do
      own_media_dir!()
      view = submit_settings(conn)
      render_async(view, 15_000)
      view |> element("#install-finish") |> render_click()

      assert [user] = User |> Ash.Query.filter(is_nil(site_id)) |> Ash.read!(authorize?: false)
      assert to_string(user.email) == "owner@example.com"
      assert %DateTime{} = user.confirmed_at

      assert [site] = Site |> Ash.read!(authorize?: false)
      assert site.master == true
      assert site.host == "localhost"
      assert site.name == "my-cms"

      # The essential settings landed in the store via Bootstrap.
      assert Settings.get("site.title") == "Acme Docs"
      assert Settings.get("mailer.from") == "hello@acme.test"

      # AND THE NEW SITE ANSWERS SOMETHING. The starter is not a choice, so every install gets a
      # site with a home page on it, beside the sign-in pages every site gets.
      pages =
        MishkaCmsCore.Runtime.Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.read!(authorize?: false, page: [limit: 20])
        |> Map.fetch!(:results)

      assert pages
             |> Enum.filter(&(&1.section == "starter"))
             |> Enum.map(& &1.path)
             |> Enum.sort() == ["/:lang"]

      assert Enum.count(pages, &(&1.section == "auth")) == 8
    end

    test "a per-component compile broadcast is handled live during install", %{conn: conn} do
      view = to_settings(conn)

      view
      |> form("#install-settings-form",
        settings: %{"site.title" => "Acme", "mailer.from" => "a@b.test"}
      )
      |> render_submit()

      # The compiler broadcasts {:bulk_compile, …} per component; the LV must handle it (sync_after_bulk
      # is a no-op in test, so inject one directly) without crashing, and still complete.
      send(view.pid, {:bulk_compile, %{kind: :component, name: "chelekom-button"}})

      render_async(view, 15_000)
      assert has_element?(view, "#install-complete")
    end
  end

  describe "dev sample-data step" do
    setup do
      Application.put_env(:mishka_cms_core, :env_dev?, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :env_dev?) end)
      :ok
    end

    test "the dev-seed entry is hidden outside dev", %{conn: conn} do
      Application.delete_env(:mishka_cms_core, :env_dev?)
      {:ok, view, _html} = live(conn, "/install")
      refute has_element?(view, "#install-dev-seeds")
    end

    test "in dev, offers the dev-seed entry and its extension categories", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/install")
      assert has_element?(view, "#install-dev-seeds")

      view |> element("#install-dev-seeds") |> render_click()
      assert has_element?(view, "#installer-seeds")

      # The extension seeds, all checked by default. Every UI-kit component is always installed, so
      # there is nothing to choose for the kits.
      refute has_element?(view, "#seed-chelekom")
      assert has_element?(view, "#seed-blog input[checked]")
      assert has_element?(view, "#seed-document input[checked]")

      # Extensions are labelled by their name, not "Blog content".
      html = render(view)
      assert html =~ "Mishka Blog"
      assert html =~ "Mishka Document"
    end

    test "loads the core sample data behind a live checklist, then the done screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/install")
      view |> element("#install-dev-seeds") |> render_click()

      # Trim to the core only (deselect the extension seeds) for a fast test.
      view |> element("#seed-blog input") |> render_click()
      view |> element("#seed-document input") |> render_click()

      view |> element("#seeds-run") |> render_click()

      # Runs async behind the same checklist the real install uses.
      assert has_element?(view, "#install-progress")
      assert has_element?(view, "#step-core")
      render_async(view, 30_000)

      assert has_element?(view, "#install-complete")
      view |> element("#install-finish") |> render_click()

      assert has_element?(view, "#install-done")
      assert render(view) =~ "Sample data loaded"
      assert Install.installed?()
      assert Site |> Ash.read!(authorize?: false) != []
    end
  end

  # THE PICKER IS THE INSTALLER'S OWN REGISTRY DRAWN. Nothing in the wizard names an extension, so
  # these register a plugin the way a real one registers itself and assert the screen follows.
  describe "the extensions step" do
    setup do
      {:ok, _registered} = MishkaBlog.Plugins.Installer.register()

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          MishkaBlog.Plugins.Installer.config(:__event__),
          :start,
          false
        )

      :ok
    end

    test "offers every registered extension, with the label the plugin declared", %{conn: conn} do
      view = to_ui_kit(conn)

      assert has_element?(view, "#install-extensions")
      assert has_element?(view, "#extension-mishka_blog")
      assert render(view) =~ "Blog"
    end

    test "installs the one that was ticked", %{conn: conn} do
      view = to_ui_kit(conn)

      view |> element("#uikit-clear-all") |> render_click()
      view |> element("#toggle-chelekom-button") |> render_click()
      view |> element("#toggle-extension-mishka_blog") |> render_click()
      view |> element("#uikit-next") |> render_click()

      view
      |> form("#install-settings-form",
        settings: %{"site.title" => "Acme", "mailer.from" => "a@b.c"}
      )
      |> render_submit()

      render_async(view, 30_000)

      assert has_element?(view, "#install-complete")
      assert "blog-post-list" in installed_components()
    end

    # TICKING NOTHING IS AN ANSWER, and the step still runs — it just has nothing to install.
    test "installs none of it when none was ticked", %{conn: conn} do
      view = to_settings(conn)

      view
      |> form("#install-settings-form",
        settings: %{"site.title" => "Acme", "mailer.from" => "a@b.c"}
      )
      |> render_submit()

      render_async(view, 30_000)

      assert has_element?(view, "#install-complete")
      refute "blog-post-list" in installed_components()
    end
  end

  defp installed_components do
    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.select([:name])
    |> Ash.read!(authorize?: false, page: [limit: 500])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end
end
