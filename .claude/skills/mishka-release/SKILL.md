---
name: mishka-release
description: Releasing a Mishka Elixir package (mishka_cms_core, mishka_blog, mishka_document, mishka_cms_builder, mishka_slug, mishka_gervaz, guarded_struct, mishka_installer, the auth extensions, chelekom…) through the shared CI to Hex and GitHub — per-repo one-time setup (release environment, hex.pm workload identity, staged publishing), the Release button or tag push, the owner's 2FA approval, the deps-bump PRs in dependents, and the release order. Use it whenever someone says release, publish, ship a version, bump a dependent, "push to hex", or asks what a repo still needs before CI can release it. CI mechanics themselves are the sibling skill mishka-ci.
---

# Mishka release

A release goes out from CI, never from a laptop: the run publishes to Hex with a workload identity (no API key), staged until the owner approves it on hex.pm with 2FA. Claude never releases, tags or approves without the owner's word, and never handles keys, tokens or the App's private key — those go straight from the owner into GitHub or hex.pm.

**Single source of truth for state:** per-repo state (what is set up, what each repo still needs) lives in `references/repos.md`. Read it before releasing a repo and update it after each step the owner finishes.

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

Order across the CMS: mishka_slug / gervaz / installer → mishka_cms_core → blog, document, builder, migration, auth extensions → the mishka_cms host. The mishka.tools site takes new releases only when the owner says so.

## Problems found (add each new one here, once)

When a release problem is solved, add one line here — symptom → cause → fix — and nowhere else; memory and handoffs point here. CI-file problems belong in mishka-ci's list instead.

- Release button run failed at `git commit` with nothing to commit → mix.exs already held the typed version → fixed: the button tags the current commit then.
- Hex publish went out without asking → staged publishing was off for that package → enable it before the first CI release.
- A tag pushed before its workflow could parse leaves no release → after the CI fix, the owner deletes and re-pushes the tag: `git push origin :refs/tags/v<version> && git push origin v<version>` (nothing was published, so this is safe).
- The host's bump PR fails `record_labels_gettext_test` (`labels missing from …errors.pot`) → core's .pot already dropped labels that the Hex release of an extension still declares (core alpha.18 vs blog alpha.8) → release the extensions that core's change follows before bumping the host; the rolling `deps/mishka` PR now collects them on its own.
