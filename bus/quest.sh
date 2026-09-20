#!/usr/bin/env bash
# quest.sh — the quest record. One file per quest, the unit of work a party is given.
#
#   quest.sh new <id> --title <t> (--brief <s> | --brief-file <f>) [--origin <basename>]
#   quest.sh show <id>                     the record, verbatim
#   quest.sh field <id> <key>              one field (`brief` prints the whole block)
#   quest.sh list [--state <s>] [--lane <l>]   one "<id> <state> <lane> <title>" per line
#   quest.sh claim <id> <lane>             open -> claimed, lane set
#   quest.sh release <id>                  claimed|blocked -> open, lane cleared
#   quest.sh state <id> <state>            any -> open|claimed|blocked|done|abandoned
#   quest.sh block <id> <dep-id> | unblock <id> <dep-id>
#   quest.sh path <id>                     where the record lives
#   quest.sh --selftest
#
# SCHEMA.md §1 is the contract and this script is its writer; they change in one commit.
#
# THREE THINGS THIS REFUSES, AND EACH ONE IS A SCAR SOMEWHERE IN THIS REPO'S PORT NOTES:
#
# 1. A TIMESTAMP HAS NO ARGUMENT POSITION. `created`/`updated` are stamped from `date -u`
#    inside the writer. There is no flag to pass one, because a field you can hand-type is
#    a field that will be hand-typed, and a stamp is evidence about when something was
#    observed — a typed one is a claim about when you think it was. The absence of the
#    parameter is the control; a validator on a parameter is a weaker one.
#
# 2. A LANE IS CHECKED FOR MEMBERSHIP, NOT MERELY RESOLVED. `actor.sh resolve` hands an
#    unknown token BACK UNCHANGED — that is its identity rule and it is correct there — so
#    resolving a typo yields the typo and a quest ends up held by a brain that does not
#    exist, rendered in a tavern view as if it were being worked. Membership is asked of
#    `actor.sh lanes`. Same single-parser rule as everything else here: this file never
#    opens party.yaml.
#
# 3. `state` AND `lane` ARE COUPLED AND THE COUPLING IS ENFORCED. `open` with a lane set,
#    or `claimed` with `lane: null`, are both records a consumer cannot render honestly.
#    They are refused at the write, not linted afterwards, because the only thing that
#    reads a quest is a view and a view will draw whatever it is handed.
#
# And one it does NOT refuse: re-claiming a quest for the lane that already holds it is a
# no-op that returns 0. A claim is state, not an event; making it idempotent is what lets a
# brain re-assert its own hold after a recycle without a special path for "already mine".
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$HERE/actor.sh"
[ -r "$ACTOR" ] || { echo "FATAL: $ACTOR missing — quest.sh will not guess at the roster" >&2; exit 2; }

case "${1:-}" in --selftest) exec bash "$REPO/tests/bus-quest-selftest.sh";; esac

# The rc is consumed HERE and not inside a helper: a helper that exits on refusal exits only
# the command-substitution subshell, and the caller runs on with an empty path.
BUS=$(bash "$ACTOR" bus) || { echo "FATAL: actor.sh refused to name the bus (unreadable roster?)" >&2; exit 2; }
[ -n "$BUS" ] || { echo "FATAL: actor.sh named an empty bus path" >&2; exit 2; }
QDIR=${INNKEEPER_QUESTS:-$BUS/quests}

STATES=" open claimed blocked done abandoned "

die()  { echo "quest.sh: $*" >&2; exit 1; }
usage(){ sed -n '2,20p' "$0"; exit 2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

_id_ok()   { case "$1" in ''|*[!a-z0-9-]*) return 1;; esac; case "$1" in -*|*-) return 1;; esac; return 0; }
_path()    { echo "$QDIR/$1.yaml"; }
_exists()  { [ -f "$(_path "$1")" ]; }

_lane_ok() {  # $1 = a lane token -> prints the resolved roster name, rc 1 if it owns no lane
  local r; r=$(bash "$ACTOR" resolve "$1" 2>/dev/null) || return 1
  bash "$ACTOR" lanes 2>/dev/null | command grep -qx "$r" || return 1
  printf '%s\n' "$r"
}

