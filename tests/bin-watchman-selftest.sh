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
# THE TTL IS THE ARMS' TIME BUDGET, AND AT 1 IT WAS SUB-SECOND. W2 asserts that a LIVE holder is
# not reported, so it is correct only while the claim and the look land inside the same whole second:
# lease.sh ages a lock on an INTEGER awake clock (/proc/uptime truncated) and calls it stale at
# `age >= TTL`, so with TTL=1 any rollover between the two makes a lease claimed 40ms ago read STALE
# and W2 fail. Measured on dellon: the claim-to-look gap is ~41ms, i.e. a ~4% chance per run of
# crossing the boundary on an IDLE box, and worse on a loaded one. 5 makes the margin two orders of
# magnitude larger than the work it has to cover; W3 waits past it rather than relying on the gap.
# This is NOT a named cause for the suite flake (not reproduced in 11 full-suite runs, 8 under 2x CPU
# oversubscription, or 35 earlier solo runs) -- it is a latent race removed on its own merits.
export INNKEEPER_PARTY="$R/party.yaml" LEASE_TTL=5
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
sleep 6
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
