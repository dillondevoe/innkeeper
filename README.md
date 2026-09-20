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
under `tests/`; run them all with `for t in tests/*-selftest.sh; do bash "$t"; done`.

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
