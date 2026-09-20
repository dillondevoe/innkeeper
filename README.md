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

Still under construction: replay, the tavern view, and the lease's second half.

MIT.
