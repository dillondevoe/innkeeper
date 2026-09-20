#!/usr/bin/env bash
# actor.sh — who a comm filename ADDRESSES. The one parser of the address grammar.
#
#   actor.sh is-actor <brain> <basename>   rc 0 if <brain> must ACT on this comm, 1 if not
#   actor.sh targets <basename>            the lanes this comm is dispatched to, one per line
#   actor.sh roster                        lanes / addressees / aliases, as read from party.yaml
#   actor.sh --selftest
#
# GRAMMAR:  <from>-to-<name>(-<name>)*-cc-…   or   <from>-to-<name>(-<name>)*-P[0-3]-…
#   The run of roster tokens after `-to-` is a target list ONLY when it is terminated by
#   `-cc-` or a priority tag. A run terminated by anything else is the single-target form:
#   the first token, and nothing after it. A leading `YYYY-MM-DD-` is stripped first.
#   `-to-all-` is a broadcast: every lane except the author. `-to-feed-` is the FYI feed:
#   nobody is an actor on it, so nothing wakes and nothing is owed.
#
# WHY A PREDICATE AND NOT A GLOB: a done-marker is one bit per comm, shared by the whole
# party, and it means THE ACTOR HAS ACTED. A sweep that marks everything it merely READ —
# a cc, a broadcast someone else owns, its own outbound — closes other brains' wake windows
# by touch. `is-actor` is the guard that stops it, and `targets` is the same grammar read
# from the producer's side, so a comm can never be dispatched to a brain that would not
# consider itself an actor on it.
#
# Port note: in the source mesh this grammar existed in THREE places — a reader, a dispatch
# loop, and one brain's hardcoded copy — and they disagreed. Here the dispatcher calls
# `targets` instead of carrying its own run parser, and the roster comes from party.yaml
# instead of from a shell array inside the dispatcher.
set -uo pipefail

PARTY=${INNKEEPER_PARTY:-${INNKEEPER_HOME:-$(cd "$(dirname "$0")/.." && pwd -P)}/party.yaml}

# --- roster ------------------------------------------------------------------------
# party.yaml is read with sed, not a YAML library, so the bus has no dependencies. Only
# the three flow-style shapes the file documents are accepted; anything else is ignored,
# which is why `roster` prints what it parsed rather than asking you to trust it.
_section() {  # $1 = top-level key -> that block's lines
  sed -e 's/[[:space:]]*#.*$//' "$PARTY" 2>/dev/null \
    | sed -n "/^$1:[[:space:]]*\$/,/^[a-z_]/{ /^[a-z_]/d; p; }"
}
_lanes() { _section brains | sed -n 's/.*[{,][[:space:]]*name:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | tr '\n' ' '; }
_extra() { sed -n 's/^addressees:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$PARTY" 2>/dev/null | tr ',' ' '; }
_alias_of() {  # $1 = token -> the roster name it resolves to, or the token itself
  local a
  a=$(_section aliases | sed -n "s/.*from:[[:space:]]*$1[[:space:]]*,[[:space:]]*to:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p" | head -1)
  [ -n "$a" ] && echo "$a" || echo "$1"
}

LANES=" $(_lanes) "
NAMES=" $(_lanes) $(_extra) "

# FAIL CLOSED ON AN UNREADABLE ROSTER. Both seds above are `2>/dev/null` over a file
# whose path comes from the environment, so a missing, misnamed or block-style
# party.yaml parses as the EMPTY roster rather than as an error. Empty is not a refusal
# here: `targets` would then print nothing for every comm and an empty list for every
# broadcast, and the dispatcher would log nothing, report "0 marker(s) queued" and exit
# 0 — a bus that is entirely dead while every exit code says it is well. `roster` prints
# the parse, but printing is not asserting, and nothing on the runtime path read it.
if [ "$LANES" = "  " ]; then
  echo "actor.sh: no brains parsed from '$PARTY' — roster empty, refusing to answer" >&2
  exit 2
fi

_split() {  # $1 = basename -> "<author> <rest-after-to>", or rc 1 if it is not a comm
  local b="${1##*/}"; b="${b%.md}"
  b="${b#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"     # a date prefix is not the author
  case "$b" in *-to-*) ;; *) return 1;; esac
  printf '%s %s' "${b%%-to-*}" "${b#*-to-}"
}

