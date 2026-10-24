#!/usr/bin/env bash
# bin-record-quest-selftest.sh — the recorded-quest fixture must not go stale, and the
# replay page must actually be built from it, not from a second hand-typed copy.
#
# bin/record-quest.sh captures bin/hello-party.sh's own stdout into
# fixtures/recorded-quest.json; bin/render-replay.sh turns that fixture into
# replay/index.html. The risk this battery exists for is exactly the one SCHEMA.md names
# for the quest-record doc (see schema-fixture-selftest.sh): a committed artifact quietly
# narrating an OLDER run than the tool it claims to replay, with both files still reading
# fine to a human. --check exists on record-quest.sh for this reason; A4 is the mutation
# control proving --check can actually FAIL, not just pass by construction (same pattern
# as bin-hello-party-selftest.sh's D1/D2 arms).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FIXTURE="$REPO/fixtures/recorded-quest.json"
REPLAY="$REPO/replay/index.html"

EXPECT_ARMS=13
fails=0
arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL"; }

command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 required"; exit 2; }

[ -x "$REPO/bin/record-quest.sh" ] && ok "A0 bin/record-quest.sh exists and is executable" \
  || bad "A0 bin/record-quest.sh missing or not executable"
[ -x "$REPO/bin/render-replay.sh" ] && ok "A1 bin/render-replay.sh exists and is executable" \
  || bad "A1 bin/render-replay.sh missing or not executable"
[ -s "$FIXTURE" ] && ok "A2 fixtures/recorded-quest.json exists and is non-empty" \
  || bad "A2 fixtures/recorded-quest.json missing/empty — run bin/record-quest.sh"
[ -s "$REPLAY" ] && ok "A3 replay/index.html exists and is non-empty" \
  || bad "A3 replay/index.html missing/empty — run bin/render-replay.sh"

if [ ! -s "$FIXTURE" ] || [ ! -s "$REPLAY" ]; then
  echo "ABORT: a substrate is missing; remaining arms would be vacuous."
  echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
  exit 1
fi

# A4: the committed fixture must match a FRESH run's lines, right now, on this checkout.
# This is the live form of the drift this battery exists to catch.
if bash "$REPO/bin/record-quest.sh" --check >/tmp/record-quest-check.$$ 2>&1; then
  ok "A4 committed fixture matches a fresh bin/hello-party.sh run (no drift)"
else
  bad "A4 committed fixture has DRIFTED from a fresh run"
  sed 's/^/    /' /tmp/record-quest-check.$$
fi
rm -f /tmp/record-quest-check.$$

# A4b: HOST PORTABILITY. The fixture was recorded on one host; CI is another, with a different
# temp root ($TMPDIR is /var/folders/.../T/ on macOS, /tmp on Linux). Re-run --check under a
# temp root that is neither, so a fixture that baked in its recorder's temp path fails here on
# EVERY host, not only on the one that differs from the recorder. Pre-fix, main was red in CI
# for exactly this: a Mac-recorded fixture against a Linux run.
ALT_TMP=$(mktemp -d)
if TMPDIR="$ALT_TMP/elsewhere.d" sh -c 'mkdir -p "$TMPDIR" && exec bash "$1" --check' _ "$REPO/bin/record-quest.sh" >"$ALT_TMP/out" 2>&1; then
  ok "A4b fixture matches a fresh run under a different temp root (host-portable)"
else
  bad "A4b fixture depends on the recording host's temp root"
  sed 's/^/    /' "$ALT_TMP/out"
fi
rm -rf "$ALT_TMP"

