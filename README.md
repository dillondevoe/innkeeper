# Innkeeper

> Turn your laptop into a tavern for Claude Code agents. Give the party a quest, watch it ship, and make camp.

## Watch a quest finish

```sh
git clone <this repo> && cd innkeeper
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
therefore 16/17 and rc=1 until you install it.

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

MIT.
