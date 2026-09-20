#!/usr/bin/env bash
# bus-actor-selftest.sh — arms for the address grammar in bus/actor.sh.
#
# Every arm below is a real failure the source mesh shipped, retold with this repo's
# example roster. The controls matter as much as the arms: without R0 a roster that
# failed to parse would make every "not an actor" arm pass vacuously, and without the
# permitting arms a predicate that answered NO to everything would look perfect.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
A="$REPO/bus/actor.sh"
export INNKEEPER_PARTY="$REPO/party.yaml"
fail=0
y() { bash "$A" is-actor "$1" "$2" && echo "  PASS actor   $1 <- $2" || { echo "  FAIL want-actor $1 <- $2"; fail=1; }; }
n() { bash "$A" is-actor "$1" "$2" && { echo "  FAIL want-NOT  $1 <- $2"; fail=1; } || echo "  PASS not     $1 <- $2"; }
eq() { # $1 = label, $2 = expected (space-separated), $3... = got lines
  local lbl="$1" want="$2"; shift 2; local got; got=$(echo "$*" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//')
  [ "$got" = "$want" ] && echo "  PASS $lbl -> [$got]" || { echo "  FAIL $lbl want [$want] got [$got]"; fail=1; }
}

echo "bus/actor selftest (roster from $INNKEEPER_PARTY):"

# R0 VACUITY ARM. Every negative arm below is satisfiable by a roster that parsed as
# empty, so assert the parse first. This is the arm that makes the zeroes informative.
lanes=$(bash "$A" roster | sed -n 's/^lanes: *//p')
case " $lanes " in *" voice "*) echo "  PASS roster  parsed lanes=[$lanes]";; *) echo "  FAIL roster  did not parse: [$lanes]"; fail=1;; esac
case " $lanes " in *" patron "*) echo "  FAIL roster  addressee leaked into lanes"; fail=1;; *) echo "  PASS roster  addressee is not a lane";; esac

# --- the single-target form ---------------------------------------------------------
y voice "researcher-to-voice-ANSWER-x-2026-09-04.md"
y voice "worker-to-voice-cc-gate-researcher-x-2026-09-04.md"
n voice "researcher-to-gate-cc-voice-worker-x-2026-09-04.md"          # cc is a READ, not an act
n voice "voice-to-gate-cc-researcher-P1-shipped-2026-09-04.md"      # own outbound
n voice "gate-to-worker-cc-researcher-x-conflict-to-voice-2026-09-03.md"  # the name in prose, not the address

# --- the terminated run is a target LIST, an unterminated one is not ------------------
y voice "gate-to-worker-voice-cc-researcher-RULINGS-2026-09-02.md"
n worker   "voice-to-researcher-worker-loop-died-2026-09-04.md"           # `worker` is the subject here
y researcher  "voice-to-researcher-worker-loop-died-2026-09-04.md"           # ...and researcher is still the target
y voice "worker-to-cleric-P1-x-2026-09-04.md"                      # alias resolves, P-tag terminates

# --- broadcasts ----------------------------------------------------------------------
y worker   "gate-to-all-P2-x-2026-09-04.md"
n gate  "gate-to-all-P2-x-2026-09-04.md"                        # never rebound to its author
n researcher  "voice-to-gate-P3-broadcast-to-all-x-2026-09-11.md"    # `-to-all-` in the SLUG is prose
y gate  "voice-to-gate-P3-broadcast-to-all-x-2026-09-11.md"    # ...the address slot still names gate
n voice "notes-2026-09-04.md"                                    # not a comm at all

# --- a date prefix is not the author -------------------------------------------------
n researcher  "2026-06-08-researcher-to-all-forecast-CONFIRMED.md"          # author excluded from its own broadcast
y worker   "2026-06-08-researcher-to-all-forecast-CONFIRMED.md"          # ...everyone else still is
y gate  "2026-09-04-worker-to-gate-x.md"
n worker   "2026-09-04-worker-to-gate-x.md"
n voice "voice-to-all-P2-broadcast-2026-09-03.md"               # undated control

# --- the FYI feed has no actor, and prose about it is not it -------------------------
n worker   "2026-09-01-voice-to-feed-cc-patron-P1-correction-x.md"
n gate  "voice-to-feed-cc-patron-P1-full-tilt-x-2026-09-01.md"
n gate  "voice-to-feed-cc-gate-P2-a-comm-about-to-gate-routing-2026-09-15.md"
y gate  "worker-to-gate-cc-voice-P3-33-claude-to-feed-files-deleted-from-the-log-2026-09-12.md"

