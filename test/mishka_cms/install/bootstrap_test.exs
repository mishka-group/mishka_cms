# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.BootstrapTest do
  @moduledoc """
  Real end-to-end tests for the first-run bootstrap: it actually writes the master user, the
  master site, and the `*` grant through the real Ash actions, then asserts the resulting
  database + install state. No mocks — only the side effects are kept test-safe (Oban is in
  `:manual` mode, so `compile_site/2`'s queued asset job does not run).
  """
  use MishkaCms.DataCase, async: false
  use Oban.Testing, repo: MishkaCms.Repo

  import Swoosh.TestAssertions

  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Install.Bootstrap
  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Media, Page, Stylesheet}
  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @params %{
    email: "owner@example.com",
    password: "Password123!",
    site_name: "My CMS",
    host: "Example.com"
  }

  # EVERY RUN WRITES THE STARTER, and its logo is a file of the master site's media library: this
  # test's own folder, not `priv/static`.
  setup do
    :persistent_term.erase(:mishka_installed)
    dir = Path.join(System.tmp_dir!(), "bootstrap_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  describe "run/1" do
    test "creates a confirmed master user (no email), grants *, creates the master site, marks installed" do
      assert {:ok, %{user: user, site: site}} = Bootstrap.run(@params)

      # Master user: site_id nil, auto-confirmed (no confirmation email), carries a JWT.
      assert is_nil(user.site_id)
      assert to_string(user.email) == "owner@example.com"
      assert %DateTime{} = reload_user(user).confirmed_at
      assert is_binary(user.__metadata__[:token])
      refute_email_sent()

      # The "*" permission is granted via exactly one UserPermission row.
      star = Permission |> Ash.Query.filter(name == "*") |> Ash.read_one!(authorize?: false)

      assert [grant] =
               UserPermission
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read!(authorize?: false)

      assert grant.permission_id == star.id

      # Master site: master flag set, name slugified, host down-cased.
      assert site.master == true
      assert site.name == "my-cms"
      assert site.host == "example.com"

      # Install flag flipped — gate will now 404 /install.
      assert Install.installed?()
    end

    test "creates the core's names, so a narrow admin can be granted" do
      assert {:ok, _} = Bootstrap.run(@params)

      stored = Permission |> Ash.read!(authorize?: false, page: false) |> Map.new(&{&1.name, &1})

      for {name, description} <- Bootstrap.permissions() do
        assert stored[name].description == description, name
      end

      for name <- [
            "admin:dashboard:runtime:*",
            "admin:api:runtime:*",
            "admin:dashboard:runtime:page",
            "admin:api:runtime:page",
            "admin:dashboard:code",
            "admin:api:code"
          ] do
        assert Map.has_key?(stored, name), name
      end
    end

    # AN EXTENSION'S NAMES ARE ITS OWN: installing it creates them, with its components and pages.
    test "creates no blog or document name" do
      assert {:ok, _} = Bootstrap.run(@params)

      stored = Permission |> Ash.read!(authorize?: false, page: false) |> Enum.map(& &1.name)

      assert Enum.filter(stored, &(&1 =~ ~r/^admin:[a-z]+:(blog|document)(:|$)/)) == []
    end

    # THE BUILDER HAS NO NAME OF ITS OWN: a type's own runtime name, or code, opens its builder.
    test "creates no builder name" do
      names = Enum.map(Bootstrap.permissions(), &elem(&1, 0))

      assert Enum.filter(names, &(&1 =~ ~r/^admin:[a-z]+:builder(:|$)/)) == []
    end

    test "creates only names of the grammar, each once" do
      names = Enum.map(Bootstrap.permissions(), &elem(&1, 0))

      assert names == Enum.uniq(names)

      for name <- names do
        assert name =~
                 ~r/^(\*|admin:\*|admin:(dashboard|api)(:[a-z][a-z0-9_]*)*:(\*|[a-z][a-z0-9_]*))$/,
               name
      end
    end

    test "keeps a name stored before, and adds only the missing ones" do
      kept =
        create_permission!(name: "admin:dashboard:runtime:page", description: "Written by hand.")

      assert {:ok, _} = Bootstrap.run(@params)
      assert {:ok, _} = Bootstrap.ensure_permissions()

      assert [%{id: id, description: "Written by hand."}] =
               Permission
               |> Ash.Query.filter(name == "admin:dashboard:runtime:page")
               |> Ash.read!(authorize?: false)

      assert id == kept.id

      assert Permission |> Ash.read!(authorize?: false, page: false) |> length() ==
               length(Bootstrap.permissions())
    end

    test "reuses an existing * permission instead of duplicating it" do
      create_permission!(name: "*")

      assert {:ok, _} = Bootstrap.run(@params)

      stars = Permission |> Ash.Query.filter(name == "*") |> Ash.read!(authorize?: false)
      assert length(stars) == 1
    end

    test "returns an error and does not mark installed when inputs are invalid" do
      assert {:error, _} = Bootstrap.run(%{@params | password: "short"})
      refute Install.installed?()
    end

    test "writes the supplied essential settings through the settings store" do
      Settings.load_definitions()

      snapshot = SettingsState.snapshot()

      on_exit(fn ->
        :persistent_term.erase({Settings, :definitions})
        SettingsState.restore(snapshot)
      end)

      assert {:ok, _} =
               Bootstrap.run(
                 Map.put(@params, :settings, %{
                   "site.title" => "Acme",
                   "mailer.from" => "hi@acme.test"
                 })
               )

      assert Settings.get("site.title") == "Acme"
      assert Settings.get("mailer.from") == "hi@acme.test"

      # The setting landed under its registered category (notifications), not the put-default "general".
      from =
        MishkaCmsCore.Runtime.Setting
        |> Ash.Query.filter(key == "mailer.from")
        |> Ash.read_one!(authorize?: false)

      assert from.category == "email"
    end
  end

  # THE STEP LIST IS THE INSTALLER'S PROGRESS LIST, drawn from `steps/0`, so a phase that is not in
  # it is a phase nobody watching the install is told about.
  describe "the starter content step" do
    test "is one of the ordered phases, before the compile" do
      ids = Bootstrap.steps() |> Enum.map(&elem(&1, 0))

      assert :starter_content in ids

      assert Enum.find_index(ids, &(&1 == :starter_content)) <
               Enum.find_index(ids, &(&1 == :compile)),
             "content has to be written before the step that compiles it"
    end

    # WITH NO COMPONENTS AT ALL, which is the install this content exists to survive: the user may
    # deselect every one of them, and a starter page drawing `chelekom-card` would put the runtime's
    # red refusal box on the first page of a brand new site.
    test "writes the home page, the logo, the layout, the components, the theme and an error page" do
      test_pid = self()

      assert {:ok, %{site: site}} =
               Bootstrap.run(
                 Map.put(@params, :component_selection, %{}),
                 &send(test_pid, &1)
               )

      # ONE PAGE: about, contact and privacy are the dev seeds', not a first install's.
      assert starter_pages(site) |> Enum.map(& &1.path) == ["/:lang"]
      assert_received {:starter_content, :log, "1 page, 2 components"}

      assert names(Component, site) == ["site-footer", "site-header"]
      assert names(Layout, site) == ["auth", "site-main"]
      assert names(Stylesheet, site) == ["site-theme"]
      assert [_error_page] = rows(ErrorPage, site)

      for page <- starter_pages(site) do
        refute page.template =~ "chelekom-", "#{page.path} needs a kit the user may not have"
        refute page.template =~ "style=", "#{page.path} carries an inline style"
        refute page.template =~ "<script", "#{page.path} carries a script tag"
      end
    end

    # THE INSTALLED SITE IS THE MASTER, so the logo is a file of its own media library, and the
    # header and the home page name the row's address.
    test "puts the logo in the master site's media library, and the header draws it" do
      assert {:ok, %{site: site}} =
               Bootstrap.run(Map.put(@params, :component_selection, %{}))

      assert site.master
      assert [logo] = rows(Media, site)
      assert {logo.name, logo.type, logo.format} == {"mishka-logo", :images, "png"}
      assert String.starts_with?(logo.relative_path, "/uploads/#{site.id}/media/")

      header = rows(Component, site) |> Enum.find(&(&1.name == "site-header"))
      assert Enum.find(header.attrs, &(&1.name == "logo")).opts["default"] == logo.relative_path

      home = starter_pages(site) |> hd()
      assert home.template =~ ~s(src="#{logo.relative_path}")
    end

    # NOT A CHOICE: every page of the site, an extension's included, is drawn in the `site-main`
    # layout, so a site without it has no frame for any of them. The installer's box cannot be
    # unticked, and a caller that asks for none gets it all the same.
    test "writes the starter even when a caller asks for none" do
      test_pid = self()

      assert {:ok, %{site: site}} =
               Bootstrap.run(Map.put(@params, :starter_content, false), &send(test_pid, &1))

      assert starter_pages(site) |> Enum.map(& &1.path) == ["/:lang"]
      assert names(Component, site) == ["site-footer", "site-header"]
      assert names(Layout, site) == ["auth", "site-main"]
      assert names(Stylesheet, site) == ["site-theme"]
      assert [_logo] = rows(Media, site)
      assert_received {:starter_content, :log, "1 page, 2 components"}
      refute_received {:starter_content, :log, "Skipped" <> _}
    end

    test "hangs the home page on the layout every page of the site is drawn in" do
      assert {:ok, %{site: site}} = Bootstrap.run(@params)

      [home] = starter_pages(site)
      assert home.layout_id == MishkaCmsCore.Runtime.SiteLayout.layout_id(site.id)
    end

    # RUN AGAIN, IT ADDS NOTHING. The dev seeds run this on every reseed, and an admin may press an
    # install step twice.
    test "a second run adds no second copy of anything" do
      assert {:ok, %{site: site}} = Bootstrap.run(@params)

      before = {starter_pages(site) |> length(), names(Component, site), names(Layout, site)}
      logo = rows(Media, site)

      StarterContent.seed!(site)

      assert {starter_pages(site) |> length(), names(Component, site), names(Layout, site)} ==
               before

      assert rows(Media, site) == logo
    end
  end

  # A site owner's plugin that says which languages the install saved, and for which site.
  defmodule LanguagesHeard do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "installer:languages:saved"

    @impl true
    def call(saved) do
      send(self(), {:languages_saved, saved})
      {:reply, saved}
    end
  end

  describe "the languages step" do
    setup do
      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)
      :ok
    end

    test "runs once the site exists and before any page is written" do
      ids = Bootstrap.steps() |> Enum.map(&elem(&1, 0))
      at = fn id -> Enum.find_index(ids, &(&1 == id)) end

      assert at.(:site) < at.(:languages)
      assert at.(:languages) < at.(:starter_content)
      assert at.(:languages) < at.(:extensions)
    end

    test "saves the chosen languages as the new site's own list, the first as its primary" do
      parent = self()

      assert {:ok, %{site: site}} =
               Bootstrap.run(
                 Map.put(@params, :languages, ["en", "fa"]),
                 &send(parent, {:progress, &1})
               )

      assert Settings.get_own("site.languages", nil, site.id) == ["en", "fa"]
      assert Languages.site(site.id) == ["en", "fa"]
      assert Languages.primary(site.id) == "en"
      assert_received {:progress, {:languages, :log, "English and Persian"}}
    end

    test "leaves the site reading the global list when given none" do
      assert {:ok, %{site: site}} = Bootstrap.run(@params)

      assert Settings.get_own("site.languages", :none, site.id) == :none
    end

    test "refuses a list that is not language codes, and does not mark installed" do
      assert {:error, {:invalid_languages, ["en", "Persian"]}} =
               Bootstrap.run(Map.put(@params, :languages, ["en", "Persian"]))

      refute Install.installed?()
    end

    test "saves how the site's addresses name a language as the new site's own" do
      params = Map.merge(@params, %{languages: ["en", "fa"], language_urls: "prefix_all"})

      assert {:ok, %{site: site}} = Bootstrap.run(params)

      assert Settings.get_own("site.language_urls", nil, site.id) == "prefix_all"
      assert Languages.url_mode(site.id) == "prefix_all"
    end

    test "saves the URL mode even when given no languages, and leaves it unset when given none" do
      assert {:ok, %{site: site}} = Bootstrap.run(Map.put(@params, :language_urls, "prefix_all"))
      assert Settings.get_own("site.language_urls", nil, site.id) == "prefix_all"
    end

    test "leaves the site reading the global URL mode when given none" do
      assert {:ok, %{site: site}} = Bootstrap.run(@params)

      assert Settings.get_own("site.language_urls", :none, site.id) == :none
      assert Languages.url_mode(site.id) == "prefix_others"
    end

    test "refuses a URL mode it does not know, and does not mark installed" do
      assert {:error, {:invalid_language_urls, "sideways"}} =
               Bootstrap.run(Map.put(@params, :language_urls, "sideways"))

      refute Install.installed?()
    end

    test "fires installer:languages:saved with the site and the saved list" do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: LanguagesHeard,
          event: "installer:languages:saved",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile("installer:languages:saved", :start, false)

      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, LanguagesHeard, false) end)

      assert {:ok, %{site: site}} = Bootstrap.run(Map.put(@params, :languages, ["en", "fa"]))

      assert_received {:languages_saved, %{site_id: site_id, languages: ["en", "fa"]}}
      assert site_id == site.id
    end
  end

  # A SITE WITH NO SIGN-IN PAGE LETS NOBODY SIGN IN, its master included — so this step is not the
  # starter checkbox's to turn off.
  describe "the sign-in pages step" do
    test "is one of the ordered phases, after the starter content and before the compile" do
      ids = Bootstrap.steps() |> Enum.map(&elem(&1, 0))

      assert Enum.find_index(ids, &(&1 == :starter_content)) <
               Enum.find_index(ids, &(&1 == :auth_pages))

      assert Enum.find_index(ids, &(&1 == :auth_pages)) <
               Enum.find_index(ids, &(&1 == :compile))
    end

    test "writes the sign-in layout and pages, and says so" do
      test_pid = self()

      assert {:ok, %{site: site}} = Bootstrap.run(@params, &send(test_pid, &1))

      assert names(Layout, site) == ["auth", "site-main"]
      assert length(auth_pages(site)) == 8
      assert_received {:auth_pages, :log, "8 sign-in pages, 0 translated words"}
      assert_received {:auth_pages, :done, nil}
    end

    # IT WRITES THEM ITSELF, so the site it creates enqueues no job to write them again.
    test "enqueues no job for the site it creates" do
      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

      assert {:ok, %{site: site}} = Bootstrap.run(@params)

      refute_enqueued(
        worker: SiteRuntimeWorker,
        args: %{"site_id" => site.id, "transition" => "provision"}
      )
    end
  end

  defp starter_pages(site), do: site |> pages() |> Enum.filter(&(&1.section == "starter"))

  defp auth_pages(site), do: site |> pages() |> Enum.filter(&(&1.section == "auth"))

  defp pages(site) do
    Page
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp rows(resource, site) do
    resource
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp names(resource, site), do: resource |> rows(site) |> Enum.map(& &1.name) |> Enum.sort()

  defp reload_user(user), do: Ash.get!(User, user.id, authorize?: false)
end
