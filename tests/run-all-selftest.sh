#!/usr/bin/env bash
# Battery for tests/run-all.sh. The runner is the thing that decides whether this repo passes,
# so its own failure modes are the ones with nothing behind them to catch a mistake.
# NOTE: run-all.sh excludes this file by name (it matches the glob and would recurse), so it is
# not reached by `bash tests/run-all.sh`. Run it directly.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
RUNNER=${RUNALL_IMPL:-$HERE/run-all.sh}
EXPECT_ARMS=10
T=$(mktemp -d); trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
n=0 pass=0
arm() { n=$((n + 1)); if printf '%s' "$2" | command grep -Eq -- "$3"; then pass=$((pass + 1));
        else echo "FAIL $1: got [$2] want /$3/"; fi; }

mkfix() { # dir, then names:state...
  local d=$1; shift; mkdir -p "$d"
  for spec in "$@"; do
    local name=${spec%%:*} state=${spec#*:}
    case $state in
      green)  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$name-selftest.sh" ;;
      red)    printf '#!/usr/bin/env bash\necho "FAIL X1-the-arm-that-failed"\nexit 1\n' > "$d/$name-selftest.sh" ;;
      # Two reporting styles live in this suite and the runner must read BOTH. 9 of the 22
      # batteries end the line with the verdict ("  W3 the arm — FAIL") instead of leading
      # with it, and a runner keyed on the leading form prints their name and no reason.
      redsuf) printf '#!/usr/bin/env bash\necho "  X2-the-suffix-arm — FAIL"\nexit 1\n' > "$d/$name-selftest.sh" ;;
      cannot) printf '#!/usr/bin/env bash\necho "CANNOT-RUN: the widget is not installed" >&2\nexit 3\n' > "$d/$name-selftest.sh" ;;
      broken) printf '#!/usr/bin/env bash\nif then fi\n' > "$d/$name-selftest.sh" ;;
    esac
  done
}
RUN() { INNKEEPER_TESTS_DIR=$1 INNKEEPER_EXPECT_BATTERIES=$2 bash "$RUNNER" 2>&1; }
RC()  { INNKEEPER_TESTS_DIR=$1 INNKEEPER_EXPECT_BATTERIES=$2 bash "$RUNNER" >/dev/null 2>&1; echo "rc=$?"; }

# R1 is the CONTROL and it comes first: a fixture that is entirely green, with the expected
# count matching, must exit 0. Without it every arm below passes on a runner that always fails.
mkfix "$T/ok" a:green b:green
arm R1-CONTROL-all-green-exits-0      "$(RC "$T/ok" 2)"    '^rc=0$'
arm R1b-CONTROL-and-says-so           "$(RUN "$T/ok" 2)"   'suite: 2/2 batteries green .*red=0 cannot-run=0'

# R2 -- the whole reason this runner exists. The README's old loop discarded exit codes, so a
# red battery in the middle still returned success.
mkfix "$T/red" a:green b:red c:green
arm R2-one-red-battery-fails-the-suite "$(RC "$T/red" 3)"  '^rc=[1-9]'
arm R2b-and-the-failing-arm-is-shown   "$(RUN "$T/red" 3)" 'X1-the-arm-that-failed'

# R2c -- and it is shown for EITHER reporting style. R2b's fixture leads with the verdict;
# 9 of this suite's 22 batteries END with it, and the runner used to match only the leading
# form. The cost is not cosmetic: a red battery printed its name and nothing else, so the
# reason existed and was discarded, and the only way back to it was a hand re-run. That is
# how bin-watchman went red on mirror/watchman with no stated cause on 2026-10-19.
mkfix "$T/reds" a:green b:redsuf
arm R2c-a-suffix-style-reason-is-shown "$(RUN "$T/reds" 2)" 'X2-the-suffix-arm'

# R3 -- THE ARM THAT MATTERS MOST. Every battery present is green; one was deleted. A suite that
# discovers its members by glob is all-green by construction once a file goes missing, so without
# the count in the verdict this is indistinguishable from a pass.
mkfix "$T/short" a:green b:green
arm R3-a-missing-battery-is-not-a-pass "$(RC "$T/short" 3)"  '^rc=[1-9]'
arm R3b-and-the-shortfall-is-visible   "$(RUN "$T/short" 3)" 'suite: 2/2 batteries green \(expected 3\)'

# R4/R5 -- three states. A battery that could not RUN is neither passed nor failed, and its
# reason must reach the reader or an unmet precondition is just an invisible check.
mkfix "$T/cant" a:green b:cannot
arm R4-unmet-precondition-is-its-own-state "$(RUN "$T/cant" 2 | tr "\n" " ")" "CANNOT-RUN +b-selftest\.sh.*the widget is not installed.*cannot-run=1"
mkfix "$T/brk" a:green b:broken
arm R5-a-syntax-error-is-cannot-run        "$(RUN "$T/brk" 2)"  'CANNOT-RUN +b-selftest\.sh'

# R6 -- the self-exclusion must be PRINTED. An exclusion nobody can see is the same as a battery
# that does not exist, which is exactly how a check goes missing without anyone noticing.
cp "$HERE/run-all-selftest.sh" "$T/ok/run-all-selftest.sh" 2>/dev/null || true
arm R6-self-exclusion-is-announced "$(RUN "$T/ok" 2)" 'SKIP +run-all-selftest\.sh'

echo "run-all-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
