#!/usr/bin/env bash
# schema-fixture-selftest.sh — SCHEMA.md and the fixture quest must not drift apart.
#
# WHY THIS EXISTS. SCHEMA.md says, in prose, "this exact record is committed as
# fixtures/quests/first-light.yaml". That sentence is a CONTROL — a consumer builds
# against the doc and tests against the fixture, and is safe only while the two agree.
# It is also, as written, unenforced prose that a one-character edit to either side
# retires in silence, with both files still reading correctly to a human.
#
# The schema was published BEFORE its writer exists (nothing emits a quest record yet),
# which is the whole point of publishing it early — and it is also exactly the condition
# under which a doc drifts from its example without anything objecting, because there is
# no running code to disagree with either one.
#
# So this battery checks the doc against the fixture, and the fixture against the field
# list the doc states. It cannot check either against a writer; when the hello-party
# slice starts emitting quest records, THAT is the arm to add, and it supersedes A2.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
DOC=${SCHEMA_DOC:-$REPO/SCHEMA.md}
FIX=${SCHEMA_FIXTURE:-$REPO/fixtures/quests/first-light.yaml}

EXPECT_ARMS=8
fails=0
arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL"; }

# A0/A1: both substrates must EXIST and be non-empty before any comparison runs.
# An absence assertion over a missing file passes vacuously, and this battery's whole
# job is comparing two files — so "they match" must not be satisfiable by neither
# existing. Note the direction: every arm below gets QUIETER, not louder, on a missing
# file, which is the failure mode that would not announce itself.
[ -s "$DOC" ] && ok "A0 SCHEMA.md exists and is non-empty" || bad "A0 SCHEMA.md missing/empty ($DOC)"
[ -s "$FIX" ] && ok "A1 fixture exists and is non-empty" || bad "A1 fixture missing/empty ($FIX)"

if [ ! -s "$DOC" ] || [ ! -s "$FIX" ]; then
  echo "ABORT: a substrate is missing; remaining arms would be vacuous."
  echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
  exit 1
fi

PYCOUNT=$(mktemp)
python3 - "$DOC" "$FIX" "$PYCOUNT" <<'PY'
import re, sys
doc = open(sys.argv[1]).read()
fx  = open(sys.argv[2]).read()
fails = 0
arms  = 0
def ok(m):
    global arms; arms += 1; print("  %s — PASS" % m)
def bad(m):
    global arms, fails; arms += 1; fails += 1; print("  %s — FAIL" % m)

# A2: the doc's yaml example IS the fixture, byte for byte. This is the sentence.
blocks = re.findall(r"```yaml\n(.*?)```", doc, re.S)
if len(blocks) != 1:
    bad("A2 exactly one yaml block in SCHEMA.md (found %d)" % len(blocks))
elif blocks[0] == fx:
    ok("A2 the doc's yaml example is byte-identical to the fixture")
else:
    bad("A2 doc example has DRIFTED from the fixture")
    import difflib
    sys.stdout.writelines(difflib.unified_diff(
        blocks[0].splitlines(True), fx.splitlines(True), "doc", "fixture"))

# A3: the fixture carries every field the doc marks required — read OUT of the doc's
# own table, not retyped here. A hand-copied field list in this file would be the second
# dialect the whole repo exists to avoid, and it would agree with the doc exactly until
# someone edited one of them.
# Markdown ESCAPES the pipe inside a cell (`string \| null`), so a naive `[^|]*`
# column matcher stops early and silently drops every row whose type is a union —
# which here is exactly the nullable fields. Caught by A4 on this battery's first
# run: A3 reported "all 6 required fields" while the table states 9. Split on
# UNESCAPED pipes only.
def cells(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line)]
required = []
allrows = []
enum = []
for line in doc.splitlines():
    if not line.startswith("|"):
        continue
    c = cells(line)
    # | <name> | <type> | <required> | <notes> |  -> c[0] is the empty pre-pipe cell
    if len(c) >= 5:
        name = re.match(r"^`([a-z_]+)`$", c[1])
        if name and c[3] in ("yes", "no"):
            allrows.append(name.group(1))
            if c[3] == "yes":
                required.append(name.group(1))
            if name.group(1) == "state":
                enum = re.findall(r"`([a-z]+)`", c[4])
