# Mishka CI

The shared GitHub Actions workflows of the Mishka Elixir repositories live here, in mishka_cms,
the way Ash keeps `ash-ci.yml` in the ash repository. Each repository calls them from a few lines.

| Workflow | What it does |
| --- | --- |
| `workflows/mishka-ci.yml` | build, then format + audit + lint side by side, then the tests and the custom jobs (only when those pass) |
| `workflows/mishka-release.yml` | the Release button bumps mix.exs and CHANGELOG, commits and pushes tag `vX` (with the GitHub App's token); the tag push is the release: CI on the tag's commit beside the ebin and NIF builds; GitHub release; Hex publish (staged: an owner approves it on hex.pm with 2FA); the hex `.tar` added to the GitHub release; notify dependents |
| `workflows/mishka-deps-bump.yml` | on `upstream-released`, move the dependency in mix.exs, `mix deps.update`, commit it to the one rolling PR `deps/mishka` (never merged by itself) |
| `mishka-dependents.json` | which repositories `notify` tells about a new release of each package |

Every workflow fails at once when the calling repository's owner is not in `allowed-owners`
(default `mishka-group`). A brand-new package's very first Hex release is the one manual
exception: Hex does not let a workload identity create a package.

## mishka-ci.yml inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `allowed-owners` | `mishka-group` | owners allowed to run it, space separated |
| `elixir`, `otp` | `.tool-versions` | pin other versions, e.g. to test the oldest supported pair |
| `mishka-deps` | `hex` | exported as `MISHKA_DEPS` for mix.exs |
| `rustler` | `false` | install a Rust toolchain before compiling and testing |
| `postgres` | `false` | start a Postgres service; tests see `POSTGRES_HOST=localhost` |
| `postgres-image` | `postgres:18` | |
| `partitions` | `1` | test machines; each has its own Postgres and `MIX_TEST_PARTITION` |
| `pre-test` | | shell run before `mix test` with `MIX_ENV=test`, e.g. `mix ash.codegen ci` |
| `test-args` | | extra `mix test` arguments |
| `mix-audit` | `true` | `mix deps.audit` (needs `mix_audit`) |
| `hex-audit` | `true` | `mix hex.audit` |
| `unused-deps` | `true` | `mix deps.unlock --check-unused` |
| `warnings-as-errors` | `true` | `--warnings-as-errors` on compile and test |
| `test-bun` | `false` | install Bun (`bun-version`) in the test jobs, for tests that run it |
| `credo` | `true` | `mix credo --strict` |
| `credence-task` | | e.g. `mishka_cms_core.credence`; empty skips |
| `sobelow` | `false` | `mix sobelow --config` |
| `dialyzer` | `true` | with a PLT cache keyed on mix.lock and .tool-versions |
| `ex_dna`, `ex-dna-args` | `true`, | `mix ex_dna <args>`, e.g. `--max-clones 92` |
| `spark-cheat-sheets` | `false` | `mix spark.cheat_sheets --check` |
| `ash-codegen-check` | `false` | `mix ash.codegen --check` |
| `assets`, `assets-dir`, `bun-version` | `false`, `assets`, `latest` | `bun install --frozen-lockfile && bun run test` |
| `tailwind-cache` | `false` | cache `_build/tailwind-*`, `esbuild-*`, `bun-*` for the test jobs, keyed on `config/*.exs` (the binary is downloaded by `pre-test`, e.g. `mix tailwind.install --if-missing`) |
| `versions` | | more Elixir/OTP pairs, JSON `[{"elixir":"1.17.1","otp":"27.0"}]`: compile + test each (format, audit and lint run on the main pair) |
| `subprojects` | | Mix projects in subdirectories, JSON `["development/web"]`: deps, unlock check, hex/deps audit, compile, format, test. A step a subproject needs first (`assets.setup`) goes in its `test` alias |
| `extra-checks` | | shell run after the build with deps and `_build` restored, e.g. `cd development/web && mix deps.get && mix run --no-start idempotency_check.exs` |
| `semgrep-path` | | `semgrep scan --config auto <path>` (reports, does not fail, as chelekom's does today) |
| `retire-path` | | `retire --path <path> --severity medium` |

## mishka-release.yml inputs

All the `mishka-ci.yml` inputs (passed through), and:

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | | the Release button: bump, commit and push tag `v<version>` with the GitHub App's token, nothing else; the tag push then runs the release. Empty: release the pushed tag, or a dry run without a tag |
| `publish` | `true` | `true`: `mix hex.publish --yes --wait` through the workload identity (staged; you approve it on hex.pm with 2FA). `false`: `mix hex.build` + `mix hex.publish --dry-run`. A run without a tag (Release with no version) is always a dry run |
| `package` | repository name | the Hex package name `notify` sends |
| `github-release` | `false` | GitHub release for the tag with every file below and the hex `.tar` |
| `ebin`, `ebin-paths` | `false`, `priv` | `MIX_ENV=prod` compile, `tar -czh` of `ebin` + `ebin-paths` (+ `consolidated`), checked to hold `<app>.app` and `.beam` files |
| `rustler-precompiled` | | the `RustlerPrecompiled` module (e.g. `MyLib.Native`). Builds one NIF per `nif-targets` entry (philss/rustler-precompiled-action), puts them on the GitHub release (forced on), then `mix rustler_precompiled.download <Module> --all --print` writes the checksum file the Hex package ships |
| `rustler-crate` | | the crate directory, e.g. `native/my_lib`; its last part is the crate name |
| `nif-version` | `2.15` | must be in the module's `nif_versions` |
| `nif-targets` | linux gnu+musl x86_64/aarch64, darwin x86_64/aarch64, windows msvc x86_64 | JSON `[{"target":..., "os":..., "cross":true}]`; add `{"target":"aarch64-linux-android","os":"ubuntu-24.04","cross":true}` or `{"target":"aarch64-apple-ios","os":"macos-15"}` |
| `ci-repo` | `mishka-group/mishka_cms` | where `.github/mishka-dependents.json` lives |

The crate needs a `.cargo/config.toml` like the test package's
(see rustler_precompiled's guide): `-C
target-feature=-crt-static` for the musl targets (a static binary cannot be a NIF) and `-C
link-arg=-undefined -C link-arg=dynamic_lookup` for `aarch64-apple-ios` (the BEAM supplies the
`enif_*` symbols). Android needs `"cross-version":"from-source"` in its target entry: cross
v0.2.4's NDK has no `libunwind`. `rustler_precompiled.download` reads the NIFs from the release's
public download URL; a private repository needs a `base_url` function that asks the GitHub API
with `GITHUB_TOKEN` .

A `-alpha.N` version is a pre-release on GitHub. RustlerPrecompiled always builds a pre-release
version from source (`force_build` is forced on for `x.y.z-…`), so a precompiled NIF only helps a
plain version.

## Custom jobs (ci.yml and release.yml `custom-jobs`)

A repository's special builds are data in its callers; the shared workflow runs them, in parallel,
after format, audit and lint pass (like the tests). `custom-jobs` is a JSON list; each entry:

| Field | Meaning |
| --- | --- |
| `name` | job and artifact name |
| `runs-on` | runner, default `ubuntu-latest` (`macos-15` for an Xcode build) |
| `setup` | any of `elixir` (setup-beam + `mix deps.get`), `java`, `gradle`, `node`, `bun`, `zig`, `rust`, `android-sdk` |
| `java-version`, `gradle-version`, `node-version`, `zig-version`, `ndk-version` | versions for those setups (`ndk-version` also installs cmake 3.22.1) |
| `run` | bash, with `$VERSION` (the release version, or mix.exs's in plain CI) and the caller's `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` secrets when the caller passes them (`secrets:` map, or `secrets: inherit`) |
| `emulator` | `{"api-level":34, "script":"..."}`: enables KVM, boots an x86_64 Android emulator (reactivecircus/android-emulator-runner) and runs `script` in it, after `run` |
| `artifacts` | paths/globs uploaded as `release-custom-<name>`; a release puts them on its GitHub release |
| `release-only` | `true`: only in release runs (bundles, store builds) |
| `timeout` | minutes, default 60 |

Two example jobs:

```yaml
      custom-jobs: >-
        [{"name":"cms-bundle","setup":["elixir"],"run":"bin/export_bundle.sh","artifacts":"priv/bundle/my_package.json","release-only":true},
         {"name":"android","setup":["java","gradle","android-sdk","zig"],"java-version":"17","ndk-version":"27.2.12479018",
          "run":"zig version && gradle -p development/android assembleDebug && mkdir -p dist && cp development/android/app/build/outputs/apk/debug/app-debug.apk \"dist/mishka_hello_$VERSION.apk\"",
          "artifacts":"dist/*.apk",
          "emulator":{"api-level":34,"script":"adb install -r dist/mishka_hello_*.apk && adb shell pm list packages | grep tools.mishka.hello"}}]
```

Chelekom maps onto it like this: the CMS bundles are one `release-only` elixir job whose `run` is
its two `mix mishka.ui.export ... --bundle-version "$VERSION"` calls plus the jq check (best kept as
a script in the repository); the Android APKs are one `release-only` job with `setup`
`["elixir","java","gradle","android-sdk","zig"]`, `ndk-version: 27.2.12479018`, `zig-version:
0.17.0`, whose `run` is its mob steps (deps.get, mob.exs, OTP runtime prefetch, native build,
`mix mob.release --android`, `./gradlew assembleRelease -PsplitAbi`) moved into a script, and
`artifacts: development/mob/dist/*`; its e2e is a job with `emulator` and
`script: cd development/mob && mix e2e --device emulator-5554`. An unsigned build needs no secret;
signing needs the keystore secrets passed with `secrets: inherit`, which a script can read.
Chelekom has no iOS build in CI today, so there is no iOS setup; a `runs-on: macos-15` job with
`run: xcodebuild ...` covers it when one is added.

## How a repository adopts it

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [master]
  pull_request:
  workflow_dispatch: # deps-bump starts it on its PR branch when no App token is set
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  ci:
    uses: mishka-group/mishka_cms/.github/workflows/mishka-ci.yml@ci-v1
    with:
      postgres: true
      partitions: 4
```

`.github/workflows/release.yml` (keep this exact file name: the hex.pm workload identity names it).
"Run workflow" with a version is the release button: it bumps `@version` in mix.exs, adds a
CHANGELOG heading for the plain version if the top one is another (alphas stay under their plain
version), commits to the default branch and pushes the tag `v<version>`, nothing more. It pushes
with the GitHub App's token, because a push made with `GITHUB_TOKEN` starts no workflow; without the
App it stops with "GitHub App not configured: push the tag vX yourself". The tag push is the
release run: CI on the tag's own commit, the GitHub release, the Hex publish and notify. Pushing a
`v*` tag by hand does the same; "Run workflow" with no version is a dry run.

```yaml
name: Release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version:
        description: Version to release, e.g. 0.1.1 (empty dry-runs the version in mix.exs)
        required: false
concurrency: release
permissions:
  contents: write
  id-token: write
jobs:
  release:
    uses: mishka-group/mishka_cms/.github/workflows/mishka-release.yml@ci-v1
    with:
      version: ${{ inputs.version }}
      postgres: true
      partitions: 4
    secrets: inherit
```

`.github/workflows/deps-bump.yml` (repositories that depend on other Mishka packages):

```yaml
name: Deps bump
on:
  repository_dispatch:
    types: [upstream-released]
permissions:
  contents: write
  pull-requests: write
  actions: write
jobs:
  bump:
    uses: mishka-group/mishka_cms/.github/workflows/mishka-deps-bump.yml@ci-v1
    with:
      package: ${{ github.event.client_payload.package }}
      version: ${{ github.event.client_payload.version }}
    secrets: inherit
```

Then list the repository under each package it depends on in `.github/mishka-dependents.json` here.

Every release lands in one rolling PR per repository, from the branch `deps/mishka`, titled
"deps: update Mishka packages"; its body lists each package and its newest version, rebuilt on each
run from the branch's `deps: update <pkg> to <version>` commits. So releases that follow each other
(core, then blog) are tested together and never conflict in mix.lock. On each run:

- an open PR: its branch takes the default branch merged in, then one more commit with the bump;
- a branch whose PR was merged or closed: it starts again from the default branch (a closed PR's
  branch is deleted first; nothing is ever force-pushed, so commits a person adds stay);
- a branch pushed without a PR (an earlier run failed before it): the run uses it and opens the PR;
- mix.exs already asks for that version or a newer one (`Version.compare`): nothing happens;
- the merge conflicts in mix.exs or mix.lock: the default branch's copies win and every bump on the
  branch is applied again (`mix deps.update` for those packages only); a conflict in any other file
  fails the run, merge it by hand;
- two releases at once: the later push is refused, and that run fetches and starts over (5 tries).
  There is no concurrency group, as GitHub would cancel the waiting run and lose its bump.

The PR is assigned to the logins in the org variable `MISHKA_CI_PR_ASSIGNEES` and asks for a
review from `MISHKA_CI_PR_REVIEWERS` (comma-separated, e.g. `octocat,hubot`; unset means nobody) when
it opens. Old per-package `deps/<pkg>-<version>` PRs are left as they are; close them by hand.

Callers pin the tag `ci-v1`, moved forward (`git tag -f ci-v1 && git push -f origin ci-v1`) for
compatible changes; a breaking change gets `ci-v2`. mishka_cms's own `ci.yml` calls
`./.github/workflows/mishka-ci.yml`, and `mishka-release.yml` calls `./.github/workflows/mishka-ci.yml`,
which is this repository at the ref the caller pinned.

## Owner one-time steps

1. **Org settings → Actions → General**: "Allow mishka-group, and select non-mishka-group, actions
   and reusable workflows" with the GitHub actions used here allowed (`actions/*`, `erlef/setup-beam`,
   `dtolnay/rust-toolchain`, `oven-sh/setup-bun`, `philss/rustler-precompiled-action`,
   `gradle/actions`, `android-actions/setup-android`, `mlugg/setup-zig`,
   `reactivecircus/android-emulator-runner`,
   `softprops/action-gh-release`, `semgrep/semgrep` container); and "Allow GitHub Actions to create and approve
   pull requests".
2. **GitHub App** (org Settings → Developer settings → GitHub Apps → New): no webhook, repository
   permissions Contents: Read and write, Pull requests: Read and write, Actions: Read and write
   (Metadata read is automatic). Install it on all mishka-group repositories. Then save its
   Client ID as the org variable `MISHKA_CI_APP_CLIENT_ID` and a generated private key as the org
   secret `MISHKA_CI_APP_PRIVATE_KEY`. The Release button needs them to push its tag; without them
   it stops and you push the tag yourself. Release's `notify` and deps-bump's App PR are skipped with
   a notice, and deps-bump falls back to `GITHUB_TOKEN` + a `workflow_dispatch` of CI.
3. **Each package repository**: Settings → Environments → New `release`; add yourself as a
   required reviewer if every publish should wait for a click.
4. **hex.pm, per package** (you must be a full owner with 2FA on). A brand-new package's very
   first release is the one manual exception: Hex does not let a workload identity create a
   package, so publish it by hand (`mix hex.publish`). Every later release publishes from CI
   (`publish: true`) and waits, staged, until you approve it on hex.pm. Then the package's **Workload identities** tab: Repository owner
   `mishka-group`, Repositories the repository name (a private one also needs its numeric id:
   `gh api repos/mishka-group/NAME --jq .id`), Workflow `release.yml`, Environment `release`.
   Turn on **staged publishing** for the package (or the organization): `mix hex.publish --wait`
   then waits until you approve the release on hex.pm.
5. Remove any `HEX_API_KEY` secret: with one set, Hex publishes with the key, not the identity.
6. A protected default branch must let the release job push its version commit (allow GitHub
   Actions, or the App, to bypass), or release by pushing a tag you made yourself.
7. Optional: org variables `MISHKA_CI_PR_ASSIGNEES` and `MISHKA_CI_PR_REVIEWERS` (GitHub logins) for
   the bump PRs. Tags `ci-vN` are lightweight (`git tag ci-v1 <sha>`, no `-a`): with an annotated
   tag GitHub cannot find the release's nested `./.github/workflows/mishka-ci.yml`.
