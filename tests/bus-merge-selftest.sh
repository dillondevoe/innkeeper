#!/usr/bin/env bash
# bus-merge-selftest.sh — battery for bus/merge.sh. The arm count is part of the verdict.
#
# MERGE_IMPL overrides the script under test, which is how the mutation arms below show the
# exactly-once arms RED against a plausible wrong implementation rather than merely green
# against the right one.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL=${MERGE_IMPL:-$R/bus/merge.sh}
EXPECT_ARMS=${MERGE_NESTED:+23}
EXPECT_ARMS=${EXPECT_ARMS:-26}
T=$(mktemp -d); H15=$(mktemp -d)
trap 'chmod -R u+w "$H15" 2>/dev/null; rm -rf "$T" "$H15"' EXIT
export INNKEEPER_HOME=$T
export INNKEEPER_PARTY=$R/party.yaml
mkdir -p "$T/state" "$T/work"

# Lanes are READ OFF THE ROSTER, never typed. Two reasons: party.yaml promises nothing keys on
# these strings, and a literal roster name beside an address separator is what the port gate
# refuses. A battery that hardcodes them is the first thing to break both.
LANE_A=$(bash "$R/bus/actor.sh" lanes | sed -n 1p)
LANE_B=$(bash "$R/bus/actor.sh" lanes | sed -n 2p)
[ -n "$LANE_A" ] && [ -n "$LANE_B" ] || { echo "FATAL: roster named fewer than two lanes"; exit 2; }

M()  { bash "$IMPL" "$@" 2>/dev/null; }
# Refusals are read with stderr ON. A negative arm that asserts only a non-zero rc passes when the
# script is ABSENT, when a flag is misspelled, or when an earlier guard shadows the branch under
# test -- the red phase of this file had four such arms passing against no implementation at all.
ME() { bash "$IMPL" "$@" 2>&1 >/dev/null; }
n=0 pass=0
arm() { # name, actual, expected-regex
  n=$((n + 1))
  if printf '%s' "$2" | command grep -Eq -- "$3"; then pass=$((pass + 1)); else echo "FAIL $1: got [$2] want /$3/"; fi
}

src_a=$T/work/a.out; printf 'result from the first worker\n' > "$src_a"
src_b=$T/work/b.out; printf 'result from the SECOND worker\n' > "$src_b"

arm M1-unmerged-initially "$(M status q-one)" '^UNMERGED$'

