#!/usr/bin/env bash
# ticks.sh <brain> <verb> — the ONE writer of the recycle-pressure counter.
#
#   ticks.sh <brain> tick            +1. Call once per REAL tick, never on a debounce skip.
#   ticks.sh <brain> reset           zero it, print what it displaced. Called by recycle.sh.
#   ticks.sh <brain> status [--all]  print without mutating; --all walks the ROSTER.
#   ticks.sh <brain> due             rc 0 = due for a recycle, 1 = not (T2, pressure)
#   ticks.sh <brain> drift           rc 0 = due for a recycle, 1 = not (T4, idle drift)
#   ticks.sh --selftest
#
# WHY IT IS A SCRIPT. In the source mesh every brain's skill file carried the sentence
# "count the ticks since boot; reset in the recycle step" and NOTHING counted it — the
# grep across all eight lanes was empty. A counter nobody increments never reaches its
# threshold, so every tick reads "no recycle needed" and the log line is correct-looking
# while it says so. An instruction no code path enforces is not a control, and the half
# you are not staring at is the half that stays prose.
#
# STORE: $INNKEEPER_HOME/state/ticks/<brain>.json — ONE FILE PER BRAIN, written only by
# that brain. Not one shared file: the state dir is the kind of thing a party replicates
# between machines, and two hosts writing one file is a conflict copy, which silently
# drops the losing side's newest lines out of a guard's evidence trail.
#
# THRESHOLD comes from the roster (`recycle_after:` on the brain's row, read through
# bus/actor.sh). A brain with no row gets DEFAULT_THRESHOLD and a stderr note, so the
# party's tenth member works on day one instead of failing closed on a table nobody
# remembered to edit. Aliases resolve, so the counter cannot be split across two
# spellings of one brain.
#
# FAIL DIRECTIONS, all deliberate, none of them "consistent":
#   unusable count (null, negative, a string)  -> set to threshold, loud on stderr. TOWARD
#     recycling: resetting to 0 would silently re-create the never-fires bug above.
#   unparseable file                           -> rc 4, file NOT overwritten, says DUE.
#   absent file                                -> NEVER TICKED, never a silent 0: a brain
#     whose writer never landed and a brain that just recycled must not read alike.
#   no outbound comm (drift anchor absent)     -> UNRECORDED -> NOT due. An unknown anchor
#     must not manufacture a recycle.
#   no last_reset (never cleanly recycled)     -> the age conjunct DOES NOT BIND -> can be
#     due. An unknown session age must not withhold the protection.
# The last two are opposite binding rules for the same word UNRECORDED, and that is the
# point: both fail AWAY from a wrong recycle, and "fixing" them into one rule breaks one.
#
# T4/drift and why the third conjunct exists: the outbound anchor SURVIVES a recycle while
# the tick count does not, so `ticks>=3 AND idle>=4h` re-fired every three ticks on a
# freshly recycled context that had merely nothing to say. Drift cannot exceed session age,
# so a young session cannot be drifting: `age >= 4h` is the fix, read from last_reset,
# which recycle.sh already stamps — no second writer.
set -u

BRAIN_IN="${1:?usage: ticks.sh <brain> tick|reset|status [--all]|due|drift|selftest}"
R=$(cd "$(dirname "$0")/.." && pwd -P)
if [ "$BRAIN_IN" = "--selftest" ]; then exec bash "$R/tests/lifecycle-ticks-selftest.sh"; fi
VERB="${2:?usage: ticks.sh <brain> tick|reset|status [--all]|due|drift|selftest}"
ALL="${3:-}"

: "${INNKEEPER_HOME:=$R}"
DIR="${TICKS_DIR:-$INNKEEPER_HOME/state/ticks}"
ACTOR="$R/bus/actor.sh"
DEFAULT_THRESHOLD=8

if ! command -v python3 >/dev/null 2>&1; then
  echo "ticks.sh: FAIL — no python3 here; counter NOT touched (treat as DUE: fail toward recycle)" >&2
  exit 3
fi

