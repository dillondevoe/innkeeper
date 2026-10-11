#!/usr/bin/env bash
# bin-watchman-selftest.sh — battery for bin/watchman.sh.
#
# The dangerous Watchman is not one that crashes. It is one that is QUIET when a worker is
# dead (the party sits forever and every look reads calm), or one that wakes the Innkeeper
# on every look (a paid model call every five seconds, which is the cost it exists to avoid),
# or one that ACTS (an unsupervised second worker). Each has an arm:
#   W3        a dead worker's stale lease IS reported            (quiet-when-dead)
#   W2, W7    a live lease and low spend are NOT reported        (permitting twins: without
#             them a watchman that woke on everything would pass W3 and W6)
#   W4        the same finding does not wake twice               (wake-every-look)
#   W5        a cleared condition is cleared, so it can wake again
#   W8        the quest and the lease are byte-identical after a look   (never acts)
#   W9        no model is called, even with a live ledger present
set -u
R=$(cd "$(dirname "$0")/.." && pwd -P)
WM="$R/bin/watchman.sh"
EXPECT_ARMS=11
n=0; fails=0
ok()  { n=$((n+1)); echo "  $1 — PASS"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "  $1 — FAIL"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export INNKEEPER_HOME="$W" INNKEEPER_BUS="$W/bus" INNKEEPER_QUESTS="$W/quests"
export INNKEEPER_PARTY="$R/party.yaml" LEASE_TTL=1
mkdir -p "$W/bus" "$W/quests" "$W/state"
unset INNKEEPER_LEDGER
LANE=$(bash "$R/bus/actor.sh" lanes | sed -n 1p)
look() { bash "$WM" once 2>&1; }

# W1: an empty bus is quiet and writes nothing.
chk "W1 empty bus is quiet" "$(look)" "quiet"
chk "W1b and wakes nothing" "$(ls "$W/bus/wake" | wc -l | tr -d ' ')" "0"

# W2: a claimed quest whose holder's lease is LIVE is not reported.
bash "$R/bus/quest.sh" new q1 --title "a quest" --brief "test" >/dev/null
bash "$R/bus/quest.sh" claim q1 "$LANE" >/dev/null
NONCE=$(PARTY_BRAIN=$LANE bash "$R/lifecycle/lease.sh" claim); NONCE=${NONCE#CLAIMED }
chk "W2 a live holder is not reported" "$(look)" "quiet"

# W3: the holder dies (its lease goes stale): reported, once, with the quest named.
sleep 2
out=$(look)
case "$out" in "WAKE stale-lease q1 quest=q1 holder=$LANE"*) ok "W3 a dead holder is reported";;
  *) bad "W3 a dead holder is reported: got [$out]";; esac
[ -f "$W/bus/wake/stale-lease.q1" ] && ok "W3b and a wake note is on the bus" || bad "W3b no wake note"

# W4: the next look does not wake again for the same thing.
chk "W4 the same finding does not wake twice" "$(look)" "quiet"

# W8: never acts. The quest and lease are unchanged by any number of looks.
before=$(cat "$(bash "$R/bus/quest.sh" path q1)" "$W/state/$LANE.lease" | cksum)
look >/dev/null; look >/dev/null
chk "W8 the Watchman never changes a quest or a lease" \
  "$(cat "$(bash "$R/bus/quest.sh" path q1)" "$W/state/$LANE.lease" | cksum)" "$before"

# W5: once the Innkeeper deals with it (quest released), the note is cleared.
bash "$R/bus/quest.sh" release q1 >/dev/null
chk "W5 a resolved finding is cleared" "$(look)" "CLEARED stale-lease q1"

# W6/W7: spend. 2.50 of 3.00 is past 80% and wakes; 1.00 of 3.00 does not.
export INNKEEPER_LEDGER="$W/ledger.tsv"
printf '2026-01-01T00:00:00Z\tworker\t1.00\n' > "$INNKEEPER_LEDGER"
chk "W7 low spend is not reported" "$(look)" "quiet"
printf '2026-01-01T00:01:00Z\tworker\t1.50\n' >> "$INNKEEPER_LEDGER"
out=$(look)
case "$out" in "WAKE spend-near-ceiling live spent=2.5000 ceiling=3.00") ok "W6 spend near the ceiling is reported";;
  *) bad "W6 spend near the ceiling: got [$out]";; esac

# W9: no model call, even with a ledger and a "claude" on PATH that would record being run.
mkdir -p "$W/fakebin"
printf '#!/bin/sh\ntouch "%s/claude-was-called"\n' "$W" > "$W/fakebin/claude"; chmod +x "$W/fakebin/claude"
PATH="$W/fakebin:$PATH" INNKEEPER_CLAUDE="$W/fakebin/claude" bash "$WM" once >/dev/null 2>&1
[ ! -e "$W/claude-was-called" ] && ok "W9 no model is called" || bad "W9 a model was called"

echo "arms run: $n (expected $EXPECT_ARMS) — $fails failure(s)"
[ "$fails" = 0 ] && [ "$n" = "$EXPECT_ARMS" ]
