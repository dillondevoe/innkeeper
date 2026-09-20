#!/usr/bin/env bash
# merge.sh — the exactly-once commit point for a quest's result.
#
#   merge.sh begin  <quest> <lane>          stage a workdir for one attempt -> ATTEMPT <dir>
#   merge.sh commit <quest> <lane> <file>   -> MERGED <dest> | ALREADY-MERGED <dest> by=<lane>
#   merge.sh status <quest>                 -> UNMERGED | MERGED by=<lane> at=<ts>
#   merge.sh dest   <quest>                 where the merged result lives
#   merge.sh --selftest
#
# WHY THIS EXISTS: kill a worker mid-task and two things must stay true — no partial result is
# ever visible, and when a second worker takes the quest over, the work lands EXACTLY ONCE. A
# done-marker cannot give you that. Two workers that both read "not merged yet" before either
# writes will both merge, and the second one silently overwrites or duplicates the first.
#
# THE COMMIT IS ONE SYSCALL, AND THE MERGED ARTIFACT IS ITS OWN RECEIPT.
# `ln` fails with EEXIST if the destination is there, so the link both TESTS and SETS in one
# indivisible step. There is no read-then-write window for a second worker to fit inside.
#
# The tempting alternative — a `<quest>.merged` marker file beside the result — is wrong in a way
# worth writing down, because it is what I reached for first. It makes the receipt a SECOND
# WRITER, and a kill between the two writes leaves one of two broken worlds: a receipt claiming a
# merge that has no result, or a result with no receipt that the next worker merges again. Both
# are invisible afterwards. Deriving "is it merged" from the artifact itself has no such window,
# because there is only ever one write.
#
# `<quest>.by` IS WRITTEN AFTER THE LINK AND IS ATTRIBUTION ONLY — never truth. A kill between
# the link and the sidecar leaves `status` reporting MERGED by=unknown, which is correct and
# complete for the only question that governs behaviour: may I merge? Nothing branches on `by`.
#
# STATED LIMIT: `ln` is a hard link, so the staged file and the destination must share a
# filesystem. Both live under $INNKEEPER_HOME by construction. If that ever stops being true the
# commit does not silently degrade — `ln` fails, the destination does not exist, and this script
# exits 2 rather than reporting a merge it did not perform.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$HERE/actor.sh"
[ -r "$ACTOR" ] || { echo "FATAL: $ACTOR missing — merge.sh will not guess at the roster" >&2; exit 2; }

case "${1:-}" in --selftest) exec bash "$REPO/tests/bus-merge-selftest.sh";; esac

# REQUIRED, not defaulted — and this is the same call lifecycle/lease.sh makes for the same
# reason. A default of $REPO would quietly write results and staged work INTO THE USER'S CLONE
# the moment the variable is unset, which is exactly the "one folder, nothing written outside
# it" promise the slice is built to keep. An unset variable is a caller that has not said where
# its state lives; guessing on its behalf is how a sandbox stops being one.
: "${INNKEEPER_HOME:?INNKEEPER_HOME not set — merge.sh will not guess where your state lives}"
MDIR=$INNKEEPER_HOME/state/merged
WDIR=$INNKEEPER_HOME/work

die()  { echo "merge.sh: $*" >&2; exit 1; }
usage(){ sed -n '2,10p' "$0" >&2; exit 2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

_id_ok() { case "$1" in ''|*[!a-z0-9-]*) return 1;; esac; case "$1" in -*|*-) return 1;; esac; return 0; }
_dest()  { echo "$MDIR/$1.out"; }

# Membership, not resolution — the same rule as quest.sh, and for the same reason: `resolve`
# hands an unknown token back unchanged, so a typo would be credited with the work and render in
# a view exactly like a brain that did it.
_lane_ok() {
  local r; r=$(bash "$ACTOR" resolve "$1" 2>/dev/null) || return 1
  bash "$ACTOR" lanes 2>/dev/null | command grep -qx "$r" || return 1
  printf '%s\n' "$r"
}

case "${1:-}" in
  begin)
    [ $# -eq 3 ] || usage
    _id_ok "$2" || die "quest id must match [a-z0-9-]+ and not start or end with '-': '$2'"
    lane=$(_lane_ok "$3") || die "'$3' owns no queue lane on this roster — work cannot be staged for a name no brain answers to"
    d=$WDIR/$2/$lane.$$
    mkdir -p "$d" || die "cannot stage an attempt under $WDIR"
    echo "ATTEMPT $d"
    ;;

  commit)
    [ $# -eq 4 ] || usage
    q=$2; lane_in=$3; src=$4
    _id_ok "$q" || die "quest id must match [a-z0-9-]+ and not start or end with '-': '$q'"
    lane=$(_lane_ok "$lane_in") || die "'$lane_in' owns no queue lane on this roster — a merge credited to a name no brain answers to reads as work that was done"
    [ -f "$src" ] || die "no such result file: $src — a merge names the bytes it is merging"
    [ -s "$src" ] || die "result file is empty: $src — a killed worker's partial write is not a result"
    mkdir -p "$MDIR" || die "cannot create $MDIR"
    d=$(_dest "$q")
    # THE COMMIT. One syscall, and the two failure directions are kept apart: EEXIST is the
    # ordinary already-merged answer, anything else is an instrument failure and must never be
    # reported as a merge. Collapsing them is how a broken filesystem reads as "someone beat me".
    if ln "$src" "$d" 2>/dev/null; then
      printf '%s %s\n' "$lane" "$(now)" > "$MDIR/$q.by" 2>/dev/null || true
      echo "MERGED $d"
      exit 0
    fi
    if [ -e "$d" ]; then
      by=unknown; [ -r "$MDIR/$q.by" ] && by=$(cut -d' ' -f1 < "$MDIR/$q.by")
      echo "ALREADY-MERGED $d by=${by:-unknown}"
      exit 0
    fi
    die "could not link $src -> $d and nothing is there: the commit did NOT happen (different filesystem? unwritable state dir?)"
    ;;

  status)
    [ $# -eq 2 ] || usage
    d=$(_dest "$2")
    [ -e "$d" ] || { echo "UNMERGED"; exit 0; }
    if [ -r "$MDIR/$2.by" ]; then
      read -r by at < "$MDIR/$2.by"
      echo "MERGED by=${by:-unknown} at=${at:-unknown}"
    else
      # The artifact is the truth and the sidecar is not. A kill between the two writes lands
      # here, and this line is what that world looks like — merged, attribution lost.
      echo "MERGED by=unknown at=unknown"
    fi
    ;;

  dest) [ $# -eq 2 ] || usage; _dest "$2";;
  *) usage;;
esac
