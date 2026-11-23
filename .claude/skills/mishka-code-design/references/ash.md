# Ash in Mishka

Ash first: if Ash, AshPostgres, AshOban, Spark or Ash Signals already does a thing, use it. Read the guide in `deps/<pkg>/documentation` before using a feature you haven't used here. Copy the shape from the closest resource in mishka_cms_core or mishka_blog.

## Resources

- **Tenancy:** attribute multi-tenancy on `site_id` (`global? false`). A tenant create sets `site_id` from the tenant. See `mishka_cms_core/lib/mishka_cms_core/runtime/resources/redirect.ex` for the pattern.
- **Policies:**
  - `MishkaCmsCore.Accounts.Checks.AccessPermissions` with permission names `admin:dashboard:<area>` and `admin:api:<area>`.
  - Then `site_id == actor(:site_id)`, or the actor is a master.
  - `access_type :strict` where a refused read should error.
  - The extension's provisioning creates the permission names on install (core `Install.Bootstrap.ensure_permissions/1`, as `ExtensionProvision` does).
- **System actions:** actions only the system runs, such as a job's own steps, refuse every actor.
  - A job reaches them through AshOban's bypass (`AshOban.Checks.AshObanInteraction`).
  - `authorize?: false` is a documented exception for a true system lookup only, for example loading the actor before one exists. Say why in the `@moduledoc`.
- **Code interfaces live on the domain.** Callers use them, never `Ash.Changeset` plumbing scattered around.
- **Identities** enforce uniqueness in the database, partial ones too: `identity :one_active_per_site, [:site_id], where: expr(status in [:running])`. That beats checking in code or relying on job uniqueness.
- **State lifecycles are actions,** e.g. `:start`, `:finish`, `:fail`, `:cancel`, guarded by a validation on the status they move from.
- **Writes that belong together go in one transaction** (`Ash.transact/3`). Never write and then record separately.
- **Sensitive data:**
  - Mark it `sensitive?: true`, keep it private, and seal secrets with `Phoenix.Token.encrypt` the way core's `Settings` seals a `:secret` setting.
  - Clear it when it is no longer needed.
  - A `pub_sub` notifier `transform` strips it from broadcasts.
- **Timestamps:** `create_timestamp` / `update_timestamp`. A resource whose edits must be detected relies on `update_timestamp`, which is maintained by Ash and not writable.
- **Extra data:** `attribute :extra, :map` (core's name) holds key/value data the resource has no column for.
- **Migrations** come from `mix ash.codegen`. Check whether the repo commits or gitignores them, and follow it.

## guarded_struct inside the resource

From `mishka_cms_migration/lib/mishka_cms_migration/resources/migration_run.ex`:

```elixir
guardedstruct do
  auto_wire true

  field :source, :string,
    derives: "sanitize(trim, downcase) validate(string, not_empty, max_len=64)"

  sub_field :options, :map, authorized_fields: true do
    field :pages, :string,
      default: "draft",
      derives: "sanitize(trim) validate(enum=String[draft::publish])"

    field :comments, :boolean, default: false, derives: "validate(boolean)"
  end
end
```

`auto_wire` checks the action's input. A bad nested value comes back as an `Ash.Error.Invalid` with an `InvalidAttribute` at its field and path, and sub_field defaults are filled. Don't add a separate options module or a change to build the struct.

## Jobs: AshOban

Use AshOban triggers when they cover the needs:

- **Running the job:** `trigger :name` calls an Ash update action, with `transaction? false` for long work. `where expr(status == :running)` makes a cancelled or finished record skip its queued job.
- **Queueing:** `scheduler_cron false`, and queue from the starting action with `AshOban.run_trigger/3` in an `after_action`.
- **Failure and limits:** `max_attempts`, `backoff`, `timeout`, and `on_error :fail` (an update action that records the reason).
- **The actor:** an `AshOban.ActorPersister` stores and loads it, so the job writes as the user who started it.
- **A job killed at its timeout** can't run `on_error`. Catch that with a small Oban telemetry handler on `[:oban, :job, :exception]` with `state: :discard`.
- **Tests:** `use AshOban.Test`, `assert_triggered` and `perform_job`.

Fall back to plain Oban only for a part AshOban can't do, and say which.

## Signals

Ash 3.36 and later: `emit` on an action, `signals_in` on a listener. Use them when one of our resources must react to another's action inside the same transaction, and only where they replace hand-written code. Extension points for other extensions stay mishka_installer events, not signals.

## Progress and live updates

Save progress through an Ash action. The resource's `pub_sub` notifier broadcasts it, with sensitive fields stripped, and the LiveView subscribes to that topic. Don't add a hand-rolled PubSub module.

## Errors

Turn Ash errors into short, human messages, `field: message`, through `MishkaGervaz.Errors.translate_error/2`. Store only that message on a record a user will see, and keep the full error in the log.

## Anti-patterns to avoid

- Writing through `Repo` around an Ash action.
- `authorize?: false` to dodge a policy.
- Read-then-write without a transaction or an identity.
- Re-implementing what an Ash type, change, validation or extension already provides.
- Uniqueness or state checks in code that the database could enforce.
