---
name: mishka-release
description: Releasing a Mishka Elixir package (mishka_cms_core, mishka_blog, mishka_document, mishka_cms_builder, mishka_slug, mishka_gervaz, guarded_struct, mishka_installer, the auth extensions, chelekom…) through the shared CI to Hex and GitHub — per-repo one-time setup (release environment, hex.pm workload identity, staged publishing), the Release button or tag push, the owner's 2FA approval, the deps-bump PRs in dependents, and the release cycle (waves, freeze, one release per package). Use it whenever someone says release, publish, ship a version, plan a release, bump a dependent, "push to hex", or asks what a repo still needs before CI can release it. CI mechanics themselves are the sibling skill mishka-ci.
---

# Mishka release

A release goes out from CI, never from a laptop: the run publishes to Hex with a workload identity (no API key), staged until the owner approves it on hex.pm with 2FA. Claude never releases, tags or approves without the owner's word, and never handles keys, tokens or the App's private key — those go straight from the owner into GitHub or hex.pm.

**Single source of truth for state:** per-repo state (what is set up, what each repo still needs) lives in `references/repos.md`. Read it before releasing a repo and update it after each step the owner finishes.

## 0. The release cycle: each package once

A cycle releases every package that changed exactly once, wave by wave. A package released a second time in one cycle means a step below was skipped.

| Wave | Packages | Waits for |
|---|---|---|
| 1 | guarded_struct, mishka_gervaz | nothing |
| 2 | mishka_slug, mishka_installer | wave 1 |
| 3 | mishka_cms_core | waves 1 and 2 |
| 4 | mishka_blog, mishka_document, mishka_cms_builder, the four auth extensions | core |
| 5 | mishka_cms_migration | mishka_blog |
| 6 | mishka_cms (host): a tag, no Hex | everything above |

The waves follow the `mishka_dep` requirements in each `mix.exs`; a new requirement between packages moves the package to a lower wave. Packages in one wave do not depend on each other and go out together.

1. **Freeze.** Every change planned for the cycle is merged in every repo before wave 1. A fix that lands after its package's release is the next cycle's, unless it is a security fix.
2. **Rehearse on the host.** Check every Mishka repo out on master next to the host (`../<name>`, so `mishka_dep` compiles the siblings) and run `mix ci` in the host. The host holds the cross-package rules (`MishkaCms.AsyncLocaleTest`, the seo and error page tests), so a failure here is a fix in the package's repo before any tag.
3. **Lint in each repo before its PR:** every step of that repo's `mix ci` but `test` (credo, credence, sobelow, ex_dna, dialyzer) and `mix gettext.extract --check-up-to-date`. CI's lint stops at its first failure, so a missing step costs one red run each.
4. **Release a wave.** Tag or press Release for each package of the wave once its master CI is green; the owner approves each on hex.pm.
5. **Close the wave.** `notify` opens the `deps/mishka` bump PRs in the next waves; merge each when green. A dependent gets the bump in its `mix.exs` every time: the cascade is how the newest versions reach the host, so keep it.
6. **Next wave** only when every package of this one is on Hex and every bump PR it opened is merged and green.

A security fix in a released package is a patch release of that package alone (0.0.5 → 0.0.6), with the unsafe version retired: `mix hex.retire <package> <version> security --message "Use <new> or later"`. The cascade from step 5 then carries it down.

## 1. Before the first CI release of a repo

Walk the owner through these one at a time, one URL per step, waiting for "done" (the owner asked for step-by-step, never a wall of steps):

1. `https://github.com/mishka-group/<repo>/settings/environments/new` → name `release`; Required reviewers off (hex 2FA is the gate) or the owner added; Save.
2. `https://hex.pm/packages/<package>` → Settings → Staged publishing: Enable. Without it CI publishes with no approval.
3. Same Settings → Workload identities: owner `mishka-group`, repository `<repo>`, workflow `release.yml`, environment `release`.
4. Check the default branch: `gh api repos/mishka-group/<repo>/branches/master --jq .protected` and `.../rulesets --jq length`. If protected, the GitHub App needs a bypass so the Release button can push its version commit.
5. A package that is not on Hex yet: its very first publish is manual (`mix hex.publish` by the owner); Hex won't let a workload identity create a package.

Org-wide pieces are done once (2026-11-14): GitHub App installed on all repos, org variable `MISHKA_CI_APP_CLIENT_ID`, org secret `MISHKA_CI_APP_PRIVATE_KEY` (public repos), no `HEX_API_KEY` anywhere. If a `HEX_API_KEY` secret ever appears, delete it — Hex would publish with the key instead of the identity.

## 2. Release

- **Version not in mix.exs yet:** Actions → Release → Run workflow → version (e.g. `0.0.5-alpha.19`). It bumps mix.exs and CHANGELOG, commits and pushes `v<version>`.
- **mix.exs already holds the version:** the button works too; it tags master as it is. Pushing the tag by hand from an up-to-date master does the same:
  `git -C <repo> fetch && git -C <repo> tag v<version> origin/master && git -C <repo> push origin v<version>`
- **No version:** dry run (CI + `mix hex.publish --dry-run`).

Watch the run in the background (`gh run watch <id> --exit-status`), and tell the owner when the publish job prints "Waiting for approval…": they approve at `https://hex.pm/dashboard/staged-releases/hexpm/<package>/<version>`.

Done = Hex shows the version, the GitHub release has the ebin tarball, the hex `.tar` and `SHA256SUMS.txt`, and `notify` lists each dependent.

## 3. After the release

`notify` sends `upstream-released` to every repo in `mishka-dependents.json`; each adds the bump to its one rolling PR `deps/mishka` ("deps: update Mishka packages", opened if none is open), so releases made one after the other are tested together. Check them with `gh pr list -R mishka-group/<dep> --head deps/mishka`. They never merge themselves; merge only on the owner's word, when green. Release tags stay the owner's.

Order across the CMS: the waves of section 0. The mishka.tools site takes new releases only when the owner says so.

## Problems found (add each new one here, once)

When a release problem is solved, add one line here — symptom → cause → fix — and nowhere else; memory and handoffs point here. CI-file problems belong in mishka-ci's list instead.

- Release button run failed at `git commit` with nothing to commit → mix.exs already held the typed version → fixed: the button tags the current commit then.
- Hex publish went out without asking → staged publishing was off for that package → enable it before the first CI release.
- A tag pushed before its workflow could parse leaves no release → after the CI fix, the owner deletes and re-pushes the tag: `git push origin :refs/tags/v<version> && git push origin v<version>` (nothing was published, so this is safe).
- The host's bump PR fails `record_labels_gettext_test` (`labels missing from …errors.pot`) → core's .pot already dropped labels that the Hex release of an extension still declares (core alpha.18 vs blog alpha.8) → release the extensions that core's change follows before bumping the host; the rolling `deps/mishka` PR now collects them on its own.
- mishka_cms_core released twice in one cycle (0.0.5, then 0.0.6) → the host's `AsyncLocaleTest` found Phoenix's own `start_async` in core only after core was on Hex, and the host's master went red → rehearse on the host with every sibling on master before wave 1 (section 0, step 2).
- A core PR went red four times, one lint step each (credence, ex_dna, dialyzer, gettext) → only tests had been run locally → run every lint step of `mix ci` before the push (section 0, step 3).
