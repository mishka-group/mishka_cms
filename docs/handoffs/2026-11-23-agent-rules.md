# 2026-11-23: agent rules for the host

## Done

- `AGENTS.md` (the single source of agent rules), `CLAUDE.md` and `.github/copilot-instructions.md`
  pointing to it, `FRICTION.md`, `GLOSSARY.md`, `docs/adr/0001`, and this handoff folder.
- `.claude/skills/mishka-code-design/` added: how Mishka code is written.
- `.claude/settings.json` enables the review and writing plugins for the project.
- CI runs credo, sobelow, dialyzer and ex_dna (they were off).

## Checks

- Docs only, apart from `.github/workflows/ci.yml`; CI proves the four lint jobs pass on master.

## Guessed

- Nothing new; the three `FRICTION.md` rows are closed.

## Next

- Each task ends with a file here, and any guess becomes a `FRICTION.md` row.
