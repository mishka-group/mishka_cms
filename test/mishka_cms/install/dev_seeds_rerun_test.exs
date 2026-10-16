# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Install.DevSeedsRerunTest do
  @moduledoc """
  Running the dev seeds a second time on the database they already seeded.

  This is how a developer picks up whatever the seeds have learned to write since — the media set is
  the current example — without dropping the database they have been working in, and it is the only
  way anyone exercises these files after changing one. Until now the second run died on
  `seed_fixed_users/2` before it wrote anything, and the only route left was `mix ecto.reset`, which
  throws that developer's own work away and signs everyone out.

  Every seeded thing is counted before and after, because "it did not raise" is not the assertion:
  a step that created a second layout, a second error page or a second copy of every picture would
  pass that and fill the database a little more on every run.
  """
  use MishkaCms.DataCase, async: false

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Dev.Seeds
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, JsHook, Layout, Media, MediaCategory, Page}

  require Ash.Query

  @counted [Layout, Page, Component, JsHook, ErrorPage, Media, MediaCategory]

  # AND IT SAYS SO. `SeedMedia.install/1` answers with the rows THIS run wrote, so `[]` on a second
  # run means the library is complete — not that the set is empty, which is what the caller used to
  # read it as. The developer reseeding to pick up new pictures was told they had none, once per
  # site, by the one step the whole change exists for.
  test "a second run of the core seed adds nothing, changes nothing, and says the library is complete" do
    core = seed_core()

    before = census(core.sites)
    said = announced(fn -> Seeds.run([]) end)

    assert census(core.sites) == before
    assert said =~ "Media library already complete"
    refute said =~ "No dev seed media files found"

    # AND SAYS NOTHING ABOUT THE PAGES. Every one of them is held on a second run — by the row this
    # seed wrote itself — and a line per page per site is a wall of them saying only that the seed
    # works, which is exactly what would hide the one line below.
    refute said =~ "No page at"
  end

  # NEVER OVERWRITE WHAT AN ADMIN MAY HAVE EDITED — the rule the whole file is written to. A second
  # run that wrote the sample text back over a page somebody had rewritten would be the seed undoing
  # a day's work every time they wanted the newest pictures.
  test "a page and a component the admin rewrote survive a second run" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))

    page = one(Page, site.id, &(&1.path == "/:lang/about"))
    component = one(Component, site.id, &(&1.name == "site-header"))

    edit!(page, site.id, %{description: "Rewritten by the admin"})
    edit!(component, site.id, %{description: "Rewritten by the admin"})

    Seeds.run([])

    assert one(Page, site.id, &(&1.id == page.id)).description == "Rewritten by the admin"

    assert one(Component, site.id, &(&1.id == component.id)).description ==
             "Rewritten by the admin"
  end

  # A NAME IS AS TAKEN AS A PATH, and no reading of paths can see it. `unique_name_per_site` refuses
  # a second page called `about` however different its address, so a site whose own About page had
  # been moved — which is all it takes — ended the run at that one page: the pages after it, the
  # error page and this site's hooks were never written, and every later run died in the same place.
  #
  # AND THE ADDRESS IS STILL SEEDED. `/:lang/about` is free once that page has been moved off it, so
  # the seed writes its own About page there under the next free NAME — the site answers where it
  # should again, and the developer's moved page is exactly where they put it.
  test "a page whose name the site holds at another address is seeded under another name" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))

    moved = one(Page, site.id, &(&1.path == "/:lang/about"))
    edit!(moved, site.id, %{path: "/:lang/about-us"})

    before = census(core.sites)
    said = announced(fn -> Seeds.run([]) end)

    assert one(Page, site.id, &(&1.id == moved.id)).path == "/:lang/about-us"

    written = one(Page, site.id, &(&1.path == "/:lang/about"))

    assert written, "the seed's About page was left out at an address nothing holds"
    assert written.name == "about-2"

    # AND NOTHING ELSE WAS WRITTEN. One page is the whole of the difference a rerun makes here — a
    # step that wrote a second layout or a second copy of every picture would pass "it did not
    # raise" and fill the database a little more every time.
    assert Map.drop(census(core.sites), [{Page, written.id}]) == before

    # AND IT SAYS SO. A page under a name nobody asked for is as hard to find as one that was never
    # written, and a developer looking for `about` in the page list has nothing else to go on.
    assert said =~
             ~s(Named /:lang/about — its name "about" is taken, so it was created as "about-2")

    refute said =~ "No page at"

    # AND IT HAPPENS ONCE. The page just written answers at `/about`, so the run after this one is
    # held on the ADDRESS the way every other rerun is and writes nothing. A rename that recurred
    # would add `about-3`, `about-4` and a row per reseed for ever — which is the one thing this
    # file counts everything to catch.
    renamed = census(core.sites)
    said_again = announced(fn -> Seeds.run([]) end)

    assert census(core.sites) == renamed
    refute said_again =~ "Named /:lang/about"
    refute said_again =~ "No page at"
  end

  # THE DATABASE THE BUG WAS FOUND ON. `users_unique_email_index` is on `(site_id, email)` and
  # `EnforceMasterEmailSeparation` refuses only a master an address a site holds, so a site's
  # registration or an admin in the dashboard can put the sample master's address on a site while the
  # master account of that name is still there. Asked without a scope, the seed's own "is this user here?" read then saw two rows,
  # `Ash.read_one/2` answered an error, the error read as "not there", and the run died trying to
  # create the master account it already had.
  test "a site account holding the sample master's address does not stop a second run" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))

    tenant_account!("master@example.com", site.id)

    before = census(core.sites)
    Seeds.run([])

    assert census(core.sites) == before

    assert [%User{}] =
             User
             |> Ash.Query.filter(email == "master@example.com" and is_nil(site_id))
             |> Ash.read!(authorize?: false)
  end

  # THE REFUSAL NAMES THE ADDRESS. `Ash.Error.Changes.InvalidAttribute` prints whatever `:value`
  # holds under the message, and leaving it out did not leave it out: it printed "Value: nil" beneath
  # a message about an email that was not nil, so the one thing whoever hit it needed — which account
  # collided — was the one thing the error would not say.
  test "the master/site email refusal says which address it refused" do
    site = create_site!()
    tenant_account!("collides@example.com", site.id)

    refused =
      assert_raise(Ash.Error.Invalid, fn ->
        User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "collides@example.com",
            password: "Password123!",
            password_confirmation: "Password123!"
          },
          authorize?: false
        )
        |> Ash.create!()
      end)

    message = Exception.message(refused)

    assert message =~ "cannot be used as a master account"
    assert message =~ "collides@example.com"
    refute message =~ "Value: nil"
  end

  # AN ERROR PAGE SEEDED BEFORE THE OFFLINE ENTRY EXISTED GETS IT. Every site on a developer's
  # database already has its Error Page, and the starter writes one only for a site with none, so
  # without this a reseed left localhost showing the built-in page when it was taken offline.
  test "a second run adds the offline entry to an error page that has none, and nothing else" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))
    page = one(ErrorPage, site.id, &(&1.site_id == site.id))

    kept = Enum.reject(page.error_pages, &(&1.status == :offline))
    assert length(kept) < length(page.error_pages)
    edit!(page, site.id, %{error_pages: kept})
    pages = length(all(ErrorPage))

    Seeds.run([])

    reseeded = one(ErrorPage, site.id, &(&1.id == page.id))

    assert [%{status: :offline}] = Enum.filter(reseeded.error_pages, &(&1.status == :offline))
    assert Enum.reject(reseeded.error_pages, &(&1.status == :offline)) == kept
    assert length(all(ErrorPage)) == pages
  end

  # A NAME CANNOT BE CROWDED OFF THE PAGE BY ITS OWN ARCHIVED HISTORY. Every one of these unique
  # indexes is partial on `archived_at IS NULL` — see the `where: "((archived_at IS NULL))"` on each
  # of them in `priv/repo/migrations` — so one name can hold any number of archived rows while a step
  # asks about all of its names at once. Read through a page sized by the names alone, one name's
  # discarded copies filled it, the other looked absent, and the run wrote a second copy of a row
  # the admin had thrown away: the duplication this whole file was changed to stop.
  test "a hook the admin archived is recognised from behind another name's archived copies" do
    core = seed_core()
    site = Enum.find(core.sites, &(&1.host == "localhost"))

    hooks = Ash.read!(JsHook, tenant: site.id, authorize?: false, page: false)
    assert length(hooks) > 1
    Enum.each(hooks, &Ash.destroy!(&1, tenant: site.id, authorize?: false))

    crowd!(site.id, "console-logger", length(hooks))

    before = census(core.sites)
    Seeds.run([])

    assert census(core.sites) == before
  end

  describe "the extension seeds" do
    setup do
      site = create_site!()
      user = create_user!()
      %{site: site, user: user}
    end

    @tag timeout: 300_000
    test "run twice on one site, each adds its rows once", %{site: site, user: user} do
      seeders = [
        {MishkaBlog.Dev.Seeds, MishkaBlog.BlogPost, :read_any},
        {MishkaDocument.Dev.Seeds, MishkaDocument.Workspace, :read_any}
      ]

      for {seeder, resource, action} <- seeders do
        seeder.dev_seed(site.id, [user])
        written = count(resource, action)

        assert written > 0, "#{inspect(seeder)} seeded nothing to compare"
        assert seeder.dev_seed(site.id, [user]) == :already_seeded
        assert count(resource, action) == written, inspect(seeder)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # IDS AND TIMESTAMPS, not just counts. A step that deleted its row and wrote a new one, or that
  # updated the one it found, keeps the count exactly where it was — the id says the first happened
  # and `updated_at` says the second did.
  defp census(sites) do
    rows =
      for resource <- @counted,
          row <- all(resource),
          into: %{},
          do: {{resource, row.id}, row.updated_at}

    # A user carries no `updated_at` of its own, so the address is what stands in for one: a run that
    # wrote a second account would land under a new id, and one that rewrote an account's address
    # would show here.
    users =
      User
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{{User, &1.id}, to_string(&1.email)})

    Map.merge(rows, Map.put(users, :files, files(sites)))
  end

  defp all(resource) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.read!(authorize?: false, page: [limit: 1000])
    |> case do
      %{results: found} -> found
      found when is_list(found) -> found
    end
  end

  defp count(resource, action) do
    resource
    |> Ash.Query.for_read(action, %{}, authorize?: false)
    |> Ash.count!(authorize?: false)
  end

  defp files(sites) do
    for site <- sites,
        path <- Path.wildcard(Path.join([uploads_directory(), site.id, "**", "*"])),
        File.regular?(path),
        do: path
  end

  defp one(resource, site_id, matches?) do
    resource
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Enum.find(matches?)
  end

  defp edit!(record, site_id, attrs) do
    record
    |> Ash.Changeset.for_update(:update, attrs, tenant: site_id, authorize?: false)
    |> Ash.update!()
  end

  # `count` archived hooks under one name, all of them sorting ahead of everything else the read can
  # return. The ids are dictated rather than generated because a paginated read is sorted by primary
  # key and a generated uuid lands wherever it lands: these are the page that a limit sized by the
  # name count hands back, so the test says the same thing on every run instead of on most of them.
  defp crowd!(site_id, name, count) do
    for index <- 1..count do
      JsHook
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, content: "console.log('crowd');", format: :js, priority: 0, active: true},
        tenant: site_id,
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(
        :id,
        "00000000-0000-4000-8000-#{String.pad_leading("#{index}", 12, "0")}"
      )
      |> Ash.create!()
      |> Ash.destroy!(tenant: site_id, authorize?: false)
    end
  end

  defp tenant_account!(email, site_id) do
    User
    |> Ash.Changeset.for_create(
      :tenant_create,
      %{email: email, password: "Password123!", password_confirmation: "Password123!"},
      tenant: site_id,
      authorize?: false
    )
    |> Ash.create!()
  end

  # A SEEDED LIBRARY IS FILES, AND THE SANDBOX CANNOT ROLL A FILE BACK — the same reason
  # `MishkaCmsCore.Dev.SeedsInstallTest` takes its own sites' directories back, and the same rule:
  # what goes is named, because that directory is the developer's own server's uploads.
  defp seed_core do
    core = Seeds.run([])

    on_exit(fn ->
      Enum.each(core.sites, &File.rm_rf!(Path.join(uploads_directory(), &1.id)))
    end)

    core
  end

  defp uploads_directory, do: Application.app_dir(:mishka_cms, "priv/static/uploads")

  # The suite turns the seeds' own progress lines off, so a test that wants to read one turns them
  # back on for as long as it takes.
  defp announced(run) do
    Application.put_env(:mishka_cms_core, :seed_announce, true)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :seed_announce, false) end)

    ExUnit.CaptureIO.capture_io(run)
  end
end
