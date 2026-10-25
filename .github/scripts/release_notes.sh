#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0
#
# The top of a GitHub release's notes, on stdout; release.yml adds the list of changes below it.
# What it reads, all from the environment:
#
#   TAG       v0.0.1
#   VERSION   0.0.1
#   DIGEST    sha256:... of the multi-arch index of the demo image
#   PACKAGES  table rows, one per package mix.lock pins at the tag: "| [name](url) | version |"
#
# Run it by hand to see the notes of a release: TAG=v0.0.1 VERSION=0.0.1 DIGEST=sha256:0 PACKAGES= $0

set -euo pipefail

: "${TAG:?}" "${VERSION:?}" "${DIGEST:?}"
PACKAGES="${PACKAGES:-}"
IMAGE="${IMAGE:-ghcr.io/mishka-group/mishka_cms-demo}"

notes="$(cat <<'NOTES'
## Packages this tag pins

The versions in `mix.lock` at @TAG@:

| Package | Version |
| --- | --- |
@PACKAGES@

## Install for real

Mishka CMS is your own copy of this repository. Its database migrations follow the extensions it loads (`ash_domains` in `config/config.exs`), so you generate them and commit them to your copy. This repository does not keep them, and no image of it can.

1. Clone this tag and make it your repository: `git clone --branch @TAG@ https://github.com/mishka-group/mishka_cms.git`.
2. Choose the extensions: keep or remove them in `mix.exs`, and in `ash_domains` and `extensions` in `config/config.exs`.
3. Generate the migrations: `mix deps.get`, `mix oban.install --yes`, then `mix ash.codegen first_install`. Commit `priv/repo/migrations` and `priv/resource_snapshots`.
4. Build the `Dockerfile`. The build fails if the migrations are missing, or if the resources have changed since they were generated.
5. Run `/app/bin/migrate`, then `/app/bin/server`, with these environment variables:
   - `DATABASE_URL`, for example `ecto://USER:PASS@HOST/DATABASE`
   - `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET`, each from `mix phx.gen.secret`
   - `MISHKA_SETUP_TOKEN`, any secret value: `/install` asks for it (`/install?token=...`) and refuses everyone without it
   - `SESSION_SIGNING_SALT`, any secret value, to replace the default salt of the session cookie
6. Mount a volume at `MISHKA_DATA_DIR` (`/app/mishka_data` in the image) for Mnesia, uploaded files and caches. The server runs as `nobody` (uid 65534) and must be able to write to it.

## Upgrade

1. Bump the Mishka packages in `mix.exs`, then `mix deps.update` them.
2. Generate the migration for what changed: `mix ash.codegen upgrade_@VERSION_SLUG@`. It diffs the resources against your committed snapshots, so it writes only the difference.
3. Commit `priv/repo/migrations` and `priv/resource_snapshots`, and deploy.

`/app/bin/migrate` runs only the migrations the database has not run yet. Do not run `mix dev_reset` on a database you want to keep: it deletes your migrations and snapshots and generates them again.

## Try it

A demo image of this release, to see Mishka CMS running with its default extensions. **It is for trying only, not for production.** Its migrations were generated for this release alone, so a newer demo needs a fresh database.

```bash
docker pull @IMAGE@:@VERSION@
```

Digest of the multi-arch index (linux/amd64 and linux/arm64): `@DIGEST@`

[`examples/docker/demo-docker-compose.yml`](https://github.com/mishka-group/mishka_cms/blob/master/examples/docker/demo-docker-compose.yml) starts it with PostgreSQL. Make the secrets as its header explains, run `docker compose -f demo-docker-compose.yml up`, and open `http://localhost:4000/install?token=` followed by your `MISHKA_SETUP_TOKEN`.

Check that the image was built from this repository by this release workflow:

```bash
gh attestation verify oci://@IMAGE@:@VERSION@ --owner mishka-group
```
NOTES
)"

# Package names are lower-case and a version has no `&`, so a plain replacement is safe here.
slug="${VERSION//[^0-9A-Za-z]/_}"
notes="${notes//@PACKAGES@/$PACKAGES}"
notes="${notes//@VERSION_SLUG@/$slug}"
notes="${notes//@TAG@/$TAG}"
notes="${notes//@VERSION@/$VERSION}"
notes="${notes//@IMAGE@/$IMAGE}"
notes="${notes//@DIGEST@/$DIGEST}"

printf '%s\n' "$notes"
