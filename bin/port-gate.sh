#!/usr/bin/env bash
# port-gate.sh — judges a file before it may enter this repo. It never rewrites.
#
#   port-gate.sh [--source SRC] DEST...
#
# Verdicts, one line per DEST:
#   PASS
#   REFUSED wall <source>            source path is in the walled family; it was not read
#   REFUSED outside-repo <dest>
#   FORBIDDEN <class> <file:line>    class = wall|host|path|identity|pipeline|address-name|net
#   SECRET <file> <scanner-rule>
#   NO-SELFTEST <file> | SELFTEST-RED <file>
#   CANNOT-ASSESS <file> <reason>    never read as PASS
#
# rc: 0 every DEST passed | 1 something refused | 2 CANNOT-ASSESS or usage.
#
# The private token list lives OUTSIDE the repo ($INNKEEPER_FORBIDDEN): the identifiers it
# guards against must not be published by the thing that guards against them. Format, one
# rule per line:  <class><TAB><extended regex>   (class `name` = roster names, address position only)
# A missing or empty list is CANNOT-ASSESS: a gate with no list checks nothing and would say clean.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
LIST=${INNKEEPER_FORBIDDEN:-}
GITLEAKS=${INNKEEPER_GITLEAKS:-gitleaks}

# Generic classes that name no one, so they can live in the repo.
BUILTIN=$(printf '%s\t%s\n' \
  net  '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' \
  net  '(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' \
  path '/(home|Users)/[A-Za-z_][A-Za-z0-9_-]*')

# Where a roster name is a hard-coded address rather than an English word (D3).
ADDR_DIRS='^(bus|lifecycle|bin|staff|roles)/'

usage() { echo "usage: port-gate.sh [--source SRC] DEST..." >&2; exit 2; }

SRC=
[ "${1:-}" = --source ] && { [ $# -ge 2 ] || usage; SRC=$2; shift 2; }
[ $# -ge 1 ] || usage
case "$1" in -*) usage ;; esac

if [ -z "$LIST" ] || [ ! -s "$LIST" ]; then
  echo "CANNOT-ASSESS - forbidden list unset or empty (INNKEEPER_FORBIDDEN)"; exit 2
fi
rules=$( { printf '%s\n' "$BUILTIN"; command grep -Ev '^[[:space:]]*(#|$)' "$LIST"; } )
if ! printf '%s\n' "$rules" | command grep -q "^name	"; then
  echo "CANNOT-ASSESS - forbidden list has no \`name\` rules; the address-name check would be vacuous"; exit 2
fi

# 1. Wall: judged on the source PATH, before anything is opened.
if [ -n "$SRC" ]; then
  while IFS=$'\t' read -r cls re; do
    [ "$cls" = wall ] || continue
    if printf '%s' "$SRC" | command grep -Eqi -- "$re"; then
      echo "REFUSED wall $SRC"; exit 1
    fi
  done <<<"$rules"
fi

worst=0
bump() { [ "$1" -gt "$worst" ] && worst=$1; }

judge() {
  local dest=$1 abs rel hit=0
  abs=$(realpath -m -- "$dest")
  case "$abs" in "$REPO"/*) rel=${abs#"$REPO"/} ;; *) echo "REFUSED outside-repo $dest"; bump 1; return ;; esac
  if [ ! -r "$abs" ] || [ -d "$abs" ]; then echo "CANNOT-ASSESS $rel unreadable"; bump 2; return; fi
  if [ ! -s "$abs" ]; then echo "CANNOT-ASSESS $rel zero-line file; an empty scan is not a clean one"; bump 2; return; fi

  # 2. Token classes over the file's bytes.
  while IFS=$'\t' read -r cls re; do
    [ -n "$cls" ] || continue
    if [ "$cls" = name ]; then
      [[ "$rel" =~ $ADDR_DIRS ]] || continue
      re="(-to-|-cc-|start-|recycle-|queues/)($re)([-/.]|$)|(^|[^A-Za-z0-9])($re)-to-"
      cls=address-name
    fi
    local ln
    ln=$(command grep -Ein -m1 -- "$re" "$abs" | cut -d: -f1)
    if [ -n "$ln" ]; then echo "FORBIDDEN $cls $rel:$ln"; hit=1; fi
  done <<<"$rules"
  [ $hit = 1 ] && { bump 1; return; }

  # 3. Secrets scanner. A missing binary is not a clean scan.
  if ! command -v "$GITLEAKS" >/dev/null 2>&1; then
    echo "CANNOT-ASSESS $rel secrets scanner not found ($GITLEAKS)"; bump 2; return
  fi
  local rep; rep=$(mktemp)
  "$GITLEAKS" dir --no-banner --log-level error --exit-code 3 -f json -r "$rep" "$abs" >/dev/null 2>&1
  local grc=$?
  if [ $grc = 3 ]; then
    echo "SECRET $rel $(python3 -c 'import json,sys;print(",".join(sorted({f["RuleID"] for f in json.load(open(sys.argv[1]))})))' "$rep")"
    rm -f "$rep"; bump 1; return
  elif [ $grc != 0 ]; then
    echo "CANNOT-ASSESS $rel secrets scanner rc=$grc"; rm -f "$rep"; bump 2; return
  fi
  rm -f "$rep"

  # 4. Executable code must carry a green selftest.
  if [[ "$rel" =~ ^(bus|lifecycle|bin|staff)/ ]]; then
    local base t; base=$(basename "$rel"); base=${base%.*}
    t=$(ls "$REPO"/tests/"$base"-selftest.* 2>/dev/null | head -1)
    if [ -z "$t" ]; then echo "NO-SELFTEST $rel"; bump 1; return; fi
    if ! INNKEEPER_GATE_NESTED=1 bash "$t" >/dev/null 2>&1; then echo "SELFTEST-RED $rel"; bump 1; return; fi
  fi
  echo "PASS $rel"
}

for d in "$@"; do judge "$d"; done
exit $worst
