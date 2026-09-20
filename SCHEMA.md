# SCHEMA — the quest record, the bus message, the lease record, the merged result

The four records a party writes to disk. Published **before** the hello-party slice is
finished, so a consumer (a live tavern view, a replay harness) can be built against a
stated shape instead of against a running system.

**These three records are NOT in the same state, and the difference is the most useful
thing on this worker.** The bus message and the lease record are *read off shipped code* —
`bus/enqueue.sh` and `lifecycle/lease.sh` write exactly these bytes today, and the field
lists below were derived from the write sites, not from memory. As of the hello-party slice the quest record is read off
shipped code too: `bus/quest.sh` writes exactly these bytes, and `tests/bus-quest-selftest.sh`
reads the committed `fixtures/quests/first-light.yaml` back through that script's own reader,
so this table and the writer are pinned to each other by a program rather than by memory.
All three are now derived from write sites.

If any of this changes, THIS FILE changes in the same commit as the code, and consumers
are told in one line. A schema that documents an older version of its own writer is worse
than no schema, because it is trusted.

---

## 1. Quest record — SHIPPED (`bus/quest.sh`)

A quest is the unit of work a party is given. One file per quest:

    $BUS/quests/<id>.yaml

| field | type | required | notes |
|---|---|---|---|
| `id` | string, `[a-z0-9-]+` | yes | Stable for the quest's life. Also the filename stem. Never reused. |
| `title` | string, one line | yes | What a tavern view shows in a list. |
| `brief` | string, multi-line | yes | The actual ask. Prose, not a spec. |
| `state` | enum | yes | `open` \| `claimed` \| `blocked` \| `done` \| `abandoned` |
| `lane` | string \| null | yes | Roster `brains[].name` holding it, or `null` when `open`. Checked for MEMBERSHIP against `bus/actor.sh lanes` — not merely passed through `resolve`, which returns an unknown token unchanged and would let an addressee who owns no queue hold a quest forever. |
| `created` | UTC `%Y-%m-%dT%H:%M:%SZ` | yes | Machine-stamped. Never hand-typed. |
| `updated` | UTC, same format | yes | Machine-stamped on every state change. |
| `origin` | string \| null | yes | Basename of the comm that raised it, or `null` if raised directly. |
| `blocked_on` | list of quest `id` | no | Empty/absent means unblocked. |

**`state` is an enum and not a boolean pair**, because `blocked` and `abandoned` are the
two a consumer most wants to render differently and the two a `done: true/false` field
silently collapses into "not done".

**`lane` is nullable and that is deliberate.** An unassigned quest is a real state — the
alternative is a sentinel name that `actor.sh resolve` would try to resolve and, per its
identity rule, hand back unchanged as if it were a brain.

Example — and this exact record is committed as `fixtures/quests/first-light.yaml`:

```yaml
id: first-light
title: Make the hello-party slice print one line from each brain
brief: |
  Four brains boot, each writes one line to the bus, the herald prints them in
  roster order. No model calls. The point is the wiring, not the content.
state: open
lane: null
created: 2026-09-20T14:07:29Z
updated: 2026-09-20T14:07:29Z
origin: gate-to-worker-P2-first-light-2026-01-01.md
blocked_on: []
```

---

## 2. Bus message — SHIPPED (`bus/enqueue.sh` writes this)

A bus message is a **marker**, not a message. It carries no payload:

    $BUS/queues/<lane>/<comm-basename>.job

| part | type | notes |
|---|---|---|
| path segment `<lane>` | roster brain name | The routing. Resolved by `bus/actor.sh targets`, never re-parsed by a consumer. |
| filename stem | the comm's full basename incl. `.md` | e.g. `worker-to-gate-P2-a-question-2026-09-20.md.job` |
| file body | integer, starts `0` | Delivery **attempt counter**. Not a status, not a timestamp. |

**The name is the entire message and the body is the retry state.** A consumer that wants
to know what a marker is *about* reads the comm the name points at; it does not parse the
name. The addressing grammar has exactly one parser (`bus/actor.sh`) and a consumer that
re-implements it is the drift this repo's port notes already record.

Two sibling stores use the **same filename**, and a consumer must not mistake them for the
queue:

| path | meaning |
|---|---|
| `$INNKEEPER_HOME/state/queues/<lane>/delivered/<base>.job` | Already handed to that lane. Suppresses re-queue. |
| `$INNKEEPER_HOME/state/deadletter/<lane>/<base>.job` | Circuit breaker holds it; re-creating the queue marker would reset the attempt counter and turn bounded retry into a loop. |

A marker's presence in `queues/` means *pending*. Absence means nothing on its own — check
the other two before concluding a comm was never routed.

---

## 3. Lease record — SHIPPED (`lifecycle/lease.sh` writes this)

One brain, one lane, one live holder:

    $INNKEEPER_HOME/state/<brain>.lease

A single line, four space-separated fields, written atomically (`mktemp` + `mv -f`):

    <claimed_epoch> <nonce> <boot_epoch> <awake_seconds>

