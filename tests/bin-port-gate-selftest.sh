#!/usr/bin/env bash
# Battery for bin/port-gate.sh. Every fixture is built in a temp repo from SYNTHETIC tokens,
# so this file names no real host, path, account or project. The arm count is part of the
# verdict: a skipped arm cannot hide inside a green.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd -P)
EXPECT_ARMS=27
pass=0 fail=0 arms=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/repo; mkdir -p "$R"/bin "$R"/bus "$R"/docs "$R"/tests
cp "$HERE"/bin/port-gate.sh "$R"/bin/
printf 'wall\tzorblax\nhost\tquuxbox\nidentity\tfrobnitz\npipeline\tsnarfwidget\nname\tpage|scout\n' > "$T"/list
printf 'echo ok\n' > "$T"/green; printf 'exit 1\n' > "$T"/red

G() { INNKEEPER_FORBIDDEN=$T/list bash "$R"/bin/port-gate.sh --no-source "$@"; }
GS() { INNKEEPER_FORBIDDEN=$T/list bash "$R"/bin/port-gate.sh "$@"; }

# arm NAME EXPECT_RC EXPECT_REGEX -- gate args...
arm() {
  local name=$1 want_rc=$2 want=$3; shift 4
  arms=$((arms+1))
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | command grep -Eq -- "$want"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL $name: rc=$rc want=$want_rc out=[$out]"
  fi
}

f() { printf '%b' "$2" > "$R/$1"; echo "$R/$1"; }

# Permitting twins first: without them a gate that refused everything passes every arm below.
arm P1-clean-doc          0 '^PASS docs/clean.md$'  -- G "$(f docs/clean.md 'a plain doc\n')"
cp "$T"/green "$R"/tests/bus-words-selftest.sh
arm P2-english-page-in-bus 0 '^PASS bus/words.sh$'  -- G "$(f bus/words.sh 'echo "see the page"\n')"
arm P3-name-in-docs-address 0 '^PASS'               -- G "$(f docs/n.md 'file mirror-to-page-x.md\n')"

# One refusal per class, naming THAT class.
arm F1-host       1 '^FORBIDDEN host docs/h.md:2$'      -- G "$(f docs/h.md 'ok\nssh quuxbox\n')"
arm F2-identity   1 '^FORBIDDEN identity '              -- G "$(f docs/i.md 'by FROBNITZ\n')"
arm F3-pipeline   1 '^FORBIDDEN pipeline '              -- G "$(f docs/p.md 'snarfwidget\n')"
arm F4-wall-token 1 '^FORBIDDEN wall '                  -- G "$(f docs/w.md 'zorblax\n')"
arm F5-net-lan    1 '^FORBIDDEN net '                   -- G "$(f docs/l.md 'at 192.168.4.20 ok\n')"
arm F6-net-cgnat  1 '^FORBIDDEN net '                   -- G "$(f docs/c.md 'tail 100.99.1.2\n')"
arm F7-path       1 '^FORBIDDEN path '                  -- G "$(f docs/u.md 'cd /home/someone/x\n')"
arm F8-addr-name  1 '^FORBIDDEN address-name bus/a.sh:1$' -- G "$(f bus/a.sh 'ls queues/scout/\n')"

# The wall refuses the SOURCE before reading it: the source does not even exist.
arm W1-wall-source-unread 1 '^REFUSED wall ' -- GS --source /nowhere/zorblax/x.sh "$R/docs/clean.md"

# Fail closed, and say why.
arm C1-empty-file   2 'zero-line'            -- G "$(f docs/empty.md '')"
arm C2-no-list      2 'forbidden list unset' -- env INNKEEPER_FORBIDDEN= bash "$R"/bin/port-gate.sh --no-source "$R/docs/clean.md"
arm C3-no-scanner   2 'scanner not found'    -- env INNKEEPER_GITLEAKS=no-such-scanner-bin INNKEEPER_FORBIDDEN=$T/list bash "$R"/bin/port-gate.sh --no-source "$R/docs/clean.md"

arm S1-secret      1 '^SECRET docs/s.md '    -- G "$(f docs/s.md "aws_access_key_id = AKIA""Z7Q3KXN4VBSW2LTM\naws_secret_access_key = \"q8Vn2rT5wX1yB4mK7pL0""sD3fG6hJ9aZcE2uI5oP8\"\n")"
arm N1-no-selftest 1 '^NO-SELFTEST bus/b.sh$' -- G "$(f bus/b.sh 'echo hi\n')"
cp "$T"/red "$R"/tests/bus-r-selftest.sh
arm N2-selftest-red 1 '^SELFTEST-RED bus/r.sh$' -- G "$(f bus/r.sh 'echo hi\n')"
arm O1-outside-repo 1 '^REFUSED outside-repo' -- G "$T/green"

# Security-review arms (2026-09-15): each was a reproduced fail-open, shown RED before the fix.
arm B1-nul-byte-is-not-clean 2 'CANNOT-ASSESS docs/nul.md not text' -- G "$(f docs/nul.md 'x quuxbox\n\0\n')"
printf 'quuxbox\n' | iconv -t UTF-16LE > "$R"/docs/u16.md
arm B2-utf16-is-not-clean    2 'CANNOT-ASSESS docs/u16.md not text' -- G "$R/docs/u16.md"
printf 'host\tquuxbox|(\nname\tpage\n' > "$T"/badlist
arm R1-invalid-regex         2 'CANNOT-ASSESS .*invalid regex' -- env INNKEEPER_FORBIDDEN=$T/badlist bash "$R"/bin/port-gate.sh --no-source "$R/docs/clean.md"
printf 'name\tpage\r\nhost\tquuxbox\r\n' > "$T"/crlist
arm R2-crlf-list             1 '^FORBIDDEN host ' -- env INNKEEPER_FORBIDDEN=$T/crlist bash "$R"/bin/port-gate.sh --no-source "$R/docs/h.md"
mkdir -p "$T"/zorblax; ln -s "$T"/zorblax "$T"/alias
arm W2-wall-via-symlink      1 '^REFUSED wall ' -- GS --source "$T/alias/x.sh" "$R/docs/clean.md"
arm W3-source-required       2 'CANNOT-ASSESS .*--source' -- GS "$R/docs/clean.md"
mkdir -p "$R"/lifecycle; cp "$T"/green "$R"/tests/deploy-selftest.sh
arm N3-basename-collision    1 '^NO-SELFTEST lifecycle/deploy.py$' -- G "$(f lifecycle/deploy.py 'print(1)\n')"
arm N4-path-keyed-selftest   0 '^PASS lifecycle/deploy.py$' -- bash -c "cp '$T/green' '$R/tests/lifecycle-deploy-selftest.sh' && INNKEEPER_FORBIDDEN='$T/list' bash '$R/bin/port-gate.sh' --no-source '$R/lifecycle/deploy.py'"

echo "port-gate-selftest: $pass/$arms passed (expected $EXPECT_ARMS arms)"
[ "$fail" = 0 ] && [ "$arms" = "$EXPECT_ARMS" ]
