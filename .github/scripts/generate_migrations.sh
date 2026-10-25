#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0
#
# Generates the database migrations of a checkout that has none, which is every clean checkout of
# this repository: they are not in git, because they follow the extensions a copy loads
# (`ash_domains` in config/config.exs) and so belong to the copy that loads them. Run from the root of
# the project, with the Mix environment and the dependencies the caller already set up:
#
#   .github/scripts/generate_migrations.sh NAME
#
# It writes the Oban tables, then runs `mix ash.codegen NAME` for the resources: the migrations in
# priv/repo/migrations and the snapshots in priv/resource_snapshots that the next `mix ash.codegen`
# diffs against. The CI test job, the CI image job and the release all call it, so they generate
# the same thing. It needs no database.
#
# Generate ONCE per build and hand the files on (a CI artifact, the Docker build context): the file
# names carry the time of generation, so two runs give two sets of migration versions.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 NAME   (the name of the migration, for example: ci)" >&2
  exit 2
fi

if [ ! -f mix.exs ]; then
  echo "::error::run $0 from the root of the project (no mix.exs here)" >&2
  exit 2
fi

name="$1"
dir=priv/repo/migrations

mkdir -p "$dir"

# The migration `mix dev_reset` writes with `oban.install`, an igniter task that neither the test
# environment nor a CI runner has. An Oban migration that is already there (a developer's copy)
# stays: a second one would create the same tables again.
if grep -qs 'Oban.Migration' "$dir"/*.exs; then
  echo "An Oban migration is already in $dir, leaving it."
else
  cat > "$dir/20000101000000_add_oban.exs" <<'MIGRATION'
defmodule MishkaCms.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
MIGRATION
fi

mix ash.codegen "$name"
