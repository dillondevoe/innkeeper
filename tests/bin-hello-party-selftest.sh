#!/usr/bin/env bash
# bin-hello-party-selftest.sh — battery for bin/hello-party.sh, the slice-1 demo.
#
# A demo script is the one thing in this repo a stranger runs FIRST, so its failure mode
# is "the product looks broken." That makes it worth arms, and the arms have to be about
# the CLAIMS the banner makes, not merely about rc=0 -- a script that printed nothing at
# all would exit 0 just as happily.
set -uo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# HELLO_IMPL must sit in a directory whose PARENT holds bus/ and party.yaml: the script
# derives REPO from its own path. A mutant dropped in a bare temp dir dies at "actor.sh
# refused to name the lanes" and every arm reds out identically, which is indistinguishable
# from the mutation being caught. Symlink a tree; do not copy the file somewhere flat.
IMPL="${HELLO_IMPL:-$R/bin/hello-party.sh}"
EXPECT_ARMS=14
n=0; pass=0
ok(){ n=$((n+1)); pass=$((pass+1)); }
bad(){ n=$((n+1)); echo "FAIL $1"; }
chk(){ if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
bash "$IMPL" >"$W/out" 2>"$W/err"; RC=$?
O=$W/out

chk H1-rc "$RC" 0
chk H2-err-empty "$(wc -c <"$W/err" | tr -d ' ')" 0
chk H3-completed "$(command grep -c 'hello-party complete' "$O")" 1

# --- the roster is READ, not hardcoded ---------------------------------------------------
LANES=$(bash "$R/bus/actor.sh" lanes)
# ONE ARM, NOT ONE PER BRAIN. This was a `bad` inside the loop plus an unconditional `ok`
# after it, so every missing brain added an arm: a failing run reported 18 arms against an
# expected 14 and tripped ARM COUNT DRIFT, whose message then buried the real failures. An
# arm whose COUNT depends on the outcome cannot be reconciled against a fixed expectation.
missing=
for b in $LANES; do
  [ "$(command grep -c "^   $b " "$O")" -ge 1 ] || missing="$missing $b"
done
if [ -z "$missing" ]; then ok; else bad "H4-every-lane-heralded: missing$missing"; fi

# --- ORDER. The load-bearing arm, and it needs BOTH halves ------------------------------
# The herald block is step 6. Pull the names it printed, in the order it printed them.
heard=$(sed -n '/6\. The herald speaks/,/^$/p' "$O" | sed -n 's/^   \([a-z][a-z-]*\)  *.*/\1/p' | tr '\n' ' ')
roster=$(printf '%s ' $LANES)
# `tac` is GNU-only, same as the one the demo itself used. Missing it here made `arrival`
# EMPTY, so H6 compared roster against "" and passed, and H7 reported a want of []. The
# control arm was the thing that broke, and it broke into a pass.
arrival=$(printf '%s\n' $LANES | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' | tr '\n' ' ')
[ -n "${arrival// /}" ] || { echo "CANNOT-RUN hello-party-selftest: could not build the arrival order" >&2; exit 3; }
chk H5-herald-is-roster-order "$heard" "$roster"
# THE CONTROL. H5 alone passes if roster order and arrival order happen to coincide -- on
# a four-name roster they would, for any demo that just echoed the directory back. This
# asserts the two orders are ACTUALLY DIFFERENT in this fixture, so H5 discriminates.
if [ "$roster" = "$arrival" ]; then bad "H6-orders-are-distinguishable: the fixture cannot tell roster from arrival"; else ok; fi
# And the brains really did speak in the other order, so H5 is not passing by accident.
spoke=$(sed -n '/3\. Four brains boot/,/^$/p' "$O" | sed -n 's/^   \([a-z][a-z-]*\) wrote .*/\1/p' | tr '\n' ' ')
chk H7-spoke-in-arrival-order "$spoke" "$arrival"

# --- the wiring each step claims ---------------------------------------------------------
chk H8-quest-claimed  "$(command grep -c 'state=claimed lane=page' "$O")" 1
chk H9-quest-done     "$(command grep -c 'state=done' "$O")" 1
nq=$(sed -n 's/.*enqueue: \([0-9]*\) marker.*/\1/p' "$O")
chk H10-one-marker-per-brain "$nq" "$(printf '%s\n' $LANES | wc -l | tr -d ' ')"
chk H11-inbound-acted "$(sed -n 's/.*--- act:\([0-9]*\) .*/\1/p' "$O")" 3
chk H12-no-unroutable "$(sed -n 's/.*unroutable:\([0-9]*\) .*/\1/p' "$O")" 0

# --- it must not leave anything behind, and --keep must ----------------------------------
sb=$(sed -n 's/.*sandbox kept at //p' "$O")
chk H13-default-run-keeps-nothing "$sb" ""
bash "$IMPL" --keep >"$W/out2" 2>/dev/null
kept=$(sed -n 's/.*sandbox kept at //p' "$W/out2")
if [ -n "$kept" ] && [ -d "$kept" ]; then ok; rm -rf "$kept"; else bad "H14-keep-leaves-the-sandbox"; fi

echo "bin-hello-party-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$n" = "$EXPECT_ARMS" ] || { echo "ARM COUNT DRIFT: ran $n, expected $EXPECT_ARMS"; exit 1; }
[ "$pass" = "$n" ]
