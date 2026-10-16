# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.InstallTest do
  @moduledoc """
  Real (Postgres-backed) tests for the install-state flag. The flag lives in process-global
  `:persistent_term` (NOT sandboxed), so each test erases the key before and after to stay isolated.
  """
  use MishkaCms.DataCase, async: false

  alias MishkaCmsCore.Install

  setup do
    :persistent_term.erase(:mishka_installed)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)
    :ok
  end

  describe "status/0" do
    test "is :unknown when the flag has never been set (test / pre-boot)" do
      assert Install.status() == :unknown
      refute Install.installed?()
    end

    test "reflects an explicit flag" do
      :persistent_term.put(:mishka_installed, false)
      assert Install.status() == :not_installed
      refute Install.installed?()

      :persistent_term.put(:mishka_installed, true)
      assert Install.status() == :installed
      assert Install.installed?()
    end
  end

  describe "refresh!/0" do
    test "is false on an empty database" do
      refute Install.refresh!()
      assert Install.status() == :not_installed
    end

    test "is true once a master user AND a site exist" do
      master = create_user!(email: "boss@example.com")
      _site = create_site!()

      assert is_nil(master.site_id)
      assert Install.refresh!()
      assert Install.status() == :installed
    end

    test "is false when a site exists but there is no master user" do
      _site = create_site!()
      refute Install.refresh!()
    end
  end

  describe "mark_installed!/0" do
    test "flips the flag without consulting the database" do
      :persistent_term.put(:mishka_installed, false)
      assert Install.mark_installed!() == :ok
      assert Install.installed?()
    end
  end
end
