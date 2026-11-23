# Processes

## One process is one queue

Every `GenServer.call/3` waits in that process's mailbox behind every other caller. A process that each request, render or job calls is a bottleneck under load, and its timeout becomes the app's timeout.

- Read shared data where the caller runs: ETS with `read_concurrency: true`, `:persistent_term` for data that rarely changes, or a module compiled at runtime (as mishka_installer compiles each event).
- Let the process own writes and lifecycle only. Callers read without asking it.
- Send work that the caller does not wait for with `cast`, a `Task` under a `Task.Supervisor`, or an Oban/AshOban job.

## Deadlocks

- A process that calls itself, or two processes that call each other, wait on each other until the timeout. Never call another server from inside `handle_call` when that server may call back.
- Do slow work (HTTP, a database transaction, a file) outside the callback: hand it to a task and reply later with `GenServer.reply/2`, or do it in the caller.
- `handle_continue` is for a process's own setup after `init`; a sync call after it is a test barrier, never a sleep.

## Anti-patterns to check

- Elixir: <https://hexdocs.pm/elixir/process-anti-patterns.html>, code, design and macro anti-patterns.
- OTP design principles: supervision trees, `:transient` vs `:permanent`, `restart` budgets.
- Ash: work goes through actions, changes and notifiers inside the transaction; no `GenServer` around a resource.

## Tests

- Never wait with `Process.sleep` or a bigger timeout. Wait on a reply, a `:DOWN` monitor message, or a telemetry event the code sends.
- If the code gives no signal to wait on, add one (a telemetry event or a returned value). That is a design fix, not a test trick.