# The address run: every roster token from the head of $1, and whether the run was
# TERMINATED by `-cc-` or a priority tag (which is what makes it a multi-address list).
_run() {  # $1 = rest-after-to -> prints "<terminated:0|1> <tok> <tok> ..."
  local rest="$1" t run="" term=0 first=1
  while :; do
    t="${rest%%-*}"; t=$(_alias_of "$t")
    if [ "$first" = 1 ]; then run=" $t"; first=0
    else case "$NAMES" in *" $t "*) run="$run $t";; *) case "$t" in cc|P0|P1|P2|P3) term=1;; esac; break;; esac
    fi
    case "$rest" in *-*) rest="${rest#*-}";; *) break;; esac
  done
  printf '%s%s' "$term" "$run"
}

is_actor() {  # $1 = brain, $2 = basename
  local me parts author rest run term
  me=$(_alias_of "$1")
  parts=$(_split "$2") || return 1
  author=$(_alias_of "${parts%% *}"); rest="${parts#* }"
  case "$rest" in
    all-*)  [ "$author" = "$me" ] && return 1; return 0;;   # broadcast: all but the author
    feed-*) return 1;;                                      # FYI feed: no actor anywhere
  esac
  [ "$author" = "$me" ] && return 1                         # never an actor on your own outbound
  run=$(_run "$rest"); term="${run%% *}"; run=" ${run#* } "
  # The FIRST token is an actor whether or not the run was terminated — that is the
  # single-target form, and it is accepted without a roster check so a name the roster
  # has not heard of still reaches the brain it names. Later tokens count only when the
  # run was terminated, or `alfa-to-bravo-loop-died` would promote a subject to an address.
  local firstt="${run# }"; firstt="${firstt%% *}"
  [ "$firstt" = "$me" ] && return 0
  [ "$term" = 1 ] || return 1
  case "$run" in *" $me "*) return 0;; esac
  return 1
}

targets() {  # $1 = basename -> the LANES to dispatch to, one per line
  local parts author rest run term t
  parts=$(_split "$1") || return 0
  author=$(_alias_of "${parts%% *}"); rest="${parts#* }"
  case "$rest" in feed-*) return 0;; esac
  if case "$rest" in all-*) true;; *) false;; esac; then
    for t in $LANES; do [ "$t" = "$author" ] || echo "$t"; done
    return 0
  fi
  run=$(_run "$rest"); term="${run%% *}"; run="${run#* }"
  [ "$term" = 1 ] || run="${run%% *}"
  # Dispatch is LANES-only even though the grammar parses the wider roster: a marker in a
  # directory no brain polls is a comm delivered to nobody, silently.
  local out=" "
  for t in $run; do
    [ "$t" = "$author" ] && continue
    case "$out" in *" $t "*) continue;; esac
    case "$LANES" in *" $t "*) out="$out$t ";; esac
  done
  # Emitted in ROSTER order, not filename order: the dispatch list is a property of the
  # party, and a stable order is what lets a caller diff two runs.
  for t in $LANES; do case "$out" in *" $t "*) echo "$t";; esac; done
}

case "${1:-}" in
  is-actor) [ $# -eq 3 ] || { echo "usage: actor.sh is-actor <brain> <basename>" >&2; exit 2; }
            is_actor "$2" "$3";;
  targets)  [ $# -eq 2 ] || { echo "usage: actor.sh targets <basename>" >&2; exit 2; }
            targets "$2";;
  roster)   echo "party:      $PARTY"; echo "lanes:     $LANES"; echo "addressees:$NAMES"
            echo "aliases:   $(_section aliases | tr -d ' ' | tr '\n' ' ')";;
  --selftest) exec bash "$(cd "$(dirname "$0")/.." && pwd -P)/tests/bus-actor-selftest.sh";;
  *) sed -n '2,20p' "$0"; exit 2;;
esac
