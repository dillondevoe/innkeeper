#!/usr/bin/env bash
# staff-defer-selftest.sh — battery for staff/defer.sh. The arm count is part of the verdict.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL=${DEFER_IMPL:-$R/staff/defer.sh}
EXPECT_ARMS=8
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export INNKEEPER_HOME=$T PARTY_BRAIN=tester
S=$T/state/tester.json
TODAY=$(date -u +%Y-%m-%d)
n=0 pass=0
arm() { n=$((n + 1)); if printf "%s" "$2" | tr "\n" " " | command grep -Eq -- "$3"; then pass=$((pass + 1)); else echo "FAIL $1: got [$2] want /$3/"; fi; }
j() { python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get("deferred")))' "$S"; }

arm D1-creates-state     "$(bash "$IMPL" first 2>&1)"  "^added \[$TODAY\] - list now 1\$"
arm D2-machine-stamped   "$(j)"                         "^\[\"\[$TODAY\] first\"\]\$"
bash "$IMPL" second >/dev/null 2>&1
arm D3-newest-first      "$(j)"                         "^\[\"\[$TODAY\] second\", \"\[$TODAY\] first\"\]\$"
# Other keys survive: the helper owns one key, not the file.
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["other"]=7;json.dump(d,open(sys.argv[1],"w"))' "$S"
bash "$IMPL" third >/dev/null 2>&1
arm D4-other-keys-kept   "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["other"])' "$S")" '^7$'
# Corrupt state is refused AND left byte-identical (negative arm names the rejection; control is the bytes).
printf 'not json{' > "$S"
out=$(bash "$IMPL" x 2>&1); rc=$?
arm D5-corrupt-refused   "rc=$rc $out"                 '^rc=1 REFUSED tester.json is not valid JSON'
arm D6-corrupt-unchanged "$(cat "$S")"                  '^not json\{$'
printf '[1,2]' > "$S"
arm D7-non-object-refused "$(bash "$IMPL" x 2>&1; cat "$S")" 'has no usable deferred list.*\[1,2\] ?$'
arm D8-empty-entry-usage "$(bash "$IMPL" '' 2>&1; echo rc=$?)" 'usage: .*rc=2'

echo "staff-defer-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"
[ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]
