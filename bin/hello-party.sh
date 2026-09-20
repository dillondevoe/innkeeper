#!/usr/bin/env bash
# hello-party.sh — the slice a stranger can run. Four brains boot, each writes ONE line
# to the bus, the herald prints them in ROSTER order. No model calls, no network, no
# state outside a sandbox this script creates and names.
#
#   bin/hello-party.sh              run in a fresh sandbox, print where it was
#   bin/hello-party.sh --keep       leave the sandbox on disk for inspection
#
# WHAT IT IS DEMONSTRATING, and it is not "four echo statements": every hop here is the
# SHIPPED script, not a stand-in. The roster comes from bus/actor.sh, the quest record
# from bus/quest.sh, dispatch from bus/enqueue.sh, delivery from staff/inbound.sh. If any
# of those regresses, this demo breaks — which is the point of having it.
#
# THE HERALD PRINTS IN ROSTER ORDER, NOT ARRIVAL ORDER, AND THAT IS THE LOAD-BEARING
# CLAIM. Arrival order is whatever the filesystem hands back, and on a four-line run it
# will usually MATCH roster order by luck — so the demo would look correct while proving
# nothing. The brains are therefore made to speak in reverse roster order below. If the
# herald ever starts echoing arrival order, the output visibly inverts.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$REPO/bus/actor.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hello-party.XXXXXX") || { echo "cannot make a sandbox" >&2; exit 2; }
[ "$KEEP" = 1 ] || trap 'rm -rf "$SANDBOX"' EXIT
export INNKEEPER_BUS="$SANDBOX/bus"
export INNKEEPER_HOME="$SANDBOX"
# INNKEEPER_HOME moves the STATE dir into the sandbox, and it also moves where the roster
# is looked for — the first run of this script died at "roster empty" for exactly that
# reason. The roster is the one thing that must stay the repo's, so it is named outright.
export INNKEEPER_PARTY="${INNKEEPER_PARTY:-$REPO/party.yaml}"
mkdir -p "$INNKEEPER_BUS/comms" "$INNKEEPER_BUS/queues" "$SANDBOX/state" "$SANDBOX/quests"
export INNKEEPER_QUESTS="$SANDBOX/quests"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# THE RC IS CONSUMED AT THE ASSIGNMENT. Same rule as bus/enqueue.sh: a helper that exits
# inside $( ) exits the subshell only, and the caller runs on with an empty string.
LANES=$(bash "$ACTOR" lanes) || { echo "FATAL: actor.sh refused to name the lanes" >&2; exit 2; }
[ -n "$LANES" ] || { echo "FATAL: roster names no lanes — nothing can boot" >&2; exit 2; }

say "1. The roster — read from party.yaml by bus/actor.sh, not by this script"
printf '   %s\n' $LANES

say "2. The quest — written by bus/quest.sh from the committed fixture brief"
bash "$REPO/bus/quest.sh" new first-light \
  --title "Make the hello-party slice print one line from each brain" \
  --brief-file "$REPO/fixtures/quests/first-light.yaml" \
  --origin "fixtures/quests/first-light.yaml" >/dev/null \
  || { echo "FATAL: quest.sh refused to open the quest" >&2; exit 1; }
bash "$REPO/bus/quest.sh" claim first-light page >/dev/null \
  || { echo "FATAL: quest.sh refused the claim" >&2; exit 1; }
echo "   first-light: state=$(bash "$REPO/bus/quest.sh" field first-light state) lane=$(bash "$REPO/bus/quest.sh" field first-light lane)"

say "3. Four brains boot and each writes ONE line to the bus (reverse roster order)"
today=$(date -u +%Y-%m-%d)
# `tac` is GNU coreutils and is ABSENT on macOS, where the demo may well be driven from.
# It failed there loudly (`tac: command not found`) and the demo carried on regardless --
# see the step guard below. awk is POSIX and on every box that has a shell.
REVERSED=$(printf '%s\n' $LANES | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}') \
  || { echo "FATAL: could not reverse the roster" >&2; exit 2; }
# The rule four lines above -- THE RC IS CONSUMED AT THE ASSIGNMENT -- was stated here and
# not applied here. When `tac` was missing on macOS, this assignment failed, REVERSED came
# out empty, the `for` loop over it ran ZERO times, and the demo carried on to print
# `enqueue: 0 marker(s) queued` and four empty delivery tiers with `(control:ok)`. A
# stranger reading that output sees a quiet party, not a broken one: the failure rendered
# as a legitimate-looking empty result, which is the only shape worth fearing on a stage.
[ -n "$REVERSED" ] || { echo "FATAL: the reversed roster is empty" >&2; exit 2; }
FIRST=$(printf '%s\n' $LANES | sed -n 1p)
SECOND=$(printf '%s\n' $LANES | sed -n 2p)
[ -n "$SECOND" ] || { echo "FATAL: a party of one cannot pass a message" >&2; exit 1; }
for b in $REVERSED; do
  role=$(bash "$ACTOR" field "$b" role 2>/dev/null || echo brain)
  # NOBODY ADDRESSES THEMSELVES, AND NO NAME IS TYPED HERE. Everyone files to the first
  # lane on the roster; that one files to the second. Two reasons it is positional:
  # party.yaml promises "nothing keys on these strings" and a demo that hardcoded two of
  # them would be the first thing to break that promise -- and bin/ is a directory the
  # port gate scans for address grammar, so a literal roster name beside `-to-` is a
  # FORBIDDEN hit. The gate caught this line; the roster is the only place names live.
  to=$FIRST; [ "$b" = "$FIRST" ] && to=$SECOND
  f="$INNKEEPER_BUS/comms/${b}-to-${to}-P2-first-light-line-${today}.md"
  { echo "from: $b"; echo "to: $to"; echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
    echo "$b here, the $role. One line, no model was called to write it."; } > "$f"
  echo "   $b wrote $(basename "$f")"
done

say "4. Dispatch — bus/enqueue.sh scans the comms dir once and queues markers"
bash "$REPO/bus/enqueue.sh" | sed 's/^/   /'

say "5. Delivery — staff/inbound.sh, read as rabbot"
PARTY_BRAIN=rabbot bash "$REPO/staff/inbound.sh" | sed 's/^/   /'

say "6. The herald speaks — ROSTER order, regardless of the order they spoke in"
for b in $LANES; do
  line=$(sed -n '5p' "$INNKEEPER_BUS"/comms/${b}-to-*-P2-first-light-line-${today}.md 2>/dev/null)
  [ -n "$line" ] || { echo "   herald: $b filed nothing — the party is not whole" >&2; exit 1; }
  printf '   %-8s %s\n' "$b" "$line"
done

# NO BACKTICKS IN A DOUBLE-QUOTED STRING. This line read ...refuses `done` while... and bash
# EXECUTED it: the banner shipped as "refuses  while anything blocks it" and a stray error
# printed two steps early. Prose about a shell keyword is still shell.
say '7. The quest closes — quest.sh refuses the done state while anything blocks it'
bash "$REPO/bus/quest.sh" state first-light done >/dev/null \
  || { echo "FATAL: quest.sh refused to close the quest" >&2; exit 1; }
echo "   first-light: state=$(bash "$REPO/bus/quest.sh" field first-light state)"

say "hello-party complete."
[ "$KEEP" = 1 ] && echo "sandbox kept at $SANDBOX" || echo "(sandbox removed; --keep to inspect it)"
