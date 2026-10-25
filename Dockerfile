# syntax=docker/dockerfile:1

# THE MISHKA PACKAGES COME FROM HEX. mishka_cms_core, mishka_blog, mishka_document, mishka_gervaz
# and the four mishka_cms_auth_* sign-in providers are fetched by `mix deps.get` at the versions
# mix.lock pins (mix.exs, `mishka_dep/2`); the `__extensions/` checkouts a developer has are not in
# the build context (.dockerignore). The one git dependency left, heroicons, is a public GitHub
# repository, so the build needs no GitHub token and takes no build secret.
#
# Builder and runner images come from Docker Hub. Debian rather than Alpine, to avoid the DNS
# resolution problems musl has in production.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags?name=1.20.4-erlang-29.1.2  build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20261005-slim        release image
#   - https://hub.docker.com/r/oven/bun/tags?name=1.4.4                     bun binary
#
# The newest Elixir and Erlang/OTP releases, on the newest snapshot of Debian's current stable
# (trixie) hexpm builds them for — the same pair as .tool-versions, which developers and CI run;
# change both together. DEBIAN_VERSION MUST be the same snapshot for both stages: the NIFs compiled
# in the builder (bcrypt_elixir, picosat_elixir, lazy_html) link against its glibc and libssl.
#
# OTP stays on the newest patch release although its :httpc cannot download from GitHub (the
# TEMPORARY step below works around that): the release ships the builder's ERTS, and 29.0.6 to 29.1.2
# fix security issues in erts, ssl, public_key, asn1 and stdlib that a running server is exposed to.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261005-slim
ARG BUN_VERSION=1.4.4

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"
ARG BUN_IMAGE="docker.io/oven/bun:${BUN_VERSION}"

FROM ${BUN_IMAGE} AS bun

FROM ${BUILDER_IMAGE} AS builder

# A C toolchain for the NIFs, git for the git dependencies, curl for the TEMPORARY downloads below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# bun, because `mix assets.setup` runs `bun install` in assets/ (mix.exs). Copied from the official
# image: pinned, amd64 and arm64, nothing piped into a shell.
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

RUN mix local.hex --force \
    && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./

RUN mix deps.get --only $MIX_ENV

# TEMPORARY, UNTIL :httpc CAN DOWNLOAD FROM GITHUB AGAIN. OTP 29.0.6 and later (29.1.2 too) make
# Erlang's :httpc stop at 10240 bytes of response headers, and the redirect GitHub answers a release
# download with now carries about 10.8 KB of them (9.2 KB of it one content-security-policy header).
# A library that downloads through :httpc without raising `max_header_size` then fails with
# {:header_too_long, {:max, 10240}}: here the precompiled NIFs of vix (elixir_make), ex_brotli and
# igniter_js (rustler_precompiled), and the Tailwind binary below (tailwind before 0.5.2). This
# script fetches the NIFs with curl into the folder each library looks in first; the library then
# finds the file, checks it against the checksum file of its package and does not download.
#
# BEFORE REVERTING, build without this step: it works again once GitHub's headers are back under
# 10240 bytes, or elixir_make, rustler_precompiled and tailwind pass `max_header_size` to :httpc.
# Then remove this step, the two ENV lines, the Tailwind step below and `curl` from the builder.
ENV ELIXIR_MAKE_CACHE_DIR=/opt/precompiled/elixir_make \
    RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/opt/precompiled/rustler_precompiled

COPY <<'EOF' /opt/prefetch_nifs.exs
arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

[nif_major, nif_minor] =
  :erlang.system_info(:nif_version)
  |> to_string()
  |> String.split(".")
  |> Enum.map(&String.to_integer/1)

# {package, prefix of its GitHub release tag, platform as its file names spell it, cache folder}
packages = [
  {"vix", "v", "#{arch}-linux-gnu", System.fetch_env!("ELIXIR_MAKE_CACHE_DIR")},
  {"ex_brotli", "", "#{arch}-unknown-linux-gnu",
   System.fetch_env!("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH")},
  {"igniter_js", "v", "#{arch}-unknown-linux-gnu",
   System.fetch_env!("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH")}
]

