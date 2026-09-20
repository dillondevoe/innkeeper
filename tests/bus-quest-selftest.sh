#!/usr/bin/env bash
# bus-quest-selftest.sh — battery for bus/quest.sh.
#
# The dangerous outcome here is not a crash: it is a RECORD A VIEW WILL DRAW HONESTLY AND
# WRONGLY. A quest claimed by a name no brain answers to, an `open` quest still carrying a
# lane, a `done` quest that is still blocked — each renders perfectly and misinforms. So
# every refusal arm asserts BOTH the rc AND that the file on disk was not changed (or not
# created), because a script that refuses by doing nothing satisfies the second on its own;
# and every refusal is paired with a PERMITTING TWIN proving the same path still writes.
#
# Two arms are worth more than the rest:
#   F1  reads the COMMITTED fixture with this script's own reader. The writer and SCHEMA.md
#       §1's published example are then pinned to each other by a program, not by my memory
#       of having written both.
#   P1/P1b  the pre-fix pair for the pipeline-die collapse. P1b runs a scratch copy with the
#       ORIGINAL `... | _write` form and asserts it CREATES the quest while printing the
#       refusal — so P1 is shown to be discriminating, not decorative.
set -u
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL="${QUEST_IMPL:-$R/bus/quest.sh}"
EXPECT_ARMS=53
n=0; pass=0
ok()  { n=$((n+1)); pass=$((pass+1)); }
bad() { n=$((n+1)); echo "FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
Q="$W/quests"
run() { INNKEEPER_QUESTS="$Q" INNKEEPER_PARTY="$R/party.yaml" bash "$IMPL" "$@" >"$W/out" 2>"$W/err"; RC=$?; }
out() { cat "$W/out"; }
err() { cat "$W/err"; }
has() { [ -f "$Q/$1.yaml" ] && echo yes || echo no; }
fld() { run field "$1" "$2"; out; }

# --- creation --------------------------------------------------------------------------
run new hello --title "Say one line each" --brief "Four boot, four lines, one order." --origin gate-to-worker-P2-x-2026-09-20.md
chk A1-new-rc          "$RC" 0
chk A1b-new-file       "$(has hello)" yes
chk A2-state-open      "$(fld hello state)" open
chk A2b-lane-null      "$(fld hello lane)" null
chk A2c-origin-kept    "$(fld hello origin)" "gate-to-worker-P2-x-2026-09-20.md"
chk A2d-deps-empty     "$(fld hello blocked_on)" ""
# The stamps are MACHINE-WRITTEN and there is no flag to supply one. Assert the SHAPE, which
# is the only thing a test can assert about a value it must not be able to control.
case "$(fld hello created)" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ok;;
  *) bad "A3-created-is-utc-stamp";;
esac
run new hello --title X --brief y
chk A4-reuse-refused   "$RC" 1
case "$(err)" in *"never reused"*) ok;; *) bad "A4b-reuse-names-the-reason";; esac
chk A4c-reuse-title-unchanged "$(fld hello title)" "Say one line each"   # the twin below permits
run new hello-two --title X --brief y
chk A5-second-id-permitted "$RC" 0
run new "Bad_ID" --title X --brief y
chk A6-bad-id-rc       "$RC" 1
chk A6b-bad-id-no-file "$(ls "$Q" | command grep -c Bad_ID || true)" 0
run new "-lead" --title X --brief y
chk A6c-leading-dash-rc "$RC" 1

# --- P1: the refusal must not also write (the pipeline-die collapse) ---------------------
run new nobrief --title X
chk P1-no-brief-rc      "$RC" 1
chk P1b-no-brief-no-file "$(has nobrief)" no
# THE PRE-FIX ARM. Without it P1b passes on any script, and cannot show the defect was real.
# The mutant lives beside a REAL actor.sh. A copy in a bare temp dir dies at quest.sh's
# missing-sibling guard, and "it refused" then looks exactly like "the defect is absent" —
# which is what P1d, the control arm, caught on this battery's first run.
mkdir -p "$W/bus"; ln -sf "$R/bus/actor.sh" "$W/bus/actor.sh"
MUT="$W/bus/mutant.sh"
# The ORIGINAL pipeline shape: die on the left of a pipe exits only its own subshell.
python3 - "$IMPL" "$MUT" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
s=s.replace('''      cat "$brieff" > "$btmp"
    elif [ -n "$brief" ]; then printf '%s\\n' "$brief" > "$btmp"
    else die "one of --brief or --brief-file is required"
    fi
    _write "$id" "$title" open null "$(now)" "$origin" "" < "$btmp"''',
'''      cat "$brieff"
    elif [ -n "$brief" ]; then printf '%s\\n' "$brief"
    else die "one of --brief or --brief-file is required"
    fi | _write "$id" "$title" open null "$(now)" "$origin" ""''')
