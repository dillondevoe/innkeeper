# Innkeeper

> Crash-safe, cost-capped, gated execution for coding agents, in plain files.

**Status: alpha. Working prototype, not a product.** Innkeeper is an independent project, not
affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic;
they are used here only to describe what the tool runs.

## Read this before running anything live

**Default to an Anthropic API key (Claude Console billing) for automation.** The live run
(`bin/live-party.sh`) shells out to the `claude` CLI in headless mode, and a party runs several
sessions. Anthropic's Consumer Terms (https://www.anthropic.com/legal/consumer-terms, section 3,
effective October 8, 2025) prohibit accessing the Services "through automated or non-human means,
whether through a bot, script, or otherwise" except "when you are accessing our Services via an
Anthropic API Key or where we otherwise explicitly permit it". Anthropic's Claude Code legal page
(https://code.claude.com/docs/en/legal-and-compliance) says "Advertised usage limits for Pro and
Max plans assume ordinary, individual usage of Claude Code and the Agent SDK", and that developers
building products "should use API key authentication". Running several concurrent sessions on a
personal subscription may exceed "ordinary, individual usage"; this README does not decide that
for you. Quotes are as fetched on 2026-10-04 and the terms change, so read the current pages
(https://www.anthropic.com/legal) yourself. This is not legal advice.

Innkeeper never reads, stores or forwards credentials; it runs the unmodified `claude` binary
with whatever login or environment you already have.

## What works, what is a toy

Works, and is checked by the test suite:

- `bin/hello-party.sh`: an end-to-end scripted run that finishes in about a second with no model,
  no network, and nothing written outside a temporary sandbox. Verified by running it: exit 0.
- `bin/murder-quest.sh`: two workers are really `kill -9`'d mid-quest and each quest still merges
  exactly once. Self-asserting; exits non-zero if the world does not match. Verified: exit 0.
- A file-based bus, quests as YAML ([SCHEMA.md](SCHEMA.md)), a lease, a deterministic script gate,
  an exactly-once merge, and a refuse-by-default spend gate for live runs
  (`bin/live-preflight.sh` exits 1 unless `INNKEEPER_LIVE` is exactly `1` and the other
  conditions are met; it spends nothing).
- 20 test batteries behind one verdict: `bash tests/run-all.sh`.

A toy or unfinished:

- There is exactly one quest: add `--version` to a small toy tool. The scripted run uses scripts
  in place of models, so it proves the plumbing, not model quality. Only a single live run is
  recorded.
- The roster in `party.yaml` is flat; the "class" names (cleric, squire...) and per-seat model
  names are labels that nothing consumes. Only the `claude` CLI is wired as a backend.
- No installer, no release tag, no CI config yet.
- The test batteries share repo-level `state/`, so they cannot run in parallel (see below).
- Not built: replay, the tavern view, the lease's second half.
- The live worker is granted `--permission-mode acceptEdits` with tools `Read,Edit,Write,Glob,Grep`
  (no Bash). A hostile prompt could still modify files in the working directory it is given. Do
  not widen this to skip permissions.

## Requirements

`bash`, `git`, `python3`, `jq`, `gitleaks` (the port-gate battery reports CANNOT-RUN without it,
and a CANNOT-RUN fails the suite), `tmux` (real runs of `lifecycle/recycle.sh`; the tests stub
it), and the `claude` CLI (live runs only; the demos and tests never call it). Install `claude`
yourself; do not vendor or redistribute it.

## Watch a quest finish

```sh
git clone https://github.com/dillondevoe/innkeeper && cd innkeeper
bin/hello-party.sh
```

A party of four takes one job and finishes it, in a sandbox, in about a second: a quest is
posted; a worker claims it under a lease (a second instance of that worker stands down); a
researcher reads the tool and briefs the worker; the worker adds a `--version` flag to a
real tool in a real git repo; **the gate refuses it** — the flag exits 0 and prints nothing
— the worker reads the refusal and fixes it; the gate passes; the result merges exactly
once, and a second merge is refused; the voice tells you what happened.

No model is called, nothing leaves the machine, nothing outside the sandbox is written, and
the sandbox is removed on exit (`--keep` to inspect it). The refusal is not decoration: with
the worker's first attempt made correct, the run FAILS rather than passing quietly, and
`tests/bin-hello-party-selftest.sh` asserts exactly that.

```sh
bin/smoke.sh
```

is the older, smaller thing: four brains boot, each writes one line to the bus, and the
herald prints them in roster order. Nothing is worked on, refused or merged — it is the
WIRING proof, and it stays because every hop in it is the real script (the roster from
`bus/actor.sh`, the quest record from `bus/quest.sh`, dispatch from `bus/enqueue.sh`,
delivery from `staff/inbound.sh`), so when it breaks, something real broke.

Record shapes are in [SCHEMA.md](SCHEMA.md). Every script here is paired with a battery
under `tests/`. Run them all, and get one verdict with an exit code:

    bash tests/run-all.sh

It prints GREEN / RED / CANNOT-RUN per battery, shows the failing arms inline, and fails if
the number of batteries is not the number it expects — a suite that finds its own members by
glob is all green the moment a file goes missing. (The runner's own battery matches that glob
and would recurse, so run it directly: `bash tests/run-all-selftest.sh`.)

The port gate's battery needs [gitleaks](https://github.com/gitleaks/gitleaks) on `PATH`, or
`INNKEEPER_GITLEAKS` pointing at it. Without it that battery reports CANNOT-RUN with the reason
rather than a verdict, because every one of its arms asserts a real scan result. **A CANNOT-RUN
fails the suite** (`run-all.sh` exits non-zero), the same as a RED: a battery that could not run
is not a battery that passed, and the fresh-clone default on a machine without gitleaks is
therefore rc=1 until you install it.

**Run the suite once at a time.** Two concurrent `run-all.sh` runs produce reds that neither
run produces alone: measured on one host, `bin-murder-quest`, `bus-merge` and
`bin-hello-party` each went red in 3 of 6 paired runs, while `bin-murder-quest` alone was
20/20 green and 12/12 green against a second copy of itself. The batteries share
repo-level state (`state/`), so a second suite is not another observer — it is another
writer. Isolating them is open work; until then a red from a machine running two suites at
once is a fact about the machine.

One battery is not a battery at all: `tests/portability-selftest.sh` greps the shell sources
for GNU-only constructs (`tac`, `sed -i`, `$BASHPID`, BRE `\|`, `grep -P`, `readlink -f`,
`date -d`). It exists because this repo was 15/15 green on Linux and 9/15 with a visibly
broken demo on macOS on the same commit — the batteries catch these faithfully, but only on
a machine that has the BSD tools, which the author's machine is not.

## Then kill a worker

```sh
bin/murder-quest.sh
```

Two workers are really `kill -9`'d mid-quest — one before it commits its work, one *after*
committing but before it could tell anyone. Both quests land exactly once: the first is redone
by whoever takes over, and the second is not redone at all, because the finished result is
already there and the takeover is told so. The script asserts all of that and exits non-zero if
the world does not match, so it cannot pass by printing.

Still under construction: replay, the tavern view, and the lease's second half.

MIT. See [LICENSE](LICENSE).
