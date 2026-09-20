#!/usr/bin/env bash
# bus-dispose-selftest.sh — battery for bus/dispose.sh.
#
# The dangerous outcome here is not a crash, it is a CLOSE THAT SHOULD NOT HAVE HAPPENED:
# a bystander's stub disarms the actor's summons and the comm dies silently. So every
# refusal arm asserts all THREE consequences — rc, no stub, no ledger row — because a
# script that refuses by doing nothing at all satisfies the last two on its own, and each
# refusal is paired with a PERMITTING TWIN that proves the same path can still close.
set -u
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL="${DISPOSE_IMPL:-$R/bus/dispose.sh}"
EXPECT_ARMS=28
n=0; pass=0
ok()  { n=$((n+1)); pass=$((pass+1)); }
bad() { n=$((n+1)); echo "FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CD="$W/comms"; mkdir -p "$CD"
run() { TICKS_COMMS_DIR="$CD" INNKEEPER_PARTY="$R/party.yaml" bash "$IMPL" "$@" >"$W/out" 2>"$W/err"; RC=$?; }
stub()  { [ -f "$CD/_done/$1" ] && echo yes || echo no; }
rows()  { command grep -c . "$CD/_done/.ledger/$1.log" 2>/dev/null || echo 0; }
mk()    { : > "$CD/$1"; }

# Names built from the repo's own roster, so the grammar under test is the real one.
A_RUN="gate-to-voice-worker-cc-researcher-P2-x-2026-09-20.md"   # voice + worker are actors
A_ONE="gate-to-voice-x-2026-09-20.md"                    # single-target form
A_CAST="gate-to-all-P2-x-2026-09-20.md"                   # broadcast: every lane but the author
mk "$A_RUN"; mk "$A_ONE"; mk "$A_CAST"

# --- the actor guard, both directions --------------------------------------------------
run researcher "$A_RUN"
chk D1-cc-only-rc          "$RC" 1
chk D1b-cc-only-no-stub    "$(stub "$A_RUN")" no
chk D1c-cc-only-no-row     "$(rows researcher)" 0
case "$(cat "$W/err")" in *"not the filename actor"*) ok;; *) bad "D1d-cc-only-names-the-reason";; esac
# THE TWIN. Without it, D1b/D1c are also green for a script that exits before doing anything.
run voice "$A_RUN"
chk D2-actor-in-run-rc     "$RC" 0
chk D2b-actor-stubs        "$(stub "$A_RUN")" yes
chk D2c-actor-rows         "$(rows voice)" 1
# The stub is CONTROL FLOW and must stay zero-byte: a reader tells a stub from a moved-in
# comm by size, so content here would make a closed comm look like a delivered one.
chk D2d-stub-is-zero-byte  "$(wc -c < "$CD/_done/$A_RUN" | tr -d ' ')" 0
# The ledger names the author — the whole reason it is separate from the stub.
case "$(cat "$CD/_done/.ledger/voice.log")" in *voice*"$A_RUN"*) ok;; *) bad "D2e-row-names-brain-and-comm";; esac

run worker "$A_ONE"    # single-target form: only the FIRST token is the actor
chk D3-nonactor-single-form-rc   "$RC" 1
chk D3b-nonactor-single-no-stub  "$(stub "$A_ONE")" no
run voice "$A_ONE"
chk D3c-twin-first-token-closes  "$RC" 0

# --- the author of a broadcast is not its actor -----------------------------------------
run gate "$A_CAST"
chk D4-own-broadcast-rc          "$RC" 1
chk D4b-own-broadcast-no-stub    "$(stub "$A_CAST")" no
run worker "$A_CAST"
chk D4c-twin-other-lane-closes   "$RC" 0

# --- the typo guard ---------------------------------------------------------------------
run voice "gate-to-voice-MISPELT-2026-09-20.md"
chk D5-typo-rc                   "$RC" 1
chk D5b-typo-writes-no-stub      "$(ls "$CD/_done" | command grep -c MISPELT)" 0
case "$(cat "$W/err")" in *"no such comm"*) ok;; *) bad "D5c-typo-names-the-reason";; esac
# A comm already MOVED into _done must still be closable — the guard checks both places, or
# a second disposal of a legitimately-closed comm would read as a typo.
T2="gate-to-voice-already-moved-2026-09-20.md"; mkdir -p "$CD/_done"; : > "$CD/_done/$T2"
run voice "$T2"
chk D5d-twin-found-in-done       "$RC" 0

# --- --force leaves evidence -------------------------------------------------------------
F="gate-to-voice-cc-researcher-P2-forced-2026-09-20.md"; mk "$F"
run --force researcher "$F"
chk D6-force-rc                  "$RC" 0
chk D6b-force-stubs              "$(stub "$F")" yes
case "$(cat "$CD/_done/.ledger/researcher.log")" in *"FORCED(non-actor)"*) ok;; *) bad "D6c-force-row-is-tagged";; esac
# CONTROL: a legitimate actor's row must NOT carry the tag, or D6c passes on a script that
# tags every row and the exception stops being distinguishable.
case "$(cat "$CD/_done/.ledger/voice.log")" in *FORCED*) bad "D6d-control-actor-row-untagged";; *) ok;; esac

# --- refusals that are not about authorship ----------------------------------------------
run voice "notamarkdownfile"
chk D7-non-md-rc                 "$RC" 1
# An unreadable roster must FAIL, not degrade into "nobody is the actor" — which would
# refuse a whole sweep for a reason that has nothing to do with who the actor is.
TICKS_COMMS_DIR="$CD" INNKEEPER_PARTY="$W/nope.yaml" bash "$IMPL" voice "$A_ONE" >/dev/null 2>"$W/err"; RC=$?
chk D8-empty-roster-rc-2         "$RC" 2
case "$(cat "$W/err")" in *"roster unreadable"*) ok;; *) bad "D8b-empty-roster-names-the-reason";; esac

# --- a batch reports the worst rc but still does the work it may ---------------------------
B="gate-to-worker-cc-researcher-P2-batch-2026-09-20.md"; mk "$B"
run worker "$B" "gate-to-worker-NOSUCH-2026-09-20.md"
chk D9-batch-rc-is-worst         "$RC" 1
chk D9b-batch-still-closed-good  "$(stub "$B")" yes

if [ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]; then
  echo "bus-dispose-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"; exit 0
fi
echo "bus-dispose-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"; exit 1
