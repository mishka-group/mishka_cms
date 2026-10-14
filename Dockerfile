# Builder and runner images come from Docker Hub. Debian rather than Alpine, to avoid the DNS
# resolution problems musl has in production.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags?name=1.20.4-erlang-29.1.1  build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260918-slim        release image
#   - https://hub.docker.com/r/oven/bun/tags?name=1.4.2                     bun binary
#
# The newest Elixir and Erlang/OTP releases, on the newest snapshot of Debian's current stable
# (trixie) hexpm builds them for — the same pair as .tool-versions, which developers and CI run;
# change both together. DEBIAN_VERSION MUST be the same snapshot for both stages: the NIFs compiled
# in the builder (bcrypt_elixir, picosat_elixir, lazy_html) link against its glibc and libssl.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261005-slim
ARG BUN_VERSION=1.4.3

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"
ARG BUN_IMAGE="docker.io/oven/bun:${BUN_VERSION}"

FROM ${BUN_IMAGE} AS bun

FROM ${BUILDER_IMAGE} AS builder

# A C toolchain for the NIFs, git for the heroicons git dependency.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# bun, because `mix assets.setup` runs `bun install` in assets/ (mix.exs). Copied from the official
# image: pinned, amd64 and arm64, nothing piped into a shell.
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

RUN mix local.hex --force \
    && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./

# The extensions and mishka_gervaz are PATH dependencies today
# (`{:mishka_cms_core, path: "__extensions/mishka_cms_core"}`), so they have to be in the build
# context before `deps.get` can resolve them. They are also what `mix admin_css` scans for the
# dashboard's Tailwind classes. An edit inside an extension invalidates the dependency cache layer;
# that is inherent to path dependencies.
#
# WHEN THEY MOVE TO THEIR OWN REPOSITORIES, installed from Hex or GitHub, this line and the `path:`
# entries in mix.exs go together — delete both, and nothing else changes: `deps.get` fetches them
# into `deps/`, and both Tailwind scanners already enumerate `deps/mishka_*` for exactly this reason.
COPY __extensions __extensions

RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config before deps.compile, so a config change recompiles the dependencies.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# The JS dependencies and the two asset binaries. package.json and bun.lock first, so a change under
# assets/js does not reinstall node_modules. `assets.setup` is bun install --frozen-lockfile, then
# tailwind.install and esbuild.install (mix.exs), so a bun.lock that disagrees with package.json
# fails the build instead of resolving silently.
COPY assets/package.json assets/bun.lock assets/
RUN mix assets.setup

# priv carries the root migrations. They are not in git (they are generated, as the extensions'
# are): the image takes the ones generated on the machine that builds it (`mix ash.codegen`, or
# `mix dev_reset`), so a build from a clean checkout has none and `bin/migrate` has nothing to run.
COPY priv priv
COPY lib lib
COPY assets assets

# Stage the JS the RUNTIME compiler bundles per site (js, vendor, sortablejs, the heroicons plugin)
# into priv/static/temp/js_assets. BEFORE assets.deploy: `mix admin_css` needs the heroicons plugin
# from that folder, or every dashboard icon renders as an empty box. It is a task of this project,
# so Mix compiles the application here; `mix compile` below is then a cache hit.
RUN mix copy_js_assets

RUN mix assets.deploy

RUN mix compile

# Precompile the RUNTIME SHELL's CSS (the layouts and `RuntimeLive`) into
# priv/static/temp/static_base.css. A release ships no .ex files, so this is the only copy of those
# classes at runtime. It is NOT the whole app: the dashboard and the marketing pages are in
# admin.css and public.css, built by `mix admin_css` inside assets.deploy above. AFTER compile,
# copy_js_assets and assets.deploy: it needs the app, the staged JS and the Tailwind binary.
RUN mix compile_static_css

# Changes to config/runtime.exs don't require recompiling the code.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS final

# libncurses6, the one trixie ships. libsctp1 because Erlang 29 opens it at boot and logs an ESOCK
# warning on every start without it. curl is for the HEALTHCHECK below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# mishka_data is MISHKA_DATA_DIR's default (config/runtime.exs) and the mount point for its volume.
# Created here and owned by the release user, so a named volume initialised from it is writable by
# `nobody` and Mnesia can start. A bind mount needs the same ownership on the host (uid 65534).
RUN mkdir -p /app/mishka_data && chown -R nobody:root /app

ENV MIX_ENV="prod"
ENV MISHKA_DATA_DIR="/app/mishka_data"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/mishka_cms ./

# The Tailwind and esbuild binaries the RUNTIME compilers build each site's CSS and JS with. Without
# Mix they are looked up under `_build/` of the working directory, which `bin/server` makes /app/bin;
# shipping the builder's copies saves every cold start a download from github.com and
# registry.npmjs.org, and a boot with no egress still compiles sites.
COPY --from=builder --chown=nobody:root /app/_build/tailwind-* /app/bin/_build/
COPY --from=builder --chown=nobody:root /app/_build/esbuild-* /app/bin/_build/

USER nobody

EXPOSE 4000

# fonts/fonts.css is served by Plug.Static ahead of the router, so this answers before the CMS is
# installed and without a Host the tenant lookup knows; favicon.ico and robots.txt are each site's
# own, and the lookup refuses them on localhost. `localhost` is excluded from the force_ssl redirect
# (Plug.SSL default), so plain http works here.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-4000}/fonts/fonts.css" > /dev/null || exit 1

# Migrations are NOT run here on purpose (ROADMAP_DISTRIBUTED_CMS.md, phase 1): run
# `/app/bin/migrate` as the deploy's pre-start command, then start.
CMD ["/app/bin/server"]
