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

EXPECT_ARMS=7
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

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
exit $((fails ? 1 : 0))
