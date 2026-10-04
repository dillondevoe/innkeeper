# Limits and spend

This page states only what the code does and what the tests check, with the conditions. Anything
not listed here is not promised.

## Hard spend ceiling

Where: `bin/live-preflight.sh` resolves the ceiling; `roles/claude-call.sh` enforces it.
Tests: `tests/live-roles-selftest.sh` (arms C1, C1b, C9, C9b, C9c, C10) and
`tests/bin-live-preflight-selftest.sh`.

What is guaranteed: **no model call STARTS once the ledger total has reached the ceiling.**
The call is refused by name and the CLI is not run.

The guarantee holds only under these conditions:

1. The call goes through `claude_call` in `roles/claude-call.sh`. That is the one place the
   `claude` CLI is invoked by this repo. Running `claude` yourself is not governed.
2. `INNKEEPER_LIVE` is exactly `1`. Anything else is refused at the spend site (C1).
3. `INNKEEPER_LEDGER` is set to a file whose directory exists and is writable. Unset or
   unwritable means refusal before anything is spent (C10, C10b).
4. The ceiling is `INNKEEPER_LIVE_MAX_USD`, a plain decimal; default `3.00` when unset. Set to a
   non-number or to empty, it refuses rather than falling back to the default.
5. Cost is whatever the CLI reports as `total_cost_usd` for each call. If a call reports none,
   the ledger records `UNKNOWN` and every later call is refused, because the total is then only
   a lower bound (C3, C9c).

What is NOT guaranteed:

- **A ceiling is checked between calls, not during one.** A call's cost is only known after it
  returns, so the last admitted call can carry the total past the ceiling. The first recorded
  live run cost $0.9569 over 2 calls. Leave headroom.
- A call that exits non-zero records nothing, and may still have cost money (the code says so).
- Spend through any other path (your own `claude` sessions, other tools) is not counted.
- The ledger is read-and-summed per call with no lock. Concurrent callers sharing one ledger are
  not tested and no guarantee is made for them.
- The preflight cannot check that the CLI is authorised, because that would require a paid call.

Also: live workers run with `--permission-mode acceptEdits`, tools `Read,Edit,Write,Glob,Grep`,
`--add-dir <workdir>` and `--max-turns` (default 12, `INNKEEPER_MAX_TURNS`). That is a grant to
edit files in the working directory, not a sandbox.

## Exactly-once merge under `kill -9`

Where: `bus/merge.sh`. Tests: `bin/murder-quest.sh` (run it directly; also covered by
`tests/bin-murder-quest-selftest.sh`) and `tests/bus-merge-selftest.sh`.

What is demonstrated: two workers are sent a real SIGKILL in a sandbox, one before and one after
committing its result. Each quest ends with one merged result; a takeover's second commit is
refused as `ALREADY-MERGED`, and the bytes on disk are the first worker's.

How it works, and therefore when it holds:

1. The commit is a single `ln` (hard link) of a staged file to `state/merged/<quest>.out`. `ln`
   fails if the destination exists, so test and set are one step.
2. The staged file and the destination must be on the same filesystem (both live under
   `$INNKEEPER_HOME`). Otherwise the commit fails with exit 1 and reports nothing merged.
3. `INNKEEPER_HOME` must be set; the script refuses to guess.
4. The result file must be non-empty. A partial or empty file is refused.
5. The `.by` attribution file is written after the link and is attribution only. A kill between
   the two leaves `MERGED by=unknown`; the merge itself still counts once.

What is NOT claimed:

- Only the merge point is exactly-once. A killed worker's *work* may be redone by its successor;
  the guarantee is that the redone result is not merged a second time.
- Tested kills are SIGKILL of a process on one machine. Power loss, filesystem crashes, network
  filesystems and clock behaviour across suspend are not covered by these guarantees.
- The demo shortens the lease (`LEASE_TTL=2`) to show a dead holder going stale quickly.
