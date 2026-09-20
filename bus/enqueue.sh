#!/usr/bin/env bash
# enqueue.sh — the PRODUCER half of the bus. Scans the comms dir once and drops a
# marker into each addressed lane for every comm that is still pending.
#
#   enqueue.sh            one pass; prints "enqueue: N marker(s) queued"
#   enqueue.sh --selftest
#
# ONE scanner, not one watcher per brain: N watchers on the same directory all wake on
# the same change and then each re-derive who the comm was for. This runs on a timer or
# a single watch, and it is idempotent, so running it twice costs nothing.
#
# It does NOT parse addresses itself — `bus/actor.sh targets` does, and that is the same
# parser the readers use. In the source mesh the producer carried its own copy of the
# grammar and the two drifted, which dispatched comms to brains that then declined to
# stub them.
#
# WAKE CLASSES. A marker WAKES a brain, and a wake costs a whole context. Reading is
# free; waking is the spend. So a comm gets a class before it gets a marker:
#   NOW   priority P0/P1/P2, `wake: now`, or a gate/ruling/decision ask   -> marker now
#   BATCH priority P3, or `wake: batch`                                   -> held, one wake per window
#   LOW   ack / received / fyi / verified / no-action re:, or `wake: no`  -> held up to the long window
# Held comms sit in the lane's pen. A pen flushes when its oldest entry ages past its
# window, or when a NOW marker is written for that lane — the brain is waking anyway, so
# hand it everything. An unreadable header is NOW: fail toward delivering the comm.
#
# STORM DAMPER. Measured storms are one sender filing status chatter at one lane. If this
# (sender -> lane) pair has already produced STORM_N NOW wakes in the trailing hour and
# this comm is not P0/P1 and not a gate ask, it is demoted to BATCH. The lane is already
# awake; it will read the rest at its next boundary. P0/P1 are never damped.
#
# Port note: the source kept its queue state inside the watched queue directory, so a lane
# was never empty at idle and a directory-watcher could not use emptiness as its signal.
# State lives under $INNKEEPER_HOME/state here and the lane holds markers only. The
# source's second, legacy ledger location was dropped: it existed for one migration.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$HERE/actor.sh"
PARTY=${INNKEEPER_PARTY:-${INNKEEPER_HOME:-$REPO}/party.yaml}
export INNKEEPER_PARTY="$PARTY"

# The bus path comes from `actor.sh bus` — the ONE roster reader. This file used to carry
# its own copy of that sed; so did two others, and all three silently defaulted to a local
# `bus/` when the roster was unreadable. actor.sh refuses instead.
#
# THE RC IS CONSUMED AT THE ASSIGNMENT, NOT INSIDE A HELPER. A helper that `exit`s on
# refusal exits only the command-substitution SUBSHELL: the caller gets the empty string,
# runs on, and the first thing it does with an empty $BUS is `mkdir -p /queues`. That is
# the same collapse of "it refused" into "it answered empty" that this repo's roster guard
# was written for, and the first version of this very comment shipped above code that
# committed it.
BUS=$(bash "$ACTOR" bus) || { echo "FATAL: actor.sh refused to name the bus (unreadable roster?)" >&2; exit 2; }
[ -n "$BUS" ] || { echo "FATAL: actor.sh named an empty bus path" >&2; exit 2; }
COMMS="$BUS/comms"
DONE="$COMMS/_done"
QUEUES="$BUS/queues"
STATE="${INNKEEPER_HOME:-$REPO}/state/queues"
DEAD="${INNKEEPER_HOME:-$REPO}/state/deadletter"
LOG_FILE=${INNKEEPER_ENQUEUE_LOG:-${INNKEEPER_HOME:-$REPO}/state/enqueue.log}
BATCH_S=${BATCH_S:-1800}            # P3 window: 30 min
BATCH_LOW_S=${BATCH_LOW_S:-21600}   # ack/FYI window: 6 h — any other wake flushes it sooner
STORM_N=${STORM_N:-4}