# The roster is read ONCE, here, through the bus's parser — never re-parsed in python below.
# A refusal from the parser (empty roster) is consumed EXPLICITLY, because command
# substitution collapses "it said no" and "it said nothing" into the same empty string.
if ! ROSTER=$(bash "$ACTOR" roster 2>&1); then
  echo "ticks.sh: FAIL — roster unreadable: ${ROSTER}" >&2; exit 2
fi
LANES=$(printf '%s\n' "$ROSTER" | sed -n 's/^lanes: *//p')
# Resolved BY THE PARSER, never by re-reading its printed roster. The first cut of this
# script scraped the alias map out of `roster` output with a sed of its own and silently
# failed to match, so a brain addressed by its alias opened a SECOND counter file under
# the alias — one brain, two counts, neither ever reaching threshold. That is the same
# two-halves-spelling-one-rule defect this whole port exists to remove, committed inside
# the port. Ask the one parser; do not re-implement it against its own output.
BRAIN=$(bash "$ACTOR" resolve "$BRAIN_IN") || BRAIN="$BRAIN_IN"

THRESH=$(bash "$ACTOR" field "$BRAIN" recycle_after 2>/dev/null) || THRESH=""
case "$THRESH" in
  ''|*[!0-9]*) [ -n "$THRESH" ] && echo "ticks.sh: note — '$BRAIN' recycle_after='$THRESH' is not a count; using default $DEFAULT_THRESHOLD" >&2 \
                                || echo "ticks.sh: note — '$BRAIN' has no recycle_after on the roster; using default $DEFAULT_THRESHOLD" >&2
               THRESH=$DEFAULT_THRESHOLD ;;
esac

# Where this brain's outbound comms land — the drift anchor. Read from the roster's bus
# path so it is the same directory the rest of the party writes to.
BUS=$(printf '%s\n' "$ROSTER" | sed -n 's/^party: *//p')
COMMS="${TICKS_COMMS_DIR:-$(dirname "$BUS")/comms}"

export TK_BRAIN="$BRAIN" TK_VERB="$VERB" TK_ALL="$ALL" TK_DIR="$DIR" \
       TK_THRESH="$THRESH" TK_LANES="$LANES" TK_COMMS="$COMMS" TK_DEFAULT="$DEFAULT_THRESHOLD"
python3 - <<'PY'
import datetime, glob, json, os, re, sys, time

brain = os.environ["TK_BRAIN"]; verb = os.environ["TK_VERB"]; allf = os.environ["TK_ALL"]
DIR = os.environ["TK_DIR"]; T = int(os.environ["TK_THRESH"]); COMMS = os.environ["TK_COMMS"]
LANES = os.environ["TK_LANES"].split()
KEY = "ticks_since_boot"
DRIFT_TICKS, DRIFT_S = 3, 4 * 3600

def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def path(b): return os.path.join(DIR, b + ".json")
def usable(v): return isinstance(v, int) and not isinstance(v, bool) and v >= 0

def load(b):
    p = path(b)
    if not os.path.exists(p): return None
    try:
        with open(p) as f: return json.load(f)
    except ValueError as e:
        sys.stderr.write("ticks.sh: FAIL — %s is present but unparseable (%s); NOT overwriting. "
                         "Treat as RECYCLE DUE and fix the file.\n" % (p, e))
        sys.exit(4)

def save(b, st):
    os.makedirs(DIR, exist_ok=True)
    tmp = path(b) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, path(b))   # atomic: a reader never sees a half-written count

def secs_since(ts):
    try: d = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception: return None
    return int((datetime.datetime.now(datetime.timezone.utc) - d).total_seconds())

def ship_idle_s(b):
    """Seconds since this brain's newest OUTBOUND comm, or None if it has never shipped.

    ANCHORED regex, not a `*<b>-to-*` glob. The bus really contains names like
    `alfa-to-bravo-RULED-bravo-to-charlie-...md` — a comm FROM alfa that the loose glob
    would count as an outbound ship by bravo, i.e. an anchor belonging to another brain.
    Both date conventions count: a leading `YYYY-MM-DD-` is a date, not an author.
    """
    pat = re.compile(r"^(?:\d{4}-\d{2}-\d{2}-)?" + re.escape(b) + r"-to-.*\.md$")
    try: fs = [os.path.join(COMMS, f) for f in os.listdir(COMMS) if pat.match(f)]
    except OSError: return None
    if not fs: return None
    return int(time.time() - max(os.path.getmtime(f) for f in fs))

