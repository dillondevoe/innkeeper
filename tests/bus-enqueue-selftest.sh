#!/usr/bin/env bash
# bus-enqueue-selftest.sh — arms for the producer.
#
# Each arm builds a throwaway bus under mktemp, so nothing here can touch a real party's
# queues. E0 is the vacuity arm: most arms below assert that NO marker appeared, and all
# of those pass just as well against a producer that does nothing at all.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
E="$REPO/bus/enqueue.sh"
fail=0
ok()   { echo "  PASS $1"; }
bad()  { echo "  FAIL $1"; fail=1; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1 want [$3] got [$2]"; fi; }

new_bus() {   # -> sets HOME_D, BUS, COMMS, QUEUES, STATE
  HOME_D=$(mktemp -d); BUS="$HOME_D/bus"; COMMS="$BUS/comms"; QUEUES="$BUS/queues"; STATE="$HOME_D/state/queues"
  mkdir -p "$COMMS/_done" "$QUEUES"
  cat > "$HOME_D/party.yaml" <<'YAML'
party:
  name: Test Party
brains:
  - { name: voice, role: voice }
  - { name: gate,  role: gate }
  - { name: worker,   role: worker }
addressees: [patron]
YAML
  export INNKEEPER_HOME="$HOME_D" INNKEEPER_PARTY="$HOME_D/party.yaml" INNKEEPER_BUS="$BUS"
}
comm() {  # $1 = basename, rest = header lines
  local b="$1"; shift
  { echo "---"; echo "from: test"; for l in "$@"; do echo "$l"; done; echo "---"; echo "body"; } > "$COMMS/$b"
}
run() { bash "$E" >/dev/null 2>&1; }
markers() { ls "$QUEUES"/*/*.job 2>/dev/null | sed "s|$QUEUES/||;s|/.*||" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
penned() { ls "$STATE"/*/pen/* 2>/dev/null | wc -l | tr -d ' '; }

echo "bus/enqueue selftest:"

# E0 VACUITY / permitting arm — a pending P2 comm reaches its lane.
new_bus; comm "worker-to-gate-P2-a-question-2026-09-20.md" "priority: P2" "re: a question"
run; chk "E0 permitting  plain comm queues" "$(markers)" "gate"
[ -f "$QUEUES/gate/worker-to-gate-P2-a-question-2026-09-20.md.job" ] && ok "E0 marker named for the comm" || bad "E0 marker name"

# E1 a resolved comm is never queued.
new_bus; comm "worker-to-gate-P2-x-2026-09-20.md" "priority: P2"
touch "$COMMS/_done/worker-to-gate-P2-x-2026-09-20.md"
run; chk "E1 control     done comm is skipped" "$(markers)" ""

# E2 idempotence: a second pass adds nothing, and does not disturb the first marker.
new_bus; comm "worker-to-gate-P2-x-2026-09-20.md" "priority: P2"
run; before=$(ls "$QUEUES"/gate | wc -l | tr -d ' '); run; after=$(ls "$QUEUES"/gate | wc -l | tr -d ' ')
chk "E2 idempotent  second pass" "$before/$after" "1/1"

# E3 broadcast fans out to every lane but the author.
new_bus; comm "worker-to-all-P2-heads-up-2026-09-20.md" "priority: P2"
run; chk "E3 broadcast   all but the author" "$(markers)" "gate voice"

# E4 the feed addresses nobody.
new_bus; comm "worker-to-feed-P1-status-2026-09-20.md" "priority: P1"
run; chk "E4 feed        no actor, no wake" "$(markers)" ""

# E5 P3 is penned, not woken.
new_bus; comm "worker-to-gate-P3-someday-2026-09-20.md" "priority: P3" "re: someday"
run; chk "E5 batch       P3 penned not queued" "$(markers)/$(penned)" "/1"

# E6 an ack is penned against the LONG window: the P3 window expiring does not flush it.
new_bus; comm "worker-to-gate-P2-ack-2026-09-20.md" "priority: P2" "re: ack — nothing owed"
run; chk "E6 low         ack penned despite P2" "$(markers)/$(penned)" "/1"
# Age it to 120s: past the shortened P3 window, nowhere near the LOW one. Ageing it to
# epoch 0 would clear BOTH windows and the arm could not tell them apart.
echo $(( $(date +%s) - 120 )) > "$STATE/gate/pen/worker-to-gate-P2-ack-2026-09-20.md"
BATCH_S=60 run; chk "E6b low window holds" "$(markers)" ""
BATCH_S=60 BATCH_LOW_S=60 run; chk "E6c low window expires" "$(markers)" "gate"

# E7 piggyback: a NOW wake for a lane flushes everything that lane was holding.
new_bus; comm "worker-to-gate-P3-held-2026-09-20.md" "priority: P3"
run; chk "E7 setup       held" "$(penned)" "1"
comm "worker-to-gate-P1-urgent-2026-09-20.md" "priority: P1"
run; n=$(ls "$QUEUES"/gate | wc -l | tr -d ' '); chk "E7 piggyback  both delivered" "$n/$(penned)" "2/0"

# E8 a delivered broadcast is never re-queued after its marker is consumed.
new_bus; comm "worker-to-all-P2-x-2026-09-20.md" "priority: P2"
run; mkdir -p "$STATE/gate/delivered"; mv "$QUEUES/gate/worker-to-all-P2-x-2026-09-20.md.job" "$STATE/gate/delivered/"
run; [ -e "$QUEUES/gate/worker-to-all-P2-x-2026-09-20.md.job" ] && bad "E8 re-queued a delivered broadcast" || ok "E8 delivered   stays delivered"

# E9 the dead-letter latch holds.
new_bus; comm "worker-to-gate-P2-x-2026-09-20.md" "priority: P2"
mkdir -p "$INNKEEPER_HOME/state/deadletter/gate"; touch "$INNKEEPER_HOME/state/deadletter/gate/worker-to-gate-P2-x-2026-09-20.md.job"
run; chk "E9 deadletter  no marker recreated" "$(markers)" ""

# E9b THE PEN IS A SECOND WRITER OF THE SAME MARKER, and until 2026-09-20 it was an
# UNGUARDED one: pen_flush checked only done/exists, so a comm that was penned as P3 and
# then circuit-broken into dead-letter had its marker recreated the moment its window
# expired — resetting the attempt counter, which is exactly the bounded-retry-becomes-a-
# loop failure E9 exists to prevent. E9 could never catch it: a penned comm takes the pen
# path and the main loop's latch never sees it again.
new_bus; comm "worker-to-gate-P3-x-2026-09-20.md" "priority: P3"
run; chk "E9b setup      penned" "$(penned)" "1"
mkdir -p "$INNKEEPER_HOME/state/deadletter/gate"; touch "$INNKEEPER_HOME/state/deadletter/gate/worker-to-gate-P3-x-2026-09-20.md.job"
echo $(( $(date +%s) - 120 )) > "$STATE/gate/pen/worker-to-gate-P3-x-2026-09-20.md"
BATCH_S=60 run; chk "E9b deadletter no marker via the pen" "$(markers)/$(penned)" "/0"
# CONTROL: the same flush, same ageing, WITHOUT the dead-letter file, must deliver — or
# the arm above would pass on a pen_flush that had simply stopped flushing.
new_bus; comm "worker-to-gate-P3-x-2026-09-20.md" "priority: P3"
run; echo $(( $(date +%s) - 120 )) > "$STATE/gate/pen/worker-to-gate-P3-x-2026-09-20.md"
BATCH_S=60 run; chk "E9b control    a clean pen still flushes" "$(markers)" "gate"
# E9c the same latch via the delivered ledger, which the pen also used to ignore.
new_bus; comm "worker-to-gate-P3-x-2026-09-20.md" "priority: P3"
run; mkdir -p "$STATE/gate/delivered"; touch "$STATE/gate/delivered/worker-to-gate-P3-x-2026-09-20.md.job"
echo $(( $(date +%s) - 120 )) > "$STATE/gate/pen/worker-to-gate-P3-x-2026-09-20.md"
BATCH_S=60 run; chk "E9c delivered  no marker via the pen" "$(markers)" ""

# E14 an unreadable roster is a REFUSAL, not an empty dispatch. Without this the whole
# file passes against a bus that parses no brains at all: every "no marker" arm is
# satisfied, and E0's permitting arm is the only thing standing between this battery and
# a producer that cannot address anyone. rc, not markers, is the channel under test.
new_bus; comm "worker-to-gate-P2-x-2026-09-20.md" "priority: P2"
INNKEEPER_PARTY="$INNKEEPER_HOME/absent.yaml" bash "$E" >/dev/null 2>&1; rc=$?
chk "E14 no roster   refuses rc=2" "$rc" "2"
run; rc=$?; chk "E14 control    a good roster runs rc=0" "$rc" "0"

# E10 retraction: a marker whose comm was resolved is withdrawn.
new_bus; comm "worker-to-gate-P2-x-2026-09-20.md" "priority: P2"
run; touch "$COMMS/_done/worker-to-gate-P2-x-2026-09-20.md"; run
chk "E10 retract    resolved marker withdrawn" "$(markers)" ""

# E11 storm damper, with its control. Four NOW wakes from one sender to one lane, then a
# fifth: demoted. The control is the same fifth comm at P1, which is never damped.
new_bus; mkdir -p "$STATE/gate/recent"; n=$(date +%s)
for i in 1 2 3 4; do echo $((n - 60)) >> "$STATE/gate/recent/worker"; done
comm "worker-to-gate-P2-chatter-2026-09-20.md" "priority: P2" "re: chatter"
run; chk "E11 storm      fifth P2 demoted" "$(markers)/$(penned)" "/1"
new_bus; mkdir -p "$STATE/gate/recent"; n=$(date +%s)
for i in 1 2 3 4; do echo $((n - 60)) >> "$STATE/gate/recent/worker"; done
comm "worker-to-gate-P1-chatter-2026-09-20.md" "priority: P1" "re: chatter"
run; chk "E11 control    P1 is never damped" "$(markers)" "gate"

# E12 the lane is the one the GRAMMAR names, not the one the filename looks like: an
# addressee with no lane must not create a queue dir nothing polls.
new_bus; comm "worker-to-patron-gate-cc-voice-P2-x-2026-09-20.md" "priority: P2"
run; chk "E12 lanes only addressee owns no lane" "$(markers)" "gate"
[ -d "$QUEUES/patron" ] && bad "E12 created a lane for a non-lane name" || ok "E12 no phantom lane"

# E13 the roster is the source: a comm addressed to a name this party has never heard of
# reaches nobody, and no directory is created for it.
new_bus; comm "worker-to-nobody-P2-x-2026-09-20.md" "priority: P2"
run; chk "E13 off-roster no lane, no marker" "$(markers)" ""

[ $fail -eq 0 ] && echo "SELFTEST: ALL PASS" || echo "SELFTEST: FAILURES"
exit $fail
