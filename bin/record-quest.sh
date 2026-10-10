#!/usr/bin/env bash
# record-quest.sh — run bin/hello-party.sh once and capture it as a timed fixture.
#
# The fixture is what bin/replay.sh and the web replay (replay/index.html) play back. It is
# the quest's own stdout, nothing invented: a line and the elapsed seconds since the quest
# started, one pair per line, in order. No model is called and nothing is read from the
# quest except what it already prints — the same text a stranger sees running it live.
#
#   bin/record-quest.sh                 write fixtures/recorded-quest.json
#   bin/record-quest.sh --check         write nothing; print DRIFT if it differs from committed
#
# --check exists because a committed fixture can go stale: hello-party.sh's own text changes
# (a line is reworded, a step is added) and the fixture silently keeps narrating the old run.
# tests/bin-record-quest-selftest.sh runs this to catch that before a replay ships a quest
# that never happened.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
OUT="$REPO/fixtures/recorded-quest.json"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required to write the fixture" >&2; exit 2; }

TMP=$(mktemp "${TMPDIR:-/tmp}"/record-quest.XXXXXX) || exit 2
trap 'rm -f "$TMP"' EXIT

# One line per output line, each stamped with seconds-since-start to two decimal places.
# gawk's strftime isn't portable (macOS ships the BSD awk); python3 times it instead, one
# process per run (not per line) so the quest's own ~1s runtime dominates the cost.
#
# hello-party.sh builds its sandbox under a fresh `mktemp -d`, so its own narration prints a
# DIFFERENT path every single run (.../hello-party.XXXXXX/...) even with nothing else changed.
# Left alone, that makes --check cry DRIFT on every run including a no-op one, and would make
# the committed fixture an unreproducible artifact (a fresh `bin/record-quest.sh` would always
# diff from the last commit in review). Normalize the random suffix to a fixed placeholder so
# the fixture reflects the quest's STRUCTURE, which is what replay and --check both care about.
python3 - "$REPO/bin/hello-party.sh" > "$TMP" <<'PY'
import re, subprocess, sys, time, json

SANDBOX_RE = re.compile(r"hello-party\.[A-Za-z0-9]{6,}")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
COMMIT_RE = re.compile(r"\bcommit [0-9a-f]{7,40}\b")

def normalize(line):
    # Three more per-run randoms, same reasoning as the sandbox path above: the lease
    # nonce (a uuid4) and each worker commit hash differ every run with nothing else
    # changed, so they'd read as drift too if left in.
    line = SANDBOX_RE.sub("hello-party.SANDBOX", line)
    line = UUID_RE.sub("00000000-0000-0000-0000-000000000000", line)
    line = COMMIT_RE.sub("commit SHA", line)
    return line

script = sys.argv[1]
start = time.monotonic()
proc = subprocess.Popen(["bash", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
events = []
for line in proc.stdout:
    events.append({"t": round(time.monotonic() - start, 2), "line": normalize(line.rstrip("\n"))})
rc = proc.wait()
if rc != 0:
    sys.stderr.write("FATAL: bin/hello-party.sh exited %d while recording\n" % rc)
    sys.exit(2)
json.dump({"quest": "version-flag", "recorded_rc": rc, "events": events}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
rc=$?
[ "$rc" = 0 ] || exit "$rc"

if [ "$CHECK" = 1 ]; then
  if [ ! -f "$OUT" ]; then
    echo "DRIFT: no committed fixture at $OUT"
    exit 1
  fi
  # Compare LINES only, not timing -- timing is expected to vary run to run; the text is
  # what must not drift silently out from under a replay.
  python3 - "$TMP" "$OUT" <<'PY'
import json, sys
fresh = [e["line"] for e in json.load(open(sys.argv[1]))["events"]]
committed = [e["line"] for e in json.load(open(sys.argv[2]))["events"]]
if fresh != committed:
    print("DRIFT: fresh run's lines differ from the committed fixture")
    print("  fresh has %d lines, committed has %d" % (len(fresh), len(committed)))
    for i, (a, b) in enumerate(zip(fresh, committed)):
        if a != b:
            print("  first difference at line %d:\n    fresh:     %r\n    committed: %r" % (i, a, b))
            break
    sys.exit(1)
print("MATCH: committed fixture's lines match a fresh run")
PY
  exit $?
fi

mkdir -p "$REPO/fixtures"
cp "$TMP" "$OUT"
echo "wrote $OUT ($(python3 -c "import json;print(len(json.load(open('$OUT'))['events']))") lines)"
