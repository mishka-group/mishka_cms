# Mishka CMS host: agent rules

The Phoenix app that runs Mishka CMS. It installs `mishka_cms_core`, `mishka_cms_builder`,
`mishka_blog`, `mishka_document` and the sign-in extensions from Hex. For local work they are linked
in `__extensions/` (`mishka_dep` in `mix.exs` takes the folder when it is there).

## Read first

- `.claude/skills/mishka-code-design/`: how Mishka code is written. Follow it for every change.
- `.claude/skills/mishka-release/` (the release waves) and `.claude/skills/mishka-ci/`.
- `GLOSSARY.md`, `docs/adr/`, and the newest file in `docs/handoffs/`.

## Layout

| Path | Holds |
|---|---|
| `lib/mishka_cms_web/` | endpoint, router, `controllers/error_html.ex`, layouts |
| `config/` | the extensions the host loads, Oban queues, the security headers |
| `assets/` | a bun project: TipTap, CodeMirror, vitest |
| `test/mishka_cms/` | rules across packages: async locale, refusal messages, gettext labels |

## Run it

- The gate: `MISHKA_DEPS=hex mix ci`. Every step but `test` passes before a push; CI's lint stops at
  its first failure.
- Local extensions: link them in `__extensions/`. Local config, `mishka_data/` and local `mix.exs`
  lines are never committed.

## Tenants

- **Site**: one tenant, served on its own host. Tenant resources carry `site_id`.
- **Master user**: a user with no `site_id` (`MishkaCmsCore.Accounts.Helper.master_user?/1`). It
  reaches every site; what it may do there is set by its permissions. A master who is a full dashboard
  admin can do everything, the Oban dashboard included. Masters sign in at `/auth?master_user=true`.
- **Site user**: a user with a `site_id`. It reads and writes only its own site, whatever it holds;
  passing another site's tenant or naming another site reads nothing.
- **Global record**: a row with no `site_id` on a resource that allows it (component, layout, page,
  stylesheet, JS hook, error page, media, setting). Every site sees it next to its own rows
  (`Preparations.SiteWithGlobals`); only a master writes it.

## Hard rules

1. **Simplicity first**: no unrequested features, abstractions or configurability; if 200 lines could
   be 50, rewrite. Never cut validation, security or error handling to get there.
2. **Reuse before you write**: Ash, mishka_installer events, mishka_gervaz, guarded_struct, and
   `Phoenix.LiveView.JS` before a JS hook.
3. **Performance and safety first**: no `rescue`, `try` or `catch` on a path many users hit unless
   nothing else works; count the queries a change adds.
4. **A paid extension is never in `mix.exs`, `mix.lock` or master.** It is linked locally only.
5. **Newest versions**: every dependency at its newest release; JS through bun; every TipTap package
   on one version.
6. **No private repository names** in this public repo.

## The loop

1. Before acting, read the state as text: the server log, page text, the browser console. Not
   screenshots first.
2. After acting, prove it independently: a test written from the requirement, or a review by someone
   who is not the author (`/code-review`).
3. Every guess or missing tool is a row in `FRICTION.md`.
4. A stage ends with no `open` row in `FRICTION.md`: each one closed as a check, a rule, a helper or
   a decision.

## Testing

No sleeps, retries or longer timeouts: wait on messages and telemetry. Run only the tests a change
touches while working; the full suite runs on CI. Browser tests act like a real user (bad input,
reload, two tabs, phone size), sign in once per role, read the server log and the console, and every
control has a `data-testid`.

## Commits and pull requests

- One open PR per repo; a new task is a commit in it. Commits are
  `type(scope): what the code now does`, staged by path.
- A PR body is short and organized, for the tester:
  - `## 👀 At a glance`: a Mermaid diagram (before and after, or the flow) with emojis, readable at
    first glance. GitHub draws it as a picture.
  - One row per problem: **Before**, **Now**, **Test it** (the fastest way to check, with the
    expected result).
  - Where it helps, the code that changed, shown small (a diff sketch or a tree) with one line on
    what it does.
  - One checks line, and `Fixes #N` (or `Part of #N`) for the issue it closes.
  - No cause essays, file lists or anything the tester does not need.

## Task end

Commits, the check results, the guesses (rows in `FRICTION.md`), what is left, and a handoff
`docs/handoffs/YYYY-MM-DD-<task-slug>.md` written with the `writing-for-agents` skill. There is no
root handoff file: the newest file in `docs/handoffs/` is the handoff.
