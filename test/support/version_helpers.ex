# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Test.VersionHelpers do
  @moduledoc """
  Deterministic, synchronous helpers for reading AshPaperTrail versions in tests.

  AshPaperTrail writes the version row **synchronously**, inside the same transaction
  as the create/update/destroy action — so versions are readable immediately, with no
  polling or sleeping. The only real source of flakiness was reading versions **without
  a sort** and then taking `List.first/1`: `create` + `update` produce two rows whose
  order is undefined, so `List.first/1` could return either, and a preview built from
  the wrong version's `changes` intermittently failed.

  Always fetch versions through `versions/3` (or `first_version/3` / `latest_version/3`),
  which sort by `version_inserted_at` (a `:utc_datetime_usec` create-timestamp, distinct
  per version) so ordering is stable and chronological. Never sort versions by hand, never
  `Process.sleep`/retry waiting for them to appear, and never rely on the order of an
  unsorted read.

  See `MishkaCmsCore.Runtime.Resources.Layout` for the `preview_version` action these back.
  """

  require Ash.Query

  alias MishkaCms.Repo

  @doc """
  All versions for `source_id`, oldest first, in a deterministic chronological order.

  `version_module` is the generated AshPaperTrail resource (e.g.
  `MishkaCmsCore.Runtime.Layout.Version`). Pass `tenant:` for tenant-scoped resources.

  ## Examples

      versions(MishkaCmsCore.Runtime.Layout.Version, layout.id, tenant: site.id)
  """
  def versions(version_module, source_id, opts \\ []) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc, version_source_id: :asc)
    |> Ash.read!(authorize?: false, tenant: Keyword.get(opts, :tenant))
  end

  @doc "The original (create/oldest) version for `source_id` — deterministic. Options as `versions/3`."
  def first_version(version_module, source_id, opts \\ []),
    do: version_module |> versions(source_id, opts) |> List.first()

  @doc "The most recent version for `source_id` — deterministic. Options as `versions/3`."
  def latest_version(version_module, source_id, opts \\ []),
    do: version_module |> versions(source_id, opts) |> List.last()

  @doc "Count of versions for `source_id` — a synchronous read, no polling. Options as `versions/3`."
  def version_count(version_module, source_id, opts \\ []),
    do: version_module |> versions(source_id, opts) |> length()

  @doc """
  The first version whose `changes` contains every key/value in `expected_changes`
  (keys compared as strings), or `nil`. Synchronous — no polling. Options as `versions/3`.
  """
  def version_with_changes(version_module, source_id, expected_changes, opts \\ []) do
    version_module
    |> versions(source_id, opts)
    |> Enum.find(fn version ->
      changes = version.changes || %{}

      Enum.all?(expected_changes, fn {key, value} -> Map.get(changes, to_string(key)) == value end)
    end)
  end

  @doc """
  Asserts at least `expected_count` versions exist for `resource_id` in `version_table`,
  querying the database directly. Synchronous — AshPaperTrail writes versions inside the
  action's transaction, so the count is correct immediately and there is nothing to wait
  for. Raises if the count is not met (a missing version is a real bug, not a timing issue).

  `version_table` is the version table name (e.g. `"page_versions"`). The trailing `opts`
  argument is accepted and ignored for compatibility with the previous polling signature.

  ## Examples

      wait_for_version_count("page_versions", page.id, 2)
  """
  def wait_for_version_count(version_table, resource_id, expected_count, _opts \\ []) do
    query = """
    SELECT COUNT(*)
    FROM #{version_table}
    WHERE version_source_id::text = $1
    """

    count = Repo.query!(query, [resource_id]) |> Map.fetch!(:rows) |> List.first() |> List.first()

    if count >= expected_count do
      :ok
    else
      raise "Expected at least #{expected_count} version(s) in #{version_table} for #{resource_id}, " <>
              "found #{count}. AshPaperTrail writes versions synchronously — a missing version is a real bug."
    end
  end
end
