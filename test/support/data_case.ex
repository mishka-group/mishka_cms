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
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaCms.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    restore_sites_on_exit(tags)
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
