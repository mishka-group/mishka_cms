# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MishkaCms.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias MishkaCms.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaCms.DataCase
      import MishkaCms.Test.Factory
      import MishkaCms.Test.VersionHelpers
    end
  end

  setup tags do
    MishkaCms.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags, and — for a test that is not async — puts
  `MishkaCmsCore.Runtime.States.SiteState` back as it found it when the test ends.

  A site a test creates is saved to `SiteState`, which is the node's, not the test's: the rollback
  takes the row back and leaves the entry, and a later test that saves a site of the same name or
  host is refused. ExUnit runs the async modules first and the others one at a time after them, so
  a test that is not async is the only one touching the tables while it runs.
  """
  def setup_sandbox(%{module_sandbox: true} = tags), do: setup_test_savepoint(tags)

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaCms.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    restore_sites_on_exit(tags)
  end

  @doc """
  The sandbox for a whole module, for a module whose `setup_all` writes rows ONCE — a site and the
  pages provisioned on it, the dev seeds — and whose tests only read them, or add to them and take
  that back. Call it FIRST in `setup_all`, then write the rows; it returns the context that tells
  every test of the module to take a savepoint instead of an owner of its own:

      setup_all do
        context = MishkaCms.DataCase.setup_module_sandbox()
        site = create_site!()
        Map.put(context, :site, site)
      end

  ## How it differs from a test's own sandbox

  `setup_sandbox/1` gives each test an owner whose transaction is thrown away when the test ends.
  Two shared owners cannot exist at once, so a module that wrote its rows in `setup_all` could not
  also give its tests one: the rows would sit in a transaction no test could see. Here the module
  holds ONE shared owner for as long as it runs, and each test runs between `SAVEPOINT` and
  `ROLLBACK TO SAVEPOINT` in that transaction. The rows `setup_all` wrote are there for every test,
  and whatever a test wrote, changed or deleted is back as it was for the next one.

  A savepoint takes back rows, not the node's memory. `SiteState` and `SettingsState` are put back
  after every test, as `setup_sandbox/1` puts `SiteState` back; anything else a test leaves in an ETS
  table, the code server or a file is the test's to take back with its own `on_exit/1`, as in any
  other module. What `setup_all` leaves of those is the module's, and it takes them back with an
  `on_exit/1` of its own. The rows need nothing: the owner ends with the module and its transaction
  is rolled back.

  ## What it is not for

  A module that is `async: true`, whose tests would share the one transaction. And a test that
  changes what `setup_all` compiled: a page module is built from the row as it was when it was first
  requested, so a test that updates that row's template or tags and then requests the page is
  answered by the module built before, and that test keeps its own `setup`.
  """
  def setup_module_sandbox do
    site_snapshot = MishkaCmsCore.Runtime.States.SiteState.snapshot()
    settings_snapshot = MishkaCmsCore.Runtime.States.SettingsState.snapshot()

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaCms.Repo,
        shared: true,
        ownership_timeout: :timer.minutes(30)
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      MishkaCmsCore.Runtime.States.SiteState.restore(site_snapshot)
      MishkaCmsCore.Runtime.States.SettingsState.restore(settings_snapshot)
    end)

    %{module_sandbox: true, module_process: self()}
  end

  # What a test of a module with `setup_module_sandbox/0` does in place of an owner of its own.
  defp setup_test_savepoint(tags) do
    share_generators(tags.module_process)

    savepoint = "test_#{System.unique_integer([:positive])}"
    sql!("SAVEPOINT #{savepoint}")

    settings = MishkaCmsCore.Runtime.States.SettingsState.snapshot()

    on_exit(fn ->
      sql!("ROLLBACK TO SAVEPOINT #{savepoint}")
      sql!("RELEASE SAVEPOINT #{savepoint}")
      MishkaCmsCore.Runtime.States.SettingsState.restore(settings)
    end)

    restore_sites_on_exit(tags)
  end

  # THE GENERATORS' SEQUENCES AND ONCES CONTINUE IN THE TEST. `Ash.Generator` keeps each in an agent it
  # finds in the process dictionary of the process that asked for it or of one of its `$ancestors`,
  # and the process that ran `setup_all` is neither the test nor an ancestor of it: a test would start
  # every sequence over at zero and generate the very slug, name or email that `setup_all` already
  # wrote. The agents are linked to the module's process and live as long as the module does.
  defp share_generators(module_process) do
    with {:dictionary, entries} <- Process.info(module_process, :dictionary) do
      for {{kind, _identifier} = key, agent} <- entries, kind in [:ash_sequence, :ash_once] do
        Process.put(key, agent)
      end
    end

    :ok
  end

  # `sandbox_subtransaction: false`, because the sandbox otherwise runs each query that is not in a
  # transaction of its own between a `SAVEPOINT` and a `RELEASE`, which would release the savepoint
  # this makes along with it.
  defp sql!(statement) do
    Ecto.Adapters.SQL.query!(MishkaCms.Repo, statement, [], sandbox_subtransaction: false)
  end

  defp restore_sites_on_exit(%{async: true}), do: :ok

  defp restore_sites_on_exit(_tags) do
    snapshot = MishkaCmsCore.Runtime.States.SiteState.snapshot()
    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.restore(snapshot) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