# --- an addressee with no lane must not truncate the run -----------------------------
y gate  "researcher-to-voice-patron-gate-cc-x-2026-09-04.md"
y gate  "voice-to-patron-gate-cc-worker-researcher-P2-admission-2026-09-04.md"
n worker   "voice-to-patron-gate-cc-worker-researcher-x-2026-09-04.md"   # cc only, still not
n gate  "voice-to-patron-gate-loop-died-2026-09-04.md"         # unterminated: patron alone
y patron "voice-to-patron-gate-cc-worker-x-2026-09-04.md"

# --- targets: the producer's half of the same grammar --------------------------------
eq "targets sole"        "voice"            "$(bash "$A" targets 'researcher-to-voice-ANSWER-x-2026-09-04.md')"
eq "targets broadcast"   "voice worker researcher" "$(bash "$A" targets 'gate-to-all-P2-x-2026-09-04.md')"
# cc is a READ: the run ends at `-cc-`, so worker is not dispatched to. patron owns no lane.
eq "targets run"         "gate"             "$(bash "$A" targets 'voice-to-patron-gate-cc-worker-P2-x-2026-09-04.md')"
eq "targets two-actor"   "gate worker"        "$(bash "$A" targets 'voice-to-worker-gate-cc-researcher-P2-x-2026-09-04.md')"
eq "targets unterminated" "researcher"            "$(bash "$A" targets 'voice-to-researcher-worker-loop-died-2026-09-04.md')"
# THE TWO ARMS THAT EXPECT NOTHING need a second channel, because "" is also what a
# script that failed to start prints. eqz asserts rc 0 as well, so "no targets" is
# distinguishable from "no run".
eqz() { # $1 = label, $2... = argv to actor.sh
  local lbl="$1"; shift; local got rc
  got=$(bash "$A" "$@"); rc=$?
  if [ $rc -eq 0 ] && [ -z "$got" ]; then echo "  PASS $lbl -> [] rc=0"
  else echo "  FAIL $lbl want [] rc=0, got [$got] rc=$rc"; fail=1; fi
}
eqz "targets feed"     targets 'voice-to-feed-cc-gate-x-2026-09-15.md'
eqz "targets non-comm" targets 'notes-2026-09-04.md'

# --- THE CYCLE INVARIANT -------------------------------------------------------------
# The two halves used to be separate parsers that disagreed, which is how a comm got
# dispatched to a brain that would not stub it. Assert they agree on every fixture here.
for f in "researcher-to-voice-ANSWER-x-2026-09-04.md" "gate-to-all-P2-x-2026-09-04.md" \
         "voice-to-patron-gate-cc-worker-P2-x-2026-09-04.md" "voice-to-researcher-worker-loop-died-2026-09-04.md" \
         "gate-to-worker-voice-cc-researcher-RULINGS-2026-09-02.md" "2026-06-08-researcher-to-all-forecast-CONFIRMED.md"; do
  for b in $(bash "$A" targets "$f"); do
    bash "$A" is-actor "$b" "$f" || { echo "  FAIL cycle    dispatched to $b who is not an actor on $f"; fail=1; }
  done
done
echo "  PASS cycle   every dispatch target is an actor"

# --- CONTROL: the roster is really the source ----------------------------------------
# Without this arm, actor.sh could carry a hardcoded name list and pass everything above.
alt=$(mktemp -d)
cat > "$alt/party.yaml" <<'YAML'
brains:
  - { name: alfa, role: voice }
  - { name: bravo, role: worker }
addressees: [charlie]
YAML
INNKEEPER_PARTY="$alt/party.yaml" bash "$A" is-actor bravo "alfa-to-bravo-x-2026-09-04.md" \
  && echo "  PASS control alternate roster resolves its own names" \
  || { echo "  FAIL control alternate roster did not resolve"; fail=1; }
# A run is parsed only out of roster tokens, so under a roster that has never heard of
# these names it stops at the first one and the cc'd brain is not reached. (The FIRST
# token is accepted unconditionally by design, so the arm has to test a later one.)
INNKEEPER_PARTY="$alt/party.yaml" bash "$A" is-actor researcher "gate-to-worker-voice-cc-researcher-x-2026-09-04.md" \
  && { echo "  FAIL control a run parsed under a roster that omits its names"; fail=1; } \
  || echo "  PASS control names absent from the roster do not parse a run"
