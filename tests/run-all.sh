#!/usr/bin/env bash
# run-all.sh — run every battery and produce ONE verdict with an exit code.
#
# WHY THIS EXISTS. The README told a stranger to run the suite with
#     for t in tests/*-selftest.sh; do bash "$t"; done
# and that loop DISCARDS EVERY EXIT CODE. Its own status is whatever the last battery
# happened to return, so a red battery in the middle scrolls past in a wall of output and
# the command still succeeds. The documented way to check this repo could not fail. Same
# shape as a guard whose result is piped somewhere that drops its status: the check runs,
# the verdict is thrown away, and nothing distinguishes that from passing.
#
# THE BATTERY COUNT IS PART OF THE VERDICT. A suite that discovers its own members by glob
# gets quietly smaller when a file is deleted, renamed, or made unreadable — and a smaller
# suite is all green by construction. EXPECT_BATTERIES is what stops a deletion from
# reading as a pass.
#
# THREE STATES, NOT TWO. A battery that could not be RUN (missing, unreadable, syntax error)
# is not a battery that FAILED and is not a battery that passed. It gets its own verdict,
# because collapsing it into either direction is how a skipped check becomes an invisible one.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
DIR=${INNKEEPER_TESTS_DIR:-$HERE}
EXPECT_BATTERIES=${INNKEEPER_EXPECT_BATTERIES:-20}

# This runner's OWN battery matches the glob, and running it from here would recurse. It is
# excluded by exact name and the exclusion is PRINTED, not silent: an exclusion nobody can see
# is indistinguishable from a battery that does not exist. Run it directly:
#   bash tests/run-all-selftest.sh
SELF_BATTERY=run-all-selftest.sh

green=0 red=0 unrunnable=0 total=0
for t in "$DIR"/*-selftest.sh; do
  [ -e "$t" ] || continue
  b=$(basename "$t")
  if [ "$b" = "$SELF_BATTERY" ]; then
    echo "  SKIP    $b (this runner's own battery — would recurse; run it directly)"
    continue
  fi
  total=$((total + 1))
  if [ ! -r "$t" ] || ! bash -n "$t" 2>/dev/null; then
    printf '  %-9s %s\n' "CANNOT-RUN" "$b"; unrunnable=$((unrunnable + 1)); continue
  fi
  out=$(bash "$t" 2>&1); rc=$?
  # rc 3 is a battery declaring its own PRECONDITION unmet (a missing external tool). That is
  # neither a pass nor a failure of the code under test, so it keeps the third state rather
  # than being folded into either -- and its reason is printed, because an unmet precondition
  # nobody can see is the same as a check that was never written.
  if [ "$rc" = 3 ]; then
    printf '  %-9s %s\n' "CANNOT-RUN" "$b"
    printf '%s\n' "$out" | sed 's/^/            /'
    unrunnable=$((unrunnable + 1)); continue
  fi
  if [ "$rc" = 0 ]; then
    printf '  %-9s %s\n' "GREEN" "$b"; green=$((green + 1))
  else
    printf '  %-9s %s\n' "RED" "$b"; red=$((red + 1))
    printf '%s\n' "$out" | command grep -E '^(FAIL|  FAIL)' | sed 's/^/            /'
  fi
done

echo "suite: $green/$total batteries green (expected $EXPECT_BATTERIES), red=$red cannot-run=$unrunnable"
[ "$red" = 0 ] && [ "$unrunnable" = 0 ] && [ "$total" = "$EXPECT_BATTERIES" ] && [ "$green" = "$EXPECT_BATTERIES" ]