# A5: MUTATION CONTROL. Copy the repo, change one printed line in hello-party.sh, then run
# --check from the COPY against the ORIGINAL committed fixture. --check must report DRIFT —
# proving a real mismatch is caught, not that the check always passes.
TMPREPO=$(mktemp -d)
trap 'rm -rf "$TMPREPO"' EXIT
cp -R "$REPO"/. "$TMPREPO"/
python3 - "$TMPREPO/bin/hello-party.sh" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().replace("The quest is posted", "The quest is announced")
open(p, "w").write(text)
PY
if grep -q "The quest is announced" "$TMPREPO/bin/hello-party.sh"; then
  if bash "$TMPREPO/bin/record-quest.sh" --check >/tmp/record-quest-mutcheck.$$ 2>&1; then
    bad "A5 MUTATION CONTROL: --check passed against a changed hello-party.sh (should DRIFT)"
    sed 's/^/    /' /tmp/record-quest-mutcheck.$$
  else
    ok "A5 MUTATION CONTROL: a changed hello-party.sh is correctly reported as DRIFT"
  fi
else
  bad "A5 MUTATION CONTROL SETUP: could not patch the copy's hello-party.sh"
fi
rm -f /tmp/record-quest-mutcheck.$$

# A6: the replay page was actually BUILT from the fixture, not hand-typed — same event
# count embedded in the page as the fixture holds, read out of each independently.
python3 - "$FIXTURE" "$REPLAY" <<'PY'
import json, re, sys
fixture = json.load(open(sys.argv[1]))
n_fixture = len(fixture["events"])
html = open(sys.argv[2]).read()
m = re.search(r"const EVENTS = (\[.*?\]);\s*\n", html, re.S)
if not m:
    print("  A6 FAIL: no EVENTS array found embedded in replay/index.html")
    sys.exit(1)
events = json.loads(m.group(1))
if len(events) == n_fixture:
    print("  A6 PASS: replay page embeds all %d fixture events" % n_fixture)
    sys.exit(0)
print("  A6 FAIL: fixture has %d events, replay page embeds %d" % (n_fixture, len(events)))
sys.exit(1)
PY
[ $? -eq 0 ] && arms=$((arms+1)) || { arms=$((arms+1)); fails=$((fails+1)); }

# A7/A7b/A7c: THE NORMALIZATION RULES ARE LIVE, AND THEY FLATTEN THE LEASE AGE.
#
# This is the arm the intermittent red on this battery was missing. lifecycle/lease.sh prints
# a lock's age in WHOLE seconds off an integer awake clock, and hello-party.sh claims the lease
# twice ~26ms apart to show the second instance standing down -- so `age=0` nearly always, and
# `age=1` whenever that pair straddles a one-second rollover. A4 then reported DRIFT with no
# other cause, which is why it was green every time it was run by hand and red occasionally
# inside run-all.sh. Measured both directions against a fake clock (lease.sh takes
# LEASE_UPTIME_FILE): 100.90 -> age=0, 101.05 -> age=1, same lock.
#
# A7 asserts the rule collapses it. A7b is the PRE-FIX arm: it applies the OTHER three rules
# only and asserts the two readings still differ -- without it, A7 would pass on a normalize()
# that returned a constant, and nothing would show the defect was ever real. A7c is the control
# in the other direction: the version number, the commit COUNT and the step numbers are what
# the quest is ASSERTING, so a rule that ate them would be worse than the flake it fixed.
python3 -B - "$REPO/bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import quest_normalize as qn

held0 = "   a second instance of the same worker stands down: HELD-BY-OTHER age=0"
held1 = "   a second instance of the same worker stands down: HELD-BY-OTHER age=1"
fails = 0

if qn.normalize(held0) == qn.normalize(held1) and "age=" in qn.normalize(held0):
    print("  A7 PASS: a lease age of 0 and of 1 normalize to the same line")
else:
    print("  A7 FAIL: the lease age is not flattened — %r vs %r"
          % (qn.normalize(held0), qn.normalize(held1)))
    fails += 1

def without_age(line):
    line = qn.SANDBOX_RE.sub("$TMPDIR/hello-party.SANDBOX", line)
    line = qn.UUID_RE.sub("00000000-0000-0000-0000-000000000000", line)
    return qn.COMMIT_RE.sub("commit SHA", line)

