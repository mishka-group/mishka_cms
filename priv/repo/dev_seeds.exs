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

# The core foundation (sites, users, permissions, components, layouts, …), then every extension
# that declares a seed on core's `dev:seed` event, on each site — see `MishkaCmsCore.Dev.Seeds`.
MishkaCmsCore.Dev.Seeds.run_all(:dev)

IO.puts("\n====================================================")
IO.puts("  Dev seeds complete!")
IO.puts("====================================================")
