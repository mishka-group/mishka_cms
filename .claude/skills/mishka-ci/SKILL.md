---
name: mishka-ci
description: How the shared Mishka GitHub Actions CI works and how to change it — the reusable workflows in mishka-group/mishka_cms (mishka-ci.yml, mishka-release.yml, mishka-deps-bump.yml), the 10-line callers in every public mishka-group repo, the ci-vN tags, adding a new repo, fixing a red CI run, CodeQL alerts on the workflows. Use it whenever a Mishka repo's CI fails, a workflow file or caller is edited, a repo joins the shared CI, or someone asks how the CI, tags or deps-bump work — even if they only paste a failing Actions link. Releasing a package is the sibling skill mishka-release.
---

# Mishka shared CI

One CI for every public mishka-group repo, kept in `mishka-group/mishka_cms/.github/` the way Ash keeps `ash-ci.yml`. A repo only declares inputs in its callers; all logic lives in the shared workflows.

**Single source of truth:** `mishka_cms/.github/CI.md` lists every input, the caller templates and the owner one-time steps. Read it there (`git -C mishka_cms show ci-v1:.github/CI.md`); this skill holds only the process and the problems found so far.

## Map

| File (mishka_cms/.github) | Role |
|---|---|
| `workflows/mishka-ci.yml` | build → format/audit/lint → tests (partitions) → custom jobs |
| `workflows/mishka-release.yml` | Release button pushes `v<version>`; the tag push runs CI, ebin/NIFs, GitHub release, staged Hex publish, notify |
| `workflows/mishka-deps-bump.yml` | on `upstream-released`, bumps the dep and opens a PR (never merges) |
| `mishka-dependents.json` | who `notify` tells about each package |

Callers in each repo: `.github/workflows/ci.yml`, `release.yml` (this exact name, hex.pm's workload identity names it), `deps-bump.yml`. They pin `@ci-vN`.

## Changing the shared workflows

1. Branch in mishka_cms (`--no-track origin/master`), one open PR per repo.
2. Prove it in temporary private test repos: copy the changed workflow into one (with `allowed-owners` set to its owner), point a second repo's caller at it, trigger the path you changed, then delete them. Never publish to Hex from them.
3. Third-party actions pinned by full SHA with a version comment; secrets passed by name, never `secrets: inherit` inside the shared files; job `permissions:` no wider than the caller grants.
4. After merge the owner moves or creates the tag (Claude's tag delete/move is blocked by the permission check, so hand the owner the command):
   - compatible change: `git tag -f ci-v1 <merge-sha> && git push -f origin ci-v1`
   - breaking change: `git tag ci-v2 <merge-sha> && git push origin ci-v2`, then bump every caller in one commit per repo.
5. CodeQL alerts on the workflows are fixed at the cause; never dismiss one ourselves.

## Adding a repo

Copy the three callers from CI.md, set only the inputs the repo needs (special builds such as Android or CMS bundles are `custom-jobs` entries, never an extra workflow), add the repo to `mishka-dependents.json` under each Mishka package it depends on, then follow mishka-release's per-repo setup before its first release.

## Fixing a red run

- `This run likely failed because of a workflow file issue`: the real message is only on the run page. Read it with
  `curl -sL https://github.com/<owner>/<repo>/actions/runs/<id> | grep -o 'error parsing[^<]*'`.
- Test failures: read `gh run view <id> --log-failed`, fix in the repo's open PR, run only the touched tests locally (the owner's Mac is short on resources), let CI run the rest.

## Problems found (add each new one here, once)

When a CI problem is solved, add one line here — symptom → cause → fix — and nowhere else; memory files and handoffs point to this list instead of copying it. If a line already covers it, sharpen that line.

- `"./.github/workflows/mishka-ci.yml" : workflow was not found (source tag with sha:…)` → the `ci-vN` tag was annotated; GitHub resolves the nested `./` call at the tag object → recreate it as a lightweight tag on the same commit (no `-a`).
- Bump PRs land unassigned → set org variables `MISHKA_CI_PR_ASSIGNEES` / `MISHKA_CI_PR_REVIEWERS`; a refused login only warns.
- deps-bump `pull request create failed: GraphQL: Resource not accessible by integration` → the GitHub App lacks Pull requests: Read and write (or the new permission wasn't accepted on the installation) → fix the App, then `gh run rerun <id>` in each dependent.
- deps-bump rerun says `deps/<pkg>-<ver> exists already; nothing to do` but no PR is open → an earlier run pushed the branch and then failed at the PR → fixed: the workflow now opens the PR for a branch that has none; just `gh run rerun <id>`.
- After a gervaz bump, LiveView tests fail with `does not have phx-focus attribute` on a relation select → gervaz 0.0.10 opens it through its colocated hook (rendered as `MishkaGervaz.UIAdapters.Tailwind.SearchSelect`, not `.SearchSelect`) → open it with `element("#search-select-<form>-<field>") |> render_hook("relation_focus", %{"filter" => "<field>"})`; the root's exact id, because the open list's options share its prefix and filter. Reproduce such a failure locally before pushing a guess.
- A test reading the DB through a leftover shared sandbox crashes with `owner #PID<…> exited` → the test must check out its own sandbox (`use <App>.DataCase`), never rely on another test's.
- A protected branch with a review rule (mishka_chelekom) blocks `gh pr merge` even when green → the owner approves or merges; never use `--admin` without the owner's word.
