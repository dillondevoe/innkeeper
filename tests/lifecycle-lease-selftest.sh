#!/usr/bin/env bash
# lifecycle-lease-selftest.sh — battery for lifecycle/lease.sh. The arm count is part of the verdict.
# LEASE_IMPL overrides the script under test (used to show arms RED against mutations and the source).
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL=${LEASE_IMPL:-$R/lifecycle/lease.sh}
EXPECT_ARMS=${LEASE_NESTED:+18}
EXPECT_ARMS=${EXPECT_ARMS:-21}
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

# ---- THE LAPTOP-SLEEP CASE ----------------------------------------------------------------
# A suspended machine keeps its WALL clock running, so a holder that was frozen for an hour wakes
# with a lease older than any TTL -- and could not renew, because it was frozen. Aging the lease on
# an awake clock (one that excludes suspend) is what separates "the holder is dead" from "the
# machine was asleep". S2 is the control and is the whole point: SAME wall age, SAME boot, opposite
# verdict, and the only thing that differs is the awake clock.
S=$T/sleep; mkdir -p "$S/state"
SL() { INNKEEPER_HOME=$S LEASE_TTL=1800 bash "$IMPL" "$@" 2>/dev/null; }
slept_lock() { echo "$(( $(date +%s) - 3600 )) livenonce ${2:-1000} $1" > "$S/state/tester.lease"; }

slept_lock 99995
arm S1-sleep-does-not-steal-a-live-lane "$(LEASE_AWAKE_S=100000 SL status)" '^HELD age=5 nonce=livenonce$'
arm S1b-and-the-second-instance-stands-down "$(LEASE_AWAKE_S=100000 SL claim)" '^HELD-BY-OTHER age=5$'
arm S2-CONTROL-awake-the-whole-time-is-stale "$(LEASE_AWAKE_S=103600 SL status)" '^STALE age=3605 nonce=livenonce$'
arm S2b-CONTROL-and-the-lane-is-takeable "$(LEASE_AWAKE_S=103600 SL claim)" '^CLAIMED '

# A reboot must still win, and must be decided BEFORE the awake clock: after a reboot the awake
# clock restarts at zero, so a lock from the previous boot can show a tiny awake delta and would
# read as freshly held. That is a live-lane-blocked-forever bug, not a stolen-lane bug.
slept_lock 99995 999
arm S3-reboot-beats-the-awake-clock "$(LEASE_AWAKE_S=100000 SL status)" '^STALE age=[0-9]+ nonce=livenonce \(previous boot\)$'

# A lock written by the OLD three-field code has no awake stamp. It must fall back to the wall
# clock -- the old behaviour, stated -- and must NOT read the missing field as "awake for 0s",
# which would make every legacy lock look infinitely old.
echo "$(( $(date +%s) - 3600 )) livenonce 1000" > "$S/state/tester.lease"
arm S4-legacy-lock-falls-back-to-wall "$(LEASE_AWAKE_S=100000 SL status)" '^STALE age=3600 nonce=livenonce$'

# ---- MUTATION ARMS -------------------------------------------------------------------------
# Mutants are staged INSIDE lifecycle/ even though lease.sh derives no path from its own location.
# bus/merge.sh does, and staging its mutants in a mktemp dir made four arms score the relocation
# instead of the mutation for their whole first life. Keeping one shape everywhere means the next
# script that grows a sibling dependency does not quietly re-open that hole.
if [ -z "${LEASE_NESTED:-}" ]; then
  mut() { # name, sed-program -> name=PASS when the mutant is CAUGHT (battery red)
    local f; f=$(mktemp "$R/lifecycle/.mut-XXXXXX.sh")
    cp "$R/lifecycle/lease.sh" "$f"
    # GNU `sed -i PROG f` and BSD `sed -i SUFFIX PROG f` are DIFFERENT COMMANDS sharing a
  # spelling. On macOS the program is eaten as a backup suffix, the edit never lands, and
  # the mutant comes out byte-identical to the original. The mut() harness caught that
  # honestly -- MUTATION-DID-NOT-APPLY, not a false PASS -- which is why it is worth
  # keeping that third state. Write through a temp file instead; POSIX sed has no -i.
  sed "$2" "$f" >"$f.ed" && mv -f "$f.ed" "$f"
    if cmp -s "$f" "$R/lifecycle/lease.sh"; then echo "$1=MUTATION-DID-NOT-APPLY"; rm -f "$f"; return; fi
    if LEASE_NESTED=1 LEASE_IMPL=$f bash "$0" >/dev/null 2>&1; then echo "$1=FAILED-TO-CATCH"; else echo "$1=PASS"; fi
    rm -f "$f"
  }
  # D0 travels the mutants' exact path with an UNMUTATED copy. Without it every mutation arm passes
  # on a nested runner that fails for any reason at all.
  arm D0-unmutated-control \
    "$(f=$(mktemp "$R/lifecycle/.mut-XXXXXX.sh"); cp "$R/lifecycle/lease.sh" "$f"; \
       LEASE_NESTED=1 LEASE_IMPL=$f bash "$0" >/dev/null 2>&1 && echo GREEN || echo RED; rm -f "$f")" '^GREEN$'
  # D1 -- ignore the awake clock and age on the wall again. This IS the laptop-sleep bug.
  arm D1-wall-clock-regression-is-caught \
    "$(mut D1 's/if \[ -n "\$lawake" \] && \[ -n "\$AWAKE" \]; then/if false; then/')" '^D1=PASS$'
  # D2 -- decide the awake clock BEFORE the reboot check, so a previous-boot lock reads as fresh.
  arm D2-reboot-must-be-decided-first \
    "$(mut D2 's/^  if \[ "\$lboot" != 0 \] && \[ "\$BOOT" != 0 \] && \[ "\$lboot" != "\$BOOT" \]; then$/  if false; then/')" '^D2=PASS$'
fi

echo "lifecycle-lease-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
