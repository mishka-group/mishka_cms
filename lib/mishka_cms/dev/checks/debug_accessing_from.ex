# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Dev.Checks.DebugAccessingFrom do
  @moduledoc """
  A development-only Ash policy check that logs the `accessing_from` context
  when a resource is accessed through a relationship.

  Always returns `true` (allows access) so it can be safely dropped into any
  policy without breaking authorization. Remove it once you've captured the
  debug output you need.

  ## Why use this?

  When writing Ash policies you often need `authorize_if accessing_from(...)`,
  but it's hard to know the exact `source` module and `relationship` name that
  Ash passes at runtime. This check prints that information to the console so
  you can copy it directly into your policy.

  ## What it prints

  When a resource is reached **through a relationship** (e.g.
  `Ash.load!(workspace, [:versions])`), Ash puts an `accessing_from` map into
  the policy context:

      %{source: MyApp.Workspace, relationship: :versions}

  This check prints that map plus the full context. When the resource is
  accessed **directly** (not through a relationship), it prints a warning
  that no `accessing_from` key is present.

  ## Quick start

  ### Step 1 — Add the check to the **target** resource

  Drop it into the resource whose `accessing_from` context you want to
  discover. It always returns `true`, so it won't block anything:

      # In the resource that is loaded via a relationship (e.g. WorkspaceVersion)
      policies do
        policy always() do
          authorize_if MishkaCms.Dev.Checks.DebugAccessingFrom
        end
      end

  ### Step 2 — Trigger the relationship load

      workspace = Ash.get!(MyApp.Workspace, workspace_id, actor: user)
      Ash.load!(workspace, [:versions], actor: user)

  ### Step 3 — Read the console output

      === ACCESSING FROM DEBUG ===
      accessing_from: %{source: MyApp.Workspace, relationship: :versions}
      ===================================

  ### Step 4 — Write the real policy and remove this check

      policies do
        policy always() do
          authorize_if accessing_from(MyApp.Workspace, :versions)
        end
      end

  ## Scoping to a single action

  If the resource has many read actions and you only want to debug one:

      policies do
        policy action(:read) do
          authorize_if MishkaCms.Dev.Checks.DebugAccessingFrom
        end
      end

  ## Real-world example from this project

  The `IssueComment` resource is loaded from `Issue` via two relationships
  (`:comments` for tenant, `:master_comments` for master). Adding this check
  revealed both paths, which led to these policy rules:

      policies do
        policy always() do
          authorize_if accessing_from(MishkaDocument.Issue, :comments)
          authorize_if accessing_from(MishkaDocument.Issue, :master_comments)
          authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                        permissions: [
                          "admin:dashboard:document:section",
                          "admin:api:document:section"
                        ]}
        end
      end

  ## Direct access (no relationship)

  If you call `Ash.get!(MyApp.Comment, id, actor: user)` directly, the check
  prints:

      No accessing_from in context

  This tells you the resource was not reached through a relationship, so
  `accessing_from/2` won't match — you need a different authorization rule
  for that code path.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "Debug: Print accessing_from context"
  end

  @impl true
  def match?(_actor, %{accessing_from: accessing_from} = context, _opts) do
    IO.puts("\n\u{1F50D} ===== ACCESSING FROM DEBUG =====")
    IO.inspect(accessing_from, label: "accessing_from")
    IO.inspect(context, label: "Full context")
    IO.puts("===================================\n")
    true
  end

  def match?(_actor, context, _opts) do
    IO.puts("\n\u26A0\uFE0F  No accessing_from in context")
    IO.inspect(context, label: "Context")
    true
  end
end
