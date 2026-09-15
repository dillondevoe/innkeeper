#!/usr/bin/env bash
# lifecycle-lease-selftest.sh — battery for lifecycle/lease.sh. The arm count is part of the verdict.
# LEASE_IMPL overrides the script under test (used to show arms RED against mutations and the source).
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL=${LEASE_IMPL:-$R/lifecycle/lease.sh}
EXPECT_ARMS=12
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export INNKEEPER_HOME=$T PARTY_BRAIN=tester LEASE_BOOT_EPOCH=1000
L() { bash "$IMPL" "$@" 2>/dev/null; }
LOCK=$T/state/tester.lease
n=0 pass=0
arm() { # name, actual, expected-regex
  n=$((n + 1))
  if printf '%s' "$2" | command grep -Eq -- "$3"; then pass=$((pass + 1)); else echo "FAIL $1: got [$2] want /$3/"; fi
}

arm A1-free            "$(L status)"   '^FREE$'
c=$(L claim); nonce=${c#CLAIMED }
arm A2-claim           "$c"            '^CLAIMED [0-9a-f-]{16,}$'
arm A3-second-held     "$(L claim)"    '^HELD-BY-OTHER age=[0-9]+$'
arm A4-status-held     "$(L status)"   "^HELD age=[0-9]+ nonce=$nonce\$"
arm A5-renew-holder    "$(L renew "$nonce")"  '^RENEWED$'
arm A6-renew-stranger  "$(L renew not-the-nonce)" '^NOT-HOLDER$'
arm A7-release-stranger "$(L release not-the-nonce)" '^NOT-HOLDER$'
# TTL: backdate the lock past the TTL, same boot -> a new claim takes over.
echo "$(( $(date +%s) - 4000 )) $nonce 1000" > "$LOCK"
arm A8-ttl-stale-takeover "$(L claim)" '^CLAIMED '
# Boot: a fresh lock from a PREVIOUS boot is stale regardless of age (the reboot scar).
echo "$(date +%s) oldnonce 999" > "$LOCK"
arm A9-previous-boot-stale "$(L status)" '^STALE age=[0-9]+ nonce=oldnonce \(previous boot\)$'
# Control for A9: the same fresh lock under the SAME boot must read HELD, or A9 passes on a script
# that calls everything stale.
echo "$(date +%s) oldnonce 1000" > "$LOCK"
arm A10-same-boot-control "$(L status)" '^HELD age=[0-9]+ nonce=oldnonce$'
arm A11-release-holder "$(L release oldnonce; [ -e "$LOCK" ] && echo STILL-THERE)" '^RELEASED$'
# Race: 8 instances boot together on a free lane; exactly one may CLAIM. Run 10 rounds, because a
# race measured once is a sample.
rounds_bad=0
for r in 1 2 3 4 5 6 7 8 9 10; do
  rm -f "$LOCK"
  for i in 1 2 3 4 5 6 7 8; do L claim > "$T/out.$i" & done; wait
  k=$(cat "$T"/out.* | command grep -c '^CLAIMED ' || true)
  [ "$k" = 1 ] || rounds_bad=$((rounds_bad + 1))
done
arm A12-concurrent-claim-single-winner "bad_rounds=$rounds_bad" '^bad_rounds=0$'

echo "lifecycle-lease-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
