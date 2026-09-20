#!/usr/bin/env bash
# lifecycle-ticks-selftest.sh — arms for lifecycle/ticks.sh. The arm count is part of the
# verdict: a guarded arm that vanishes into a byte-identical PASS is how coverage is lost.
# TICKS_IMPL overrides the script under test (used to show arms RED against a mutation).
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL=${TICKS_IMPL:-$R/lifecycle/ticks.sh}
EXPECT_ARMS=26
export INNKEEPER_PARTY="$R/party.yaml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Its OWN empty comms dir, planted rather than inherited: absence is a fixture too, and an
# arm that relies on "no earlier arm wrote one" asserts against its neighbour, not its input.
EMPTY=$(mktemp -d)
n=0 pass=0
arm() { # name, actual, expected-regex
  n=$((n + 1))
  if printf '%s' "$2" | command grep -Eq -- "$3"; then pass=$((pass + 1)); else echo "FAIL $1: got [$2] want /$3/"; fi
}
armrc() { # name, actual-rc, expected-rc
  n=$((n + 1))
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else echo "FAIL $1: rc=$2 want $3"; fi
}
K() { # fresh store dir
  local d; d=$T/store.$1; rm -rf "$d"; mkdir -p "$d"; echo "$d"
}
TK() { TICKS_DIR="$1" TICKS_COMMS_DIR="${CD:-$EMPTY}" bash "$IMPL" "${@:2}"; }
plant() { python3 -c 'import json,sys; json.dump(json.loads(sys.argv[2]), open(sys.argv[1],"w"))' "$1" "$2"; }
ship() { # comms-dir, filename, hours-ago
  local p=$1/$2; : > "$p"
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*3600; os.utime(sys.argv[1],(t,t))' "$p" "$3"
}
zstamp() { python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

# --- counting -----------------------------------------------------------------------
d=$(K a)
arm A1-absent-first-tick "$(TK "$d" gate tick)" 'ticks_since_boot=1/6'
# A2 CONTROL. The defect this script exists for is a counter NOTHING increments, which
# reads as "never due" forever. Assert the count MOVES, or every threshold arm below is
# satisfied by a writer that always says 1.
arm A2-control-tick-moves "$(TK "$d" gate tick)" 'ticks_since_boot=2/6'

# --- threshold comes from the ROSTER, not a table inside the script -------------------
d=$(K b)
arm A3-threshold-per-brain-6 "$(TK "$d" gate tick)"  'gate ticks_since_boot=1/6'
arm A4-threshold-per-brain-12 "$(TK "$d" voice tick)" 'voice ticks_since_boot=1/12'
arm A5-unknown-brain-default "$(TK "$d" stranger tick 2>&1)" 'no recycle_after.*default 8'

# A6 ALIAS. An alias must not open a SECOND counter file: one brain under two spellings
# accrues two counts and neither reaches threshold. This arm is the defect the first cut
# of the script actually shipped, caught by running it rather than by reading it.
d=$(K c)
TK "$d" cleric tick >/dev/null
arm A6-alias-one-counter "$(ls "$d")" '^voice\.json$'

# --- fail directions ------------------------------------------------------------------
d=$(K d)
plant "$d/gate.json" '{"ticks_since_boot": "eight"}'
out=$(TK "$d" gate tick 2>&1)
arm A7-unusable-fails-toward-recycle "$out" 'unusable.*threshold 6'
arm A7b-unusable-lands-at-threshold "$out" 'ticks_since_boot=6/6.*RECYCLE DUE'
d=$(K e); printf '{not json' > "$d/gate.json"
out=$(TK "$d" gate tick 2>&1); rc=$?
armrc A8-corrupt-rc4 "$rc" 4
arm A8b-corrupt-not-overwritten "$(cat "$d/gate.json")" '^\{not json$'
# A9 absent file is NEVER TICKED, never a silent 0: a writer that never landed and a brain
# that just recycled are different states and must not print alike.
d=$(K f)
arm A9-absent-never-ticked "$(TK "$d" gate status)" 'NEVER TICKED'
TK "$d" gate due >/dev/null; armrc A9b-absent-not-due "$?" 1

# --- due, both directions (the permitting twin) ---------------------------------------
d=$(K g); plant "$d/gate.json" '{"ticks_since_boot": 6}'
TK "$d" gate due >/dev/null; armrc A10-due-at-threshold "$?" 0
d=$(K h); plant "$d/gate.json" '{"ticks_since_boot": 5}'
TK "$d" gate due >/dev/null; armrc A10b-control-below-threshold "$?" 1

# --- reset ----------------------------------------------------------------------------
d=$(K i); plant "$d/gate.json" '{"ticks_since_boot": 9, "note": "keep me"}'
arm A11-reset-reports-displaced "$(TK "$d" gate reset)" 'reset 0/6 displaced=9'
arm A11b-reset-preserves-other-keys "$(cat "$d/gate.json" | tr -d ' \n')" '"note":"keepme"'

# --- status --all walks the ROSTER, not the files that exist --------------------------
d=$(K j); TK "$d" gate tick >/dev/null
out=$(TK "$d" x status --all 2>/dev/null)
arm A12-all-lists-ticked "$out" 'gate ticks_since_boot=1/6'
arm A12b-all-names-untouched-brains "$out" 'worker NEVER TICKED'

# --- drift (the idle anchor) ------------------------------------------------------------
CD=$(mktemp -d)
d=$(K k); ship "$CD" "gate-to-voice-x-2026-09-04.md" 5
plant "$d/gate.json" "{\"ticks_since_boot\": 3, \"last_reset\": \"$(zstamp 9)\"}"
out=$(TK "$d" gate drift); rc=$?
arm A13-drift-due "$out" 'DRIFT DUE'
armrc A13b-drift-rc0-means-DUE "$rc" 0
# A14 CONTROL: the identical world with too few ticks must NOT be due, or A13 passes on a
# predicate that says yes to everything.
d=$(K l); plant "$d/gate.json" "{\"ticks_since_boot\": 2, \"last_reset\": \"$(zstamp 9)\"}"
TK "$d" gate drift >/dev/null; armrc A14-control-few-ticks-not-due "$?" 1
# A15 a young session cannot have drifted: the anchor survives a recycle, the count does not.
d=$(K m); plant "$d/gate.json" "{\"ticks_since_boot\": 3, \"last_reset\": \"$(zstamp 1.5)\"}"
TK "$d" gate drift >/dev/null; armrc A15-young-session-not-due "$?" 1
# A16 absent last_reset does NOT bind the age conjunct...
d=$(K n); plant "$d/gate.json" '{"ticks_since_boot": 3}'
TK "$d" gate drift >/dev/null; armrc A16-absent-age-does-not-bind "$?" 0
# A17 ...while an absent ANCHOR does withhold. Two UNRECORDEDs, opposite binding rules, and
# both fail away from a wrong recycle. An arm each, so a later "consistency" fix shows red.
d=$(K o); CD=$EMPTY; plant "$d/gate.json" "{\"ticks_since_boot\": 5, \"last_reset\": \"$(zstamp 9)\"}"
out=$(TK "$d" gate drift); rc=$?
arm A17-absent-anchor-unrecorded "$out" 'ship_idle=UNRECORDED'
armrc A17b-absent-anchor-not-due "$rc" 1
# A18 the anchor regex is ANCHORED: `<b>-to-` mid-string is another brain's comm, and a
# loose glob would adopt it as this brain's newest ship.
CD=$(mktemp -d); d=$(K p)
ship "$CD" "voice-to-worker-RULED-gate-to-researcher-x-2026-09-04.md" 0.5
plant "$d/gate.json" "{\"ticks_since_boot\": 5, \"last_reset\": \"$(zstamp 9)\"}"
arm A18-midstring-is-not-an-outbound "$(TK "$d" gate drift)" 'ship_idle=UNRECORDED'

CD=$EMPTY
echo "lifecycle-ticks-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
