# Workflow: branches, commits, PRs, releases

## Branches and PRs

- **One open PR per repo.** Check with `gh pr list -R <repo> --state open`. New work joins that PR as its own commit. Only with no open PR, create one: `git switch -c <branch> --no-track origin/master`, then `git push -u origin <branch>`. Before a push, check that the upstream isn't `origin/master`.
- **Never force-push** over shared history.
- **Never merge, release or deploy** without the owner's word.
- **PR body, written for the tester:** one table row per problem.

  | Problem | Before | Now | Test it |
  |---|---|---|---|

  Then one checks line, and the footer "🤖 Generated with [Claude Code](https://claude.com/claude-code)". A small diagram or screenshot is fine. Leave out root-cause essays.

## Commits

- Small, with related files only, staged by explicit path (never `git add -A` when others work on the branch).
- The message is `type(scope): what the code now does`. The body says what changed and why.
  - Good: `fix(jobs): retry a job whose progress the database cannot save`.
  - Bad: `step 2 done`, `fix(credo): findings`.
- Trailers:
  - Most repos: `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
  - mishka_cms_builder: only `Co-authored-by: Mona Aghili <28711325+MonaAghili@users.noreply.github.com>`.
  - A fix for a reported issue also credits the reporter.

## Versions and CHANGELOG

- `mix.exs` `@version` carries the pre-release (`0.0.5-alpha.2`), and so do `package.json` and the README install line. The CHANGELOG heading stays the plain version (`# Changelog for MishkaCmsCore 0.0.5`), with every pre-release's changes under it.
- A brand-new package's first CHANGELOG is only the heading plus `- Initial version: [mishka.tools/cms](https://mishka.tools/cms)`.
- **Release order:**
  1. core: merge, then the owner releases.
  2. builder and the extensions: require the new core and update the lock, then merge, then the owner releases.
  3. host: update to both.

  A pre-release needs an explicit requirement (`~> 0.0.5-alpha.2`), because `~> 0.0.4` doesn't match pre-releases.
- A library fixed alongside a feature is used as a sibling path dependency through `mishka_dep` while the work is in progress. It is released before the dependent PR can pass CI on Hex.

## Dependencies and CI

- Use the newest releases. A PR touching `mix.exs` or `mix.lock` runs `mix deps.update --all` and `mix hex.outdated --all`. Resolve Hex-only locks in a clone without siblings when the repo prefers sibling checkouts.
- When CI breaks because an action or runner is too old, update every action to its newest release, in its own CI PR.

## README

- Name other Mishka products by their page title, linked to their mishka.tools page, never to their GitHub repo. For example, [Mishka Blog: Open-Source Blog Engine](https://mishka.tools/cms/extensions/blog).
- No links to internal plan issues.
- Planned work goes in a short checkbox list.

## Working with agents (if you delegate)

- **Opus:** design and complex work, and fixing confirmed bugs, with targeted tests only.
- **Sonnet:** implementing against a clear brief, project setup, and CI or check runs.
- **Haiku:** tests and checks, including the final developer and end-user check.
- **Browser tests:** Haiku or Sonnet only.
- **Mishka Chelekom:** Haiku and Sonnet.
- **Each brief carries the rules it needs,** since agents inherit nothing.
- **Deliver in small steps:** stop at the first testable point, say how to test it, and wait for the owner's OK before the next step.

## Cleanup

After a merge, remove worktrees, scratch clones (their `deps` and `_build` are large) and merged local branches (`git branch -d`). Never delete repo `deps`/`_build`, the app's data folder, or anything unmerged.
