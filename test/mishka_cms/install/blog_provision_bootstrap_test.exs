# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Install.BlogProvisionBootstrapTest do
  @moduledoc """
  A site the installer sets up gets the extensions the operator TICKED, and nothing it did not.

  `MishkaCmsCore.Install.Bootstrap` knows nothing about this extension — its `:components` step
  offers Chelekom and stops there. What puts blog components in that site's palette is its
  `:extensions` step, firing `installer:extension:install` for each key it was given, and
  `MishkaBlog.Plugins.Installer` answering to its own.

  Nothing short of running the installer proves the two meet: the plugin is written against an
  event name and the step fires a string, so a rename on either side is silent.

  Here rather than in either project's own suite. `mishka_cms_core` has no
  `mishka_blog` dependency, so the installer cannot see the plugin there;
  `mishka_blog` has no installer. This application has both.
  """
  use MishkaCms.DataCase, async: false

  alias MishkaBlog.Plugins.Installer
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Install.Bootstrap
  alias MishkaCmsCore.Runtime.Component
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @moduletag :integration

  # THE EVENT THE PLUGIN DECLARES. Spelling it out here instead would register the plugin wherever
  # this file says and prove nothing about where it is actually listening — which is the half of
  # this that a rename on either side breaks in silence.
  @event Installer.config(:__event__)

  @params %{
    email: "owner@example.com",
    password: "Password123!",
    site_name: "Blogged CMS",
    host: "blogged.example.com"
  }

  # REGISTERED BY HAND: the applications start their plugins before this suite's Mnesia registry is
  # up, so nothing an extension ships is registered by the time a test runs. `register/0` is the
  # plugin's own and is an upsert, so it is safe however often it runs.
  #
  # EVERY INSTALL WRITES THE STARTER, whose logo is a file of the master site's media library: this
  # test's own folder, not `priv/static`.
  setup do
    :persistent_term.erase(:mishka_installed)
    dir = Path.join(System.tmp_dir!(), "provision_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    {:ok, _registered} = Installer.register()
    :ok = EventHandler.do_compile(@event, :start, false)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  # THE HEADER AND THE FOOTER EVERY SITE IS DRAWN IN, which the installer writes whatever else it is
  # asked: `MishkaCmsCore.Install.StarterContent`.
  @starter ["site-footer", "site-header"]

  defp stored_names(provision) do
    names = Enum.map(provision.manifest().permissions, &elem(&1, 0))

    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(name in ^names)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp components(site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.Query.select([:name])
    |> Ash.read!(page: [limit: 100])
    |> then(&Enum.map(&1.results, fn component -> component.name end))
    |> Enum.sort()
  end

  test "the first site gets the blog when the operator ticked it" do
    assert {:ok, %{site: site}} = Bootstrap.run(Map.put(@params, :extensions, ["mishka_blog"]))

    installed = components(site)

    assert "blog-post-list" in installed
    assert installed -- @starter == Enum.sort(Provision.component_names())

    assert stored_names(Provision) ==
             Provision.manifest().permissions |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  # TICKING NOTHING IS AN ANSWER. An operator who wants a bare CMS gets one, the starter's frame and
  # nothing of the extension, and the extension's own menu is where they change their mind — see
  # `MishkaCmsCore.Install.Extensions`.
  test "and gets none of it when they did not" do
    assert {:ok, %{site: site}} = Bootstrap.run(@params)

    assert components(site) == @starter
    assert stored_names(Provision) == []
  end

  # AN EXTENSION NOBODY SHIPS IS NOT A FAILED INSTALL. The step logs it and carries on, because an
  # operator left without an admin at all over a key that answered nothing is the worse outcome.
  test "an unknown key does not stop the install" do
    assert {:ok, %{site: site}} = Bootstrap.run(Map.put(@params, :extensions, ["mishka_nothing"]))

    assert components(site) == @starter
    assert MishkaCmsCore.Install.installed?()
  end
end
