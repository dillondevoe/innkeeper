#!/usr/bin/env bash
# murder-quest.sh — kill a worker mid-task and watch the work land EXACTLY ONCE.
#
#   bin/murder-quest.sh            run in a fresh sandbox
#   bin/murder-quest.sh --keep     leave the sandbox on disk for inspection
#
# The hello-party slice shows four brains cooperating when nothing goes wrong. This one shows
# the case a stranger actually worries about: the machine running your work disappears. A real
# `kill -9` is sent to a real child process in both acts below — nothing here simulates a crash
# by printing that one happened.
#
# TWO KILLS, AND THE SECOND IS THE ONE THAT MATTERS.
#
#   ACT 1 — killed BEFORE the commit. The obvious case. Nothing merged, a partial sits in the
#           attempt dir, the takeover redoes the work and merges it. The property being shown is
#           that the partial is INVISIBLE: it is not a result, and no consumer can mistake it
#           for one.
#
#   ACT 2 — killed AFTER the commit and before the quest was released. This is the case a
#           done-marker gets wrong, and it is why bus/merge.sh exists. The takeover has every
#           reason to believe the work was never finished — the quest still says claimed, the
#           lease still names a dead holder — so it redoes the work and tries to commit. It must
#           be told ALREADY-MERGED, and the bytes on disk must still be the DEAD worker's.
#
# Both acts are asserted, not narrated: the script exits non-zero if the world is not what the
# prose above says it is. A demo that only prints is a demo that cannot fail.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$REPO/bus/actor.sh"
QUEST="$REPO/bus/quest.sh"
MERGE="${INNKEEPER_MERGE:-$REPO/bus/merge.sh}"
LEASE="$REPO/lifecycle/lease.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/murder-quest.XXXXXX") || { echo "cannot make a sandbox" >&2; exit 2; }
[ "$KEEP" = 1 ] || trap 'rm -rf "$SANDBOX"' EXIT
export INNKEEPER_BUS="$SANDBOX/bus"
export INNKEEPER_HOME="$SANDBOX"
export INNKEEPER_PARTY="${INNKEEPER_PARTY:-$REPO/party.yaml}"
export INNKEEPER_QUESTS="$SANDBOX/quests"
mkdir -p "$INNKEEPER_BUS/comms" "$INNKEEPER_BUS/queues" "$SANDBOX/state" "$SANDBOX/quests" "$SANDBOX/work"
# A demo must not wait half an hour to show a dead holder going stale.
export LEASE_TTL=2

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail=0
check() { # description, actual, expected
  if [ "$2" = "$3" ]; then printf '   \033[32mok\033[0m   %s\n' "$1"
  else printf '   \033[31mFAIL\033[0m %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# Names are read off the roster, never typed here: party.yaml promises nothing keys on these
# strings, and bin/ is the directory the port gate scans for hardcoded addressing.
LANES=$(bash "$ACTOR" lanes) || { echo "FATAL: actor.sh refused to name the lanes" >&2; exit 2; }
A=$(printf '%s\n' $LANES | sed -n 1p)
B=$(printf '%s\n' $LANES | sed -n 2p)
[ -n "$A" ] && [ -n "$B" ] || { echo "FATAL: a party of one cannot take over from itself" >&2; exit 1; }

# A worker: claims the lane, begins an attempt, writes its result INTO THE ATTEMPT DIR, and only
# then commits. `--die-before` and `--die-after` make it exit in the two places a crash can land.
# It is a real process and it is really killed; the exit is the child's, not a message.
worker() { # $1=lane $2=quest $3=text $4=before|after|clean
  local lane=$1 q=$2 text=$3 when=$4 att nonce
  nonce=$(PARTY_BRAIN=$lane bash "$LEASE" claim); nonce=${nonce#CLAIMED }
  att=$(bash "$MERGE" begin "$q" "$lane") || return 9
  att=${att#ATTEMPT }
  printf '%s' "$text" > "$att/result.part"
  # $BASHPID, NOT $$. Inside `( ... )` the variable `$$` still names the PARENT shell, so
  # `kill -9 $$` kills the demo instead of the worker -- which is what the first run of this
  # script did, exiting 137 four lines into act 1. Same family as the refusals in bus/quest.sh
  # that exited only their own subshell: a construct that looks like it is talking about "me"
  # and is not.
  [ "$when" = before ] && { kill -9 $BASHPID; sleep 5; }
  bash "$MERGE" commit "$q" "$lane" "$att/result.part" || return 8
  [ "$when" = after ] && { kill -9 $BASHPID; sleep 5; }
  PARTY_BRAIN=$lane bash "$LEASE" release "$nonce" >/dev/null
  bash "$QUEST" state "$q" done >/dev/null
}

say "ACT 1 — a worker is killed BEFORE it commits"
bash "$QUEST" new rescue-the-cat --title "Get the cat out of the tree" \
  --brief "One worker will be killed doing this. Another must finish it, once." >/dev/null
bash "$QUEST" claim rescue-the-cat "$A" >/dev/null
echo "   $A claims the quest and starts work"
# THE "Killed" LINE IS PRINTED BY THIS SHELL, NOT BY THE WORKER, so redirecting the subshell
# does not silence it -- the enclosing group has to be redirected. Kept quiet on purpose: the
# evidence that the kill was real is the exit status asserted below, which a message cannot fake.
{ ( worker "$A" rescue-the-cat "the cat, rescued by the first worker" before ) >/dev/null 2>&1; rc=$?; } 2>/dev/null
check "the worker died of a real SIGKILL, not a return" "$rc" "137"
check "the quest still reads as claimed"        "$(bash "$QUEST" field rescue-the-cat state)" "claimed"
check "nothing was merged"                      "$(bash "$MERGE" status rescue-the-cat)"      "UNMERGED"
check "a partial is on disk and is not a result" "$(find "$SANDBOX/work/rescue-the-cat" -name '*.part' | wc -l | tr -d ' ')" "1"

say "   ...the lease goes stale, and $B takes over"
sleep 3
check "the dead holder's lease is stale"        "$(PARTY_BRAIN=$A bash "$LEASE" status | cut -d' ' -f1)" "STALE"
bash "$QUEST" release rescue-the-cat >/dev/null
bash "$QUEST" claim rescue-the-cat "$B" >/dev/null
( worker "$B" rescue-the-cat "the cat, rescued by the second worker" clean ) >/dev/null 2>&1
check "the takeover merged it"                  "$(bash "$MERGE" status rescue-the-cat | cut -d' ' -f1)" "MERGED"
check "credited to the worker that finished it" "$(bash "$MERGE" status rescue-the-cat | sed -n 's/.*by=\([^ ]*\).*/\1/p')" "$B"
check "exactly one result exists"               "$(ls "$SANDBOX/state/merged"/rescue-the-cat.out* | wc -l | tr -d ' ')" "1"
check "the quest is closed"                     "$(bash "$QUEST" field rescue-the-cat state)" "done"

say "ACT 2 — a worker is killed AFTER it commits, before it could say so"
bash "$QUEST" new mend-the-roof --title "Patch the roof before the rain" \
  --brief "The worker finishes the job and dies before telling anyone. Nobody may do it twice." >/dev/null
bash "$QUEST" claim mend-the-roof "$A" >/dev/null
{ ( worker "$A" mend-the-roof "the roof, mended by the first worker" after ) >/dev/null 2>&1; rc2=$?; } 2>/dev/null
echo "   $A committed its work and was then killed before releasing anything"
check "this worker also died of a real SIGKILL" "$rc2" "137"
check "the quest STILL reads as claimed"        "$(bash "$QUEST" field mend-the-roof state)" "claimed"
echo "   every signal a takeover can see says this work was never finished:"
echo "     quest state = claimed, lease = held by a process that no longer exists"
sleep 3
bash "$QUEST" release mend-the-roof >/dev/null
bash "$QUEST" claim mend-the-roof "$B" >/dev/null
echo "   $B takes over, redoes the work, and tries to commit it"
out=$( ( worker "$B" mend-the-roof "the roof, mended by the SECOND worker" clean ) 2>/dev/null )
check "the second commit was refused, by name"  "$(printf '%s' "$out" | sed -n 1p | cut -d' ' -f1)" "ALREADY-MERGED"
check "still exactly one result"                "$(ls "$SANDBOX/state/merged"/mend-the-roof.out* | wc -l | tr -d ' ')" "1"
check "and the bytes are the DEAD worker's"     "$(cat "$(bash "$MERGE" dest mend-the-roof)")" "the roof, mended by the first worker"
check "credited to the worker that did it"      "$(bash "$MERGE" status mend-the-roof | sed -n 's/.*by=\([^ ]*\).*/\1/p')" "$A"

say "murder-quest complete."
[ "$fail" = 0 ] || { echo "SOME CHECKS FAILED — the world is not what this script says it is." >&2; exit 1; }
echo "Two workers were killed. Each quest merged exactly once, and the second kill —"
echo "after the commit, before the announcement — did not cost the work or duplicate it."
[ "$KEEP" = 1 ] && echo "sandbox kept at $SANDBOX" || echo "(sandbox removed; --keep to inspect it)"