| field | type | notes |
|---|---|---|
| `claimed_epoch` | integer, Unix seconds | Rewritten on every `renew`. Age is `now - claimed_epoch`. |
| `nonce` | uuid (or 16 random bytes hex) | The holder's proof. `renew`/`release` without it return `NOT-HOLDER`. |
| `boot_epoch` | integer, Unix seconds, `0` = unknown | The machine boot the lease was claimed under. |
| `awake_seconds` | integer, or **absent** | A clock that does not advance while the machine is suspended (Linux `/proc/uptime`). **Absent means this host has no awake clock — it does not mean zero.** A lock written by the older three-field code has no fourth field and is read as absent. |

Example:

    1758376324 9f3a1c7e-5b20-4e11-8d6a-77c0e2b41a99 1758298811 99995

**Staleness is decided in two steps, and the order matters.**

1. **A different `boot_epoch` is stale, full stop.** A process cannot hold a lease across a
   reboot, and a TTL alone leaves a dead holder blocking relaunches for its remaining minutes.
   This is decided FIRST because `awake_seconds` restarts at zero on reboot, so a lock from the
   previous boot can show a tiny awake delta and would otherwise read as freshly held — which
   blocks a live lane forever rather than merely stealing one.
2. **Otherwise the lease ages on the awake clock**, when both the host and the lock carry one:
   stale once `awake_seconds` has advanced by `LEASE_TTL` (default 1800s). With no awake clock
   on either side it falls back to wall-clock age, which is the older behaviour.

**Why the awake clock — the laptop-sleep case.** The wall clock keeps running while a machine is
suspended. A laptop that sleeps an hour wakes with every lease older than any TTL worth picking,
so a second instance sees `STALE` and claims a lane whose holder is alive and mid-task — two live
holders, the exact thing the lease exists to prevent. The holder cannot defend itself: it was
frozen, so it could not renew. An awake clock excludes suspend by construction, which makes
"the holder is dead" and "the machine was asleep" two different readings instead of one.

**Direction of failure, chosen deliberately:** this makes leases expire LATER, never earlier.
Holding a dead holder's lane too long blocks a relaunch — visible, and cleared by the boot check
on the next restart. Expiring a LIVE holder's lane hands two workers the same task and corrupts
quietly. When a clock is uncertain, the safe error is to keep the lane held.

Never hand-edit a lease file. Read it with `lease.sh status`, which returns
`FREE` | `HELD age=<s> nonce=<n>` | `STALE age=<s> nonce=<n> [(previous boot)]`. **`age` is the
age the verdict was made on** — awake-seconds when the awake clock decided it, wall-seconds
otherwise — so the number never contradicts the verdict printed beside it.

---

## 4. Merged result — SHIPPED (`bus/merge.sh` writes this)

The output of a quest, and the one file in this repo whose EXISTENCE is a decision:

    $INNKEEPER_HOME/state/merged/<quest-id>.out     the result
    $INNKEEPER_HOME/state/merged/<quest-id>.by      attribution, not truth

| path | type | notes |
|---|---|---|
| `<id>.out` | the worker's bytes, verbatim | Created by `ln` from the staged attempt file. Its presence *is* "this quest has been merged"; there is no separate flag. Never rewritten. |
| `<id>.by` | `<lane> <UTC timestamp>`, one line | Written **after** the link, best-effort. Attribution only. |

**The artifact is its own receipt, and that is the whole design.** `ln` fails with `EEXIST`
if the destination is already there, so the commit tests and sets in one indivisible step —
there is no read-then-write window for a second worker to fit inside. A separate
`<id>.merged` marker would make the receipt a SECOND WRITER, and a worker killed between the
two writes would leave either a receipt with no result or a result with no receipt, the second
of which the next worker merges again.

**`<id>.by` is never consulted to decide whether a merge may happen.** A worker killed between
the link and the sidecar leaves `status` reporting `MERGED by=unknown at=unknown`, which is
correct and complete for the only question that governs behaviour. Nothing branches on `by`.

**Staged work is not a result and is stored somewhere else on purpose:**

    $INNKEEPER_HOME/work/<quest-id>/<lane>.<pid>/...

A killed worker leaves a partial here. It is invisible to `merge.sh status` by construction —
a consumer that went looking for results under `work/` would be reading half-written bytes and
rendering them as finished work.

Read this with `merge.sh status <id>`, which returns `UNMERGED` | `MERGED by=<lane> at=<ts>`,
and `merge.sh dest <id>` for the path. **Stated limit:** `ln` is a hard link, so the staged
file and the destination must share a filesystem; both live under `$INNKEEPER_HOME`. If that
stops being true the commit does not silently degrade — the link fails, nothing is at the
destination, and `merge.sh` exits 2 rather than reporting a merge it did not perform.

---

## Reading these from a consumer

Resolve names through `bus/actor.sh` (`resolve`, `targets`, `field`, `list`) rather than
parsing `party.yaml`. That is the single-parser rule the whole repo is built on: every
script here reads the roster through that one reader, and the ports exist because the
source mesh had two halves spelling one grammar in two languages with no test that they
agreed.