[ "${1:-}" = "--selftest" ] && exec bash "$REPO/tests/bus-enqueue-selftest.sh"
[ $# -eq 0 ] || { sed -n '2,10p' "$0"; exit 2; }

mkdir -p "$QUEUES" "$STATE" "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

_hdr() { head -n 14 "$1" 2>/dev/null; }
wake_class() {  # $1 = comm path -> NOW | BATCH | LOW
  local hdr pri wk re
  hdr=$(_hdr "$1")
  wk=$(printf '%s\n' "$hdr" | grep -m1 -iE '^wake:' | tr -d '\r' | awk '{print tolower($2)}')
  pri=$(printf '%s\n' "$hdr" | grep -m1 -iE '^priority:' | tr -d '\r' | awk '{print toupper($2)}')
  re=$(printf '%s\n' "$hdr" | grep -m1 -iE '^(re|subject):' | cut -d: -f2- | sed -E 's/^[[:space:]]+//' | tr '[:upper:]' '[:lower:]')
  case "$wk" in now) echo NOW; return;; batch) echo BATCH; return;; no|never) echo LOW; return;; esac
  case "$pri" in P0|P1) echo NOW; return;; esac
  case "$re" in
    *gate*|*ruling*|*directive*|*decision*|*blocked*|*urgent*) echo NOW; return;;
    ack*|acked*|received*|fyi*|verified*|"no action"*|"nothing owed"*|"no-op"*|"no objection"*) echo LOW; return;;
  esac
  case "$pri" in P3) echo BATCH; return;; esac
  echo NOW
}

