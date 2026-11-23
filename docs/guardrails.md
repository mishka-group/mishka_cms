# Guardrails

How this project keeps written code honest. The full gate is `MISHKA_DEPS=hex mix ci`; CI runs the
same steps as separate jobs (`.github/workflows/ci.yml`). Once per clone: `mix hooks`.

| Step | Tool | Catches |
|---|---|---|
| Commit hook | `.githooks/pre-commit`: `mix format --check-formatted` and `mix credo --strict` on the staged files | style and smells before they are committed |
| Audit | `mix hex.audit`, `mix deps.audit`, `mix deps.unlock --check-unused` | retired or vulnerable packages, unused locks |
| Compile | `mix compile --warnings-as-errors` | every warning |
| Format | `mix format --check-formatted` | style drift |
| Lint | `mix credo --strict` (with `jump_credo_checks`, `ex_slop`) | bugs, smells, patterns written by habit |
| Security | `mix sobelow --config` (reviewed findings in `.sobelow-skips`) | XSS, CSRF, unsafe config |
| Types | `mix dialyzer` (exceptions in `.dialyzer_ignore.exs`, each with its reason) | wrong shapes |
| Copies | `mix ex_dna --max-clones 0` | copied code |
| Tests | `mix test` | behaviour |
| JS | `bun run test` in `assets/` (vitest) | the editor's hooks |

## Project checks

Rules no general tool knows, kept as tests in `test/mishka_cms/`. A `FRICTION.md` row seen twice
becomes one of these.

| Test | Keeps |
|---|---|
| `agent_files_test.exs` | `CLAUDE.md` and Copilot point to `AGENTS.md`; agent pages link only to files that exist; every `FRICTION.md` row says what catches it |
| `async_locale_test.exs` | no page starts work through Phoenix's own `start_async`/`assign_async` |
| `refusal_messages_test.exs` | every refusal a person reads is a translated message |
| `record_labels_gettext_test.exs` | every record label is in the gettext templates |
| `permission_names_test.exs` | permission names stay what the admin shows |
| `content_editor_engine_test.exs` | every TipTap package resolves to one version |

## Seeing the real state

- `mix cms.state <resource> <id> [--site <site_id>]`: one record and the records it belongs to, as
  text. It proves the data, not that a page shows it.
- A browser run proves the page: read its text and the server log, not only a screenshot.
