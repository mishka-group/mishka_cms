defmodule MishkaCms.Test.Factory do
  @moduledoc """
  Fixtures for the CMS's own tests.

  Deliberately small: every extension carries its own factory now, so this holds only what the tests
  that remain here actually build — the CMS's web layer, its installer, and the handful of checks
  that need more than one extension installed at once. The blog and document fixtures below are here
  because those cross-extension tests need real records from both.

  See `MishkaBlog.Test.Factory`, `MishkaDocument.Test.Factory` and `MishkaCmsCore.Test.Factory` for
  each extension's own.
  """

  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import MishkaBlog.Dev.Generator, except: [generate: 1, generate: 2]
  import MishkaDocument.Dev.Generator, except: [generate: 1, generate: 2]
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

  # Blog and document records, for the tests here that span extensions.

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

  def create_workspace!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {skip_version, overrides} = Keyword.pop(overrides, :skip_version, false)

    # Workspace MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    # Step 1: Create workspace (no version_ids needed)
    workspace =
      overrides
      |> workspace(tenant)
      |> generate()

    # Step 2: Create a default version unless skip_version is true
    unless skip_version do
      _version = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
    end

    workspace
  end

  def create_workspace_version!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {workspace_id, overrides} = Keyword.pop(overrides, :workspace_id)

    {site_id, workspace_id} =
      cond do
        site_id && workspace_id ->
          {site_id, workspace_id}

        workspace_id ->
          workspace =
            Ash.get!(MishkaDocument.Workspace, workspace_id,
              action: :master_get,
              authorize?: false
            )

          {workspace.site_id, workspace.id}

        site_id ->
          workspace = create_workspace!(site_id: site_id)
          {site_id, workspace.id}

        true ->
          workspace = create_workspace!()
          {workspace.site_id, workspace.id}
      end

    tenant = site_id

    overrides
    |> Keyword.put(:workspace_id, workspace_id)
    |> workspace_version(tenant)
    |> generate()
  end

  def create_section!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {workspace_version_id, overrides} = Keyword.pop(overrides, :workspace_version_id)

    # Section MUST have site_id and workspace_version_id
    site_id = site_id || create_site!().id

    workspace_version_id =
      workspace_version_id ||
        create_workspace_version!(
          workspace_id: create_workspace!(site_id: site_id).id,
          site_id: site_id
        ).id

    tenant = site_id

    overrides
    |> Keyword.put(:site_id, site_id)
    |> Keyword.put(:workspace_version_id, workspace_version_id)
    |> section(tenant)
    |> generate()
  end
end
