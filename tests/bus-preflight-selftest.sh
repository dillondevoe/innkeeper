#!/usr/bin/env bash
# bus-preflight-selftest.sh — battery for bus/preflight.sh
#
# Every refusal arm asserts WHICH rejection fired, not merely that rc was 1. "It failed"
# passes when an earlier guard shadows the branch under test, and this file has five
# distinct ways to return 1 — an arm that only reads the exit code cannot tell them apart
# and would stay green if they collapsed into one.
#
# And it drives report_one (via the real entry point) rather than a resolver, because the
# source tool's two shipped defects both lived in the reporting loop its selftest never
# entered. A check's coverage is decided by its call site.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
PRE="$REPO/bus/preflight.sh"

EXPECT_ARMS=22
fails=0; arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL${2:+ :: $2}"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export INNKEEPER_HOME="$WORK"
export INNKEEPER_PARTY="$WORK/party.yaml"
export INNKEEPER_COMMS="$WORK/comms"
mkdir -p "$WORK/comms"

# The roster dialect must be the REAL one. A fixture that spells the roster in a second
# dialect is the same defect the port exists to remove — and it has already bitten once
# here (an inline `alias:` field on a brain row, which actor.sh never reads, so resolve
# returned the token unchanged and the arm failed for a fixture reason).
cat > "$WORK/party.yaml" <<'YAML'
party:
  name: Test Party
  bus: BUSDIR
brains:
  - { name: rabbot, role: voice,  recycle_after: 12 }
  - { name: geist,  role: gate,   recycle_after: 6 }
  - { name: page,   role: worker, recycle_after: 8 }
addressees: [teague]
aliases:
  - { from: cleric, to: rabbot }
YAML
sed -i "s|BUSDIR|$WORK|" "$WORK/party.yaml"

run() { bash "$PRE" "$@" 2>&1; }          # combined output
rcof() { bash "$PRE" "$@" >/dev/null 2>&1; echo $?; }
comm() { # comm <basename> <frontmatter-lines...>
  local b="$1"; shift
  { echo "---"; for l in "$@"; do echo "$l"; done; echo "---"; echo "body"; } > "$WORK/comms/$b"
}

echo "bus-preflight-selftest:"

# ---- A. the happy path, and its SILENCE is the assertion -------------------------------
comm "geist-to-page-cc-rabbot-P2-a-clean-one-2026-09-20.md" "from: geist" "to: [page]"
out=$(run "$WORK/comms/geist-to-page-cc-rabbot-P2-a-clean-one-2026-09-20.md")
case "$out" in *"DISPATCHES TO: page"*) ok "A1 clean comm dispatches to page";;
  *) bad "A1 clean comm dispatches to page" "$out";; esac
# The dropped-name check must be SILENT here. The source's first cut flagged the subject
# slug of every comm without a -cc-, returning 1 on clean filenames: a check that flags
# everything flags nothing. This arm is the one that catches that regression.
# These two negative arms name the CURRENT strings. They briefly asserted the absence of
# "SILENTLY DROPPED", a label removed when the two causes were split — an absence assertion
# whose target cannot appear passes on anything, including a totally broken report.
case "$out" in *TRUNCATED*|*"NO LANE"*) bad "A2 clean comm reports NO dropped names" "$out";;
  *) ok "A2 clean comm reports NO dropped names";; esac
[ "$(rcof "$WORK/comms/geist-to-page-cc-rabbot-P2-a-clean-one-2026-09-20.md")" = 0 ] \
  && ok "A3 clean comm exits 0" || bad "A3 clean comm exits 0"
# A4: a subject slug containing a NON-roster word that looks like a name must stay silent.
comm "geist-to-page-P2-the-squire-and-the-gate-2026-09-20.md" "from: geist" "to: [page]"
out=$(run "$WORK/comms/geist-to-page-P2-the-squire-and-the-gate-2026-09-20.md")
case "$out" in *TRUNCATED*|*"NO LANE"*) bad "A4 subject words are not dropped names" "$out";;
  *) ok "A4 subject words are not dropped names";; esac

# ---- B. the two silent drop causes — MEASURED here, not assumed from the source --------
# B1/B2 are the arms that corrected this port. They were first written expecting the
# source's behaviour (second actor always dropped) and FAILED, because actor.sh honours a
# whole run of names. The expectation was wrong, not the router.
comm "geist-to-page-rabbot-P2-two-actors-2026-09-20.md" "from: geist" "to: [page, rabbot]"
out=$(run "$WORK/comms/geist-to-page-rabbot-P2-two-actors-2026-09-20.md")
case "$out" in *"DISPATCHES TO: rabbot page"*) ok "B1 a TERMINATED run dispatches to BOTH names";;
  *) bad "B1 a TERMINATED run dispatches to BOTH names" "$out";; esac
case "$out" in *TRUNCATED*|*"NO LANE"*) bad "B2 TWIN: a terminated run reports no drop" "$out";;
  *) ok "B2 TWIN: a terminated run reports no drop";; esac

# B3/B4: UNTERMINATED — "two" is neither a roster name nor a terminator, so the run stops
# there and everything after the first name is truncated away, silently.
comm "geist-to-page-rabbot-two-actors-2026-09-20.md" "from: geist" "to: [page]"
out=$(run "$WORK/comms/geist-to-page-rabbot-two-actors-2026-09-20.md")
case "$out" in *"TRUNCATED"*rabbot*) ok "B3 an UNTERMINATED run reports rabbot truncated";;
  *) bad "B3 an UNTERMINATED run reports rabbot truncated" "$out";; esac
case "$out" in *"DISPATCHES TO: page"*) ok "B4 and the first name still dispatches";;
  *) bad "B4 and the first name still dispatches" "$out";; esac
