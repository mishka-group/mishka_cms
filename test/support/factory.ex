defmodule MishkaCms.Test.Factory do
  @moduledoc """
  Fixtures for the CMS's own tests.

  Deliberately small: every extension carries its own factory now, so this holds only what the tests
  that remain here actually build — the CMS's web layer, its installer, and the handful of checks
  that need more than one extension installed at once. The blog fixtures below are here
  because those cross-extension tests need real records from it.

  See `MishkaBlog.Test.Factory` and `MishkaCmsCore.Test.Factory` for
  each extension's own.
  """

  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import MishkaBlog.Dev.Generator, except: [generate: 1, generate: 2]
  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{Layout, Page}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState

  require Ash.Query

  def create_site!(overrides \\ []) do
    overrides
    |> site()
    |> generate()
  end

  def create_user!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # User can be global (nil) or site-specific
    tenant = site_id

    overrides
    |> user(tenant)
    |> generate()
  end

  def create_permission!(overrides \\ []) do
    overrides
    |> permission()
    |> generate()
  end

  def create_page!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Page MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> page(tenant)
    |> generate()
  end

  # A layout without a site_id is global, shared by every site.
  def create_layout!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    overrides
    |> layout(site_id)
    |> generate()
  end

  # Same rule as a layout: no site_id means the global component every site can draw, which a
  # template reaches by `site="Global"`.
  def create_component!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    overrides
    |> component(site_id)
    |> generate()
  end

  @doc """
  Gives `site` its sign-in layout and pages with `StarterContent.ensure_auth!/1`, and puts them in
  the routing table the way a boot does, so `/<lang>/auth…` answers through
  `MishkaCmsWeb.RuntimeLive`. Call it from a test or a `setup`: when the test exits, the routing
  table forgets them and their compiled modules are unloaded. Returns `ensure_auth!/1`'s report.
  """
  def seed_auth_pages!(%{id: site_id, name: site_name} = site) do
    report = StarterContent.ensure_auth!(site)

    layout = Ash.get!(Layout, report.layout_id, action: :read_any, authorize?: false)

    pages =
      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site_id and section == "auth")
      |> Ash.read!(authorize?: false, page: false)

    routes = [{layout, "Layout"} | Enum.map(pages, &{&1, "Page"})]

    for {record, section} <- routes do
      :ok =
        WebRunTimeMetaDataState.save(%{
          id: record.id,
          site: site_name,
          path: record.path,
          title: record.name,
          created_at: DateTime.utc_now(),
          section: section,
          priority: 0
        })
    end

    ExUnit.Callbacks.on_exit(fn ->
      for {record, section} <- routes do
        WebRunTimeMetaDataState.delete(record.id)
        module = Helpers.module_name(record.id, site_name, section)
        :code.purge(module)
        :code.delete(module)
      end
    end)

    report
  end

  # Blog records, for the tests here that span extensions.

  def create_blog_post!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # BlogPost MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> blog_post(tenant)
    |> generate()
  end

  def create_collection!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Collection MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> collection(tenant)
    |> generate()
  end
end
