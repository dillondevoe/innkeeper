#!/usr/bin/env bash
# defer.sh "<entry>" — prepend a deferred entry to the brain's state, with a date the MACHINE stamps.
#
# Why: a rule that every deferred item must carry its date went in, and dozens of entries were
# added undated the same day, some within the hour. The rule was not ignored; it depended on a
# person typing a value, which is the discipline that lapses. Stop asking for a value the machine has.
#
# State: $INNKEEPER_HOME/state/$PARTY_BRAIN.json, key "deferred" (a list, newest first).
# A missing state file is created. A state file that is not a JSON object is refused unchanged:
# rewriting it would destroy whatever it held.
set -euo pipefail
: "${INNKEEPER_HOME:?INNKEEPER_HOME not set}"
: "${PARTY_BRAIN:?PARTY_BRAIN not set}"
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: defer.sh \"<entry>\"" >&2; exit 2; }
mkdir -p "$INNKEEPER_HOME/state"
python3 - "$INNKEEPER_HOME/state/$PARTY_BRAIN.json" "$1" <<'PY'
import json, os, sys, tempfile, datetime
p, entry = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except ValueError:
        print(f"REFUSED {os.path.basename(p)} is not valid JSON; left unchanged", file=sys.stderr); sys.exit(1)
    if not isinstance(d, dict) or not isinstance(d.get("deferred", []), list):
        print(f"REFUSED {os.path.basename(p)} has no usable deferred list; left unchanged", file=sys.stderr); sys.exit(1)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
d.setdefault("deferred", []).insert(0, f"[{stamp}] {entry}")
# Write to a temp file and rename, so an interrupted write cannot leave a truncated state file.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, p)
print(f"added [{stamp}] - list now {len(d['deferred'])}")
PY
