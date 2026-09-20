#!/usr/bin/env bash
# bin-murder-quest-selftest.sh — battery for bin/murder-quest.sh, the slice-2 demo.
#
# The demo asserts its own world and exits non-zero when that world is wrong, so a naive battery
# here would be one arm reading rc. That arm is worth almost nothing on its own: it passes
# whenever the demo's OWN checks are vacuous. The arms that carry this file are the mutation
# arms at the bottom, which break the exactly-once guarantee underneath the demo and assert the
# demo NOTICES.
set -uo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
IMPL="${MURDER_IMPL:-$R/bin/murder-quest.sh}"
EXPECT_ARMS=12
n=0; pass=0
ok(){ n=$((n+1)); pass=$((pass+1)); }
bad(){ n=$((n+1)); echo "FAIL $1"; }
chk(){ if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
has(){ if command grep -Eq -- "$3" "$2"; then ok; else bad "$1: no match /$3/"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
bash "$IMPL" >"$W/out" 2>"$W/err"; RC=$?
O=$W/out

chk K1-rc "$RC" 0
# A real SIGKILL leaves a job-control notice on the PARENT's stderr. Silence here is not
# cosmetic: it is the evidence that the notice is being handled rather than leaking into a
# stranger's terminal as an unexplained "Killed".
chk K2-err-empty "$(wc -c <"$W/err" | tr -d ' ')" 0
chk K3-completed "$(command grep -c 'murder-quest complete' "$O")" 1
# NO CHECK MAY HAVE FAILED, and this is asserted on the OUTPUT rather than on rc alone, because
# rc is one bit and this file's whole thesis is that one bit is not enough.
chk K4-no-failed-checks "$(command grep -c 'FAIL' "$O")" 0
# ARM COUNT OF THE DEMO ITSELF. Without it a demo that stopped running half its checks -- an
# early `exit 0`, a guard that shadows act 2 -- still prints "complete" and still exits 0.
# The count is matched against the ESCAPE, not the word: `ok` appears in prose and the check
# marker is colour-wrapped, so a bare grep for "ok" counted 0 here on the first run and would
# have counted noise on the next.
chk K5-every-check-ran "$(command grep -c $'\033\[32mok' "$O")" 15
has K6-act-one-present "$O" 'killed BEFORE it commits'
has K7-act-two-present "$O" 'killed AFTER it commits'
has K8-exactly-once-claimed "$O" 'merged exactly once'

# Names are read off the roster; the demo must not be printing typed ones.
LANES=$(bash "$R/bus/actor.sh" lanes)
A=$(printf '%s\n' $LANES | sed -n 1p)
has K9-first-lane-named "$O" "^   $A claims the quest"

# --- MUTATION ARMS ------------------------------------------------------------------------
# Each points the demo at a merge.sh whose exactly-once property is BROKEN and asserts the demo
# goes red. A mutation that does not change the file proves the mutator's regex, not the battery,
# so that case is reported by name rather than counted as a catch.
mut(){ # name, sed-program
  # The mutant MUST be staged inside bus/: merge.sh finds actor.sh at "$HERE/actor.sh",
  # so a copy in a mktemp dir dies at the first verb no matter what the sed did. That is
  # how D1/D2 were vacuous for their whole first life -- they caught the RELOCATION, and
  # every mutation arm reported PASS against an implementation it never executed. The D0
  # control could not see it because D0 pointed at the in-repo path and so did not share
  # the mutants' construction. A control that does not travel the mutant's path is not a
  # control. (Caught by review, 2026-09-20, before this ever shipped.)
  local f; f=$(mktemp "$R/bus/.mut-XXXXXX.sh")
  cp "$R/bus/merge.sh" "$f"
  sed -i "$2" "$f"
  if cmp -s "$f" "$R/bus/merge.sh"; then echo "$1=MUTATION-DID-NOT-APPLY"; rm -f "$f"; return; fi
  if INNKEEPER_MERGE=$f bash "$IMPL" >/dev/null 2>&1; then echo "$1=FAILED-TO-CATCH"; else echo "$1=PASS"; fi
  rm -f "$f"
}
# D0 — the control. The UNMUTATED merge.sh, injected through the same override, must stay green.
# Without it every mutation arm passes on a demo that fails whenever INNKEEPER_MERGE is set at
# all, which would catch the override and nothing else.
chk D0-override-control "$(f=$(mktemp "$R/bus/.mut-XXXXXX.sh"); cp "$R/bus/merge.sh" "$f"; INNKEEPER_MERGE=$f bash "$IMPL" >/dev/null 2>&1 && echo GREEN || echo RED; rm -f "$f")" GREEN
# D1 — last-writer-wins. `ln -f` always succeeds, so the takeover in act 2 silently overwrites
# the dead worker's finished result. This is the exact defect the slice exists to rule out.
chk D1-ln-force-caught "$(mut D1 's/if ln "\$src" "\$d" 2>\/dev\/null; then/if ln -f "$src" "$d" 2>\/dev\/null; then/')" D1=PASS
# D2 — the partial becomes a result. Dropping the empty/-s guard is not enough on its own, so
# this one lets a zero-byte source through and checks the demo still refuses to call it merged.
# D2 -- the second commit LIES and claims it merged. The empty-guard mutation used to live here
# and was vacuous: the demo never stages a zero-byte result, so that mutant and the real script
# produce byte-identical output. It reported PASS only because the harness relocated it out of
# bus/. Act 2 DOES exercise this branch -- the takeover's commit must come back ALREADY-MERGED --
# so this mutation is one the demo can actually see. (The empty guard is merge.sh's own property
# and is armed there, by M8; demo-level coverage should not be claimed for what the demo never runs.)
chk D2-already-merged-must-not-claim-merged "$(mut D2 's/echo "ALREADY-MERGED \$d by=\${by:-unknown}"/echo "MERGED $d"/')" D2=PASS

echo "bin-murder-quest-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
