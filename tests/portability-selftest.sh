#!/usr/bin/env bash
# portability-selftest.sh — the GNU-isms that made this repo green on one substrate and
# broken on another. Every pattern here is a DEFECT THAT SHIPPED, found on 2026-09-20 by
# running the suite on macOS (bash 3.2 + BSD userland) two weeks before the public demo:
# 15/15 green on WSL2, 9/15 with a broken demo there.
#
# WHY A GREP AND NOT JUST THE BATTERIES. The batteries do catch these -- on a machine that
# has the BSD tools. On the authoring machine they cannot, because the construct works
# there. This arm is what a Linux-only contributor gets instead.
#
# COMMENTS ARE STRIPPED FIRST, and that is load-bearing. Every banned literal below also
# appears in the prose explaining why it is banned -- including in this header. A lint that
# reads its own warning as a violation is a lint nobody keeps.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
R=${INNKEEPER_HOME:-$(cd "$HERE/.." && pwd -P)}

fails=0; arms=0
code() { # strip full-line and trailing comments, and the shebang
  sed -e 's/[[:space:]]#[^"'"'"']*$//' -e '/^[[:space:]]*#/d' "$1"
}
FILES=$(find "$R/bin" "$R/bus" "$R/lifecycle" "$R/staff" "$R/tests" -name '*.sh' -type f | sort)
[ -n "$FILES" ] || { echo "CANNOT-RUN portability-selftest: found no shell scripts under $R" >&2; exit 3; }

ban() { # name, ERE, why, [per-line exemption ERE]
  arms=$((arms+1))
  local hit=""
  for f in $FILES; do
    [ "$f" = "$HERE/portability-selftest.sh" ] && continue
    # The exemption is PER LINE and per pattern, never per file: a file-level allowlist
    # retires the whole file from scrutiny and becomes the hole. A line may carry a banned
    # construct only if it also carries the guard that makes it safe.
    code "$f" | grep -nE -- "$2" | grep -vE -- "${4:-\$^}" | grep -q . && hit="$hit ${f#$R/}"
  done
  if [ -n "$hit" ]; then echo "  FAIL $1 —$hit"; echo "       $3"; fails=$((fails+1));
  else echo "  ok   $1"; fi
}

ban tac-is-gnu-only        '(^|[^[:alnum:]_])tac([^[:alnum:]_]|$)' \
  'tac is GNU coreutils; absent on macOS. Use awk to reverse.'
ban sed-i-is-not-portable  'sed[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-i([[:space:]]|$)' \
  'GNU sed -i PROG and BSD sed -i SUFFIX PROG are different commands. Write via a temp file.'
ban bashpid-needs-bash4    '\$BASHPID|\$\{BASHPID\}' \
  'BASHPID arrived in bash 4.0; macOS ships 3.2, where it is unset. Guard it with a ${BASHPID:-} test.' \
  'BASHPID:-'
ban bre-alternation        '(sed|grep)([^;|]*[^E;|])?[[:space:]][^;|]*\\\|' \
  'BSD BRE has no \| alternation -- it matches a literal bar. Use -E with a bare |, or two -e expressions.'
ban grep-P-is-gnu-only     'grep[[:space:]]+(-[a-zA-Z]*)?P' \
  'grep -P is GNU/PCRE and is absent on macOS. Use -E.'
ban readlink-f-is-gnu-only 'readlink[[:space:]]+-f' \
  'readlink -f is GNU; macOS readlink has no -f. Use cd + pwd -P.'
ban date-d-is-gnu-only     'date[[:space:]]+(-u[[:space:]]+)?-d[[:space:]]' \
  'date -d is GNU; BSD date uses -v/-j -f. Prefer epoch arithmetic.'

EXPECT_ARMS=${INNKEEPER_EXPECT_PORT_ARMS:-7}
echo "portability-selftest: $((arms-fails))/$arms passed (expected $EXPECT_ARMS arms)"
[ "$arms" = "$EXPECT_ARMS" ] || { echo "  FAIL arm count: ran $arms, expected $EXPECT_ARMS" >&2; exit 1; }
[ "$fails" = 0 ]
