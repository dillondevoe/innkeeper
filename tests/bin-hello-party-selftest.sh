#!/usr/bin/env bash
# bin-hello-party-selftest.sh — the quest ran, and the INTERESTING parts of it happened.
#
# A battery that only checked rc 0 would pass on a quest where the gate never refused, the
# worker never repaired anything, and the result merged twice -- which is precisely the
# hollow-demo failure this script was built to replace. So every arm below asserts a VERB
# in the transcript, and D1/D2 are the controls: with the gate's refusal defeated, the run
# must FAIL rather than quietly succeed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P); R=$(cd "$HERE/.." && pwd -P)
arms=0; fails=0
EXPECT_ARMS=${INNKEEPER_EXPECT_HP_ARMS:-13}
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL${2:+ :: $2}"; }
arm() { # arm <name> <haystack> <ERE>
  arms=$((arms+1))
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then echo "  $1 — PASS"
  else fails=$((fails+1)); echo "  $1 — FAIL :: wanted /$3/"; fi
}

command -v git >/dev/null 2>&1 || { echo "CANNOT-RUN: git is not installed, and this quest commits to a real repo"; exit 2; }

OUT=$(bash "$R/bin/hello-party.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "A0 the quest exits 0" || bad "A0 the quest exits 0" "rc=$RC"

arm A1-quest-posted        "$OUT" 'state=open'
arm A2-lease-claimed       "$OUT" 'lease: CLAIMED'
arm A3-second-instance-refused "$OUT" 'HELD-BY-OTHER'
arm A4-gate-REFUSED-once   "$OUT" 'NO .*printed NOTHING'
arm A5-refusal-announced   "$OUT" 'REFUSED\. This is the step'
arm A6-worker-repaired     "$OUT" 'gate refused: it printed nothing'
arm A7-gate-passed-after   "$OUT" 'PASS .*prints: [0-9]+\.[0-9]+'
arm A8-merged-once         "$OUT" '^   MERGED '
arm A9-second-merge-refused "$OUT" 'ALREADY-MERGED'
arm A10-voice-spoke        "$OUT" 'The party made 2 commits to get there'

# D1/D2 -- CONTROLS. Defeat the defect the gate exists to catch: make attempt 1 already
# correct. The gate then passes on the first try, and the run MUST die at step 5 rather
# than sail through. Without this, every arm above could be satisfied by a script that
# prints the right words in the right order.
MUT=$(mktemp -d); cp -R "$R"/. "$MUT"/ 2>/dev/null
sed 's/echo \\"\$VERSION\\"/echo \\"0.9.9\\"/' "$R/roles/worker.sh" > "$MUT/roles/worker.sh"
MOUT=$(bash "$MUT/bin/hello-party.sh" 2>&1); MRC=$?
[ "$MRC" != 0 ] && ok "D1 CONTROL a first-try-correct worker FAILS the run" \
                || bad "D1 CONTROL a first-try-correct worker FAILS the run" "rc=$MRC"
printf '%s\n' "$MOUT" | grep -q 'gate PASSED attempt 1' \
  && ok "D2 CONTROL and it says WHY it failed" \
  || bad "D2 CONTROL and it says WHY it failed" "$(printf '%s\n' "$MOUT" | tail -1)"
rm -rf "$MUT"

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "bin-hello-party-selftest: $((arms-fails))/$arms passed (expected $EXPECT_ARMS arms)"
[ "$fails" = 0 ]
