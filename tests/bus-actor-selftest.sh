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
case " $lanes " in *" rabbot "*) echo "  PASS roster  parsed lanes=[$lanes]";; *) echo "  FAIL roster  did not parse: [$lanes]"; fail=1;; esac
case " $lanes " in *" teague "*) echo "  FAIL roster  addressee leaked into lanes"; fail=1;; *) echo "  PASS roster  addressee is not a lane";; esac

# --- the single-target form ---------------------------------------------------------
y rabbot "augur-to-rabbot-ANSWER-x-2026-09-04.md"
y rabbot "page-to-rabbot-cc-geist-augur-x-2026-09-04.md"
n rabbot "augur-to-geist-cc-rabbot-page-x-2026-09-04.md"          # cc is a READ, not an act
n rabbot "rabbot-to-geist-cc-augur-P1-shipped-2026-09-04.md"      # own outbound
n rabbot "geist-to-page-cc-augur-x-conflict-to-rabbot-2026-09-03.md"  # the name in prose, not the address

# --- the terminated run is a target LIST, an unterminated one is not ------------------
y rabbot "geist-to-page-rabbot-cc-augur-RULINGS-2026-09-02.md"
n page   "rabbot-to-augur-page-loop-died-2026-09-04.md"           # `page` is the subject here
y augur  "rabbot-to-augur-page-loop-died-2026-09-04.md"           # ...and augur is still the target
y rabbot "page-to-cleric-P1-x-2026-09-04.md"                      # alias resolves, P-tag terminates

# --- broadcasts ----------------------------------------------------------------------
y page   "geist-to-all-P2-x-2026-09-04.md"
n geist  "geist-to-all-P2-x-2026-09-04.md"                        # never rebound to its author
n augur  "rabbot-to-geist-P3-broadcast-to-all-x-2026-09-11.md"    # `-to-all-` in the SLUG is prose
y geist  "rabbot-to-geist-P3-broadcast-to-all-x-2026-09-11.md"    # ...the address slot still names geist
n rabbot "notes-2026-09-04.md"                                    # not a comm at all

# --- a date prefix is not the author -------------------------------------------------
n augur  "2026-06-08-augur-to-all-forecast-CONFIRMED.md"          # author excluded from its own broadcast
y page   "2026-06-08-augur-to-all-forecast-CONFIRMED.md"          # ...everyone else still is
y geist  "2026-09-04-page-to-geist-x.md"
n page   "2026-09-04-page-to-geist-x.md"
n rabbot "rabbot-to-all-P2-broadcast-2026-09-03.md"               # undated control

# --- the FYI feed has no actor, and prose about it is not it -------------------------
n page   "2026-09-01-rabbot-to-feed-cc-teague-P1-correction-x.md"
n geist  "rabbot-to-feed-cc-teague-P1-full-tilt-x-2026-09-01.md"
n geist  "rabbot-to-feed-cc-geist-P2-a-comm-about-to-geist-routing-2026-09-15.md"
y geist  "page-to-geist-cc-rabbot-P3-33-claude-to-feed-files-deleted-from-the-log-2026-09-12.md"

# --- an addressee with no lane must not truncate the run -----------------------------
y geist  "augur-to-rabbot-teague-geist-cc-x-2026-09-04.md"
y geist  "rabbot-to-teague-geist-cc-page-augur-P2-admission-2026-09-04.md"
n page   "rabbot-to-teague-geist-cc-page-augur-x-2026-09-04.md"   # cc only, still not
n geist  "rabbot-to-teague-geist-loop-died-2026-09-04.md"         # unterminated: teague alone
y teague "rabbot-to-teague-geist-cc-page-x-2026-09-04.md"

# --- targets: the producer's half of the same grammar --------------------------------
eq "targets sole"        "rabbot"            "$(bash "$A" targets 'augur-to-rabbot-ANSWER-x-2026-09-04.md')"
eq "targets broadcast"   "rabbot page augur" "$(bash "$A" targets 'geist-to-all-P2-x-2026-09-04.md')"
# cc is a READ: the run ends at `-cc-`, so page is not dispatched to. teague owns no lane.
eq "targets run"         "geist"             "$(bash "$A" targets 'rabbot-to-teague-geist-cc-page-P2-x-2026-09-04.md')"
eq "targets two-actor"   "geist page"        "$(bash "$A" targets 'rabbot-to-page-geist-cc-augur-P2-x-2026-09-04.md')"
eq "targets unterminated" "augur"            "$(bash "$A" targets 'rabbot-to-augur-page-loop-died-2026-09-04.md')"
# THE TWO ARMS THAT EXPECT NOTHING need a second channel, because "" is also what a
# script that failed to start prints. eqz asserts rc 0 as well, so "no targets" is
# distinguishable from "no run".
eqz() { # $1 = label, $2... = argv to actor.sh
  local lbl="$1"; shift; local got rc
  got=$(bash "$A" "$@"); rc=$?
  if [ $rc -eq 0 ] && [ -z "$got" ]; then echo "  PASS $lbl -> [] rc=0"
  else echo "  FAIL $lbl want [] rc=0, got [$got] rc=$rc"; fail=1; fi
}
eqz "targets feed"     targets 'rabbot-to-feed-cc-geist-x-2026-09-15.md'
eqz "targets non-comm" targets 'notes-2026-09-04.md'

# --- THE CYCLE INVARIANT -------------------------------------------------------------
# The two halves used to be separate parsers that disagreed, which is how a comm got
# dispatched to a brain that would not stub it. Assert they agree on every fixture here.
for f in "augur-to-rabbot-ANSWER-x-2026-09-04.md" "geist-to-all-P2-x-2026-09-04.md" \
         "rabbot-to-teague-geist-cc-page-P2-x-2026-09-04.md" "rabbot-to-augur-page-loop-died-2026-09-04.md" \
         "geist-to-page-rabbot-cc-augur-RULINGS-2026-09-02.md" "2026-06-08-augur-to-all-forecast-CONFIRMED.md"; do
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
INNKEEPER_PARTY="$alt/party.yaml" bash "$A" is-actor augur "geist-to-page-rabbot-cc-augur-x-2026-09-04.md" \
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
got=$(INNKEEPER_PARTY="$REPO/party.yaml" bash "$A" targets 'rabbot-to-page-geist-cc-augur-P2-x.md'); rc=$?
[ $rc -eq 0 ] && echo "  PASS control  a parsing roster is not refused" || { echo "  FAIL control  refused a good roster rc=$rc"; fail=1; }
rm -rf "$blk"

[ $fail -eq 0 ] && echo "SELFTEST: ALL PASS" || echo "SELFTEST: FAILURES"
exit $fail
