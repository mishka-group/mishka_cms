#!/usr/bin/env elixir
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Dev Seeds — realistic, production-like data covering all extensions.
# Run with: mix run priv/repo/dev_seeds.exs
#
# RUN IT AGAIN WHENEVER YOU LIKE. Every step below creates only what is missing and never writes
# over what is there, so a second run on the same database picks up whatever the seeds have learned
# to write since — new pictures, a new sample page — and leaves the rest, including anything you
# have edited, exactly as it is. There is no need to drop the database to reseed it.

IO.puts("====================================================")
IO.puts("  MishkaCMS Dev Seeds — realistic production data")
IO.puts("====================================================\n")

# Step 1: Seed core foundation data (sites, users, permissions, components, layouts, etc.)
core = MishkaCmsCore.Dev.Seeds.dev_seed()

# Step 2: Seed extension data per site
Enum.each(core.sites, fn site ->
  IO.puts("\n>> Processing site: #{site.name} (#{String.slice(site.id, 0, 8)}...)")

  all_users = core.users.master ++ Map.get(core.users.tenant, site.id, [])

  # Blog extension
  if Code.ensure_loaded?(MishkaBlog.Dev.Seeds) do
    MishkaBlog.Dev.Seeds.dev_seed(site.id, all_users)
  end

  # Document extension
  if Code.ensure_loaded?(MishkaDocument.Dev.Seeds) do
    MishkaDocument.Dev.Seeds.dev_seed(site.id, all_users)
  end
end)

IO.puts("\n====================================================")
IO.puts("  Dev seeds complete!")
IO.puts("====================================================")