# --- reading ---------------------------------------------------------------------------
# A scalar is read off its own line; `brief` is a block and is dedented by two. The parse is
# deliberately narrow: it reads back only what this file writes.
_scalar() { sed -n "s/^$2: *\(.*[^ ]\) *\$/\1/p" "$(_path "$1")" | head -1; }
_brief()  { sed -n '/^brief: |$/,/^[a-z_]*:/{ /^brief: |$/d; /^[a-z_]*:/d; s/^  //; p; }' "$(_path "$1")"; }
_blocked(){ sed -n 's/^blocked_on: \[\(.*\)\]$/\1/p' "$(_path "$1")" | tr ',' '\n' | sed 's/^ *//; s/ *$//; /^$/d'; }

# --- writing ---------------------------------------------------------------------------
# Atomic, and it rewrites the WHOLE record: an in-place edit of one line is what lets a
# record drift into a shape its own reader no longer parses.
_write() {  # $1=id $2=title $3=state $4=lane $5=created $6=origin ; brief on stdin, deps in $7
  local t; t=$(mktemp "$QDIR/.quest.XXXXXX") || die "cannot write under $QDIR"
  {
    echo "id: $1"
    echo "title: $2"
    echo "brief: |"
    sed 's/^/  /'
    echo "state: $3"
    echo "lane: $4"
    echo "created: $5"
    echo "updated: $(now)"
    echo "origin: $6"
    echo "blocked_on: [$7]"
  } > "$t"
  mv -f "$t" "$(_path "$1")"
}

_rewrite() {  # $1=id, then key=value overrides for state/lane/blocked_on
  local id=$1; shift
  local st lane deps kv
  st=$(_scalar "$id" state); lane=$(_scalar "$id" lane); deps=$(_blocked "$id" | paste -sd, - )
  for kv in "$@"; do
    case "$kv" in
      state=*) st=${kv#state=};;
      lane=*)  lane=${kv#lane=};;
      deps=*)  deps=${kv#deps=};;
    esac
  done
  case "$st" in
    open)    [ "$lane" = null ] || die "a quest in state 'open' must have lane: null (use claim/release, not state)";;
    claimed) [ "$lane" = null ] && die "a quest in state 'claimed' needs a lane — claim it instead";;
  esac
  [ "$st" = done ] && [ -n "$deps" ] && die "'$id' still lists blocked_on [$deps] — unblock it before calling it done"
  _brief "$id" | _write "$id" "$(_scalar "$id" title)" "$st" "$lane" "$(_scalar "$id" created)" "$(_scalar "$id" origin)" "$deps"
}

