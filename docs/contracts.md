# Contracts: fixed output shapes

Any agent working here reports in these shapes. "The author" writes; "a separate reviewer" checks.

## Task report (the message that ends a task)

- A title line with ✅ and 3 or 4 lines: what it is, why, where (commit or PR).
- A tree of what changed: added ✚, changed ✎, removed ✖, one short comment each.
- A checks table: each check and its result.
- Decided: choices made without asking, with the reason.
- Your to-do: only what blocks, or a fact only the owner has.
- A stage table (✅ 🔄 ⏳ ❓ ⏸️) only in the message that ends a task.

## Commit

`type(scope): what the code now does`, related files only, staged by path. No step numbers, tool
names or "findings". Push only when the owner says so.

## Pull request

One open PR per repo; each task is a commit in it. Title in commit style. Body:

1. `## 👀 At a glance`: a Mermaid diagram (before and after, or the flow) with emojis.
2. One row per problem: Before / Now / Test it (the fastest check and the expected result).
3. Where it helps, the change shown small: a diff sketch or a tree with one line each.
4. One checks line, then `Fixes #N` or `Part of #N`.

Only the owner merges.

## Issue

Title `<Area>: <what a person can do when it is done>`. Body: `Part of #N`, the goal in one or two
lines, steps as checkboxes, and `Done when` checkboxes (each a test, a log line or a picture). A
library bug: example code in a fenced block, the workaround used today, one `Done when` line.

## Handoff

`docs/handoffs/YYYY-MM-DD-<task-slug>.md`, written with the `writing-for-agents` skill:

- Done: commits and PRs.
- Checks: each one with its result.
- Guessed: links to the `FRICTION.md` rows.
- Next.
- Questions for the owner.