if without_age(held0) != without_age(held1):
    print("  A7b PASS: PRE-FIX arm — without the age rule the same lock reads as drift")
else:
    print("  A7b FAIL: PRE-FIX arm did not fire; this battery cannot show the defect was real")
    fails += 1

load_bearing = [
    "  The tool now answers --version with: 0.1.0",
    "  The party made 2 commits to get there: the gate refused the first one.",
    "   PASS `tool.sh --version` prints: 0.1.0",
]
untouched = [l for l in load_bearing if qn.normalize(l) == l]
if len(untouched) == len(load_bearing):
    print("  A7c PASS: CONTROL — the version, the commit count and the step text are untouched")
else:
    for l in load_bearing:
        if qn.normalize(l) != l:
            print("  A7c FAIL: a rule ate text the quest is asserting: %r -> %r" % (l, qn.normalize(l)))
    fails += 1

sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then arms=$((arms+3)); else arms=$((arms+3)); fails=$((fails+1)); fi

# A8/A8b: THE TWO HALVES ACTUALLY MEET. A7 proves the rule flattens an age and A4 proves the
# committed fixture matches a fresh run -- but both can pass while the rule never reaches the
# recorded line, which is the shape where a unit arm and an integration arm are each green and
# the bug is in the join. So force the boundary crossing in a COPY of the repo (lease.sh made
# to report age+1, i.e. what it prints when the two claims straddle a rollover) and run the
# real `--check` against the real committed fixture.
#
# A8b is the control: the SAME forced copy with the age rule removed must DRIFT. Without it,
# A8 would also pass on a --check that had stopped comparing lines at all.
force_boundary() { # force_boundary <dest> <strip-age-rule:0|1>
  cp -R "$REPO"/. "$1"/
  python3 - "$1/lifecycle/lease.sh" "$1/bin/quest_normalize.py" "$2" <<'PY'
import sys
lease, norm, strip = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(lease).read()
old = 'echo "HELD-BY-OTHER age=$age$(awake_clock_note)"'
if t.count(old) != 1:
    sys.stderr.write("SETUP: expected exactly one HELD-BY-OTHER print, found %d\n" % t.count(old))
    sys.exit(2)
open(lease, "w").write(t.replace(old, 'echo "HELD-BY-OTHER age=$((age+1))$(awake_clock_note)"'))
if strip == "1":
    s = open(norm).read()
    rule = '    line = AGE_RE.sub("age=N", line)\n'
    if rule not in s:
        sys.stderr.write("SETUP: the age rule is not where this arm expects it\n")
        sys.exit(2)
    open(norm, "w").write(s.replace(rule, ""))
PY
}

B8=$(mktemp -d)
if force_boundary "$B8" 0 2>"$B8/setup.err"; then
  if bash "$B8/bin/record-quest.sh" --check >"$B8/out" 2>&1; then
    ok "A8 a run that straddles a one-second lease rollover is NOT drift (end to end)"
  else
    bad "A8 a boundary-crossing run still reports DRIFT — the flake is not fixed on the real path"
    sed 's/^/    /' "$B8/out"
  fi
else
  bad "A8 SETUP: could not force the boundary crossing"; sed 's/^/    /' "$B8/setup.err"
fi
rm -rf "$B8"

B8B=$(mktemp -d)
if force_boundary "$B8B" 1 2>"$B8B/setup.err"; then
  if bash "$B8B/bin/record-quest.sh" --check >"$B8B/out" 2>&1; then
    bad "A8b CONTROL: with the age rule removed a boundary-crossing run passed — --check is inert"
    sed 's/^/    /' "$B8B/out"
  else
    ok "A8b CONTROL: with the age rule removed the same run DOES drift (the defect was real)"
  fi
else
  bad "A8b SETUP: could not force the boundary crossing"; sed 's/^/    /' "$B8B/setup.err"
fi
rm -rf "$B8B"

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
exit $((fails ? 1 : 0))