open(sys.argv[2],'w').write(s)
PY
QM="$W/mq"; INNKEEPER_QUESTS="$QM" INNKEEPER_PARTY="$R/party.yaml" bash "$MUT" new nobrief --title X >/dev/null 2>&1
if [ -f "$QM/nobrief.yaml" ]; then ok; else bad "P1c-prefix-arm-must-show-the-defect (mutant did NOT create the quest — the arm is vacuous)"; fi
# ...and the mutant must otherwise still work, or P1c would pass on a mutant that is simply broken.
INNKEEPER_QUESTS="$QM" INNKEEPER_PARTY="$R/party.yaml" bash "$MUT" new fine --title X --brief y >/dev/null 2>&1
chk P1d-mutant-control "$([ -f "$QM/fine.yaml" ] && echo yes || echo no)" yes

# --- claiming: membership, not resolution ------------------------------------------------
run claim hello pge
chk B1-typo-lane-rc      "$RC" 1
# READ err() FIRST. fld() calls run(), which overwrites $W/err — asserting on the message
# after a field read asserts on the LAST command's stderr, and this arm failed that way.
case "$(err)" in *"owns no queue lane"*) ok;; *) bad "B1d-typo-names-the-reason";; esac
chk B1b-typo-lane-state  "$(fld hello state)" open
chk B1c-typo-lane-lane   "$(fld hello lane)" null
# A NON-LANE ROSTER NAME. `patron` is an addressee — a real, resolvable name that owns no
# queue. Without this arm B1 passes on a check that merely spell-checks, and the sentinel
# case SCHEMA.md §1 warns about walks straight through.
# ON ITS OWN QUEST, NOT `hello`. This arm used to reuse `hello`, and a mutation that
# disables the membership check made B1's claim SUCCEED -- so `hello` arrived here already
# claimed and the STEAL guard refused it. B2 stayed green under the exact defect it exists
# to catch: an earlier guard shadowing the branch under test. A fresh, unclaimed quest is
# what makes the refusal attributable, and B2c makes it say which refusal fired.
run new b2-probe --title X --brief y
run claim b2-probe patron
chk B2-addressee-refused "$RC" 1
case "$(err)" in *"owns no queue lane"*) ok;; *) bad "B2c-addressee-names-the-reason";; esac
chk B2b-addressee-lane   "$(fld b2-probe lane)" null
# THE PERMITTING TWINS.
run claim hello worker
chk B3-claim-rc          "$RC" 0
chk B3b-claim-state      "$(fld hello state)" claimed
chk B3c-claim-lane       "$(fld hello lane)" worker
# An ALIAS resolves to the roster name it addresses, and the record stores the resolved one.
run claim hello-two cleric
chk B4-alias-rc          "$RC" 0
chk B4b-alias-stored-resolved "$(fld hello-two lane)" voice
# Idempotent: re-asserting your own hold is state, not an event.
run claim hello worker
chk B5-reclaim-rc        "$RC" 0
case "$(out)" in *already*) ok;; *) bad "B5b-reclaim-says-already";; esac
run claim hello researcher
chk B6-steal-refused     "$RC" 1
chk B6b-steal-lane-kept  "$(fld hello lane)" worker

# --- the state/lane coupling --------------------------------------------------------------
run state hello claimed
chk C1-state-claimed-refused "$RC" 1
case "$(err)" in *"claim <id> <lane>"*) ok;; *) bad "C1b-names-the-verb-to-use";; esac
run state hello open
chk C2-open-clears-lane  "$(fld hello lane)" null
chk C2b-open-state       "$(fld hello state)" open
run state hello nonsense
chk C3-bad-state-rc      "$RC" 1
chk C3b-bad-state-kept   "$(fld hello state)" open

# --- blocking ------------------------------------------------------------------------------
run block hello hello
chk D1-self-block-rc     "$RC" 1
run block hello ghost
chk D2-unknown-dep-rc    "$RC" 1
chk D2b-unknown-dep-deps "$(fld hello blocked_on)" ""
run block hello hello-two
chk D3-block-permitted   "$RC" 0
chk D3b-dep-recorded     "$(fld hello blocked_on)" hello-two
run state hello done
chk D4-done-while-blocked-refused "$RC" 1
chk D4b-state-kept       "$(fld hello state)" open
run unblock hello hello-two
run state hello done
chk D5-done-after-unblock "$RC" 0
chk D5b-state-done       "$(fld hello state)" done

# --- F1: the committed fixture, read by this script's own reader ---------------------------
FQ="$R/fixtures/quests"
fx() { INNKEEPER_QUESTS="$FQ" INNKEEPER_PARTY="$R/party.yaml" bash "$IMPL" field first-light "$1" 2>/dev/null; }
chk F1-fixture-state  "$(fx state)" open
chk F1b-fixture-lane  "$(fx lane)"  null
chk F1c-fixture-id    "$(fx id)"    first-light
case "$(fx brief)" in *"roster order"*) ok;; *) bad "F1d-fixture-brief-block-reads-back";; esac

echo "bus-quest-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$n" = "$EXPECT_ARMS" ] || { echo "ARM COUNT DRIFT: ran $n, expected $EXPECT_ARMS — a guarded arm that vanishes is a byte-identical PASS"; exit 1; }
[ "$pass" = "$n" ]
