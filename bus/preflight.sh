#!/usr/bin/env bash
# preflight.sh <path-or-basename> [...] — WHO WILL ACTUALLY RECEIVE THIS COMM?
#
#   preflight.sh draft.md              report on one draft; rc 1 on any finding
#   preflight.sh a.md b.md             several; rc 1 if ANY had a finding
#   preflight.sh --selftest
#
# WHY THIS EXISTS. A name in the filename that is not dispatched is not REJECTED — it is
# never a candidate. No warning, no log line, no unroutable bucket. In the source mesh
# three brains each lost a handful of comms to this in a week, and one party had four asks
# sit unread for five days.
#
# BUT THE CAUSE HERE IS NOT THE CAUSE THERE, AND THE DIFFERENCE WAS MEASURED, NOT ASSUMED.
# The source's router took the FIRST name after `-to-` and only ever that one, so a second
# actor was always dropped. `bus/actor.sh targets` honours a whole RUN of names. Writing
# this port from the source's premise would have produced a tool that warns about a defect
# this router does not have — the warning would be wrong in the confident direction, and a
# false warning about silent loss is worse than none, because it trains the reader to
# discount the true ones. The selftest arm asserting a two-actor name DISPATCHES TO BOTH is
# what caught it; it was written expecting the opposite.
#
# The two ways a name really is dropped here, both silent, both with different fixes:
#   TRUNCATED — the run of names is kept only when it ends at a recognised terminator
#               (`cc`, or a priority token). An unterminated run keeps the FIRST name
#               only: a name like `<a>-to-<b>-<c>-subject-...` reaches <b> and never <c>.
#               Spelled with placeholders on purpose: the port gate forbids an address
#               construction in this directory, and an EXAMPLE of the grammar is
#               indistinguishable from a use of it to a byte scanner. The selftest carries
#               the concrete one, where the roster is a fixture.
#   NO LANE   — a roster addressee who owns no queue. Nothing polls for them, so no
#               marker can be written no matter how the name is spelled.
#
# WHAT THIS PORT DELIBERATELY DOES NOT DO, AND IT IS THE WHOLE POINT.
# The source of this tool re-implemented its router's address parsing, and said so in its
# own header: "a second implementation of a router is a MAP, and routing on a map is
# exactly the error this file exists to prevent." It carried that hazard because its
# router had no --explain mode and was not its file to change.
#
# That constraint does not exist here. `bus/actor.sh targets` IS the dispatcher's parser,
# so this file ASKS IT and owns no grammar of its own. Porting the mirroring along with
# the lesson would have reproduced the defect while quoting the warning about it.
#
# So the value added here is only what the router cannot answer by construction:
#   DROPPED NAMES  — who is named in the filename and still gets nothing.
#   DIRECTION      — a filename can be wrong in its DIRECTION, not just its names, and a
#                    reversed one routes PERFECTLY, to the wrong end. A "who receives
#                    this?" check is structurally blind to it; frontmatter is the second
#                    witness. This is the one check here that needs the file to exist.
#
# A CHECK THAT CANNOT RUN MUST SAY SO — rc 1, never silence. The source shipped two silent
# skip paths at once: a bare filename resolved against the caller's cwd (so the DOCUMENTED
# invocation form was the one that opted out), and an empty `from:` made the mismatch
# predicate false and printed nothing — "cannot be checked" and "passed" were byte-identical
# output. Both are represented in the selftest as arms that assert the NOISE, not the pass.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$HERE/actor.sh"
PARTY=${INNKEEPER_PARTY:-${INNKEEPER_HOME:-$REPO}/party.yaml}
export INNKEEPER_PARTY="$PARTY"

# The bus path comes from `actor.sh bus` — the ONE roster reader. This file used to carry
# its own copy of that sed; so did two others, and all three silently defaulted to a local
# `bus/` when the roster was unreadable. actor.sh refuses instead.
#
# THE RC IS CONSUMED AT THE ASSIGNMENT, NOT INSIDE A HELPER. A helper that `exit`s on
# refusal exits only the command-substitution SUBSHELL: the caller gets the empty string,
# runs on, and the first thing it does with an empty $BUS is `mkdir -p /queues`. That is
# the same collapse of "it refused" into "it answered empty" that this repo's roster guard
# was written for, and the first version of this very comment shipped above code that
# committed it.
if [ -n "${INNKEEPER_COMMS:-}" ]; then COMMS=$INNKEEPER_COMMS
else
  _b=$(bash "$ACTOR" bus) || { echo "FATAL: actor.sh refused to name the bus (unreadable roster?)" >&2; exit 2; }
  [ -n "$_b" ] || { echo "FATAL: actor.sh named an empty bus path" >&2; exit 2; }
  COMMS=$_b/comms