case "${1:-}" in
  new)
    shift; id=${1:-}; shift || true
    _id_ok "$id" || die "id must match [a-z0-9-]+ and not start or end with '-': '${id:-}'"
    title=""; brief=""; brieff=""; origin="null"
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)      title=${2:?--title needs a value}; shift 2;;
        --brief)      brief=${2:?--brief needs a value}; shift 2;;
        --brief-file) brieff=${2:?--brief-file needs a path}; shift 2;;
        --origin)     origin=${2:?--origin needs a basename}; shift 2;;
        *) die "unknown flag '$1'";;
      esac
    done
    [ -n "$title" ] || die "--title is required: it is the one field a tavern view lists"
    case "$title" in *$'\n'*) die "--title is one line";; esac
    mkdir -p "$QDIR"
    # NEVER REUSED. An id that comes back names a different quest to every consumer that
    # cached the first one, and nothing downstream can tell the two apart.
    ! _exists "$id" || die "'$id' already exists at $(_path "$id") — ids are never reused"
    # THE BRIEF IS RESOLVED BEFORE THE WRITE, NOT PIPED INTO IT. The first version of this
    # was `if ...; else die ...; fi | _write ...`, and `die` on the left of a PIPELINE exits
    # only its own subshell: `quest.sh new c --title X` printed the refusal AND created the
    # quest, rc=0. Same collapse as the `_bus` helper eight lines up — caught by RUNNING the
    # refusal and reading what came after it, not by reading the code.
    btmp=$(mktemp "${TMPDIR:-/tmp}/.quest-brief.XXXXXX") || die "cannot stage the brief"
    trap 'rm -f "$btmp"' EXIT
    if [ -n "$brieff" ]; then
      [ -r "$brieff" ] || die "--brief-file not readable: $brieff"
      [ -s "$brieff" ] || die "--brief-file is empty: a quest with no ask is not a quest"
      cat "$brieff" > "$btmp"
    elif [ -n "$brief" ]; then printf '%s\n' "$brief" > "$btmp"
    else die "one of --brief or --brief-file is required"
    fi
    _write "$id" "$title" open null "$(now)" "$origin" "" < "$btmp"
    echo "CREATED $id"
    ;;

  show)  [ $# -eq 2 ] || usage; _exists "$2" || die "no such quest: $2"; cat "$(_path "$2")";;
  path)  [ $# -eq 2 ] || usage; _path "$2";;
  field)
    [ $# -eq 3 ] || usage; _exists "$2" || die "no such quest: $2"
    case "$3" in
      brief)      _brief "$2";;
      blocked_on) _blocked "$2";;
      id|title|state|lane|created|updated|origin) _scalar "$2" "$3";;
      *) die "not a quest field: $3";;
    esac;;

  list)
    shift; want_state=""; want_lane=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --state) want_state=${2:?--state needs a value}; shift 2;;
        --lane)  want_lane=${2:?--lane needs a value}; shift 2;;
        *) die "unknown flag '$1'";;
      esac
    done
    [ -d "$QDIR" ] || exit 0
    for f in "$QDIR"/*.yaml; do
      [ -e "$f" ] || continue
      qid=$(basename "$f" .yaml)
      st=$(_scalar "$qid" state); ln=$(_scalar "$qid" lane)
      [ -n "$want_state" ] && [ "$want_state" != "$st" ] && continue
      [ -n "$want_lane" ]  && [ "$want_lane"  != "$ln" ] && continue
      echo "$qid $st $ln $(_scalar "$qid" title)"
    done;;

  claim)
    [ $# -eq 3 ] || usage; _exists "$2" || die "no such quest: $2"
    lane=$(_lane_ok "$3") || die "'$3' owns no queue lane on this roster — a quest held by a name no brain answers to reads as worked, and is not"
    cur=$(_scalar "$2" lane); st=$(_scalar "$2" state)
    if [ "$cur" = "$lane" ] && [ "$st" = claimed ]; then echo "CLAIMED $2 $lane (already)"; exit 0; fi
    [ "$cur" = null ] || die "'$2' is held by $cur — release it first"
    _rewrite "$2" state=claimed "lane=$lane"; echo "CLAIMED $2 $lane";;

  release)
    [ $# -eq 2 ] || usage; _exists "$2" || die "no such quest: $2"
    _rewrite "$2" state=open lane=null; echo "RELEASED $2";;

  state)
    [ $# -eq 3 ] || usage; _exists "$2" || die "no such quest: $2"
    case "$STATES" in *" $3 "*) ;; *) die "not a state: '$3' (one of:$STATES)";; esac
    case "$3" in
      open)    _rewrite "$2" state=open lane=null;;
      claimed) die "use 'claim <id> <lane>' — a claimed quest needs the lane that holds it";;
      *)       _rewrite "$2" "state=$3";;
    esac
    echo "STATE $2 $3";;

  block|unblock)
    [ $# -eq 3 ] || usage; _exists "$2" || die "no such quest: $2"
    [ "$2" != "$3" ] || die "a quest cannot block on itself"
    if [ "$1" = block ]; then
      _exists "$3" || die "blocked_on names no quest: $3"
      _blocked "$2" | command grep -qx "$3" && { echo "BLOCKED $2 on $3 (already)"; exit 0; }
      d=$(_blocked "$2"; echo "$3")
    else
      d=$(_blocked "$2" | command grep -vx "$3" || true)
    fi
    _rewrite "$2" "deps=$(printf '%s\n' "$d" | sed '/^$/d' | paste -sd, -)"
    echo "$(echo "$1" | tr a-z A-Z) $2 $3";;

  *) usage;;
esac
