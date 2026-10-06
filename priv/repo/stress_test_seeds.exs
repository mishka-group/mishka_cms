#!/usr/bin/env elixir
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

# Core: 3,000 sites with large amounts of per-site data
IO.puts("Step 1: Seeding core data (3,000 sites)...")

# COMPONENTS AND PAGES ARE NOT LISTED HERE, and were removed rather than implemented.
# `stress_seed/1` reads eight keys and never read these two, so `components_per_site: 50` and
# `pages_per_site: 50` sat in this call promising 150,000 components and 150,000 pages that were
# never written — a reader checking whether the editor holds up under load would have concluded it
# had been tested against them. The dev seed is where components are demonstrated, two per site;
# a stress run wanting them should add them to `stress_seed/1` deliberately.
core =
  MishkaCmsCore.Dev.Seeds.stress_seed(
    sites: 3000,
    layouts_per_site: 20,
    error_pages_per_site: 3,
    hooks_per_site: 10,
    media_categories_per_site: 10,
    media_per_site: 100,
    master_users: 10,
    tenant_users: 20
  )

IO.puts("Step 1 complete.\n")

# Note: for stress test the core stress_seed returns :ok (not a map with sites).
# If you need per-extension stress seeding per site, use dev_seed approach below
# or adapt stress_seed to return site list.
#
# Example per-extension stress seeding (uncomment to enable):
#
# Enum.each(sites, fn site ->
#   all_users = master_users ++ Map.get(tenant_users, site.id, [])
#
#   if Code.ensure_loaded?(MishkaBlog.Dev.Seeds) do
#     MishkaBlog.Dev.Seeds.stress_seed(site.id, all_users,
#       posts: 500, comments: 1000, tags: 100, collections: 20, bloggers: 10, teams: 5
#     )
#   end
#
#   if Code.ensure_loaded?(MishkaDocument.Dev.Seeds) do
#     MishkaDocument.Dev.Seeds.stress_seed(site.id, all_users,
#       workspaces: 50, versions_per_workspace: 5, sections_per_version: 20,
#       notes_per_section: 10, issues: 50, tags: 50
#     )
#   end
# end)

IO.puts("\n======================================================")
IO.puts("  Stress seed complete!")
IO.puts("======================================================")