eq "control targets" "bravo" "$(INNKEEPER_PARTY="$alt/party.yaml" bash "$A" targets 'alfa-to-all-P2-x.md')"
rm -rf "$alt"

# --- the roster must FAIL CLOSED, not parse as empty --------------------------------
# The silent-empty roster is the one input that satisfies every negative arm above at
# once, and R0 cannot see it: R0 runs against the repo's own party.yaml, so it proves
# only that THAT file parses. These arms drive the parse to empty three ways a real
# deployment can — an absent file, a misnamed one, and block-style YAML the sed shapes
# do not accept — and assert a refusal on each, on BOTH verbs.
refuses() { # $1 = label, $2 = party path, $3... = argv
  local lbl="$1" party="$2"; shift 2; local got rc
  got=$(INNKEEPER_PARTY="$party" bash "$A" "$@" 2>&1); rc=$?
  if [ $rc -eq 2 ] && printf '%s' "$got" | grep -q 'roster empty'; then echo "  PASS $lbl refused rc=2"
  else echo "  FAIL $lbl want rc=2 + 'roster empty', got rc=$rc [$got]"; fail=1; fi
}
blk=$(mktemp -d)
printf 'brains:\n  - name: alfa\n    role: voice\n' > "$blk/block.yaml"
refuses "no party file / targets"  "$blk/nope.yaml"  targets  'alfa-to-bravo-cc-charlie-P2-x.md'
refuses "no party file / is-actor" "$blk/nope.yaml"  is-actor bravo 'alfa-to-bravo-cc-charlie-P2-x.md'
refuses "block-style / targets"    "$blk/block.yaml" targets  'alfa-to-bravo-cc-charlie-P2-x.md'
# CONTROL: the same three calls against a roster that DOES parse must not refuse, or
# the arms above would pass on a script that refuses unconditionally.
got=$(INNKEEPER_PARTY="$REPO/party.yaml" bash "$A" targets 'voice-to-worker-gate-cc-researcher-P2-x.md'); rc=$?
[ $rc -eq 0 ] && echo "  PASS control  a parsing roster is not refused" || { echo "  FAIL control  refused a good roster rc=$rc"; fail=1; }
rm -rf "$blk"

# --- the three verbs the lifecycle scripts consume: resolve / field / list -----------
# These exist so that ticks.sh and recycle.sh never parse party.yaml themselves. That is
# the whole point: a second reader of the roster is the defect the port removes, so these
# arms are the contract that keeps the second reader from being written again.
eq "resolve alias"     "voice" "$(bash "$A" resolve cleric)"
eq "resolve canonical" "gate"  "$(bash "$A" resolve gate)"
# An unknown token resolves to ITSELF and exits 0. It must not become empty: ticks.sh
# names a state file after this value, and an empty one writes .json at the store root.
eq "resolve unknown is identity" "nosuchbrain" "$(bash "$A" resolve nosuchbrain)"
eq "field recycle_after" "12" "$(bash "$A" field voice recycle_after)"
# field takes the ALIAS too, or the caller has to resolve first and we are back to two
# readers spelling one rule.
eq "field via alias"     "12" "$(bash "$A" field cleric recycle_after)"
# An absent key is rc 1 AND empty — not rc 0 with empty output. ticks.sh branches on the
# rc to fall back to its built-in threshold; a silent empty would make that fallback
# unreachable and every brain's threshold would come out as the default.
got=$(bash "$A" field gate nosuchkey 2>/dev/null); rc=$?
[ $rc -eq 1 ] && [ -z "$got" ] && echo "  PASS field absent key rc=1 empty" \
  || { echo "  FAIL field absent key want rc=1+empty, got rc=$rc [$got]"; fail=1; }
# CONTROL for that arm: a key that IS present must return rc 0, or the arm above passes
# on a verb that fails for everything.
bash "$A" field gate recycle_after >/dev/null 2>&1 \
  && echo "  PASS control field present key rc=0" \
  || { echo "  FAIL control field present key did not return rc=0"; fail=1; }
# list reads a flow list; launchers is the one recycle.sh consumes.
bash "$A" list launchers | grep -q 'start-' \
  && echo "  PASS list launchers yields a glob" \
  || { echo "  FAIL list launchers yielded nothing"; fail=1; }
eq "list of an absent key is empty" "" "$(bash "$A" list nosuchlist)"

[ $fail -eq 0 ] && echo "SELFTEST: ALL PASS" || echo "SELFTEST: FAILURES"
exit $fail
