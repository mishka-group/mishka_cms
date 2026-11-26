#!/usr/bin/env elixir
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Stress Test Seeds — large volumes of data for performance and pagination testing.
# Run with: mix run priv/repo/stress_test_seeds.exs
#
# Data targets:
#   - 3,000 sites
#   - 20 layouts per site
#   - 3 error pages per site
#   - 10 JS hooks per site
#   - 100 media per site
#   - 500 blog posts per site
#   - 1,000 comments per site
#   - 100 tags per site (blog)
#   - 50 workspaces per site, 5 versions each, 20 sections each
#   - 100 files per site
#   - 500 sales per site
#   - 20 forms per site, 100 submissions each

IO.puts("======================================================")
IO.puts("  MishkaCMS Stress Test Seeds")
IO.puts("======================================================\n")
IO.puts("WARNING: This will create 3,000 sites with proportional")
IO.puts("data in each. This may take a very long time.\n")

# Core: 3,000 sites with large amounts of per-site data, then every extension's dev parts on
# core's `installer:seed` event, at their own stress volumes, on each of them — see
# `MishkaCmsCore.Install.Seeds.run_all/2`.
IO.puts("Seeding core data (3,000 sites), then every extension's stress seed...")

# COMPONENTS AND PAGES ARE NOT LISTED HERE, and were removed rather than implemented.
# `stress_seed/1` reads eight keys and never read these two, so `components_per_site: 50` and
# `pages_per_site: 50` sat in this call promising 150,000 components and 150,000 pages that were
# never written — a reader checking whether the editor holds up under load would have concluded it
# had been tested against them. The dev seed is where components are demonstrated, two per site;
# a stress run wanting them should add them to `stress_seed/1` deliberately.
MishkaCmsCore.Install.Seeds.run_all(:stress,
  sites: 3000,
  layouts_per_site: 20,
  error_pages_per_site: 3,
  hooks_per_site: 10,
  media_categories_per_site: 10,
  media_per_site: 100,
  master_users: 10,
  tenant_users: 20
)

IO.puts("\n======================================================")
IO.puts("  Stress seed complete!")
IO.puts("======================================================")