att=$(M begin q-one "$LANE_A")
arm M2-begin-makes-a-dir "$(case "$att" in "ATTEMPT "*) [ -d "${att#ATTEMPT }" ] && echo OK;; esac)" '^OK$'

arm M3-first-commit "$(M commit q-one "$LANE_A" "$src_a")" '^MERGED '
dest=$(M dest q-one)
arm M3b-dest-has-the-bytes "$(cmp -s "$dest" "$src_a" && echo SAME)" '^SAME$'

# THE ARM THE FILE EXISTS FOR. A second worker, with DIFFERENT bytes, must be refused.
arm M4-second-commit-refused "$(M commit q-one "$LANE_B" "$src_b")" '^ALREADY-MERGED '
arm M4b-dest-bytes-unchanged "$(cmp -s "$dest" "$src_a" && echo SAME)" '^SAME$'
arm M4c-exactly-one-artifact "$(ls "$T/state/merged"/q-one.out* 2>/dev/null | wc -l | tr -d ' ')" '^1$'

arm M5-status-names-the-winner "$(M status q-one)" "^MERGED by=$LANE_A at=[0-9]{4}-[0-9]{2}-[0-9]{2}T"

# PERMITTING TWIN for M4. Without it, a merge.sh that answered ALREADY-MERGED to everything
# passes M4, M4b and M4c and would ship.
arm M6-different-quest-still-merges "$(M commit q-two "$LANE_B" "$src_b")" '^MERGED '

# ABSENT and EMPTY are refused, and each refusal asserts BOTH consequences — a script that
# refuses by doing nothing satisfies the second one on its own.
arm M7-missing-source-refused "$(ME commit q-three "$LANE_A" "$T/work/nope.out")" 'no such result file'
arm M7b-missing-source-no-dest "$([ -e "$T/state/merged/q-three.out" ] && echo LEAKED || echo NONE)" '^NONE$'
: > "$T/work/empty.out"
arm M8-empty-source-refused "$(ME commit q-four "$LANE_A" "$T/work/empty.out")" 'empty'
arm M8b-empty-source-no-dest "$([ -e "$T/state/merged/q-four.out" ] && echo LEAKED || echo NONE)" '^NONE$'

# A lane that owns no queue cannot be credited with the work: a merge attributed to a name no
# brain answers to renders in a view exactly like work that was done, and was not.
arm M9-unknown-lane-refused "$(ME commit q-five nobody-here "$src_a")" 'owns no queue lane'
arm M9b-unknown-lane-no-dest "$([ -e "$T/state/merged/q-five.out" ] && echo LEAKED || echo NONE)" '^NONE$'

# THE MURDER CASE, at the level this script owns: a worker killed mid-write leaves a staged
# partial. Partial work must be INVISIBLE — not merged, not half-merged, not discoverable as a
# result by status.
mkdir -p "$T/work/partial"; printf 'half a re' > "$T/work/partial/killed.part"
arm M10-partial-is-not-merged "$(M status q-six)" '^UNMERGED$'

# CONCURRENCY. This is the only arm that tests the property rather than the happy path: eight
# workers commit the same quest at once, over 10 rounds, because a race measured once is a sample.
rounds_bad=0
for r in 1 2 3 4 5 6 7 8 9 10; do
  q="q-race-$r"
  for i in 1 2 3 4 5 6 7 8; do M commit "$q" "$LANE_A" "$src_a" > "$T/out.$i" 2>/dev/null & done; wait
  k=$(cat "$T"/out.* | command grep -c '^MERGED ' || true)
  [ "$k" = 1 ] || rounds_bad=$((rounds_bad + 1))
done
arm M11-concurrent-commit-single-winner "bad_rounds=$rounds_bad" '^bad_rounds=0$'

# VACUITY ARM. Without it every arm above could be passing against a script that is never
# reached — the selftest's own version of an unarmed control.
# Unset INNKEEPER_HOME must REFUSE, not silently target the checkout. Asserted on the message,
# not on rc, because rc alone passes on any refusal including the usage one two lines down.
arm M14-home-required "$(env -u INNKEEPER_HOME bash "$IMPL" status q-one 2>&1 >/dev/null)" 'INNKEEPER_HOME'
arm M14b-nothing-written-to-repo "$([ -e "$R/state/merged" ] && echo LEAKED-INTO-CHECKOUT || echo NONE)" '^NONE$'

arm M12-usage-is-reached "$(M not-a-verb; echo "rc=$?")" 'rc=2'

# CONTROL ARM for M9: the same commit with a ROSTER lane must be permitted, or M9 passes on a
# script that refuses every lane it is given.
# M15 -- ln fails for a reason that is NOT EEXIST, and the destination is genuinely absent.
# This is the ONLY condition that separates the two ln-failure directions, so without it D2
# below is vacuous: it was, and reported PASS for its whole first life. An unwritable state dir
# must be a HARD error, never ALREADY-MERGED -- the permissive reading would tell a caller its
# work is safely merged at the exact moment nothing was written anywhere.
mkdir -p "$H15/state/merged" "$H15/work"
printf 'x' > "$H15/src.part"
chmod a-w "$H15/state/merged"
arm M15-nonexistent-dest-is-a-hard-error \
  "$(INNKEEPER_HOME=$H15 bash "$IMPL" commit q-fifteen "$LANE_A" "$H15/src.part" 2>&1; echo "rc=$?")" \
  'did NOT happen'
arm M15b-and-it-is-not-reported-as-merged \
  "$(INNKEEPER_HOME=$H15 bash "$IMPL" commit q-fifteen "$LANE_A" "$H15/src.part" 2>/dev/null; echo "rc=$?")" \
  '^rc=1$'
chmod u+w "$H15/state/merged"

arm M13-known-lane-permitted "$(M commit q-seven "$LANE_B" "$src_a")" '^MERGED '

# MUTATION ARMS. Every arm above is written from the same reading of the world as merge.sh, so
# green means "consistent with my intent" and nothing more. These two point the battery at
# plausible WRONG implementations and assert it goes RED -- the only evidence that M4/M11 are
# discriminating rather than riding on a happy path.
if [ -z "${MERGE_NESTED:-}" ]; then
  mut() { # name, sed-program -> "name=PASS" if the mutant is CAUGHT (battery red), else FAILED-TO-CATCH
    # The mutant MUST be staged inside bus/: merge.sh resolves actor.sh as "$HERE/actor.sh",
    # so a copy in a mktemp dir dies at its first verb whatever the sed did. That is how D1/D2
    # were vacuous for their whole first life -- they caught the RELOCATION, reporting PASS
    # against an implementation that never ran. D0 could not see it because D0 pointed at the
    # in-repo path and so did not share the mutants' construction: a control that does not
    # travel the mutant's path is not a control. (Review catch, 2026-09-20, before shipping.)
    local f; f=$(mktemp "$R/bus/.mut-XXXXXX.sh")
    cp "$R/bus/merge.sh" "$f"
    sed -i "$2" "$f"
    # A mutation that did not change the file proves the mutator's regex, not the battery.
    if cmp -s "$f" "$R/bus/merge.sh"; then echo "$1=MUTATION-DID-NOT-APPLY"; rm -f "$f"; return; fi
    if MERGE_NESTED=1 MERGE_IMPL=$f bash "$0" >/dev/null 2>&1
      then echo "$1=FAILED-TO-CATCH"; else echo "$1=PASS"; fi
    rm -f "$f"
  }
  # D0 is the control: the UNMUTATED script, run through the same nested path, must stay green.
  # Without it a nested runner that always fails would make every mutation arm pass.
  arm D0-unmutated-control "$(f=$(mktemp "$R/bus/.mut-XXXXXX.sh"); cp "$R/bus/merge.sh" "$f"; MERGE_NESTED=1 MERGE_IMPL=$f bash "$0" >/dev/null 2>&1 && echo GREEN || echo RED; rm -f "$f")" '^GREEN$'
  # `ln -f` is the single most plausible wrong edit here: it makes the commit succeed always, so
  # the second worker silently OVERWRITES the first. Exactly-once becomes last-writer-wins.
  arm D1-ln-force-is-caught "$(mut D1 's/if ln "\$src" "\$d" 2>\/dev\/null; then/if ln -f "$src" "$d" 2>\/dev\/null; then/')" '^D1=PASS$'
  # Collapsing the two ln failure directions: reporting ALREADY-MERGED without checking that the
  # destination is actually there. An unwritable state dir then reads as "someone beat me to it".
  arm D2-eexist-collapse-is-caught "$(mut D2 's/^    if \[ -e "\$d" \]; then$/    if true; then/')" '^D2=PASS$'
fi

echo "bus-merge-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