for {package, tag_prefix, platform, cache_dir} <- packages do
  [checksum_file] = Path.wildcard("deps/#{package}/checksum*.exs")
  {checksums, _binding} = Code.eval_file(checksum_file)
  {:ok, metadata} = :file.consult(~c"deps/#{package}/hex_metadata.config")
  {"version", version} = List.keyfind(metadata, "version", 0)
  {"links", links} = List.keyfind(metadata, "links", 0)
  {"GitHub", repository} = List.keyfind(links, "GitHub", 0)

  # The file the library will ask for: the newest NIF version for this platform that is not newer
  # than this OTP's, which is how elixir_make and rustler_precompiled choose too.
  {_minor, file} =
    Enum.max(
      for {file, _checksum} <- checksums,
          String.contains?(file, platform),
          [major, minor] <- [Regex.run(~r/-nif-(\d+)\.(\d+)-/, file, capture: :all_but_first)],
          String.to_integer(major) == nif_major and String.to_integer(minor) <= nif_minor do
        {String.to_integer(minor), file}
      end
    )

  File.mkdir_p!(cache_dir)
  path = Path.join(cache_dir, file)
  url = "#{repository}/releases/download/#{tag_prefix}#{version}/#{file}"

  {_output, 0} =
    System.cmd(
      "curl",
      ["--fail", "--silent", "--show-error", "--location", "--retry", "3", "--output", path, url],
      into: IO.stream()
    )

  "sha256:" <> expected = Map.fetch!(checksums, file)
  actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  if actual != expected do
    raise "#{file}: sha256 #{actual}, but the package's checksum file says #{expected}"
  end

  IO.puts("fetched #{url}")
end
EOF

RUN elixir /opt/prefetch_nifs.exs

RUN mkdir config

# Compile-time config before deps.compile, so a config change recompiles the dependencies.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# TEMPORARY, the same cause as the NIFs above: the Tailwind binary, downloaded with curl to the path
# `mix tailwind.install --if-missing` (in assets.setup below) checks, so it finds the file and does
# not download. The version, target and path are Tailwind's own, from config/config.exs. Mix warns
# that :mishka_cms is not available: the app is not compiled yet, and this step does not need it.
RUN <<'EOF'
mix run --no-compile --no-start --no-deps-check -e '
  url =
    Tailwind.default_base_url()
    |> String.replace("$version", Tailwind.configured_version())
    |> String.replace("$target", Tailwind.configured_target())

  path = Tailwind.bin_path()
  File.mkdir_p!(Path.dirname(path))

  {_output, 0} =
    System.cmd(
      "curl",
      ["--fail", "--silent", "--show-error", "--location", "--retry", "3", "--output", path, url],
      into: IO.stream()
    )

  File.chmod!(path, 0o755)
  IO.puts("fetched #{url}")
'
EOF

# The JS dependencies and the two asset binaries. package.json and bun.lock first, so a change under
# assets/js does not reinstall node_modules. `assets.setup` is bun install --frozen-lockfile, then
# tailwind.install and esbuild.install (mix.exs), so a bun.lock that disagrees with package.json
# fails the build instead of resolving silently.
COPY assets/package.json assets/bun.lock assets/
RUN mix assets.setup

# priv carries the migrations (priv/repo/migrations) and the snapshots they were generated from
# (priv/resource_snapshots). They are YOURS: they follow the extensions your copy loads (`ash_domains`
# in config/config.exs), so this repository does not keep them in git. You generate them with
# `mix ash.codegen <name>` and commit them to your copy, and the image takes what is committed. The
# guard before `mix release` below fails the build when they are missing or out of date.
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

# THE MIGRATIONS GUARD. Without a migration `bin/migrate` has nothing to run and the server starts
# on an empty database, so a build with none fails here instead of at the first request. `mix
# ash.codegen --check` fails when the resources (the extensions this build loads, and any change
# to them) describe a schema that the committed migrations and snapshots do not: after a package
# upgrade, say. Neither needs a database. It runs before runtime.exs is copied, which is what keeps
# the build from needing DATABASE_URL.
RUN <<'EOF'
set -eu
found=0
# The glob skips .formatter.exs, which is not a migration, and stays as written when nothing matches.
for migration in priv/repo/migrations/*.exs; do
  if [ -e "$migration" ]; then found=1; fi
done
if [ "$found" -eq 0 ]; then
  cat >&2 <<'MESSAGE'

ERROR: priv/repo/migrations holds no migration, so this image would start on an empty database.

The migrations belong to your copy of Mishka CMS, because they follow the extensions it loads
(ash_domains in config/config.exs). Generate them and commit them, then build again:

    mix ash.codegen <name>
    git add priv/repo/migrations priv/resource_snapshots

MESSAGE
  exit 1
fi
if ! mix ash.codegen --check; then
  cat >&2 <<'MESSAGE'

ERROR: the resources have changed since the migrations in priv/repo/migrations were generated.

Generate the new migration and commit it with its snapshots, then build again:

    mix ash.codegen <name>
    git add priv/repo/migrations priv/resource_snapshots

MESSAGE
  exit 1
fi
EOF

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

# mishka_data is MISHKA_DATA_DIR's default (config/runtime.exs) and the mount point for its volume:
# Mnesia, the installer's store, the CLDR and Chelekom caches and every uploaded file (`static/`).
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
