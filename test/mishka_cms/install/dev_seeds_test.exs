defmodule MishkaCmsCore.Dev.SeedsInstallTest do
  @moduledoc """
  Real tests for the installer's dev-seed entry points. `run/1` actually seeds the foundation
  through the live Ash actions (no mocks); the heavier extension seeds are not run at their dev
  volumes here — `run([])` covers the core path the installer's default selection takes, and the
  blog's own pipeline is run once at the smallest volume it accepts, to check the pictures it writes.
  """
  use MishkaCms.DataCase, async: false
  use Oban.Testing, repo: MishkaCms.Repo

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Dev.Generator
  alias MishkaCmsCore.Dev.SeedMedia
  alias MishkaCmsCore.Dev.Seeds
  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.JsHook
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.CompileFailureState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.{Component, Layout, Media, Page, PageDraft, Site, Stylesheet}
  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker
  alias MishkaCmsCore.Settings

  require Ash.Query

  test "categories/0 lists the loaded extension seeders" do
    keys = Seeds.categories() |> Enum.map(& &1.key)
    assert :blog in keys
    assert :document in keys
  end

  # THREE SITES A BROWSER ON THIS MACHINE CAN REALLY OPEN. `mishka.tools` and `api.mishka.tools`
  # resolve to public IPs, so every page seeded onto them was unreachable from the machine that
  # seeded them; `*.localhost` is the loopback.
  test "run/1 seeds the three dev sites, the sample master and the content" do
    core = seed_core()

    assert Enum.map(core.sites, &{&1.name, &1.host}) |> Enum.sort() ==
             [
               {"localhost", "localhost"},
               {"site-a", "site-a.localhost"},
               {"site-b", "site-b.localhost"}
             ]

    assert length(core.sites) > 0
    assert Enum.any?(core.users.master, &(to_string(&1.email) == "master@example.com"))
    assert Site |> Ash.count!(authorize?: false) == length(core.sites)

    master = User |> Ash.Query.filter(is_nil(site_id)) |> Ash.read!(authorize?: false)
    assert Enum.any?(master, &(to_string(&1.email) == "master@example.com"))

    # `users.master` is what every extension's seed is handed as the masters, so it holds only users
    # whose `site_id` is nil. The fixed `none@example.com` belongs to localhost and is listed there.
    assert Enum.all?(core.users.master, &is_nil(&1.site_id))
    localhost = Enum.find(core.sites, &(&1.host == "localhost"))

    assert Enum.any?(
             Map.fetch!(core.users.tenant, localhost.id),
             &(to_string(&1.email) == "none@example.com")
           )
  end

  # THE SAMPLE PAGES ARE MADE OF THE KIT, so the kit has to exist before they are written. When it
  # does not, nothing raises — `LiveViewHelpers.component/1` renders a red "failed to render" box
  # where the component should be, and the seed reports success. This asserts the thing that box
  # would tell you: every component a seeded page calls for is really in the database.
  #
  # NAME AND SITE, not name alone. A page names a component with two things — `component_name` and
  # `site` — and `LiveViewHelpers.component/1` resolves `"Global"` to the rows with no site and any
  # other name to that site's own. Checking names against one flat set said yes to a page calling
  # `site-header site="localhost"` from the mishka-tools site, which is the component equivalent of
  # the `LocalhostClipboard` bug the hook test below exists for: seeded for three sites from one
  # string, a hardcoded site name gives one site a header and the other two a red box.
  test "every component the seeded pages call for exists, in the scope the page asks for" do
    seed_core()

    pages =
      Page
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.load([:site])
      |> Ash.read!(authorize?: false)

    assert pages != []

    installed =
      Component
      |> Ash.Query.for_read(:read_any)
      |> Ash.read!(authorize?: false, page: [limit: 1000])
      |> Map.fetch!(:results)

    sites = Site |> Ash.Query.for_read(:read_any) |> Ash.read!(authorize?: false)
    by_id = Map.new(sites, &{&1.id, &1.name})

    # The scope a row answers to, spelled the way a template spells it.
    available =
      MapSet.new(installed, fn component ->
        {component.name, (component.site_id && by_id[component.site_id]) || "Global"}
      end)

    called =
      for page <- pages,
          [_match, name, site] <-
            Regex.scan(~r/component_name="([^"]+)"\s+site="([^"]+)"/, page.template || ""),
          do: {page.path, by_id[page.site_id], name, site}

    assert called != [], "the sample pages are supposed to demonstrate components"

    missing =
      called
      |> Enum.reject(fn {_path, _page_site, name, site} ->
        MapSet.member?(available, {name, site})
      end)
      |> Enum.uniq()

    assert missing == [],
           "seeded pages call components that do not exist in the scope asked for: #{inspect(missing)}"

    # A SITE COMPONENT NAMED FROM ANOTHER SITE'S PAGE resolves — the row exists, just not for this
    # visitor — so the check above cannot see it. This is the one that can.
    wrong_site =
      called
      |> Enum.reject(fn {_path, page_site, _name, site} ->
        site == "Global" or site == page_site
      end)
      |> Enum.uniq()

    assert wrong_site == [],
           "seeded pages name another site's component: #{inspect(wrong_site)}"
  end

  # WHAT THE KIT CANNOT DEMONSTRATE. 136 global components say nothing about the half of the model
  # that is per-site, and until this seeded them the Site filter on the components screen matched
  # nothing whatever a developer picked. Two, so a developer has the shape without a catalogue to
  # wade through — and both used by every seeded page, because a component nothing calls is a row,
  # not a demonstration.
  test "every site gets its own two components, and its own name in them" do
    core = seed_core()

    components =
      Component
      |> Ash.Query.for_read(:read_any)
      |> Ash.read!(authorize?: false, page: [limit: 1000])
      |> Map.fetch!(:results)

    for site <- core.sites do
      own = Enum.filter(components, &(&1.site_id == site.id))

      assert Enum.map(own, & &1.name) |> Enum.sort() == ["site-footer", "site-header"],
             "#{site.name} has #{inspect(Enum.map(own, & &1.name))}"

      # The site's own name, written in as the attribute's default. This is what makes the scoping
      # visible on the page itself rather than only in a `site_id` column.
      #
      # `.name` and `.opts["default"]`: Ash gives the map's own keys back as atoms and leaves the
      # nested `opts` as it was written, which is also how the kit's rows read.
      for component <- own do
        brand = Enum.find(component.attrs, &(&1.name == "brand"))

        assert brand, "#{component.name} on #{site.name} lost its brand attribute"
        assert brand.opts["default"] == site.name
      end

      # AND NEITHER OF THEM NEEDS THE KIT. They are written by
      # `MishkaCmsCore.Install.StarterContent`, which a production install runs with whatever
      # components the user chose — possibly none — so a header drawing `chelekom-navbar` would put
      # the red "Component failed to render!" box at the top of every page on exactly the install
      # that chose least.
      for component <- own do
        refute component.template =~ "chelekom-", "#{component.name} needs the kit to render"
        assert component.dependencies == []
      end
    end
  end

  # A HOOK THAT IS NOT REGISTERED IS AN ATTRIBUTE AND NOTHING ELSE. The button renders, it carries
  # `phx-hook`, and clicking it does nothing — there is no error anywhere, because an unknown hook
  # name is simply a name LiveView was never given.
  #
  # The contact page named `LocalhostClipboard`, and a SITE hook is registered under its site's
  # prefix. Seeded for three sites, that is one site where the button works and two where it is
  # decoration. Found by opening a seeded page's preview and reading what the socket had actually
  # registered, which is the only place the difference shows.
  test "every hook a seeded page names is one its site really registers" do
    seed_core()

    # `is_global` is a CALCULATION, and unloaded it is `%Ash.NotLoaded{}` — which `browser_name/2`
    # reads as "not global", so every global hook comes back under its bare name and this test would
    # accuse the seeds of naming hooks that exist.
    hooks =
      JsHook
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.load([:is_global])
      |> Ash.read!(authorize?: false, page: false)

    sites = Site |> Ash.Query.for_read(:read_any) |> Ash.read!(authorize?: false)
    by_id = Map.new(sites, &{&1.id, &1.name})

    # WHO registers it, not merely that somebody does. A flat set of every name on the node said yes
    # to the Home page naming `LocalhostConsoleLogger` on all three sites — the very bug the comment
    # above describes — because the localhost site really did register it. A visitor is only ever on
    # ONE site, and the only name that helps them is one their own site registers.
    registered =
      MapSet.new(hooks, fn hook ->
        site_name = hook.site_id && by_id[hook.site_id]
        {JavaScriptCompiler.browser_name(hook, site_name), site_name}
      end)

    pages =
      Page
      |> Ash.Query.for_read(:read_any)
      |> Ash.read!(authorize?: false)

    named =
      for page <- pages,
          [_match, name] <- Regex.scan(~r/phx-hook="([^"]+)"/, page.template || ""),
          do: {page.path, by_id[page.site_id], name}

    assert named != [], "no seeded page demonstrates a hook, so this proves nothing"

    # A GLOBAL hook is registered for everyone, so it carries no site of its own.
    missing =
      named
      |> Enum.reject(fn {_path, page_site, name} ->
        MapSet.member?(registered, {name, nil}) or MapSet.member?(registered, {name, page_site})
      end)
      |> Enum.uniq()

    assert missing == [],
           "seeded pages name hooks their own site does not register: #{inspect(missing)}"
  end

  # A PAGE TO DEVELOP THE FORM MACHINERY AGAINST. Everything about page forms — the naming, the
  # validation rules lifted from the constraint attributes, the per-form events, the errors that stay
  # in their own form — is only exercised by a page that HAS forms, and no seeded page had one. So
  # every change to that code was checked against a page somebody had to build first.
  #
  # Two of them, deliberately: one form is not enough to catch the bug that matters, which is one
  # form's typing marking the other's fields.
  test "a seeded page carries two independent forms to develop against" do
    seed_core()

    template =
      Page
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.filter(path == "/:lang/forms")
      |> Ash.read!(authorize?: false)
      |> List.first()
      |> then(& &1.template)

    assert template, "the /forms dev page is missing"

    declared = PageForms.declared(template)

    assert length(declared) == 2, "expected two forms, got #{inspect(declared)}"

    # EACH ONE NAMED FOR ITSELF. One seed becomes five names — the DOM id, the `as`, the page assign
    # and both events — and a second form sharing any of them is the two writing over each other.
    assert Enum.map(declared, & &1.as) |> Enum.sort() == ["feedback", "signup"]

    for form <- declared do
      assert form.id == "#{form.as}-form"
      assert form.assign == :"#{form.as}_form"
      assert form.change == "#{form.as}_validate"
      assert form.submit == "#{form.as}_submit"
      assert form.success not in [nil, ""]
    end

    # AND THE RULES ARE REAL, lifted from the constraint attributes rather than declared twice. A
    # page of bare text inputs would exercise none of the validation this page exists to develop.
    signup = Enum.find(declared, &(&1.as == "signup"))
    rules = Map.new(signup.fields, &{&1.key, &1.rules})

    assert rules.full_name == [:required, {:min_length, 2}, {:max_length, 80}]
    assert rules.email == [:required, {:format, :email}]
    assert rules.site == [format: :url]
    assert rules.age == [min: 13, max: 120]

    # The second form has its own, including a fieldset — related fields under a legend, which is a
    # shape the field walker has to look through rather than stop at.
    feedback = Enum.find(declared, &(&1.as == "feedback"))

    assert Enum.map(feedback.fields, & &1.key) |> Enum.sort() ==
             [:body, :name, :reply_to, :subject]

    assert template =~ "<fieldset"
  end

  # THE SITE CACHE IS GLOBAL AND THE SANDBOX IS NOT. `SiteState` is one ETS table for the whole node,
  # filled from pub_sub and never rolled back, while every test here seeds a fresh "localhost" with a
  # fresh id inside a transaction that is thrown away. From the second test onwards a component asked
  # for by SITE NAME therefore resolves to the FIRST test's id, reads no row, and `LiveViewHelpers`
  # remembers `:not_found` for that module — a red box from a cache that is stale, not a component
  # that is broken. Nothing about this can happen to a running site, whose id does not change under
  # it; it is what a global cache costs in a sandboxed suite, and this is where the suite pays it.
  #
  # `clear/0` before `save_batch/1`, not `save/1` per site: `save/1` REFUSES a name already in the
  # table (`{:error, :name_already_exists}`) and returns that quietly, so telling the cache about
  # this run's sites one at a time changed nothing at all.
  #
  # The remembered miss has to go with it. It can only have been left by an earlier test rendering
  # against the stale id — a component that genuinely will not compile fails again below, on its own
  # merits, because the memo is gone before anything is asked to render.
  defp tell_the_cache(sites) do
    SiteState.clear()
    SiteState.save_batch(sites)

    for site <- sites, name <- ["site-header", "site-footer"] do
      name |> CompilerHelpers.module_name(site.name, "Component") |> CompileFailureState.clear()
    end
  end

  # EXISTING IS NOT RENDERING. `LiveViewHelpers.component/1` never raises for a name it cannot
  # resolve — it returns a red "Component failed to render!" box — so a row in the right place with
  # a template nothing can build looks exactly like a working one from the database's side. This is
  # the only assertion here that would have caught `site="Global"` being written as
  # `assigns[:site]` in the footer, which resolves `chelekom-footer` under the SITE, finds nothing,
  # and puts that box where every page's footer should be.
  test "each site's own components really render, with that site's name in them" do
    core = seed_core()
    tell_the_cache(core.sites)

    for site <- core.sites, name <- ["site-header", "site-footer"] do
      # FOR THE SITE ITSELF, as a page on it renders: another site's component is drawn nowhere else.
      html =
        LiveViewHelpers.rendering_for(site.name, fn ->
          name |> LiveViewHelpers.component(site.name, %{}) |> rendered_to_string()
        end)

      refute html =~ "failed to render",
             "#{name} on #{site.name}: #{html} " <>
               "(failed? #{inspect(CompileFailureState.failed?(CompilerHelpers.module_name(name, site.name, "Component")))} " <>
               "reason #{inspect(CompileFailureState.reason(CompilerHelpers.module_name(name, site.name, "Component")))})"

      refute html =~ "Slot Error", "#{name} on #{site.name}: #{html}"

      assert html =~ site.name,
             "#{name} on #{site.name} renders somebody else's name: #{html}"
    end
  end

  # AND THE FOOTER IS A `<footer>`. The site's two components are the only markup every page on
  # every site carries, so whatever is wrong with them is wrong everywhere at once.
  test "the site footer renders a real footer element" do
    core = seed_core()
    tell_the_cache(core.sites)
    site = hd(core.sites)

    html =
      LiveViewHelpers.rendering_for(site.name, fn ->
        "site-footer" |> LiveViewHelpers.component(site.name, %{}) |> rendered_to_string()
      end)

    assert html =~ "<footer", "the footer renders no <footer>: #{html}"
  end

  # THE PALETTE'S CATEGORY ROW IS `distinct type`. A generator that leaves `type` unset gets one
  # invented for it — Ash fills a `:string` attribute with arbitrary unicode — and the editor drew a
  # chip for each, so four unreadable categories sat beside Feedback, Forms and Media.
  test "every seeded component lands in a category a reader can read" do
    seed_core()

    types =
      Component
      |> Ash.Query.for_read(:read_any)
      |> Ash.read!(authorize?: false, page: [limit: 1000])
      |> Map.fetch!(:results)
      |> Enum.map(& &1.type)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert types != []

    for type <- types do
      assert String.match?(type, ~r/^[a-z][a-z0-9_-]*$/),
             "#{inspect(type)} would be drawn as a palette category"
    end
  end

  # AN ADDRESS ONLY ONE OF THE TWO ROUTERS ANSWERS. This application's own pages are matched by
  # `Phoenix.Router` before the `/*path` catch-all that reads the database, so a seeded page at an
  # address a static route holds is a page nobody can ever reach — and nothing says so: the row is
  # written, the admin lists it, and the visitor gets the marketing page.
  #
  # ASKED OF THE ROUTER, not of a list of paths written out here. A route added tomorrow is in the
  # answer the moment it is added; a list would go on passing.
  test "no address the seeds write is one this application's own router answers" do
    core = seed_core()

    for site <- core.sites, page <- seeded_pages(site) do
      address = concrete(page.path)

      answered = Phoenix.Router.route_info(MishkaCmsWeb.Router, "GET", address, site.host)

      assert match?(%{route: "/*path"}, answered),
             "#{site.name} seeds #{page.path}, and #{address} is answered by " <>
               inspect(is_map(answered) && answered[:route])
    end
  end

  # EVERY LANGUAGE A SITE PUBLISHES IN IS ONE ITS SEEDED PAGES ANSWER IN. The list is a setting, and
  # a `/:lang` page answers only the codes it holds — see `MishkaCmsCore.Runtime.Languages`.
  test "each site is given its own languages, and nothing overwrites one a developer changed" do
    core = seed_core()

    by_host = Map.new(core.sites, &{&1.host, Languages.site(&1.id)})

    assert by_host["localhost"] == ["en", "fa"]
    assert by_host["site-a.localhost"] == ["en", "fr"]
    assert by_host["site-b.localhost"] == ["en"]

    site = Enum.find(core.sites, &(&1.host == "localhost"))
    {:ok, _value} = Settings.put("site.languages", ["en", "de"], site_id: site.id)

    Seeds.run([])

    assert Languages.site(site.id) == ["en", "de"]
  end

  # BOTH URL MODES ARE OPEN ON EVERY RESEED: `site-a` prefixes every language, the others leave
  # their first unprefixed.
  test "each site is given its URL mode, and nothing overwrites one a developer changed" do
    core = seed_core()

    by_host = Map.new(core.sites, &{&1.host, Languages.url_mode(&1.id)})

    assert by_host["localhost"] == "prefix_others"
    assert by_host["site-a.localhost"] == "prefix_all"
    assert by_host["site-b.localhost"] == "prefix_others"

    site = Enum.find(core.sites, &(&1.host == "localhost"))
    {:ok, _value} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

    Seeds.run([])

    assert Languages.url_mode(site.id) == "prefix_all"
  end

  # THE ACCOUNTS AN END-TO-END RUN CAN TYPE IN, one per role a permission check has to be seen
  # allowing and refusing. The tenant emails used to carry a slice of the site's own uuid, so nobody
  # could sign in without reading the database first.
  @site_roles %{
    "admin" => ["*"],
    "viewer" => [],
    "builder" => ["admin:dashboard:runtime:page"],
    "developer" => ["admin:dashboard:code"],
    "accounts" => ["admin:dashboard:permission", "admin:dashboard:user"],
    "api" => ["admin:api:*"]
  }

  test "every site gets an account per role, holding exactly that role's names" do
    core = seed_core()

    for site <- core.sites, {role, names} <- @site_roles do
      email = "#{role}@#{site.name}.test"
      account = account(email, site.id)

      assert account, "#{site.name} has no #{email}"
      assert account |> held() == names, "#{email} holds #{inspect(held(account))}"
    end
  end

  test "a second run grants no account anything more" do
    core = seed_core()
    before = Map.new(core.sites, &{&1.id, grants(&1.id)})

    Seeds.run([])

    for site <- core.sites, do: assert(grants(site.id) == before[site.id])
  end

  test "stores the install's names and no other" do
    seed_core()

    stored =
      Permission
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert stored ==
             MishkaCmsCore.Install.Bootstrap.permissions()
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort()
  end

  test "the sample master holds * and none@example.com holds nothing" do
    core = seed_core()
    localhost = Enum.find(core.sites, &(&1.host == "localhost"))

    assert "master@example.com" |> account(nil) |> held() == ["*"]
    assert "none@example.com" |> account(localhost.id) |> held() == []
  end

  defp held(account), do: account.permissions |> Enum.map(& &1.name) |> Enum.sort()

  defp grants(site_id) do
    User
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.Query.load(:permissions)
    |> Ash.read!(authorize?: false, page: false)
    |> Map.new(&{to_string(&1.email), held(&1)})
  end

  # WHAT A SITE'S OWN STYLESHEET IS FOR. Every seeded and starter template is written in `bg-ground`,
  # `text-ink`, `border-line` and the rest, and those are utilities only because this row declares
  # the tokens they are generated from. Without it the whole design renders as unstyled body text —
  # silently, since a class nothing generated is simply a class.
  test "every site gets the theme its pages are written in" do
    core = seed_core()

    for site <- core.sites do
      sheets =
        Stylesheet
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.read!(authorize?: false, page: [limit: 10])
        |> Map.fetch!(:results)

      assert [%{kind: :theme, content: content}] = sheets

      for token <- [
            "--color-ground",
            "--color-ink",
            "--color-line",
            "--color-accent",
            "--font-sans"
          ] do
        assert content =~ token, "#{site.name}'s theme declares no #{token}"
      end
    end
  end

  # A LAYOUT IS RENDERED INSIDE THE APPLICATION'S OWN DOCUMENT, so a `<body>` in one nests a document
  # in a document — which is what the generated layouts this replaced all did. And a layout that
  # shows the flash is what lets every page stop carrying a message region of its own; see
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.shows_messages?/1`.
  test "every seeded layout shows messages and opens no second document" do
    core = seed_core()

    layouts =
      Layout
      |> Ash.Query.for_read(:read_any)
      |> Ash.read!(authorize?: false, page: [limit: 50])
      |> Map.fetch!(:results)

    assert length(layouts) == 2 * length(core.sites) + 1,
           "site-main and auth per site, plus the global one"

    for layout <- layouts do
      refute layout.template =~ "<body", "#{layout.name} opens a second document"

      assert LiveViewCompiler.shows_messages?(layout),
             "#{layout.name} renders no flash, so every page on it has to carry its own"
    end
  end

  # THE SIGN-IN PAGES EVERY SITE GETS, and their Persian words only where a site publishes in `fa`.
  test "every site gets the sign-in pages, and a site publishing in fa their Persian words" do
    core = seed_core()

    for site <- core.sites do
      signing_in = site |> seeded_pages() |> Enum.filter(&(&1.section == "auth"))

      assert length(signing_in) == 8, "#{site.name} has #{length(signing_in)} sign-in pages"
    end

    localhost = Enum.find(core.sites, &(&1.host == "localhost"))
    site_b = Enum.find(core.sites, &(&1.host == "site-b.localhost"))

    assert persian(localhost, "Sign in") == "ورود"
    assert persian(site_b, "Sign in") == nil
  end

  # THE SEEDS WRITE THEM THEMSELVES, so the sites they create enqueue no job to write them again.
  test "the sites it creates enqueue no job for their sign-in pages" do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    core = seed_core()

    for site <- core.sites do
      refute_enqueued(
        worker: SiteRuntimeWorker,
        args: %{"site_id" => site.id, "transition" => "provision"}
      )
    end
  end

  defp persian(site, key) do
    MishkaCmsCore.Runtime.Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and language == "fa" and key == ^key)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      row -> row.value
    end
  end

  # NEITHER OF THE TWO THINGS THE CONTENT SECURITY POLICY REFUSES. An inline `style=` and a
  # `<script>` in a page template are both dropped by the browser with nothing in the page to say so
  # — see `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` — so a sample page written with either is a
  # sample of something that does not work.
  test "no seeded template carries an inline style or a script tag" do
    core = seed_core()

    for site <- core.sites, page <- seeded_pages(site) do
      refute page.template =~ "style=", "#{site.name} #{page.path} carries an inline style"
      refute page.template =~ "<script", "#{site.name} #{page.path} carries a script tag"
    end
  end

  # THE ONE PART OF THE EDITOR A FRESH SEED LEFT EMPTY. A draft picker with nothing in it says
  # nothing about what a draft is; this is an edit waiting on a live page, on the site a developer
  # opens first.
  test "localhost is seeded an unpublished draft, and a second run does not add another" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))

    pricing = Enum.find(seeded_pages(site), &(&1.path == "/:lang/pricing"))

    assert [draft] = drafts(site)
    assert draft.source_page_id == pricing.id
    assert draft.template != pricing.template
    assert draft.label == "Half-price week"

    # AND ONLY THE SITE THAT DEMONSTRATES IT HAS ONE.
    for other <- core.sites, other.host != "localhost", do: assert(drafts(other) == [])

    Seeds.run([])

    assert [^draft] = drafts(site)
  end

  defp drafts(site) do
    PageDraft
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 10])
    |> Map.fetch!(:results)
  end

  defp seeded_pages(site) do
    Page
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
  end

  # THE ADDRESS A PATTERN ANSWERS AT, since a pattern is not one. `lang` is filled with a language
  # rather than a word, because that is the one capture the resolver checks.
  defp concrete(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", fn
      ":lang" -> "en"
      "*" <> _rest -> "one/two"
      ":" <> _capture -> "one"
      segment -> segment
    end)
    |> then(&("/" <> &1))
  end

  defp account(email, nil) do
    User
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(email == ^email and is_nil(site_id))
    |> Ash.Query.load(:permissions)
    |> Ash.read_one!(authorize?: false)
  end

  defp account(email, site_id) do
    User
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(email == ^email and site_id == ^site_id)
    |> Ash.Query.load(:permissions)
    |> Ash.read_one!(authorize?: false)
  end

  test "steps/1 always starts with :core and adds the extensions selected" do
    assert Seeds.steps([]) |> Enum.map(&elem(&1, 0)) == [:core]
    assert Seeds.steps([:blog]) |> Enum.map(&elem(&1, 0)) == [:core, :blog]
  end

  # NOTHING TO CHOOSE. A dev database is where every component gets tried, so the seed installs all
  # of every kit on disk — the picker's "only what every site needs" is the production install's.
  test "the core seed installs every component of every kit" do
    seed_core()

    for kit <- UiKitHandler.available_kits() do
      installed =
        Component
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(extra["ui_kit"] == ^kit.name and is_nil(site_id))
        |> Ash.count!(authorize?: false)

      assert installed == kit.components, "#{kit.name}: #{installed} of #{kit.components}"
    end
  end

  # A ROW IS NOT A FILE. Every media row a seed wrote used to be invented whole — a random size and a
  # path like `/uploads/images/3.jpg` that nothing had written — so the library drew its type glyph
  # in place of every thumbnail, and any page or post that used one of those pictures answered 404
  # for it. Nothing raised, then or now: a missing file is a 404 in the browser and silence in the
  # seed, which is exactly why it has to be asserted here.
  test "every media row a dev seed writes has its file where the endpoint serves it" do
    core = seed_core()

    rows = Enum.flat_map(core.sites, &Ash.read!(Media, tenant: &1.id, authorize?: false))

    assert rows != []

    assert length(rows) == length(SeedMedia.files()) * length(core.sites),
           "every site gets the whole set: #{length(rows)} rows for #{length(core.sites)} sites"

    for row <- rows do
      assert resolves?(row.relative_path), "#{row.name}: #{row.relative_path}"

      # AND THE ROW DESCRIBES ITS OWN FILE. A size read from the file rather than made up is what
      # makes the library's size column, its sorting and its filters mean anything.
      assert row.size == File.stat!(served_path(row.relative_path)).size, row.name
    end

    # An image says how big it is, so a thumbnail can reserve its space and the edit screen can show
    # the picture's real dimensions.
    for row <- rows, row.type == :images do
      assert %{width: width, height: height} = row.dimensions
      assert width > 0 and height > 0, "#{row.name}: #{inspect(row.dimensions)}"
    end

    # AND THE LIBRARY IS FILLED BEFORE THE PAGES ARE WRITTEN, because a page's content is written
    # out of it — the page generators ask the site what pictures it has. A run that seeds the
    # library afterwards seeds it for the NEXT run and for no page in this one, and says nothing
    # about it: a page whose content names no picture renders perfectly well. The order the rows
    # were written in is the only place that shows, so it is read back here.
    pages = Page |> Ash.Query.for_read(:read_any) |> Ash.read!(authorize?: false)

    for site <- core.sites do
      newest_row = rows |> own(site) |> Enum.max_by(& &1.inserted_at, DateTime)
      oldest_page = pages |> own(site) |> Enum.min_by(& &1.inserted_at, DateTime)

      assert DateTime.compare(newest_row.inserted_at, oldest_page.inserted_at) == :lt,
             "#{site.name}: its library was filled at #{newest_row.inserted_at}, after its first " <>
               "page was written at #{oldest_page.inserted_at}"
    end
  end

  defp own(rows, site) do
    case Enum.filter(rows, &(&1.site_id == site.id)) do
      [] -> flunk("#{site.name} was seeded nothing to compare")
      site_rows -> site_rows
    end
  end

  # THE PICTURES IN A GENERATED PAGE'S CONTENT. `dev_page_with_layout/3` wrote `/images/hero.jpg` and
  # `/images/feature.jpg` into every page's `content`, and neither is under `priv/static` in this
  # project or in the extension the generator lives in — so a template reading
  # `@page_data.page.content["images"]` drew two broken pictures. A generator cannot know what files
  # exist; the site's own media rows do.
  test "a page the dev generators build names only pictures its site really has" do
    core = seed_core()
    site = hd(core.sites)
    layout = Layout |> Ash.read!(tenant: site.id, authorize?: false) |> hd()

    content =
      [precompile: false]
      |> Generator.dev_page_with_layout(site.id, layout.id)
      |> Enum.at(0)
      |> Ash.Changeset.get_attribute(:content)

    sources = paths(content)

    assert sources != [], "the seeded site has media, so a generated page should name some"

    for source <- sources do
      assert resolves?(source), "a generated page names #{inspect(source)}, which nothing answers"
    end
  end

  # THE BLOG'S OWN PICTURES, through the blog's own pipeline. Post covers came from two paths under
  # `/images/` written into the generator by hand — files that exist in this application and in no
  # other, so the same generator produced a working cover here and a 404 in the extension's own
  # suite — and every blogger and team was seeded faceless. `stress_seed/3` is `dev_seed/3`'s
  # pipeline with the volumes given rather than derived, which is the only way to run the real code
  # path in a test without seeding a whole blog.
  test "every picture the blog seed writes points at a file that is there" do
    core = seed_core()
    site = hd(core.sites)
    users = core.users.master ++ Map.get(core.users.tenant, site.id, [])

    # SIXTY, WHICH IS TWELVE PER LANGUAGE — enough posts that the share of them carrying a cover is
    # a share and not a rounding. Two `nil`s in front of six pictures reads as half at four posts
    # and is a quarter by twelve, which is the count that can tell the two apart.
    MishkaBlog.Dev.Seeds.stress_seed(site.id, users,
      posts: 60,
      comments: 4,
      tags: 3,
      collections: 2,
      bloggers: 3,
      teams: 2,
      auto_postings: 1
    )

    posts = seeded_posts(site.id)
    bloggers = MishkaBlog.Blogger |> Ash.read!(tenant: site.id, authorize?: false)
    teams = MishkaBlog.Team |> Ash.read!(tenant: site.id, authorize?: false)

    covers = Enum.map(posts, & &1.featured_image_url)
    faces = Enum.flat_map(bloggers ++ teams, &[&1.avatar_url, &1.cover_image_url])

    assert Enum.any?(covers, &is_binary/1),
           "no seeded post carries a cover, so this proves nothing"

    assert Enum.any?(faces, &is_binary/1), "no seeded blogger or team carries a picture"

    # AND HALF OF THEM CARRY NONE, however many covers the set ships. A list, a card and the admin
    # table all have to look right for a post without one, which is the common case in any blog
    # anybody writes — and a share that is really "one over however many files happen to be in
    # `priv/dev_seed_media`" quietly stops being that the day somebody adds a file. Half within a
    # tenth, because the seed rounds its per-language count.
    with_cover = Enum.count(covers, &is_binary/1)

    assert abs(2 * with_cover - length(covers)) <= div(length(covers), 10),
           "#{with_cover} of #{length(covers)} seeded posts carry a cover, which is not half"

    for url <- covers ++ faces do
      assert resolves?(url), "the blog seed wrote #{inspect(url)}, which nothing answers"
    end
  end

  # LIVE AND ARCHIVED BOTH. The admin's Archived tab draws a soft-deleted post with its cover, so
  # reading only the live ones leaves those pictures unchecked — and the seed archives a fixed slice
  # of what it wrote, which would also decide, run by run, whether a post with no cover survived to
  # be seen here.
  defp seeded_posts(site_id) do
    archived =
      MishkaBlog.BlogPost
      |> Ash.Query.for_read(:archived, %{}, tenant: site_id, authorize?: false)
      |> Ash.read!(page: [limit: 100])
      |> Map.fetch!(:results)

    Ash.read!(MishkaBlog.BlogPost, tenant: site_id, authorize?: false) ++ archived
  end

  # WHAT THE BROWSER WOULD DO WITH IT. The first segment has to be one `Plug.Static` is told to
  # serve — a file under `priv/static` the endpoint never offers is a 404 with the file right there —
  # and then the file itself has to exist under the `priv/static` that plug serves from. `nil` is not
  # a picture and passes: a post without a cover is a seeded case, not a broken one.
  defp resolves?(nil), do: true

  defp resolves?("/" <> path) do
    [segment | _rest] = String.split(path, "/")

    segment in MishkaCmsWeb.static_paths() and File.exists?(served_path("/" <> path))
  end

  defp resolves?(_other), do: false

  defp served_path("/" <> path),
    do: Path.join(Application.app_dir(:mishka_cms, "priv/static"), path)

  # EVERY PATH IN THERE, whatever it is keyed by. `content` is an author's own map — Ash hands it
  # back with the keys it feels like — so what is asserted is the one thing that is certain about a
  # URL: it is a string starting with a slash, and the browser will ask for it.
  defp paths(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&paths/1)
  defp paths(value) when is_list(value), do: Enum.flat_map(value, &paths/1)
  defp paths("/" <> _rest = value), do: [value]
  defp paths(_other), do: []

  # A SEEDED LIBRARY IS FILES, AND THE SANDBOX CANNOT ROLL A FILE BACK. Every run here stores the
  # whole shipped media set under `priv/static/uploads/<site id>/`, and each seeded site has an id of
  # its own, so nothing a run writes is ever written over: left alone, this file would grow that
  # directory without bound.
  #
  # WHAT GOES IS NAMED, not whatever turned up. That is the directory the developer's own server
  # uploads into, and this file takes a minute to run — long enough for a real upload to land in it
  # under a site id of its own, which a "remove everything that appeared" sweep would take with it.
  # A run knows the sites it made, and those are the ones it takes back.
  defp seed_core do
    core = Seeds.run([])

    on_exit(fn ->
      Enum.each(core.sites, &File.rm_rf!(Path.join(uploads_directory(), &1.id)))
    end)

    core
  end

  defp uploads_directory, do: Application.app_dir(:mishka_cms, "priv/static/uploads")

  test "run/1 survives a registered-name (atom) ancestor — the LiveView/installer context" do
    # A LiveView process carries a registered NAME (atom) in `$ancestors`; `Ash.Generator.sequence`
    # (used by the seed generators) used to crash calling `Process.info/2` on it. run/1 must prune the
    # ancestor chain to pids and seed successfully from that context too.
    Process.put(:"$ancestors", [self(), :a_registered_process_name])

    core = seed_core()

    assert length(core.sites) > 0
    assert Enum.all?(Process.get(:"$ancestors", []), &is_pid/1)
  end
end
