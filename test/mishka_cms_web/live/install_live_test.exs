defmodule MishkaCmsWeb.InstallLiveTest do
  @moduledoc """
  Real LiveView tests for the installer wizard (config → ui-kit picker → settings → done). They drive
  the actual endpoint + router + InstallGate plug, load the real Chelekom bundle for the picker, and
  assert the real database side effects of `Bootstrap.run/1`. `async: false` (the install flag is
  process-global). The UI-kit install side effects are test-safe: `sync_after_bulk` is a no-op under
  `env_test?`, so the picker step's install path doesn't compile components.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Install
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

  # THE STYLED KIT ONLY, so this suite never touches the network. The shipped default also offers a
  # headless package whose bundle has no published URL yet, and letting every test in this file wait
  # on that 404 made the suite both slow and dependent on the internet. The tests that care about a
  # failing package configure one deliberately.
  @offline_kits [
    %{
      key: :styled,
      label: "Chelekom — styled",
      file: "chelekom.json",
      tag: "test",
      url: "https://127.0.0.1:1/never-reached.json"
    }
  ]

  setup do
    :persistent_term.put(:mishka_installed, false)
    official = Application.fetch_env!(:mishka_cms_core, :official_ui_kits)
    Application.put_env(:mishka_cms_core, :official_ui_kits, @offline_kits)

    # EVERY TEST GETS ITS OWN KITS DIRECTORY, holding the shipped bundle. The real one is core's
    # priv, which the core suite writes fixture kits into while this suite runs beside it: read
    # there, a test counts a kit it never added; swept there, it deletes one the core suite is
    # using. The headless bundle and `add_custom_kit/2` write here, and the directory goes with
    # the test.
    kits_dir = Path.join(System.tmp_dir!(), "install_kits_#{System.unique_integer([:positive])}")
    File.mkdir_p!(kits_dir)
    File.ln_s!(UiKitHandler.default_bundle_path(), Path.join(kits_dir, "chelekom.json"))
    Application.put_env(:mishka_cms_core, :ui_kits_dir, kits_dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :ui_kits_dir)
      File.rm_rf(kits_dir)
    end)

    System.delete_env("MISHKA_SETUP_TOKEN")
    # The settings step renders from the registry; build it so `site.title` / `mailer.from` exist.
    Settings.load_definitions()
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Application.put_env(:mishka_cms_core, :official_ui_kits, official)
      :persistent_term.erase({Settings, :definitions})
      System.delete_env("MISHKA_SETUP_TOKEN")
      SettingsState.restore(snapshot)
    end)

    :ok
  end

  defp to_ui_kit(conn, config \\ @valid) do
    {:ok, view, _html} = live(conn, "/install")
    view |> form("#install-form", install: config) |> render_submit()

    # The real ~7MB Chelekom bundle is parsed in start_async — give it room past the 100ms default.
    render_async(view, 15_000)

    # The picker is collapsed by default (everything selected) — open it so the list + toolbar render.
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

  defp to_settings(conn, config \\ @valid) do
    view = to_ui_kit(conn, config)

    # Trim the all-selected default to a single component so commit installs just button (+ its icon dep).
    view |> element("#uikit-clear-all") |> render_click()
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

    test "select all / clear update the selection", %{conn: conn} do
      view = to_ui_kit(conn)

      assert view |> element("#uikit-select-all") |> render_click() =~ "136 of 136 chosen"
      assert view |> element("#uikit-clear-all") |> render_click() =~ "0 of 136 chosen"
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

  describe "settings step" do
    test "the picker advances to the settings step, prefilled from the config", %{conn: conn} do
      view = to_settings(conn)

      assert has_element?(view, "#installer-settings")
      # Title defaults to the entered site name; the email "from" to noreply@<host>, with `.test`
      # after a dotless host.
      assert has_element?(view, "#install-set-site-title[value='My CMS']")
      assert has_element?(view, "#install-set-mailer-from[value='noreply@localhost.test']")
      assert has_element?(view, "#install-settings-submit")

      # ON UNLESS THE USER SAYS OTHERWISE. A first install with an empty site is a `/` that answers
      # nothing, and the pages are four rows they can edit or delete.
      assert has_element?(view, "#install-starter-content input[type=checkbox][checked]")
    end

    # THE STEP IS REBUILT FROM DEFAULTS on the way forward, and the box is not one of them: a user
    # who says no, steps back to look at the kit again and comes forward would install the four
    # pages they had just turned down.
    test "unticking the starter pages survives a trip back to the kit step", %{conn: conn} do
      view = to_settings(conn)

      view
      |> form("#install-settings-form", settings: %{"starter_content" => "false"})
      |> render_change()

      view |> element("#settings-back") |> render_click()
      view |> element("#uikit-next") |> render_click()

      assert has_element?(view, "#install-starter-content")
      refute has_element?(view, "#install-starter-content input[type=checkbox][checked]")
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

  describe "commit" do
    test "installs the master + site and writes the chosen settings, then shows success", %{
      conn: conn
    } do
      view = to_settings(conn)

      view
      |> form("#install-settings-form",
        settings: %{"site.title" => "Acme Docs", "mailer.from" => "hello@acme.test"}
      )
      |> render_submit()

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

      # AND THE NEW SITE ANSWERS SOMETHING. The starter checkbox rides the same form, on by
      # default, so a user who changed nothing gets a site with pages on it, beside the sign-in
      # pages every site gets.
      pages =
        MishkaCmsCore.Runtime.Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.read!(authorize?: false, page: [limit: 20])
        |> Map.fetch!(:results)

      assert pages
             |> Enum.filter(&(&1.section == "starter"))
             |> Enum.map(& &1.path)
             |> Enum.sort() ==
               ["/:lang", "/:lang/about", "/:lang/contact", "/:lang/privacy"]

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
end
