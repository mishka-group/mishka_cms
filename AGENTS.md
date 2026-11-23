# Mishka CMS host: agent rules

The Phoenix app that runs Mishka CMS. It installs `mishka_cms_core`, `mishka_cms_builder`,
`mishka_blog`, `mishka_document` and the sign-in extensions from Hex. For local work they are linked
in `__extensions/` (`mishka_dep` in `mix.exs` takes the folder when it is there).

## Read first

- `.claude/skills/mishka-code-design/`: how Mishka code is written. Follow it for every change.
- `.claude/skills/mishka-release/` (the release waves) and `.claude/skills/mishka-ci/`.
- `docs/INDEX.md`: the handbook (contracts, guardrails), `GLOSSARY.md`, `docs/adr/`, and the newest
  file in `docs/handoffs/`.
- UI kit components come from Mishka Chelekom: read its usage rules
  (https://github.com/mishka-group/mishka_chelekom/blob/master/usage-rules.md) before touching a kit.

## Layout

| Path | Holds |
|---|---|
| `lib/mishka_cms_web/` | endpoint, router, `controllers/error_html.ex`, layouts |
| `config/` | the extensions the host loads, Oban queues, the security headers |
| `assets/` | a bun project: TipTap, CodeMirror, vitest |
| `test/mishka_cms/` | project checks: rules across packages, and the agent files' own test |
| `lib/mix/tasks/cms.state.ex` | `mix cms.state`: a record as plain text |
| `.githooks/` | the commit hook |
| `.claude/skills/` | Mishka skills (code design, CI, release) and Matt Pocock's engineering skills (MIT) |

## Run it

- The gate: `MISHKA_DEPS=hex mix ci`. Every step but `test` passes before a push; CI's lint stops at
  its first failure.
- Once per clone: `mix hooks` (format and credo on staged files before each commit).
- The state of a record, as text: `mix cms.state <resource> <id> [--site <site_id>]`.
- Local extensions: link them in `__extensions/`. Local config, `mishka_data/` and local `mix.exs`
  lines are never committed.

## Dependencies' usage rules

Before using a library, read its usage rules: the links at the end of this file, written by
`mix usage_rules.sync` from every dependency that ships them (Ash and its extensions, Phoenix,
mishka_gervaz, guarded_struct, Elixir, OTP). Search their docs with `mix usage_rules.search_docs
<query> -p <package>`. After adding or updating a dependency, run `mix usage_rules.sync --yes` and
commit the new links. `usage_rules` is a dev-only dependency at its newest release; a Mishka project
without it should add `{:usage_rules, "~> <newest>", only: [:dev]}` and a `usage_rules:` entry in
`project/0` (see this repo's `mix.exs`), then sync.

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

1. **Think before coding**: state your assumptions; when a request can be read more than one way,
   ask instead of guessing; push back with reasons.
2. **Simplicity first**: no unrequested features, abstractions or configurability; if 200 lines could
   be 50, rewrite. Never cut validation, security or error handling to get there.
3. **Reuse before you write**: Ash, mishka_installer events, mishka_gervaz, guarded_struct, and
   `Phoenix.LiveView.JS` before a JS hook.
4. **Performance and safety first**: no `rescue`, `try` or `catch` on a path many users hit unless
   nothing else works; count the queries a change adds.
5. **Local-only stays local**: an extension linked for development, and its config lines, are never
   committed to `mix.exs`, `mix.lock` or `config/`.
6. **Newest versions**: every dependency at its newest release; JS through bun; every TipTap package
   on one version.
7. **No private repository names** in this public repo.

## Planning

The plan is issues in the repository the work changes: a plan issue with sub-issues, research as
comments. Read the open issues before starting, and name them in commits and PRs (`Fixes #N`,
`Part of #N`). Release planning lives in `.claude/skills/mishka-release/`.

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

The exact shapes are in `docs/contracts.md`.


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

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

[ash usage rules](deps/ash/usage-rules.md)
<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
[ash:actions usage rules](deps/ash/usage-rules/actions.md)
<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
[ash:aggregates usage rules](deps/ash/usage-rules/aggregates.md)
<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
[ash:authorization usage rules](deps/ash/usage-rules/authorization.md)
<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
[ash:calculations usage rules](deps/ash/usage-rules/calculations.md)
<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
[ash:code_interfaces usage rules](deps/ash/usage-rules/code_interfaces.md)
<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
[ash:code_structure usage rules](deps/ash/usage-rules/code_structure.md)
<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
[ash:data_layers usage rules](deps/ash/usage-rules/data_layers.md)
<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
[ash:exist_expressions usage rules](deps/ash/usage-rules/exist_expressions.md)
<!-- ash:exist_expressions-end -->
<!-- ash:generating_code-start -->
## ash:generating_code usage
[ash:generating_code usage rules](deps/ash/usage-rules/generating_code.md)
<!-- ash:generating_code-end -->
<!-- ash:migrations-start -->
## ash:migrations usage
[ash:migrations usage rules](deps/ash/usage-rules/migrations.md)
<!-- ash:migrations-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
[ash:query_filter usage rules](deps/ash/usage-rules/query_filter.md)
<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
[ash:querying_data usage rules](deps/ash/usage-rules/querying_data.md)
<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
[ash:relationships usage rules](deps/ash/usage-rules/relationships.md)
<!-- ash:relationships-end -->
<!-- ash:signals-start -->
## ash:signals usage
[ash:signals usage rules](deps/ash/usage-rules/signals.md)
<!-- ash:signals-end -->
<!-- ash:temporal-start -->
## ash:temporal usage
[ash:temporal usage rules](deps/ash/usage-rules/temporal.md)
<!-- ash:temporal-end -->
<!-- ash:testing-start -->
## ash:testing usage
[ash:testing usage rules](deps/ash/usage-rules/testing.md)
<!-- ash:testing-end -->
<!-- ash_authentication-start -->
## ash_authentication usage
_Authentication extension for the Ash Framework._

[ash_authentication usage rules](deps/ash_authentication/usage-rules.md)
<!-- ash_authentication-end -->
<!-- ash_events-start -->
## ash_events usage
_The extension for tracking changes to your resources via a centralized event log, with replay functionality._

[ash_events usage rules](deps/ash_events/usage-rules.md)
<!-- ash_events-end -->
<!-- ash_graphql-start -->
## ash_graphql usage
_The extension for building GraphQL APIs with Ash_

[ash_graphql usage rules](deps/ash_graphql/usage-rules.md)
<!-- ash_graphql-end -->
<!-- ash_graphql:custom_types-start -->
## ash_graphql:custom_types usage
[ash_graphql:custom_types usage rules](deps/ash_graphql/usage-rules/custom_types.md)
<!-- ash_graphql:custom_types-end -->
<!-- ash_graphql:domain_configuration-start -->
## ash_graphql:domain_configuration usage
[ash_graphql:domain_configuration usage rules](deps/ash_graphql/usage-rules/domain_configuration.md)
<!-- ash_graphql:domain_configuration-end -->
<!-- ash_graphql:resource_configuration-start -->
## ash_graphql:resource_configuration usage
[ash_graphql:resource_configuration usage rules](deps/ash_graphql/usage-rules/resource_configuration.md)
<!-- ash_graphql:resource_configuration-end -->
<!-- ash_json_api-start -->
## ash_json_api usage
_The JSON:API extension for the Ash Framework._

[ash_json_api usage rules](deps/ash_json_api/usage-rules.md)
<!-- ash_json_api-end -->
<!-- ash_oban-start -->
## ash_oban usage
_The extension for integrating Ash resources with Oban._

[ash_oban usage rules](deps/ash_oban/usage-rules.md)
<!-- ash_oban-end -->
<!-- ash_oban:best_practices-start -->
## ash_oban:best_practices usage
[ash_oban:best_practices usage rules](deps/ash_oban/usage-rules/best_practices.md)
<!-- ash_oban:best_practices-end -->
<!-- ash_oban:debugging_and_error_handling-start -->
## ash_oban:debugging_and_error_handling usage
[ash_oban:debugging_and_error_handling usage rules](deps/ash_oban/usage-rules/debugging_and_error_handling.md)
<!-- ash_oban:debugging_and_error_handling-end -->
<!-- ash_oban:defining_triggers-start -->
## ash_oban:defining_triggers usage
[ash_oban:defining_triggers usage rules](deps/ash_oban/usage-rules/defining_triggers.md)
<!-- ash_oban:defining_triggers-end -->
<!-- ash_oban:multi_tenancy_support-start -->
## ash_oban:multi_tenancy_support usage
[ash_oban:multi_tenancy_support usage rules](deps/ash_oban/usage-rules/multi_tenancy_support.md)
<!-- ash_oban:multi_tenancy_support-end -->
<!-- ash_oban:scheduled_actions-start -->
## ash_oban:scheduled_actions usage
[ash_oban:scheduled_actions usage rules](deps/ash_oban/usage-rules/scheduled_actions.md)
<!-- ash_oban:scheduled_actions-end -->
<!-- ash_oban:setting_up_ash_oban-start -->
## ash_oban:setting_up_ash_oban usage
[ash_oban:setting_up_ash_oban usage rules](deps/ash_oban/usage-rules/setting_up_ash_oban.md)
<!-- ash_oban:setting_up_ash_oban-end -->
<!-- ash_oban:triggering_jobs_programmatically-start -->
## ash_oban:triggering_jobs_programmatically usage
[ash_oban:triggering_jobs_programmatically usage rules](deps/ash_oban/usage-rules/triggering_jobs_programmatically.md)
<!-- ash_oban:triggering_jobs_programmatically-end -->
<!-- ash_oban:working_with_actors-start -->
## ash_oban:working_with_actors usage
[ash_oban:working_with_actors usage rules](deps/ash_oban/usage-rules/working_with_actors.md)
<!-- ash_oban:working_with_actors-end -->
<!-- ash_phoenix-start -->
## ash_phoenix usage
_Utilities for integrating Ash and Phoenix_

[ash_phoenix usage rules](deps/ash_phoenix/usage-rules.md)
<!-- ash_phoenix-end -->
<!-- ash_phoenix:best_practices-start -->
## ash_phoenix:best_practices usage
[ash_phoenix:best_practices usage rules](deps/ash_phoenix/usage-rules/best_practices.md)
<!-- ash_phoenix:best_practices-end -->
<!-- ash_phoenix:debugging_form_submissions-start -->
## ash_phoenix:debugging_form_submissions usage
[ash_phoenix:debugging_form_submissions usage rules](deps/ash_phoenix/usage-rules/debugging_form_submissions.md)
<!-- ash_phoenix:debugging_form_submissions-end -->
<!-- ash_phoenix:error_handling-start -->
## ash_phoenix:error_handling usage
[ash_phoenix:error_handling usage rules](deps/ash_phoenix/usage-rules/error_handling.md)
<!-- ash_phoenix:error_handling-end -->
<!-- ash_phoenix:form_integration-start -->
## ash_phoenix:form_integration usage
[ash_phoenix:form_integration usage rules](deps/ash_phoenix/usage-rules/form_integration.md)
<!-- ash_phoenix:form_integration-end -->
<!-- ash_phoenix:nested_forms-start -->
## ash_phoenix:nested_forms usage
[ash_phoenix:nested_forms usage rules](deps/ash_phoenix/usage-rules/nested_forms.md)
<!-- ash_phoenix:nested_forms-end -->
<!-- ash_phoenix:union_forms-start -->
## ash_phoenix:union_forms usage
[ash_phoenix:union_forms usage rules](deps/ash_phoenix/usage-rules/union_forms.md)
<!-- ash_phoenix:union_forms-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

[ash_postgres usage rules](deps/ash_postgres/usage-rules.md)
<!-- ash_postgres-end -->
<!-- ash_postgres:advanced_features-start -->
## ash_postgres:advanced_features usage
[ash_postgres:advanced_features usage rules](deps/ash_postgres/usage-rules/advanced_features.md)
<!-- ash_postgres:advanced_features-end -->
<!-- ash_postgres:best_practices-start -->
## ash_postgres:best_practices usage
[ash_postgres:best_practices usage rules](deps/ash_postgres/usage-rules/best_practices.md)
<!-- ash_postgres:best_practices-end -->
<!-- ash_postgres:check_constraints-start -->
## ash_postgres:check_constraints usage
[ash_postgres:check_constraints usage rules](deps/ash_postgres/usage-rules/check_constraints.md)
<!-- ash_postgres:check_constraints-end -->
<!-- ash_postgres:configuration-start -->
## ash_postgres:configuration usage
[ash_postgres:configuration usage rules](deps/ash_postgres/usage-rules/configuration.md)
<!-- ash_postgres:configuration-end -->
<!-- ash_postgres:custom_indexes-start -->
## ash_postgres:custom_indexes usage
[ash_postgres:custom_indexes usage rules](deps/ash_postgres/usage-rules/custom_indexes.md)
<!-- ash_postgres:custom_indexes-end -->
<!-- ash_postgres:custom_sql_statements-start -->
## ash_postgres:custom_sql_statements usage
[ash_postgres:custom_sql_statements usage rules](deps/ash_postgres/usage-rules/custom_sql_statements.md)
<!-- ash_postgres:custom_sql_statements-end -->
<!-- ash_postgres:foreign_keys-start -->
## ash_postgres:foreign_keys usage
[ash_postgres:foreign_keys usage rules](deps/ash_postgres/usage-rules/foreign_keys.md)
<!-- ash_postgres:foreign_keys-end -->
<!-- ash_postgres:migrations-start -->
## ash_postgres:migrations usage
[ash_postgres:migrations usage rules](deps/ash_postgres/usage-rules/migrations.md)
<!-- ash_postgres:migrations-end -->
<!-- ash_postgres:multitenancy-start -->
## ash_postgres:multitenancy usage
[ash_postgres:multitenancy usage rules](deps/ash_postgres/usage-rules/multitenancy.md)
<!-- ash_postgres:multitenancy-end -->
<!-- guarded_struct-start -->
## guarded_struct usage
_Build Elixir structs with validation, sanitization, nested sub-structs, conditional fields, pattern-keyed maps, and an Ash extension. Built on Spark._

[guarded_struct usage rules](deps/guarded_struct/usage-rules.md)
<!-- guarded_struct-end -->
<!-- guarded_struct:api-start -->
## guarded_struct:api usage
[guarded_struct:api usage rules](deps/guarded_struct/usage-rules/api.md)
<!-- guarded_struct:api-end -->
<!-- guarded_struct:ash-start -->
## guarded_struct:ash usage
[guarded_struct:ash usage rules](deps/guarded_struct/usage-rules/ash.md)
<!-- guarded_struct:ash-end -->
<!-- guarded_struct:conditional-start -->
## guarded_struct:conditional usage
[guarded_struct:conditional usage rules](deps/guarded_struct/usage-rules/conditional.md)
<!-- guarded_struct:conditional-end -->
<!-- guarded_struct:core-keys-start -->
## guarded_struct:core-keys usage
[guarded_struct:core-keys usage rules](deps/guarded_struct/usage-rules/core-keys.md)
<!-- guarded_struct:core-keys-end -->
<!-- guarded_struct:derive-start -->
## guarded_struct:derive usage
[guarded_struct:derive usage rules](deps/guarded_struct/usage-rules/derive.md)
<!-- guarded_struct:derive-end -->
<!-- guarded_struct:dsl-start -->
## guarded_struct:dsl usage
[guarded_struct:dsl usage rules](deps/guarded_struct/usage-rules/dsl.md)
<!-- guarded_struct:dsl-end -->
<!-- guarded_struct:errors-start -->
## guarded_struct:errors usage
[guarded_struct:errors usage rules](deps/guarded_struct/usage-rules/errors.md)
<!-- guarded_struct:errors-end -->
<!-- guarded_struct:extensions-start -->
## guarded_struct:extensions usage
[guarded_struct:extensions usage rules](deps/guarded_struct/usage-rules/extensions.md)
<!-- guarded_struct:extensions-end -->
<!-- guarded_struct:validators-start -->
## guarded_struct:validators usage
[guarded_struct:validators usage rules](deps/guarded_struct/usage-rules/validators.md)
<!-- guarded_struct:validators-end -->
<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

[igniter usage rules](deps/igniter/usage-rules.md)
<!-- igniter-end -->
<!-- mishka_gervaz-start -->
## mishka_gervaz usage
_Mishka Gervaz is a comprehensive, declarative UI library for the Ash ecosystem — define tables, forms, and data-driven interfaces entirely through DSL, with built-in sorting, filtering, real-time updates, and extensible templates._

[mishka_gervaz usage rules](deps/mishka_gervaz/usage-rules.md)
<!-- mishka_gervaz-end -->
<!-- mishka_gervaz:customization-start -->
## mishka_gervaz:customization usage
[mishka_gervaz:customization usage rules](deps/mishka_gervaz/usage-rules/customization.md)
<!-- mishka_gervaz:customization-end -->
<!-- mishka_gervaz:form-start -->
## mishka_gervaz:form usage
[mishka_gervaz:form usage rules](deps/mishka_gervaz/usage-rules/form.md)
<!-- mishka_gervaz:form-end -->
<!-- mishka_gervaz:mounting-start -->
## mishka_gervaz:mounting usage
[mishka_gervaz:mounting usage rules](deps/mishka_gervaz/usage-rules/mounting.md)
<!-- mishka_gervaz:mounting-end -->
<!-- mishka_gervaz:table-start -->
## mishka_gervaz:table usage
[mishka_gervaz:table usage rules](deps/mishka_gervaz/usage-rules/table.md)
<!-- mishka_gervaz:table-end -->
<!-- mishka_gervaz:troubleshooting-start -->
## mishka_gervaz:troubleshooting usage
[mishka_gervaz:troubleshooting usage rules](deps/mishka_gervaz/usage-rules/troubleshooting.md)
<!-- mishka_gervaz:troubleshooting-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
[phoenix:ecto usage rules](deps/phoenix/usage-rules/ecto.md)
<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
[phoenix:elixir usage rules](deps/phoenix/usage-rules/elixir.md)
<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
[phoenix:html usage rules](deps/phoenix/usage-rules/html.md)
<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
[phoenix:liveview usage rules](deps/phoenix/usage-rules/liveview.md)
<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
[phoenix:phoenix usage rules](deps/phoenix/usage-rules/phoenix.md)
<!-- phoenix:phoenix-end -->
<!-- sobelow-start -->
## sobelow usage
_Security-focused static analysis for Elixir & the Phoenix framework_

[sobelow usage rules](deps/sobelow/usage-rules.md)
<!-- sobelow-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
