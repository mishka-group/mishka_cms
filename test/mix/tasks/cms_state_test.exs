# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Cms.StateTest do
  use MishkaCms.DataCase, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints a record's attributes by the resource's short name" do
    site = create_site!()

    Mix.Tasks.Cms.State.run(["site", site.id])

    assert_received {:mix_shell, :info, [text]}
    assert text =~ "MishkaCmsCore.Runtime.Site"
    assert text =~ "id: #{inspect(site.id)}"
    assert text =~ "name: #{inspect(site.name)}"
  end

  test "names the resource it cannot find" do
    assert_raise Mix.Error, "No resource is named no_such_thing.", fn ->
      Mix.Tasks.Cms.State.run(["no_such_thing", Ash.UUID.generate()])
    end
  end

  test "says how to call it when the arguments are wrong" do
    assert_raise Mix.Error, ~r/^Usage: mix cms.state/, fn -> Mix.Tasks.Cms.State.run(["site"]) end
  end
end