if not required:
    bad("A3 SETUP: parsed ZERO required fields out of the doc table")
else:
    missing = [f for f in required if not re.search(r"^%s:" % re.escape(f), fx, re.M)]
    if missing:
        bad("A3 fixture missing required field(s): %s" % ", ".join(missing))
    else:
        ok("A3 fixture carries all %d required fields from the doc table" % len(required))

# A4: CONTROL for A3. A3 can only fail if it parsed a non-empty field list, so assert the
# parse found the fields we can see with our own eyes. Without this, deleting the doc's
# table turns A3 into "no required fields, nothing missing, PASS".
# The table states 9 fields, 8 required + `blocked_on` optional. Assert BOTH counts:
# watching only the required subset would let an optional row be dropped unseen, and
# pinning the numbers is what makes a future edit to the table announce itself here
# instead of quietly shrinking what A3 checks.
if (len(allrows), len(required)) == (9, 8) and {"id", "lane", "state"} <= set(required) \
   and "blocked_on" in allrows and "blocked_on" not in required:
    ok("A4 CONTROL: doc table parsed 9 rows / 8 required, blocked_on optional")
else:
    bad("A4 CONTROL: doc table parse degenerate — rows=%r required=%r" % (allrows, required))

# A5: state must be one of the enum values the doc lists — again read from the doc.
sv = re.search(r"^state:\s*(\S+)", fx, re.M)
if len(enum) < 5:
    bad("A5 SETUP: parsed a degenerate `state` enum from the doc: %r" % (enum,))
elif sv and sv.group(1) in enum:
    ok("A5 fixture state=%s is in the doc's enum %s" % (sv.group(1), enum))
else:
    bad("A5 fixture state=%s NOT in doc enum %s" % (sv.group(1) if sv else None, enum))

# A6: timestamps are machine-stamped UTC in the stated format. The doc says "never
# hand-typed"; the shape is the only part of that a test can see — but a hand-typed
# stamp with round :00 seconds is the tell the source mesh actually hit, so check the
# format strictly rather than loosely.
ts = re.findall(r"^(?:created|updated):\s*(\S+)", fx, re.M)
bad_ts = [t for t in ts if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", t)]
if len(ts) == 2 and not bad_ts:
    ok("A6 created/updated are strict UTC %Y-%m-%dT%H:%M:%SZ")
else:
    bad("A6 timestamp shape wrong: %s" % (bad_ts or ts))

# A7: `lane: null` on an open quest. The doc argues nullability is deliberate; a fixture
# that named a brain here would quietly teach the opposite.
lane  = re.search(r"^lane:\s*(\S+)", fx, re.M)
state = sv.group(1) if sv else ""
if state == "open" and lane and lane.group(1) == "null":
    ok("A7 an open quest has lane: null")
elif state != "open":
    ok("A7 n/a — fixture is not `open` (state=%s); lane unconstrained" % state)
else:
    bad("A7 open quest has lane=%s, doc says null" % (lane.group(1) if lane else None))

print("  (python arms: %d)" % arms)
# Hand the COUNTS back, not just an rc. Folding N failures into one exit status made the
# summary line understate every multi-arm break — seen live: two arms FAIL, total "1".
open(sys.argv[3], "w").write("%d %d\n" % (arms, fails))
sys.exit(1 if fails else 0)
PY
pyrc=$?
# Read the python half's OWN arm and failure counts. If it crashed before writing them,
# the file is empty and that is not a green run: count it as a failure and leave the arm
# total short, so the arm-count check below fires rather than a crash reading as clean.
pyarms=0; pyfails=0
if [ -s "$PYCOUNT" ]; then
  read -r pyarms pyfails < "$PYCOUNT"
else
  echo "  python half produced NO counts (rc=$pyrc) — treating as a failed, short run"
  pyfails=1
fi
rm -f "$PYCOUNT"
arms=$((arms + pyarms))
fails=$((fails + pyfails))

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
exit $((fails ? 1 : 0))
