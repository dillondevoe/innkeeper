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
# roles/ was missing from this list, so the live-call wrappers were never scanned at all.
FILES=$(find "$R/bin" "$R/bus" "$R/roles" "$R/lifecycle" "$R/staff" "$R/tests" -name '*.sh' -type f | sort)
[ -n "$FILES" ] || { echo "CANNOT-RUN portability-selftest: found no shell scripts under $R" >&2; exit 3; }

ban() { # name, ERE, why, [per-line exemption ERE]
  arms=$((arms+1))
  local hit=""
  for f in $FILES; do
    [ "$f" = "$HERE/portability-selftest.sh" ] && continue
    # The exemption is PER LINE and per pattern, never per file: a file-level allowlist
    # retires the whole file from scrutiny and becomes the hole. A line may carry a banned
    # construct only if it also carries the guard that makes it safe.
    code "$f" | grep -nE -- "$2" | grep -vE -- "${4:-\$^}" | grep -q . && hit="$hit ${f#"$R"/}"
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
ban realpath-m-is-gnu-only 'realpath[[:space:]]+(-[a-zA-Z]*)?m([[:space:]]|$)' \
  'realpath -m is GNU; macOS realpath has only -q and errors "illegal option -- m". Use abspath_m (python3 os.path.realpath).'

ban stat-c-is-gnu-only     '(^|[^[:alnum:]_-])stat[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-c' \
  'stat -c FMT is GNU; BSD stat uses -f FMT (and GNU -f means --file-system). Fall back on the same line: stat -c %Y f || stat -f %m f.' \
  'stat[[:space:]]+-f'
ban mktemp-x-must-trail    'mktemp[^|;]*XXX+[^X[:space:]"'"'"')]' \
  'BSD mktemp replaces only TRAILING Xs: mktemp d/.f-XXXXXX.sh creates the literal name .f-XXXXXX.sh, and the second call fails. End the template in Xs.'
ban bash4-only-features    'declare[[:space:]]+-[a-zA-Z]*[Agn]|local[[:space:]]+-[a-zA-Z]*[An]|(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)|&>>|[[:space:]]\|&([[:space:]]|$)' \
  'associative arrays, namerefs, declare -g, mapfile/readarray, coproc, ${v,,}/${v^^}, &>> and |& are bash 4+; macOS ships bash 3.2.'
ban find-printf-is-gnu-only 'find[^|;]*[[:space:]]-printf' \
  'find -printf is GNU findutils; BSD find has no -printf. Print paths and post-process with awk or stat.'
ban date-gnu-formats       'date[^|;]*(%[0-9-]*N|[[:space:]]-I|--(date|iso-8601|rfc))' \
  'date %N (BSD prints a literal N), -I and the --long options are GNU. Use %s, or python3 for sub-second time.'

# PLANTED ARMS. A ban that never fires is green by construction, so every pattern above is shown
# RED on a planted line in a scratch tree, and the per-line exemptions are shown GREEN on the guarded
# form -- the only evidence that each regex is discriminating. The nested run scans ONLY the plant.
if [ -z "${PORT_NESTED:-}" ]; then
  P=$(mktemp -d "${TMPDIR:-/tmp}/port-plant.XXXXXX") || { echo "CANNOT-RUN portability-selftest: no scratch dir" >&2; exit 3; }
  trap 'rm -rf "$P"' EXIT
  plant() { # tree-name, file-content -> the nested verdict lines
    rm -rf "${P:?}/$1"; mkdir -p "$P/$1/bin" "$P/$1/bus" "$P/$1/roles" "$P/$1/lifecycle" "$P/$1/staff" "$P/$1/tests"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$P/$1/bin/plant.sh"
    PORT_NESTED=1 INNKEEPER_HOME="$P/$1" bash "$HERE/portability-selftest.sh" 2>&1; echo "rc=$?"
  }
  planted() { # ban-name, offending line: that ban, and ONLY that ban, must go red
    arms=$((arms+1)); local out; out=$(plant "$1" "$2")
    if printf '%s\n' "$out" | grep -q "FAIL $1 " && [ "$(printf '%s\n' "$out" | grep -c '  FAIL ')" = 1 ] \
       && printf '%s\n' "$out" | grep -qx 'rc=1'; then echo "  ok   planted $1"
    else echo "  FAIL planted $1 — the line [$2] did not turn exactly that arm red:"; printf '%s\n' "$out" | sed 's/^/       /'; fails=$((fails+1)); fi
  }
  planted tac-is-gnu-only         'tac f'
  planted sed-i-is-not-portable   "sed -i 's/a/b/' f"
  planted bashpid-needs-bash4     'me=$BASHPID'
  planted bre-alternation         "grep 'a\\|b' f"
  planted grep-P-is-gnu-only      "grep -P '\\d' f"
  planted readlink-f-is-gnu-only  'd=$(readlink -f x)'
  planted date-d-is-gnu-only      'date -d yesterday'
  planted realpath-m-is-gnu-only  'realpath -m x'
  planted stat-c-is-gnu-only      'm=$(stat -c %Y f)'
  planted mktemp-x-must-trail     'f=$(mktemp "$d/.mut-XXXXXX.sh")'
  planted bash4-only-features     'declare -A seen'
  planted find-printf-is-gnu-only "find . -name x -printf '%p'"
  planted date-gnu-formats        't=$(date +%s%N)'
  # THE CONTROL: guarded forms, and banned literals that live only in comments, must stay green --
  # or every planted arm above would pass against a lint that flags everything.
  arms=$((arms+1))
  out=$(plant control "$(printf '%s\n' \
    '# tac, sed -i, readlink -f, date -d, stat -c, declare -A: all prose here' \
    'm=$(stat -c %Y f 2>/dev/null || stat -f %m f 2>/dev/null)  # BSD fallback on the line' \
    '[ -n "${BASHPID:-}" ] && me=$BASHPID' \
    'd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"); f=$(mktemp "$d/.q.XXXXXX")' \
    'grep -E "a|b" f; sed "s|^|&|" f; date -u +%Y-%m-%dT%H:%M:%SZ')")
  if printf '%s\n' "$out" | grep -qx 'rc=0'; then echo "  ok   planted control (guarded forms stay green)"
  else echo "  FAIL planted control — a guarded or comment-only line was flagged:"; printf '%s\n' "$out" | sed 's/^/       /'; fails=$((fails+1)); fi
fi

EXPECT_ARMS=${INNKEEPER_EXPECT_PORT_ARMS:-${PORT_NESTED:+13}}
EXPECT_ARMS=${EXPECT_ARMS:-27}
echo "portability-selftest: $((arms-fails))/$arms passed (expected $EXPECT_ARMS arms)"
[ "$arms" = "$EXPECT_ARMS" ] || { echo "  FAIL arm count: ran $arms, expected $EXPECT_ARMS" >&2; exit 1; }
[ "$fails" = 0 ]
