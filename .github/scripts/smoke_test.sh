#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0
#
# Boots a Mishka CMS image the way a deploy does and checks that it works, before anything is
# published. The same script runs on a laptop and in CI:
#
#   .github/scripts/smoke_test.sh IMAGE        for example: mishka-cms:ci
#
# It starts a throwaway PostgreSQL 18 on a private Docker network (no host port is published, so a
# Postgres of your own on 5432 does not matter), runs `/app/bin/migrate` against the empty database
# and checks that it created the tables, starts `/app/bin/server`, waits for the image's own
# HEALTHCHECK to report healthy, and asks the running server what it answers before the CMS is
# installed. Everything it creates is removed on the way out, whether it passes or not. The secrets
# are random and live only for the run.
#
# HEALTH_TIMEOUT (seconds, default 300) is how long the server has to become healthy.

set -euo pipefail

image="${1:?usage: $0 IMAGE}"
health_timeout="${HEALTH_TIMEOUT:-300}"

id="mishka-smoke-$$"
network="$id"
db="$id-db"
app="$id-app"

# What config/runtime.exs reads in production, plus the token /install asks for there
# (require_setup_token). Passed by name below, so none of it shows up in a process list.
db_password="$(openssl rand -hex 16)"
export DATABASE_URL="ecto://postgres:${db_password}@${db}/mishka_cms"
SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
TOKEN_SIGNING_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
MISHKA_SETUP_TOKEN="$(openssl rand -hex 16)"
export SECRET_KEY_BASE TOKEN_SIGNING_SECRET MISHKA_SETUP_TOKEN
export POSTGRES_PASSWORD="$db_password"
env_flags=(-e DATABASE_URL -e SECRET_KEY_BASE -e TOKEN_SIGNING_SECRET -e MISHKA_SETUP_TOKEN)

step() { echo; echo "==> $*"; }
fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && docker inspect "$app" > /dev/null 2>&1; then
    echo; echo "---- docker logs, $app (last 200 lines) ----" >&2
    docker logs --tail 200 "$app" >&2 || true
  fi
  docker rm -fv "$app" "$db" > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# One request, from another container on the network, the way a proxy in front reaches the app.
# `X-Forwarded-Proto: https` is what that proxy sends: without it the production endpoint answers
# any host but localhost with a redirect to https. Prints "STATUS REDIRECT_URL".
request() {
  docker run --rm --network "$network" --entrypoint curl "$image" \
    -sS -o /dev/null -w '%{http_code} %{redirect_url}' \
    -H 'X-Forwarded-Proto: https' "http://${app}:4000$1"
}

expect_status() {
  local path="$1" want="$2" got
  got="$(request "$path")"
  echo "GET ${path%%\?*} -> $got"
  case "$got" in
    "$want"*) ;;
    *) fail "GET ${path%%\?*}: expected $want, got $got" ;;
  esac
}

step "Image $image ($(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$image"))"
docker image inspect -f '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Test}}{{else}}none{{end}}' "$image" \
  | grep -q 'fonts.css' || fail "the image has no HEALTHCHECK on /fonts/fonts.css"

step "Start PostgreSQL"
docker network create "$network" > /dev/null
docker run -d --name "$db" --network "$network" \
  -e POSTGRES_PASSWORD -e POSTGRES_DB=mishka_cms \
  postgres:18 > /dev/null

# Over TCP (-h 127.0.0.1): while the image initialises the database it runs a server that listens
# on a socket only, and pg_isready on that socket says "ready" a moment before the real one is.
for _ in $(seq 1 60); do
  docker exec "$db" pg_isready -q -U postgres -d mishka_cms -h 127.0.0.1 && break
  sleep 1
done
docker exec "$db" pg_isready -q -U postgres -d mishka_cms -h 127.0.0.1 || fail "PostgreSQL did not start"

psql() { docker exec "$db" psql -U postgres -d mishka_cms -Atc "$1"; }

step "Run /app/bin/migrate on the empty database"
before="$(psql "select count(*) from information_schema.tables where table_schema = 'public'")"
[ "$before" -eq 0 ] || fail "the database was not empty ($before tables)"

# Its log is a line per table and index, several hundred of them: shown when it fails, and its end
# when it does not.
if ! migrate_log="$(docker run --rm --network "$network" "${env_flags[@]}" "$image" /app/bin/migrate 2>&1)"; then
  echo "$migrate_log" >&2
  fail "/app/bin/migrate failed"
fi
echo "$migrate_log" | tail -n 3

shipped="$(docker run --rm --entrypoint sh "$image" -c 'ls /app/lib/mishka_cms-*/priv/repo/migrations/*.exs 2> /dev/null | wc -l' | tr -d ' ')"
applied="$(psql "select count(*) from schema_migrations")"
tables="$(psql "select count(*) from information_schema.tables where table_schema = 'public'")"
echo "migrations in the image: $shipped, applied: $applied, tables: $tables"

[ "$shipped" -gt 0 ] || fail "the image carries no migration"
[ "$applied" -eq "$shipped" ] || fail "$shipped migrations in the image, $applied applied"
[ "$(psql "select to_regclass('public.oban_jobs') is not null")" = "t" ] || fail "no oban_jobs table"
[ "$tables" -gt 10 ] || fail "only $tables tables after migrating"

step "Start /app/bin/server and wait for the HEALTHCHECK"
docker run -d --name "$app" --network "$network" "${env_flags[@]}" "$image" > /dev/null

started=$SECONDS
while :; do
  state="$(docker inspect -f '{{.State.Status}}' "$app")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$app")"
  [ "$state" = "running" ] || fail "the server container is $state"
  [ "$health" = "healthy" ] && break
  [ $((SECONDS - started)) -lt "$health_timeout" ] || fail "not healthy after ${health_timeout}s (health: $health)"
  sleep 5
done
echo "healthy after $((SECONDS - started))s"

step "What the server answers before the CMS is installed"
# Nothing is installed yet, so InstallGate sends every page to /install. Production (require_setup_token)
# refuses /install without MISHKA_SETUP_TOKEN, and shows the installer with it.
expect_status "/" 302
case "$(request "/")" in
  *"/install") ;;
  *) fail "GET / does not redirect to /install" ;;
esac
expect_status "/install" 403
expect_status "/install?token=${MISHKA_SETUP_TOKEN}" 200
expect_status "/fonts/fonts.css" 200

step "Smoke test passed"
