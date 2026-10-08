defmodule MishkaCmsWeb.TranslationRenderTest do
  @moduledoc """
  A word a runtime template asks `t/1` for, as a visitor reads it, driven through the REAL router.

  `t/1` answers from two things the template never passes: the language — Gettext's locale — and the
  site, both kept in the PROCESS rendering the page. They are set where a request becomes a page,
  `MishkaCmsWeb.RuntimeLive`, once for the HTTP render and again in the socket, which is another
  process. A router built for a test resolves the site and the language its own way, and the
  language work's worst bugs lived exactly in that difference, so these requests go through
  `MishkaCmsWeb.Router` with the host a visitor sends.

  What it proves:

    * a page published at `/:lang/…` renders its translation under `/fa/…` and the key under `/en/…`;
    * a translation written after a page was served reaches it with no recompile, and one emptied
      again shows the key;
    * a component the page draws and the layout around it answer in the same language;
    * a translation is text, never markup;
    * a site's own translation wins over the global one, and no other site sees it;
    * a row the admin's form creates — a global one, or one for a key the template computes —
      renders like one a template's save registered.

  Each write goes through Ash and reaches the cache off its PubSub broadcast, the way an admin's
  does. `async: false` — `SiteState`, the routing table, the settings cache and the translation cache
  are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Translation
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, TranslationsState}
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Settings

  require Ash.Query

  # The zero-width non-joiners are written as escapes so the assertion cannot pass on a copy that
  # lost them: `دسته‌بندی‌ها` without them is the same letters, joined, and a different word.
  @categories_fa "دسته\u200cبندی\u200cها"

  @template ~S"""
  <div>
    <h2 data-role="heading">{t("Categories")}</h2>
    <p data-role="count">{t("Read %{count} posts", count: 3)}</p>
  </div>
  """

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    SiteState.save(site_entry(site))

    put_setting!("site.languages", ["en", "fa"], site.id)
    # The addresses below name every language, English included.
    put_setting!("site.language_urls", "prefix_all", site.id)
    put_setting!("cms.offline", false, nil)
    :persistent_term.put(:mishka_installed, true)

    # The routing table outlives a test, so a second one asking for the same address would be
    # refused `:path_already_exists` by a row the first left behind.
    WebRunTimeMetaDataState.delete_by_site(site.name)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      WebRunTimeMetaDataState.delete_by_site(site.name)
    end)

    %{site: site, slug: "shelf-#{System.unique_integer([:positive])}"}
  end

  describe "a page whose template asks t/1 for a word" do
    test "renders its translation under /fa and the key itself under /en", %{
      site: site,
      slug: slug
    } do
      published!(site, slug)
      translate!(site.id, "Categories", "fa", @categories_fa)

      assert text(served("/fa/#{slug}"), "heading") == @categories_fa
      assert text(served("/en/#{slug}"), "heading") == "Categories"
    end

    # The module is compiled on the first request and kept. A translation is read at render, so the
    # admin's save has to reach a page already being served without rebuilding it.
    test "picks up a translation written after it was first served, with no recompile", %{
      site: site,
      slug: slug
    } do
      published!(site, slug)

      assert text(served("/fa/#{slug}"), "heading") == "Categories"

      translate!(site.id, "Categories", "fa", @categories_fa)

      assert text(served("/fa/#{slug}"), "heading") == @categories_fa
    end

    # Clearing a value in the admin means "show the key again". A cache entry left behind by the
    # write before it would keep rendering the old word.
    test "shows the key again once its translation is emptied", %{site: site, slug: slug} do
      published!(site, slug)
      translate!(site.id, "Categories", "fa", @categories_fa)
      assert text(served("/fa/#{slug}"), "heading") == @categories_fa

      translate!(site.id, "Categories", "fa", nil)

      assert text(served("/fa/#{slug}"), "heading") == "Categories"
    end

    test "fills its placeholders after translating", %{site: site, slug: slug} do
      published!(site, slug)
      translate!(site.id, "Read %{count} posts", "fa", "خواندن %{count} نوشته")

      assert text(served("/fa/#{slug}"), "count") == "خواندن 3 نوشته"
      assert text(served("/en/#{slug}"), "count") == "Read 3 posts"
    end

    # Whoever holds the admin's translation form must not be able to put a script on every page
    # that asks for the word.
    test "renders a translation as text, never as markup", %{site: site, slug: slug} do
      markup = ~s|<img src="x" onerror="alert(1)" data-role="injected">|

      published!(site, slug)
      translate!(site.id, "Categories", "fa", markup)

      page = served("/fa/#{slug}")

      assert text(page, "heading") == markup
      assert LazyHTML.query(page, ~s([data-role="injected"])) |> Enum.empty?()
    end

    # The socket is a process of its own, and the locale and site `t/1` reads live in the process
    # rendering it. Set only where the HTTP render ran, the first diff after connecting would put
    # the page back into the key.
    test "answers in the same words once its socket connects", %{site: site, slug: slug} do
      published!(site, slug)
      translate!(site.id, "Categories", "fa", @categories_fa)

      {:ok, view, _html} = live(on_site(), "/fa/#{slug}")

      assert view |> render() |> LazyHTML.from_fragment() |> text("heading") == @categories_fa
    end
  end

  # Component, page and layout are three compilers, each told what to import by
  # `MishkaCmsCore.Runtime.LiveViewHelpers.imports/1`. A page proves one of them.
  describe "wherever the page's words come from" do
    test "a component the page draws answers in the page's language", %{site: site, slug: slug} do
      component =
        create_component!(
          site_id: site.id,
          name: "shelf-label-#{System.unique_integer([:positive])}",
          template: ~S|<span data-role="component">{t("Tags")}</span>|
        )

      published!(site, slug,
        template:
          ~s(<div><.component component_name="#{component.name}" site="#{site.name}" /></div>)
      )

      translate!(site.id, "Tags", "fa", "برچسب‌ها")

      assert text(served("/fa/#{slug}"), "component") == "برچسب‌ها"
      assert text(served("/en/#{slug}"), "component") == "Tags"
    end

    test "the layout around the page answers in it too", %{site: site, slug: slug} do
      layout =
        create_layout!(
          site_id: site.id,
          path: "/layouts/shelf-#{System.unique_integer([:positive])}",
          template: ~S|<div><nav data-role="menu">{t("Menu")}</nav>{@inner_content}</div>|
        )

      :ok = WebRunTimeMetaDataState.save(route(layout, site, "Layout"))

      published!(site, slug, layout_id: layout.id)
      translate!(site.id, "Menu", "fa", "فهرست")

      page = served("/fa/#{slug}")

      assert text(page, "menu") == "فهرست"
      assert text(served("/en/#{slug}"), "menu") == "Menu"
      assert text(page, "heading") == "Categories"
    end
  end

  describe "whose translation a site reads" do
    # A global row serves every site that has not written its own, and that is what a site shows
    # until it does. The global row here is the one a global template's save registers, in the
    # languages the global list names.
    test "its own wins over the global one, which answers until it is written", %{
      site: site,
      slug: slug
    } do
      put_setting!("site.languages", ["en", "fa"], nil)

      create_component!(
        name: "global-shelf-#{System.unique_integer([:positive])}",
        template: ~S|<span>{t("Categories")}</span>|
      )

      published!(site, slug)

      translate!(nil, "Categories", "fa", "رده‌ها")
      assert text(served("/fa/#{slug}"), "heading") == "رده‌ها"

      translate!(site.id, "Categories", "fa", @categories_fa)
      assert text(served("/fa/#{slug}"), "heading") == @categories_fa
    end

    # The first site is requested FIRST on purpose. An HTTP render runs in the calling process, and
    # the site `t/1` reads is kept in the process — so a request that failed to name its own would
    # inherit the one before it and show that site's Persian.
    test "another site at the same address does not see the first site's", %{
      site: site,
      slug: slug
    } do
      other = another_site!()

      published!(site, slug)
      published!(other, slug)
      translate!(site.id, "Categories", "fa", @categories_fa)

      assert text(served("/fa/#{slug}"), "heading") == @categories_fa
      assert text(served("/fa/#{slug}", other.host), "heading") == "Categories"
    end

    # A master who leaves the form's site empty is writing for every site, and a key no global
    # template asks for has no row to update — the form creates one.
    test "a global one written from the admin's form reaches a site with none of its own", %{
      site: site,
      slug: slug
    } do
      put_setting!("site.languages", ["en", "fa"], nil)
      published!(site, slug)

      written!(nil, "Categories", "fa", "رده‌ها")

      assert text(served("/fa/#{slug}"), "heading") == "رده‌ها"
    end
  end

  # THE PREVIEW IS WHERE A TRANSLATION IS CHECKED BEFORE A VISITOR READS IT. It is its own LiveView,
  # another process, so it has to name the language and the site itself — left alone it read only the
  # global rows, in the admin's locale.
  describe "the admin's preview of a page" do
    test "answers in the page's language, from the page's site", %{site: site, slug: slug} do
      page =
        create_page!(
          site_id: site.id,
          name: "shelf-#{System.unique_integer([:positive])}",
          path: "/#{slug}",
          language: "fa",
          template: @template
        )

      translate!(site.id, "Categories", "fa", @categories_fa)

      {:ok, _view, html} = live(on_site(), "/_preview/page/#{page.preview_token}")

      assert html |> LazyHTML.from_document() |> text("heading") == @categories_fa
    end
  end

  # `t(@page.title)` names no key until the page renders, so saving the template registers nothing
  # for it. The one way it is ever translated is somebody writing the row by hand.
  describe "a word the template computes" do
    test "renders once a site admin writes its translation in the form", %{
      site: site,
      slug: slug
    } do
      published!(site, slug,
        title: "Shelf",
        template: ~S|<div><span data-role="computed">{t(@page.title)}</span></div>|
      )

      assert text(served("/fa/#{slug}"), "computed") == "Shelf"

      written!(site.id, "Shelf", "fa", "قفسه")

      assert text(served("/fa/#{slug}"), "computed") == "قفسه"
    end
  end

  defp published!(site, slug, overrides \\ []) do
    page =
      create_page!(
        [
          site_id: site.id,
          name: "shelf-#{System.unique_integer([:positive])}",
          path: "/:lang/#{slug}",
          template: @template
        ] ++ overrides
      )

    :ok = WebRunTimeMetaDataState.save(Map.put(route(page, site, "Page"), :language, nil))
    page
  end

  defp route(record, site, section) do
    %{
      id: record.id,
      site: site.name,
      path: record.path,
      title: record.name,
      created_at: DateTime.utc_now(),
      section: section,
      priority: 0
    }
  end

  # What the admin's Translate action does to a row the template's save registered: the value, and
  # only the value.
  defp translate!(site_id, key, language, value) do
    row = registered!(site_id, key, language)

    row
    |> Ash.Changeset.for_update(:master_update, %{value: value}, authorize?: false)
    |> Ash.update!(authorize?: false)

    cached!(site_id, language, key)
  end

  # What the admin's form does for a key no template registered: `:master_create` for a master, who
  # may leave the site empty for a global row, `:create` for a site admin, whose tenant is the site.
  defp written!(site_id, key, language, value) do
    Translation
    |> Ash.Changeset.for_create(
      form_action(site_id),
      %{key: key, language: language, value: value},
      tenant: site_id,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    cached!(site_id, language, key)
  end

  defp form_action(nil), do: :master_create
  defp form_action(_site_id), do: :create

  defp registered!(site_id, key, language) do
    row =
      Translation
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(key == ^key and language == ^language)
      |> of_site(site_id)
      |> Ash.read_one!(authorize?: false)

    assert %Translation{} = row,
           "saving the template registered no #{language} row for #{inspect(key)}"

    row
  end

  defp of_site(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp of_site(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  # The cache follows a write off the broadcast Ash sends once it returns. A call is answered only
  # after every message ahead of it has been handled, so this returns with the write in ETS. The
  # sandbox rolls the row back and sends nothing, so the entry is taken out by hand.
  defp cached!(site_id, language, key) do
    :sys.get_state(TranslationsState)

    on_exit({TranslationsState, site_id, language, key}, fn ->
      TranslationsState.put(site_id, language, key, nil)
    end)
  end

  defp put_setting!(key, value, site_id) do
    prior = prior_setting(site_id, key)
    {:ok, _} = Settings.put(key, value, site_id: site_id)

    on_exit({SettingsState, site_id, key}, fn ->
      if prior == :unset,
        do: SettingsState.delete(site_id, key),
        else: SettingsState.put(site_id, key, prior)
    end)
  end

  # A site this test created has nothing of its own yet, and a read for it would answer the global
  # value — which, put back under the site, would outlive the test.
  defp prior_setting(nil, key), do: SettingsState.get(nil, key, :unset)
  defp prior_setting(_site_id, _key), do: :unset

  defp another_site! do
    n = System.unique_integer([:positive])
    site = create_site!(name: "other-#{n}", host: "other-#{n}.localhost", active: true)

    SiteState.save(site_entry(site))
    put_setting!("site.languages", ["en", "fa"], site.id)

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
    end)

    site
  end

  defp site_entry(site) do
    Map.take(site, [:id, :name, :host, :priority, :active, :master])
  end

  defp on_site(host \\ "localhost") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp served(path, host \\ "localhost") do
    host |> on_site() |> get(path) |> html_response(200) |> LazyHTML.from_document()
  end

  defp text(doc, role) do
    doc |> LazyHTML.query(~s([data-role="#{role}"])) |> LazyHTML.text() |> String.trim()
  end
end