fi

# Every roster name that may be ADDRESSED, so a dropped-name check can tell a brain from a
# subject word. Read through actor.sh; this script never opens party.yaml for names.
# TWO -e EXPRESSIONS, NOT `\(a\|b\)`. GNU sed accepts `\|` as alternation in a BASIC regex;
# BSD sed (macOS) does not -- it matches a literal bar, so this produced NOTHING there. Every
# token then failed the `known_names | grep -qx` test on line 124 and was skipped as a subject
# word, which disabled the TRUNCATED and NO LANE checks ENTIRELY. Three arms went red together
# and pointed at three different symptoms; the cause was one regex dialect. Note the direction:
# an empty roster makes this gate report CLEAN on everything, so on macOS it failed open.
known_names() { bash "$ACTOR" roster 2>/dev/null \
  | sed -n -e 's/^lanes:[[:space:]]*//p' -e 's/^addressees:[[:space:]]*//p' \
  | tr ' ' '\n' | sed '/^$/d'; }

# report_one <path-or-basename> -> prints one report, rc 1 on any finding.
#
# Hoisted out of the argv loop on purpose. In the source, two defects in a row lived in a
# loop the selftest never entered — it only exercised the resolver — so both shipped green.
# A CHECK'S COVERAGE IS DECIDED BY ITS CALL SITE, NOT ITS CODE, and --selftest drives THIS
# function for exactly that reason.
report_one() {
  local f="$1" rc=0
  local base="${f##*/}"; base="${base%.md}"

  case "$base" in *-to-*) ;; *)
    printf '%s\n  NOT A ROUTED COMM: no `-to-` segment, so nothing dispatches it.\n' "$base"
    return 1 ;;
  esac

  local who dropped=""
  who=$(bash "$ACTOR" targets "$base.md" 2>/dev/null | tr '\n' ' ')
  who="${who% }"

  printf '%s\n' "$base"
  if [ -n "$who" ]; then
    printf '  DISPATCHES TO: %s\n' "$who"
  else
    printf '  DISPATCHES TO: NOBODY — no lane polls anything this name addresses.\n'
    rc=1
  fi

  # DROPPED NAMES. Only tokens that are ACTUAL roster names count. The source's first cut
  # treated every hyphen-token after the target as a dropped name, so it fired on the
  # subject slug of every comm without a `-cc-` and returned rc 1 on clean filenames — a
  # check that flags everything flags nothing. That is why this intersects with the roster
  # and why the selftest carries a clean-filename arm asserting SILENCE here.
  #
  # The two causes are reported SEPARATELY because their fixes are different, and a single
  # "dropped" line would send a writer to rename a comm that no rename can deliver.
  local rest head t n nolane=""
  rest="${base#*-to-}"; head="${rest%%-cc-*}"
  # ...AND AT THE PRIORITY TOKEN, WHICH IS THE OTHER RECOGNISED TERMINATOR. Dispatch already
  # stops there; this scan did not, so it read the entire SUBJECT slug as address position.
  # That was harmless only while the roster held invented names. The moment the example party
  # was renamed to the four ROLE names -- `voice`, `worker`, `gate`, `researcher` -- every one
  # of them became an ordinary English word, and a subject like `-P2-the-squire-and-the-gate-`
  # produced a confident false TRUNCATED on a perfectly routed comm. A false warning about
  # silent loss is worse than none (see the header); the rename is what made the class live.
  head=$(printf '%s\n' "$head" | sed -E 's/-P[0-9]+-.*$//')
  # CAPTURE, THEN MATCH -- never `<producer> | grep -q` under pipefail. grep -q exits on the
  # first match, the producer's next write takes SIGPIPE (141), and pipefail turns a FOUND
  # name into a not-found. Same defect merge.sh/quest.sh carried as FOREGROUND-382 item 3,
  # hoisted out of the loop because the rosters do not change between iterations.
  # The failure DIRECTION differs per line and both are bad: on the known_names test it
  # skips a name that IS on the roster, so a real TRUNCATED goes unreported (silent loss --
  # the exact thing this check exists to warn about); on the lane test it reports NO LANE
  # for an actor that owns one, sending the writer to the wrong fix. Arm A-PIPE pins the
  # first; A-PIPE2 pins the second.
  local _kn _lanes
  _kn=$(known_names)
  _lanes=$(bash "$ACTOR" list lanes 2>/dev/null; bash "$ACTOR" roster 2>/dev/null \
             | sed -n 's/^lanes:[[:space:]]*//p' | tr ' ' '\n')
  for t in $(printf '%s\n' "$head" | tr '-' ' '); do
    n=$(bash "$ACTOR" resolve "$t" 2>/dev/null)
    command grep -qx -- "$n" <<<"$_kn" || continue      # not a roster name: subject word
    case " $who " in *" $n "*) continue;; esac          # actually dispatched
    if command grep -qx -- "$n" <<<"$_lanes"; then
      case " $dropped " in *" $t "*) continue;; esac
      dropped="$dropped $t"                             # has a lane, still not dispatched
    else
      case " $nolane " in *" $t "*) continue;; esac
      nolane="$nolane $t"                               # no lane: undeliverable by name
    fi
  done
  dropped="${dropped# }"; nolane="${nolane# }"
  if [ -n "$dropped" ]; then
    printf '  TRUNCATED (named, owns a lane, still gets nothing): %s\n' "$dropped"
    printf '  FIX: the run of names is kept only up to a recognised terminator — end it with\n'
    printf '       `-cc-` or a priority token (`-P2-`), or file one comm per actor.\n'
    rc=1
  fi
  if [ -n "$nolane" ]; then
    printf '  NO LANE (named in the filename, owns no queue, can never receive): %s\n' "$nolane"
    printf '  FIX: nothing polls for this name — no rename delivers it. Reach them another\n'
    printf '       way, or give them a lane in the roster.\n'
    rc=1
  fi

  # DIRECTION CHECK. Needs the file. Try the path as given, THEN the comms dir — a bare
  # basename is the documented invocation form, and in the source it was resolved against
  # the caller's cwd, which meant the advertised form was the one that silently opted out.
  local p="$f"
  [ -f "$p" ] || p="$COMMS/$base.md"
  if [ ! -f "$p" ]; then
    printf '  DIRECTION CHECK NOT RUN: no such file (looked at %s and %s)\n' "$f" "$p"
    printf '  FIX: pass the PATH to the draft — a scratch copy is fine. Without the\n'
    printf '       frontmatter there is no second witness to the direction.\n'
    return 1
  fi
  local ffrom nfrom
  ffrom=$(sed -n '1,15p' "$p" | sed -n 's/^from:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | head -1)
  nfrom="${base%%-to-*}"
  if [ -z "$ffrom" ]; then
    printf '  DIRECTION CHECK NOT RUN: no frontmatter `from:` in %s\n' "${p##*/}"
    printf '  FIX: add a frontmatter block with `from:`. Without it a REVERSED filename\n'
    printf '       dispatches cleanly to the wrong end and nothing ever flags it.\n'
    rc=1
  elif [ "$(bash "$ACTOR" resolve "$ffrom")" != "$(bash "$ACTOR" resolve "$nfrom")" ]; then
    printf '  DIRECTION MISMATCH: frontmatter says from:%s but the filename says %s-to-...\n' \
           "$ffrom" "$nfrom"
    printf '  FIX: the grammar is <from>-to-<to>-. If %s wrote this, rename it. A reversed\n' "$ffrom"
    printf '       name dispatches cleanly to the WRONG END; no receipt check will flag it.\n'
    rc=1
  fi
  return $rc
}

case "${1:-}" in
  --selftest) exec bash "$REPO/tests/bus-preflight-selftest.sh";;
  "") sed -n '2,6p' "$0"; exit 2;;
esac

rc=0
for a in "$@"; do report_one "$a" || rc=1; done
exit $rc
