#!/usr/bin/env bash
# port-gate.sh — judges a file before it may enter this repo. It never rewrites.
#
#   port-gate.sh --source SRC | --no-source  DEST...
#   (one of the two is REQUIRED: an omitted source must not silently skip the wall)
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

usage() { echo "usage: port-gate.sh --source SRC | --no-source  DEST..." >&2; exit 2; }

SRC= NOSRC=
case "${1:-}" in
  --source) [ $# -ge 2 ] || usage; SRC=$2; shift 2 ;;
  --no-source) NOSRC=1; shift ;;
  -*|'') usage ;;
  *) echo "CANNOT-ASSESS - no --source given; pass --source SRC, or --no-source for a file authored in place"; exit 2 ;;
esac
[ $# -ge 1 ] || usage
case "$1" in -*) usage ;; esac

if [ -z "$LIST" ] || [ ! -s "$LIST" ]; then
  echo "CANNOT-ASSESS - forbidden list unset or empty (INNKEEPER_FORBIDDEN)"; exit 2
fi
# CR stripped: a CRLF list would otherwise put \r at the end of every regex and disable every rule.
rules=$( { printf '%s\n' "$BUILTIN"; tr -d '\r' <"$LIST" | command grep -Ev '^[[:space:]]*(#|$)'; } )
# Every rule must compile. grep rc=2 on a bad regex is otherwise indistinguishable from "no match".
while IFS=$'\t' read -r cls re; do
  command grep -Eq -- "$re" /dev/null 2>/dev/null; [ $? = 2 ] && { echo "CANNOT-ASSESS - invalid regex in class $cls"; exit 2; }
done <<<"$rules"
if ! printf '%s\n' "$rules" | command grep -q "^name	"; then
  echo "CANNOT-ASSESS - forbidden list has no \`name\` rules; the address-name check would be vacuous"; exit 2
fi

# 1. Wall: judged on the source PATH, before anything is opened.
# Judged on the path as given AND as resolved, so a symlink or relative path cannot launder it.
if [ -n "$SRC" ]; then
  srcreal=$(realpath -m -- "$SRC")
  while IFS=$'\t' read -r cls re; do
    [ "$cls" = wall ] || continue
    if printf '%s\n%s\n' "$SRC" "$srcreal" | command grep -Eqi -- "$re"; then
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

  # Text only. grep on a binary/NUL/UTF-16 file prints "binary file matches" with no line number,
  # which read as clean; a gate that cannot read the bytes as text cannot judge them.
  # `grep -P` IS GNU/PCRE AND macOS DOES NOT HAVE IT. There the NUL half of this test errored
  # out instead of matching, so the `||` fell through and a NUL-bearing file was accepted as
  # text -- the gate failing open on exactly the input it exists to refuse. `tr -d` is POSIX:
  # if deleting NULs changes the byte count, the file had NULs.
  if ! LC_ALL=C command grep -Eq -- $'^[\t -~\x80-\xff]*$' "$abs" \
     || [ "$(LC_ALL=C tr -d '\000' <"$abs" | wc -c)" != "$(wc -c <"$abs")" ]; then
    echo "CANNOT-ASSESS $rel not text"; bump 2; return
  fi

  # 2. Token classes over the file's bytes.
  while IFS=$'\t' read -r cls re; do
    [ -n "$cls" ] || continue
    if [ "$cls" = name ]; then
      [[ "$rel" =~ $ADDR_DIRS ]] || continue
      re="(-to-|-cc-|start-|recycle-|queues/)($re)([-/.]|$)|(^|[^A-Za-z0-9])($re)-to-"
      cls=address-name
    fi
    local ln
    local out grc
    out=$(LC_ALL=C command grep -aEin -m1 -- "$re" "$abs"); grc=$?
    if [ $grc = 0 ]; then echo "FORBIDDEN $cls $rel:${out%%:*}"; hit=1
    elif [ $grc != 1 ]; then echo "CANNOT-ASSESS $rel grep rc=$grc on class $cls"; bump 2; return; fi
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
  # Keyed on the repo-relative path (lifecycle/deploy.py -> tests/lifecycle-deploy-selftest.*), so
  # a same-basename test for another file cannot satisfy it. roles/ is prose run by an LLM, not code:
  # it is token-gated above and exempt here by design.
  if [[ "$rel" =~ ^(bus|lifecycle|bin|staff)/ ]]; then
    local key t; key=${rel%.*}; key=${key//\//-}
    t=$(ls "$REPO"/tests/"$key"-selftest.* 2>/dev/null | head -1)
    if [ -z "$t" ]; then echo "NO-SELFTEST $rel"; bump 1; return; fi
    if ! INNKEEPER_GATE_NESTED=1 bash "$t" >/dev/null 2>&1; then echo "SELFTEST-RED $rel"; bump 1; return; fi
  fi
  echo "PASS $rel"
}

for d in "$@"; do judge "$d"; done
exit $worst
