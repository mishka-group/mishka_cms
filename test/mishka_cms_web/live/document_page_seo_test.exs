defmodule MishkaCmsWeb.DocumentPageSeoTest do
  @moduledoc """
  The head of the documentation's provisioned page of a document, `/:lang/docs/:workspace/:section`,
  as a crawler reads it: the page's own title, summary and JSON-LD, put there by
  `MishkaDocument.Plugins.PageSeo` on `runtime:page:seo`.

  Here rather than in the extension's own suite because only this application has the router, the
  runtime LiveView and the root layout that renders the head.

  `async: false` — the install flag, `SiteState`, the routing table, the settings cache and the
  plugin registry are process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.PageSeo
  alias MishkaDocument.Provision
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @moduletag :integration

  # A unique site name per test: a component's module is named from its site's name, so a reused one
  # renders the previous test's module against a site that test rolled back.
  setup do
    SiteState.clear()
    name = "docseo#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    Settings.put("cms.offline", false)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    # The extension registers the plugin as it starts; registering it again keeps the one record, and
    # compiling the event here is what makes the chain hold it before the first request.
    {:ok, _registered} = PageSeo.register()
    :ok = EventHandler.do_compile(Seo.event(), :start, false)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SettingsState.delete(site.id, "site.languages")
      SiteState.clear()
    end)

    Provision.ensure!(site)
    register_routes!(site)

    %{site: site, conn: on_site(site)}
  end

  defp register_routes!(site) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
    |> Enum.each(fn page ->
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
    end)
  end

  defp on_site(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
  end

  defp attr(doc, selector, name), do: LazyHTML.attribute(LazyHTML.query(doc, selector), name)

  test "a page of a document is answered with its own head", %{site: site, conn: conn} do
    document =
      create_workspace!(
        site_id: site.id,
        skip_version: true,
        status: :active,
        name: "Guide",
        slug: "guide",
        language: "en"
      )

    version =
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        version_number: "2.0.0",
        is_latest_for_version: true,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

    create_section!(
      site_id: site.id,
      workspace_version_id: version.id,
      title: "Install",
      slug: "install",
      content: "<p>Run the installer.</p>",
      content_review_status: :approved,
      technical_review_status: :approved
    )

    url = Seo.base(site.host) <> "/en/docs/guide/install"
    doc = conn |> get("/en/docs/guide/install") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() == "Install"
    assert attr(doc, ~s(link[rel="canonical"]), "href") == [url]
    assert attr(doc, ~s(meta[property="og:type"]), "content") == ["article"]
    assert attr(doc, ~s(meta[name="description"]), "content") == ["Run the installer."]

    schema =
      doc
      |> LazyHTML.query(~s(script[type="application/ld+json"]))
      |> Enum.map(&Jason.decode!(LazyHTML.text(&1)))

    assert %{"headline" => "Install", "version" => "2.0.0", "mainEntityOfPage" => ^url} =
             Enum.find(schema, &(&1["@type"] == "TechArticle"))

    assert %{"itemListElement" => [_docs, %{"name" => "Guide"}, %{"item" => ^url}]} =
             Enum.find(schema, &(&1["@type"] == "BreadcrumbList"))
  end
end
