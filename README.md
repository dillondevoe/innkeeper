# Innkeeper

> Turn your laptop into a tavern for Claude Code agents. Give the party a quest, watch it ship, and make camp.

## Run the first quest

```sh
git clone <this repo> && cd innkeeper
bin/hello-party.sh
```

Four brains boot, each writes one line to the bus, and the herald prints them in roster
order. No model is called, nothing leaves the machine, and the sandbox it builds is
removed on exit (`--keep` to inspect it). Every hop is the real script — the roster from
`bus/actor.sh`, the quest record from `bus/quest.sh`, dispatch from `bus/enqueue.sh`,
delivery from `staff/inbound.sh` — so when the demo works, the wiring works.

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
therefore 15/16 and rc=1 until you install it.

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