def fmt(sec): return "UNRECORDED" if sec is None else "%.1fh" % (sec / 3600.0)

def drift_due(st, b):
    n = st.get(KEY); si = ship_idle_s(b); age = secs_since(st.get("last_reset", ""))
    return (usable(n) and n >= DRIFT_TICKS and si is not None and si >= DRIFT_S
            and (age is None or age >= DRIFT_S))          # absent age does not bind

def line(b, n, t, st=None, extra=""):
    tail = ""
    if st is not None:
        tail = "  idle=%s ship_idle=%s age=%s" % (fmt(secs_since(st.get("last_tick", ""))),
                                                  fmt(ship_idle_s(b)),
                                                  fmt(secs_since(st.get("last_reset", ""))))
        if drift_due(st, b):
            tail += "  DRIFT DUE (ticks>=%d, ship_idle>=4h, age>=4h)" % DRIFT_TICKS
    due = "  RECYCLE DUE (>=%d)" % t if (usable(n) and n >= t) else ""
    return "ticks: %s %s=%s/%d%s%s%s" % (b, KEY, n, t, due, tail, extra)

if verb == "status" and allf == "--all":
    # Walks the ROSTER, not the files that happen to exist: a brain whose writer never
    # landed has NO file, and if --all listed only files it would be invisible — exactly
    # the silence this script was written to end. NEVER TICKED and 0/T are different states.
    files = {os.path.basename(p)[:-5]: p for p in glob.glob(os.path.join(DIR, "*.json"))}
    for b in sorted(set(LANES) | set(files)):
        if b not in files:
            print("ticks: %s NEVER TICKED (no file — writer not landed, or no real tick yet)" % b); continue
        try: st = json.load(open(files[b]))
        except ValueError: print("ticks: %s UNPARSEABLE (treat as DUE)" % b); continue
        print(line(b, st.get(KEY), st.get("threshold", T), st=st,
                   extra="  last_tick=%s last_reset=%s" % (st.get("last_tick"), st.get("last_reset"))))
    sys.exit(0)

if verb == "tick":
    st = load(brain) or {}
    raw = st.get(KEY, 0)
    if usable(raw): n = raw + 1
    else:
        sys.stderr.write("ticks.sh: %s %s=%r is unusable — failing TOWARD recycle (set to threshold %d) "
                         "rather than resetting to 0.\n" % (brain, KEY, raw, T))
        n = T
    st.update({KEY: n, "brain": brain, "threshold": T, "last_tick": now()})
    save(brain, st); print(line(brain, n, T, st=st)); sys.exit(0)

if verb == "reset":
    st = load(brain) or {}
    before = st.get(KEY)
    st.update({KEY: 0, "brain": brain, "threshold": T, "last_reset": now()})
    save(brain, st)
    print("ticks: %s %s reset 0/%d displaced=%s" % (brain, KEY, T, before)); sys.exit(0)

if verb in ("status", "due", "drift"):
    st = load(brain)
    if st is None:
        print("ticks: %s NEVER TICKED (no file) — %s=0/%d  idle=UNRECORDED ship_idle=UNRECORDED age=UNRECORDED"
              % (brain, KEY, T))
        sys.exit(1 if verb in ("due", "drift") else 0)
    n = st.get(KEY)
    if not usable(n):
        print(line(brain, n, T, st=st, extra="  (unusable — treat as DUE)"))
        sys.exit(0 if verb == "due" else (1 if verb == "drift" else 0))
    print(line(brain, n, T, st=st))
    if verb == "due":   sys.exit(0 if n >= T else 1)
    if verb == "drift": sys.exit(0 if drift_due(st, brain) else 1)
    sys.exit(0)

sys.stderr.write("ticks.sh: unknown verb '%s' (tick|reset|status [--all]|due|drift|selftest)\n" % verb)
sys.exit(5)
PY