pen_flush() {  # $1 = lane; write markers for every penned comm still live and pending
  local b="$1" pen="$STATE/$1/pen" n=0 pb base
  [ -d "$pen" ] || return 0
  for pb in "$pen"/*; do
    [ -e "$pb" ] || continue; base=$(basename "$pb")
    if [ -f "$DONE/$base" ] || [ ! -f "$COMMS/$base" ]; then rm -f "$pb"; continue; fi
    # THE SAME TWO GUARDS THE MAIN LOOP APPLIES, and for the same reasons. A penned comm
    # takes the pen path on flush and the main-loop path never sees it again, so a flush
    # that checked only done/exists was a SECOND, unguarded writer of the same marker:
    # a comm penned as BATCH and later circuit-broken into dead-letter had its marker
    # recreated at window expiry, resetting the attempt counter — the bounded-retry-
    # becomes-a-loop failure the main loop's own comment says it is preventing.
    # Class is deliberately NOT re-checked: releasing a BATCH/LOW comm is what the pen
    # is FOR, and re-classifying here would re-pen it forever.
    if [ -e "$DEAD/$b/$base.job" ] || [ -e "$STATE/$b/delivered/$base.job" ]; then rm -f "$pb"; continue; fi
    mkdir -p "$QUEUES/$b"
    [ -e "$QUEUES/$b/$base.job" ] || { echo 0 > "$QUEUES/$b/$base.job"; n=$((n+1)); log "pen-flush $base -> $b"; }
    rm -f "$pb"
  done
  [ "$n" -gt 0 ] && log "pen-flush $n marker(s) -> $b"
  return 0
}

# The roster is a PRECONDITION, not an input: actor.sh refuses an empty one, and this
# is where that refusal has to be consumed, because `$(... targets ...)` swallows both
# its exit code and its emptiness into the same empty string.
bash "$ACTOR" roster >/dev/null || { echo "enqueue: roster unreadable — refusing to dispatch" >&2; log "REFUSED roster unreadable"; exit 2; }

enqueued=0
shopt -s nullglob

for f in "$COMMS"/*.md; do
  base=$(basename "$f")
  [ -f "$DONE/$base" ] && continue                       # already resolved
  from=${base%%-to-*}; from=${from#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}
  for b in $(bash "$ACTOR" targets "$base"); do
    q="$QUEUES/$b"; marker="$q/$base.job"
    [ -e "$marker" ] && continue                          # already queued — idempotent
    # A broadcast has no completer, so its lane ledgers the marker on delivery instead.
    # Without this, every change to the comms dir re-pokes every lane with every live
    # broadcast, for as long as the broadcast stays pending.
    [ -e "$STATE/$b/delivered/$base.job" ] && continue
    # While a circuit breaker holds a comm in the dead-letter store, do NOT recreate its
    # marker: that resets the attempt counter and turns bounded retry into a loop.
    [ -e "$DEAD/$b/$base.job" ] && continue
    cls=$(wake_class "$f")
    if [ "$cls" = "NOW" ]; then
      _pri=$(_hdr "$f" | grep -m1 -iE '^priority:' | awk '{print toupper($2)}')
      _re=$(_hdr "$f" | grep -m1 -iE '^(re|subject):' | tr '[:upper:]' '[:lower:]')
      case "$_pri" in P0|P1) ;; *)
        case "$_re" in *gate*|*ruling*|*directive*|*decision*|*urgent*) ;; *)
          rec="$STATE/$b/recent/$from"; mkdir -p "$(dirname "$rec")"
          _now=$(date +%s); _n=0
          [ -f "$rec" ] && _n=$(awk -v t="$_now" '$1 >= t-3600' "$rec" | wc -l | tr -d ' ')
          [ "$_n" -ge "$STORM_N" ] && { cls=BATCH; log "storm-damped $base ($from->$b: $_n NOW wakes in 1h)"; }
        ;; esac
      ;; esac
    fi
    if [ "$cls" = "NOW" ]; then
      rec="$STATE/$b/recent/$from"; mkdir -p "$(dirname "$rec")"; date +%s >> "$rec"
      awk -v t="$(date +%s)" '$1 >= t-7200' "$rec" > "$rec.tmp" 2>/dev/null && mv "$rec.tmp" "$rec"
      mkdir -p "$q"; echo 0 > "$marker"
      enqueued=$((enqueued + 1)); log "queued $base -> $b"
      pen_flush "$b"                                      # piggyback: it is waking anyway
    else
      pen="$STATE/$b/pen"; mkdir -p "$pen"
      [ -e "$pen/$base" ] || { date +%s > "$pen/$base"; log "penned($cls) $base -> $b"; }
    fi
  done
done

[ "$enqueued" -gt 0 ] && log "enqueued $enqueued marker(s)"

# Pen windows: flush a lane when its OLDEST held comm has aged past that comm's window.
# Any expiry flushes the WHOLE pen for the lane — one wake, everything held.
now_s=$(date +%s)
for pen in "$STATE"/*/pen; do
  [ -d "$pen" ] || continue
  b=$(basename "$(dirname "$pen")"); flush=0
  for pb in "$pen"/*; do
    [ -e "$pb" ] || continue; base=$(basename "$pb")
    if [ -f "$DONE/$base" ] || [ ! -f "$COMMS/$base" ]; then rm -f "$pb"; continue; fi
    first=$(cat "$pb" 2>/dev/null); case "$first" in ''|*[!0-9]*) first=0;; esac
    win=$BATCH_S; [ "$(wake_class "$COMMS/$base")" = "LOW" ] && win=$BATCH_LOW_S
    [ $((now_s - first)) -ge "$win" ] && flush=1
  done
  [ "$flush" = 1 ] && pen_flush "$b"
done

# Ledger hygiene: a delivered-entry whose comm is resolved or gone can never block
# anything again, so each lane's ledger stays bounded by the count of LIVE broadcasts.
for led in "$STATE"/*/delivered/*.job; do
  lbase=$(basename "$led" .job)
  if [ -f "$DONE/$lbase" ] || [ ! -f "$COMMS/$lbase" ]; then rm -f "$led"; log "ledger purge: $lbase"; fi
done

# Marker retraction: the producer withdraws markers whose comm has since been resolved or
# removed. A lane whose consumer is not running yet would otherwise accumulate them
# forever. Benign race with a consumer mid-delivery: its own done check stops a stale poke.
for mk in "$QUEUES"/*/*.job; do
  mbase=$(basename "$mk" .job)
  if [ -f "$DONE/$mbase" ] || [ ! -f "$COMMS/$mbase" ]; then rm -f "$mk"; log "marker retract: $mbase"; fi
done

echo "enqueue: $enqueued marker(s) queued"
exit 0
