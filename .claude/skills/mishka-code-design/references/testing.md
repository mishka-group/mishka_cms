# Testing

Copy the repo's test support (`DataCase`, factories, test plugins) and the style of its nearest test file.

## What a test proves

A test checks behaviour: what the code does for a user or a caller.

- A dry run writes nothing.
- A re-run updates and doesn't duplicate.
- A record edited by a person is kept.
- Site B can't see site A's records.
- A user without the permission is refused.
- An event fires with its documented payload.
- A failure is recorded with a reason.

Assert on outcomes and meaning: status, counts, which records exist, error type and field. Don't assert on exact strings, full markup or the order of unrelated output. A loose match (`=~ "already redirects"`) is enough where wording may change.

## Waiting without timeouts

Never use `Process.sleep`, retry or poll loops, "eventually" helpers, or a bigger `assert_receive` timeout. Make the test wait on the real event:

- **A process that sets up in `handle_continue`:** call it once with any sync call. The reply comes after `handle_continue` has run. For example, call the Oban producer before sending it signals.
- **A process that must be done:** `Process.monitor` with `assert_receive {:DOWN, …}`, or `:sys.get_state/1` as a barrier.
- **Asynchronous work that announces itself:** wait for the message or telemetry event it sends. If it sends none and a test needs it, add a telemetry event to the library code.
- **A limit or a delay** (a timeout, a retry wait): never let the test sit through it. Give the code a value of 0 (or the smallest) and assert on the telemetry event that reports the decision, such as the `:wait` it chose or the `:outcome` it ended with. See `references/telemetry.md`.
- **Jobs:** Oban `testing: :manual`, then `perform_job`, `Oban.drain_queue`, or AshOban's `assert_triggered`.
- **Plugins:** core's `Test.Installer.await/1` and the repo's `register_plugin!` helpers.

A flaky test gets a deterministic fix, and sometimes the race is in the library code. Prove it with `mix test <file> --repeat-until-failure 300`. To flush out races, also run it under load (`ELIXIR_ERL_OPTIONS="+S 2:2"` plus CPU load).

## External systems

Test against the real thing: for example a real WordPress in Docker, seeded with realistic data. Unit tests replay responses recorded from it, and integration tests tagged for the live service are excluded by default. Never hand-write mock JSON that the real system wouldn't send. Scrub secrets from recordings.

## Running

- While working, run only the tests of the files you changed.
- Run the full gate once at the end: the repo's CI alias (`mix ci` where it exists) and, for an Ash repo, a fresh `MIX_ENV=test mix ash.codegen setup && mix test`, then a few random seeds.
- Where GitHub Actions is off for a repo, this local gate is the check.
- Check background test runs for hangs, and use `/bin/rm`, `/bin/cp` and `/bin/ls`, because the shell aliases prompt and hang.

## The final check

When a task is done, a separate check tests it twice over:

- **as a developer:** the gate, reading the docs, probing edge cases;
- **as an end user:** in the admin UI through the browser, where there is UI.

Only then report it as ready.