[ "$(rcof "$WORK/comms/geist-to-page-rabbot-two-actors-2026-09-20.md")" = 1 ] \
  && ok "B5 truncation exits 1" || bad "B5 truncation exits 1"

# B6/B7: NO LANE — a roster addressee who owns no queue. Distinct message, because no
# rename can deliver it and the truncation FIX would send the writer chasing a terminator.
comm "geist-to-page-teague-P2-no-lane-2026-09-20.md" "from: geist" "to: [page]"
out=$(run "$WORK/comms/geist-to-page-teague-P2-no-lane-2026-09-20.md")
case "$out" in *"NO LANE"*teague*) ok "B6 an addressee with no lane is reported NO LANE";;
  *) bad "B6 an addressee with no lane is reported NO LANE" "$out";; esac
case "$out" in *"TRUNCATED"*) bad "B7 NO LANE is not also reported as TRUNCATED" "$out";;
  *) ok "B7 NO LANE is not also reported as TRUNCATED";; esac

# ---- C. direction — routes perfectly, to the wrong end ---------------------------------
comm "geist-to-page-P2-reversed-2026-09-20.md" "from: page" "to: [geist]"
out=$(run "$WORK/comms/geist-to-page-P2-reversed-2026-09-20.md")
case "$out" in *"DIRECTION MISMATCH"*"from:page"*) ok "C1 reversed filename names the mismatch";;
  *) bad "C1 reversed filename names the mismatch" "$out";; esac
[ "$(rcof "$WORK/comms/geist-to-page-P2-reversed-2026-09-20.md")" = 1 ] \
  && ok "C2 direction mismatch exits 1" || bad "C2 direction mismatch exits 1"
# C3 PERMITTING TWIN: same shape, right direction -> the mismatch branch must NOT fire.
# Without this, C1 would still pass if the check fired unconditionally.
comm "page-to-geist-P2-correct-2026-09-20.md" "from: page" "to: [geist]"
out=$(run "$WORK/comms/page-to-geist-P2-correct-2026-09-20.md")
case "$out" in *"DIRECTION MISMATCH"*) bad "C3 TWIN: correct direction does not fire" "$out";;
  *) ok "C3 TWIN: correct direction does not fire";; esac
# C4: from: written as an ALIAS of the filename author is NOT a mismatch. Comparing raw
# strings would report a loss that does not happen — the noisy direction, but still wrong.
comm "rabbot-to-geist-P2-alias-from-2026-09-20.md" "from: cleric" "to: [geist]"
out=$(run "$WORK/comms/rabbot-to-geist-P2-alias-from-2026-09-20.md")
case "$out" in *"DIRECTION MISMATCH"*) bad "C4 alias in from: is not a mismatch" "$out";;
  *) ok "C4 alias in from: is not a mismatch";; esac

# ---- D. the two silent skip paths — assert the NOISE, not the pass ---------------------
# D1/D2: empty from:. In the source this made the predicate false and printed NOTHING, so
# "cannot be checked" and "passed" were byte-identical. The arm is the MESSAGE.
comm "geist-to-page-P2-no-from-2026-09-20.md" "to: [page]"
out=$(run "$WORK/comms/geist-to-page-P2-no-from-2026-09-20.md")
case "$out" in *"DIRECTION CHECK NOT RUN"*"no frontmatter"*) ok "D1 missing from: SAYS the check did not run";;
  *) bad "D1 missing from: SAYS the check did not run" "$out";; esac
[ "$(rcof "$WORK/comms/geist-to-page-P2-no-from-2026-09-20.md")" = 1 ] \
  && ok "D2 missing from: exits 1 (not a silent pass)" || bad "D2 missing from: exits 1"
# D3/D4: the BARE BASENAME is the documented invocation form. In the source it resolved
# against the caller's cwd, so the advertised form was the one that opted out of the
# check. Run from a cwd where the file is NOT present, to prove resolution uses the
# comms dir and not luck.
out=$(cd / && bash "$PRE" "geist-to-page-P2-reversed-2026-09-20.md" 2>&1)
case "$out" in *"DIRECTION MISMATCH"*) ok "D3 bare basename resolves via comms dir (cwd-independent)";;
  *) bad "D3 bare basename resolves via comms dir" "$out";; esac
out=$(cd / && bash "$PRE" "geist-to-page-P2-nonexistent-2026-09-20.md" 2>&1)
case "$out" in *"DIRECTION CHECK NOT RUN"*"no such file"*) ok "D4 a truly missing file SAYS so";;
  *) bad "D4 a truly missing file SAYS so" "$out";; esac

# ---- E. shapes that are not comms ------------------------------------------------------
out=$(run "notes-2026-09-20.md")
case "$out" in *"NOT A ROUTED COMM"*) ok "E1 a name with no -to- is called out";;
  *) bad "E1 a name with no -to- is called out" "$out";; esac
[ "$(rcof "notes-2026-09-20.md")" = 1 ] && ok "E2 non-comm exits 1" || bad "E2 non-comm exits 1"
# E3: addressed to a roster name that owns NO lane -> dispatches to nobody, and says so.
comm "geist-to-teague-P2-no-lane-2026-09-20.md" "from: geist" "to: [teague]"
out=$(run "$WORK/comms/geist-to-teague-P2-no-lane-2026-09-20.md")
case "$out" in *"DISPATCHES TO: NOBODY"*) ok "E3 an addressee with no lane dispatches to nobody";;
  *) bad "E3 an addressee with no lane dispatches to nobody" "$out";; esac

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "bus-preflight-selftest: $((arms-fails))/$arms passed (expected $EXPECT_ARMS arms)"
exit $((fails ? 1 : 0))
