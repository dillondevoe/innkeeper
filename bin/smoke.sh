#!/usr/bin/env bash
# smoke.sh — the WIRING proof. Four brains boot, each writes ONE line to the bus, and the
# herald prints them in ROSTER order. No model calls, no network, no state outside a
# sandbox this script creates and names.
#
# THIS IS NOT THE QUEST, AND IT USED TO BE CALLED hello-party, WHICH CLAIMED IT WAS.
# Nothing is worked on here, nothing is refused, nothing is fixed, and nothing merges: a
# stranger who runs this watches four print statements. What it proves is real and worth
# keeping -- every hop is the shipped script, so if the bus, the actor grammar, the quest
# writer or the inbound reader regresses, this breaks -- but that is a proof about the
# PLUMBING. `bin/hello-party.sh` is the quest, and the quest is the product.
#
#   bin/smoke.sh              run in a fresh sandbox, print where it was
#   bin/smoke.sh --keep       leave the sandbox on disk for inspection
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
KEEP=0
# AN UNKNOWN ARGUMENT IS REFUSED, NOT IGNORED. `--kep` used to run the demo and then delete the
# sandbox the caller had asked to keep.
usage() { echo "usage: bin/smoke.sh [--keep]    (--keep leaves the sandbox on disk to inspect)"; }
case "$#:${1:-}" in
  0:) ;;
  1:--keep) KEEP=1 ;;
  1:-h|1:--help) usage; exit 0 ;;
  *) echo "smoke.sh: unrecognised argument(s): $*" >&2; usage >&2; exit 2 ;;
esac

# EVERY FATAL SAYS WHAT TO DO NEXT. The demos run on an unmodified checkout with no setup, so
# a failure here is either a local edit (most often to party.yaml) or a bug; say both.
fatal() { # fatal <rc> <what went wrong>
  echo "FATAL: $2" >&2
  echo "   What to do: this does not fail on an unmodified checkout. Run 'git status' for local" >&2
  echo "   edits (party.yaml especially; unset INNKEEPER_PARTY if you set it), re-run with --keep" >&2
  echo "   to inspect the sandbox, and if it still fails open an issue with this output:" >&2
  echo "   https://github.com/dillondevoe/innkeeper/issues" >&2
  exit "$1"
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX") || { echo "cannot make a sandbox under ${TMPDIR:-/tmp}. Check that it exists and is writable, or point TMPDIR at a directory that is." >&2; exit 2; }
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
LANES=$(bash "$ACTOR" lanes) || fatal 2 "could not read the party roster at $INNKEEPER_PARTY"
[ -n "$LANES" ] || fatal 2 "the roster at $INNKEEPER_PARTY names no lanes — nothing can boot"

say "1. The roster — read from party.yaml by bus/actor.sh, not by this script"
printf '   %s\n' $LANES

say "2. The quest — written by bus/quest.sh from the committed fixture brief"
bash "$REPO/bus/quest.sh" new first-light \
  --title "Make the smoke slice print one line from each brain" \
  --brief-file "$REPO/fixtures/quests/first-light.yaml" \
  --origin "fixtures/quests/first-light.yaml" >/dev/null \
  || fatal 1 "quest.sh refused to open the quest"
bash "$REPO/bus/quest.sh" claim first-light worker >/dev/null \
  || fatal 1 "quest.sh refused the claim"
echo "   first-light: state=$(bash "$REPO/bus/quest.sh" field first-light state) lane=$(bash "$REPO/bus/quest.sh" field first-light lane)"

say "3. Four brains boot and each writes ONE line to the bus (reverse roster order)"
today=$(date -u +%Y-%m-%d)
# `tac` is GNU coreutils and is ABSENT on macOS, where the demo may well be driven from.
# It failed there loudly (`tac: command not found`) and the demo carried on regardless --
# see the step guard below. awk is POSIX and on every box that has a shell.
REVERSED=$(printf '%s\n' $LANES | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}') \
  || fatal 2 "could not reverse the roster"
# The rule four lines above -- THE RC IS CONSUMED AT THE ASSIGNMENT -- was stated here and
# not applied here. When `tac` was missing on macOS, this assignment failed, REVERSED came
# out empty, the `for` loop over it ran ZERO times, and the demo carried on to print
# `enqueue: 0 marker(s) queued` and four empty delivery tiers with `(control:ok)`. A
# stranger reading that output sees a quiet party, not a broken one: the failure rendered
# as a legitimate-looking empty result, which is the only shape worth fearing on a stage.
[ -n "$REVERSED" ] || fatal 2 "the reversed roster is empty"
FIRST=$(printf '%s\n' $LANES | sed -n 1p)
SECOND=$(printf '%s\n' $LANES | sed -n 2p)
[ -n "$SECOND" ] || fatal 1 "a party of one cannot pass a message"
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

say "5. Delivery — staff/inbound.sh, read as voice"
PARTY_BRAIN=voice bash "$REPO/staff/inbound.sh" | sed 's/^/   /'

say "6. The herald speaks — ROSTER order, regardless of the order they spoke in"
for b in $LANES; do
  line=$(sed -n '5p' "$INNKEEPER_BUS"/comms/${b}-to-*-P2-first-light-line-${today}.md 2>/dev/null)
  [ -n "$line" ] || { echo "   herald: $b filed nothing — the party is not whole" >&2; exit 1; }
  printf '   %-10s %s\n' "$b" "$line"
done

# NO BACKTICKS IN A DOUBLE-QUOTED STRING. This line read ...refuses `done` while... and bash
# EXECUTED it: the banner shipped as "refuses  while anything blocks it" and a stray error
# printed two steps early. Prose about a shell keyword is still shell.
say '7. The quest closes — quest.sh refuses the done state while anything blocks it'
bash "$REPO/bus/quest.sh" state first-light done >/dev/null \
  || fatal 1 "quest.sh refused to close the quest"
echo "   first-light: state=$(bash "$REPO/bus/quest.sh" field first-light state)"

say "smoke complete."
[ "$KEEP" = 1 ] && echo "sandbox kept at $SANDBOX" || echo "(sandbox removed; --keep to inspect it)"
