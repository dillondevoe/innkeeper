#!/usr/bin/env bash
# dispose.sh <brain> <basename>... — close a comm the party's way, WITH authorship.
#
#   dispose.sh [--force] <brain> <basename>...
#   dispose.sh --selftest
#
# Two writes, and they are deliberately different kinds:
#   1. touch <comms>/_done/<basename>  — ZERO-BYTE, always. Every existence check in the
#      party is `[ -f _done/<base> ]`, and at least one reader distinguishes a STUB from a
#      moved-in copy of the comm by size (`-s`). Content in the stub breaks that test, so
#      the stub carries no content, ever. What it means is one bit: THE ACTOR HAS ACTED.
#   2. append "<utc> <brain> <basename>" to _done/.ledger/<brain>.log — PER-BRAIN and
#      append-only. One writer per file, so a syncing filesystem never has to merge it, and
#      "who closed X" is a grep across the ledger. Nothing reads it to make a decision.
#
# WHY THE LEDGER EXISTS AT ALL. A zero-byte stub has no author. When a party went looking
# for who had closed a comm out from under its actor, the file itself could not answer:
# mode splits by operating system rather than by machine, and mtime says WHEN, never WHO.
# An hour of four brains' time ended under-determined. The ledger is the cheapest thing
# that answers the question, and it is separate from the stub precisely because the stub
# must stay zero-byte.
#
# THE STUB IS CONTROL FLOW, NOT ONLY A RECORD. A watcher that keys candidacy on
# `not exists(_done/<base>)` re-fires its lane on every pass for as long as that holds. On
# such a lane an unclosed comm is an ARMED REPEATING TIMER and this stub is the only thing
# that disarms it — one party measured 529 re-fires across 87 basenames before anyone
# noticed. "The thread is closed anyway" is not a reason to skip the stub; it is the reason
# to write it.
#
# THE ACTOR GUARD, and why it is a REFUSAL rather than a warning. A brain that was only cc
# on a comm once wrote its stub 41 seconds before the real actor did. It was harmless by
# those 41 seconds and no further. Reverse the order and the actor's summons never fires:
# the existence check reads TRUE, and the comm dies with a ledger row saying someone else
# handled it. So only the FILENAME ACTOR may close a comm. A cc read, a body-to read, a
# broadcast you were not the actor on, your own outbound: no stub. Record those wherever
# you keep your own read-state — that is a private store, not this shared bit.
#
# `--force` is the deliberate escape (an archival sweep, a hand disposal you can defend).
# It writes the stub AND a ledger row tagged FORCED(non-actor), so an exception leaves
# evidence rather than hiding inside a zero-byte file.
#
# The actor question is answered by bus/actor.sh and is NOT re-implemented here. It is a
# grammar with a broadcast form, an alias map and a priority-terminated run; a second
# reader of it would drift from the first, and the drift would show up as this script
# refusing the actor or closing for a bystander.
set -u

R=$(cd "$(dirname "$0")/.." && pwd -P)
[ "${1:-}" = "--selftest" ] && exec bash "$R/tests/bus-dispose-selftest.sh"

ACTOR="$R/bus/actor.sh"
# Same rule as bus/enqueue.sh and bus/merge.sh: a comms dir is WRITTEN, so it is never guessed.
# TICKS_COMMS_DIR still wins outright; only the fallback changed, and bash evaluates the inner
# expansion solely when TICKS_COMMS_DIR is unset or empty — a caller that sets it is unaffected.
CD="${TICKS_COMMS_DIR:-${INNKEEPER_HOME:?INNKEEPER_HOME not set — dispose.sh will not guess where your comms live}/comms}"

force=0
[ "${1:-}" = "--force" ] && { force=1; shift; }
brain="${1:-}"; shift 2>/dev/null || true
case "$brain" in ''|-*) echo "usage: dispose.sh [--force] <brain> <basename>..." >&2; exit 2;; esac
[ $# -ge 1 ] || { echo "usage: dispose.sh [--force] <brain> <basename>..." >&2; exit 2; }

# The roster must be readable before anything is written. actor.sh refuses rc 2 on an empty
# roster; if we did not check here, every comm would look like "not the actor" and a whole
# sweep would be REFUSED for a reason that has nothing to do with authorship.
if ! ROSTER_ERR=$(bash "$ACTOR" roster 2>&1); then
  echo "dispose.sh: FAIL — roster unreadable: ${ROSTER_ERR}" >&2; exit 2
fi

mkdir -p "$CD/_done/.ledger" 2>/dev/null
rc=0
for b in "$@"; do
  b="$(basename "$b")"
  case "$b" in *.md) ;; *) echo "skip (not a .md basename): $b" >&2; rc=1; continue;; esac
  # The typo guard. `touch` of a misspelt name exits 0 and creates a stub that matches
  # NOTHING — the comm stays armed while the ledger says it was closed. A disposal whose
  # only failure mode is a silent no-op is worse than no disposal, so an unknown basename
  # is a refusal. Both locations count: a comm already closed may have been moved.
  if [ ! -f "$CD/$b" ] && [ ! -f "$CD/_done/$b" ]; then
    echo "REFUSED (no such comm in the bus or in _done): $b" >&2; rc=1; continue
  fi
  tag=""
  if ! bash "$ACTOR" is-actor "$brain" "$b" >/dev/null 2>&1; then
    if [ "$force" = 1 ]; then
      tag=" FORCED(non-actor)"
    else
      echo "REFUSED (not the filename actor — a cc read, a body-to read or your own outbound gets NO stub; --force overrides and is ledgered): $brain $b" >&2
      rc=1; continue
    fi
  fi
  touch "$CD/_done/$b"
  printf '%s %s %s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$brain" "$b" "$tag" >> "$CD/_done/.ledger/$brain.log"
done
exit $rc
