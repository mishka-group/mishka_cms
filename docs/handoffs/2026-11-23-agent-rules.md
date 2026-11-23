# 2026-11-23: agent rules for the host

## Done

- `AGENTS.md` (the single source of agent rules), `CLAUDE.md` and `.github/copilot-instructions.md`
  pointing to it, `FRICTION.md`, `GLOSSARY.md`, `docs/adr/0001`, and this handoff folder.
- `.claude/skills/mishka-code-design/` added: how Mishka code is written.
- `.claude/settings.json` enables the review and writing plugins for the project.
- CI runs credo, sobelow, dialyzer and ex_dna (they were off).
- `usage_rules` (dev only, `~> 1.3`) links every dependency's usage rules into `AGENTS.md`;
  `mix usage_rules.sync --yes` refreshes them.
- `.dockerignore` keeps the agent files out of the image's build context.

## Checks

- Locally with Hex deps: hex.audit, compile with warnings as errors, format, credo, sobelow,
  deps.audit, unused deps, ex_dna 0 and dialyzer pass; tests run on CI.

## Guessed

- Nothing new; the three `FRICTION.md` rows are closed.

## Next

- Each task ends with a file here, and any guess becomes a `FRICTION.md` row.
