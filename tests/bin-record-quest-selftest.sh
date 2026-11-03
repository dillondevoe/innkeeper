#!/usr/bin/env bash
# bin-record-quest-selftest.sh — the recorded-quest fixture must not go stale, and the
# replay page must actually be built from it, not from a second hand-typed copy.
#
# bin/record-quest.sh captures bin/hello-party.sh's own stdout into
# fixtures/recorded-quest.json; bin/render-replay.sh turns that fixture into
# replay/index.html. The risk this battery exists for is exactly the one SCHEMA.md names
# for the quest-record doc (see schema-fixture-selftest.sh): a committed artifact quietly
# narrating an OLDER run than the tool it claims to replay, with both files still reading
# fine to a human. --check exists on record-quest.sh for this reason; A4 is the mutation
# control proving --check can actually FAIL, not just pass by construction (same pattern
# as bin-hello-party-selftest.sh's D1/D2 arms).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FIXTURE="$REPO/fixtures/recorded-quest.json"
REPLAY="$REPO/replay/index.html"

EXPECT_ARMS=19
fails=0
arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL"; }

command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 required"; exit 2; }

[ -x "$REPO/bin/record-quest.sh" ] && ok "A0 bin/record-quest.sh exists and is executable" \
  || bad "A0 bin/record-quest.sh missing or not executable"
[ -x "$REPO/bin/render-replay.sh" ] && ok "A1 bin/render-replay.sh exists and is executable" \
  || bad "A1 bin/render-replay.sh missing or not executable"
[ -s "$FIXTURE" ] && ok "A2 fixtures/recorded-quest.json exists and is non-empty" \
  || bad "A2 fixtures/recorded-quest.json missing/empty — run bin/record-quest.sh"
[ -s "$REPLAY" ] && ok "A3 replay/index.html exists and is non-empty" \
  || bad "A3 replay/index.html missing/empty — run bin/render-replay.sh"

if [ ! -s "$FIXTURE" ] || [ ! -s "$REPLAY" ]; then
  echo "ABORT: a substrate is missing; remaining arms would be vacuous."
  echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
  exit 1
fi

# A4: the committed fixture must match a FRESH run's lines, right now, on this checkout.
# This is the live form of the drift this battery exists to catch.
if bash "$REPO/bin/record-quest.sh" --check >/tmp/record-quest-check.$$ 2>&1; then
  ok "A4 committed fixture matches a fresh bin/hello-party.sh run (no drift)"
else
  bad "A4 committed fixture has DRIFTED from a fresh run"
  sed 's/^/    /' /tmp/record-quest-check.$$
fi
rm -f /tmp/record-quest-check.$$

# A4b: HOST PORTABILITY. The fixture was recorded on one host; CI is another, with a different
# temp root ($TMPDIR is /var/folders/.../T/ on macOS, /tmp on Linux). Re-run --check under a
# temp root that is neither, so a fixture that baked in its recorder's temp path fails here on
# EVERY host, not only on the one that differs from the recorder. Pre-fix, main was red in CI
# for exactly this: a Mac-recorded fixture against a Linux run.
ALT_TMP=$(mktemp -d)
if TMPDIR="$ALT_TMP/elsewhere.d" sh -c 'mkdir -p "$TMPDIR" && exec bash "$1" --check' _ "$REPO/bin/record-quest.sh" >"$ALT_TMP/out" 2>&1; then
  ok "A4b fixture matches a fresh run under a different temp root (host-portable)"
else
  bad "A4b fixture depends on the recording host's temp root"
  sed 's/^/    /' "$ALT_TMP/out"
fi
rm -rf "$ALT_TMP"

# A5: MUTATION CONTROL. Copy the repo, change one printed line in hello-party.sh, then run
# --check from the COPY against the ORIGINAL committed fixture. --check must report DRIFT —
# proving a real mismatch is caught, not that the check always passes.
TMPREPO=$(mktemp -d)
trap 'rm -rf "$TMPREPO"' EXIT
cp -R "$REPO"/. "$TMPREPO"/
python3 - "$TMPREPO/bin/hello-party.sh" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().replace("The quest is posted", "The quest is announced")
open(p, "w").write(text)
PY
if grep -q "The quest is announced" "$TMPREPO/bin/hello-party.sh"; then
  if bash "$TMPREPO/bin/record-quest.sh" --check >/tmp/record-quest-mutcheck.$$ 2>&1; then
    bad "A5 MUTATION CONTROL: --check passed against a changed hello-party.sh (should DRIFT)"
    sed 's/^/    /' /tmp/record-quest-mutcheck.$$
  else
    ok "A5 MUTATION CONTROL: a changed hello-party.sh is correctly reported as DRIFT"
  fi
else
  bad "A5 MUTATION CONTROL SETUP: could not patch the copy's hello-party.sh"
fi
rm -f /tmp/record-quest-mutcheck.$$

# A6: the replay page was actually BUILT from the fixture, not hand-typed — same event
# count embedded in the page as the fixture holds, read out of each independently.
python3 - "$FIXTURE" "$REPLAY" <<'PY'
import json, re, sys
fixture = json.load(open(sys.argv[1]))
n_fixture = len(fixture["events"])
html = open(sys.argv[2]).read()
m = re.search(r"const EVENTS = (\[.*?\]);\s*\n", html, re.S)
if not m:
    print("  A6 FAIL: no EVENTS array found embedded in replay/index.html")
    sys.exit(1)
events = json.loads(m.group(1))
if len(events) == n_fixture:
    print("  A6 PASS: replay page embeds all %d fixture events" % n_fixture)
    sys.exit(0)
print("  A6 FAIL: fixture has %d events, replay page embeds %d" % (n_fixture, len(events)))
sys.exit(1)
PY
[ $? -eq 0 ] && arms=$((arms+1)) || { arms=$((arms+1)); fails=$((fails+1)); }

# A7/A7b/A7c: THE NORMALIZATION RULES ARE LIVE, AND THEY FLATTEN THE LEASE AGE.
#
# This is the arm the intermittent red on this battery was missing. lifecycle/lease.sh prints
# a lock's age in WHOLE seconds off an integer awake clock, and hello-party.sh claims the lease
# twice ~26ms apart to show the second instance standing down -- so `age=0` nearly always, and
# `age=1` whenever that pair straddles a one-second rollover. A4 then reported DRIFT with no
# other cause, which is why it was green every time it was run by hand and red occasionally
# inside run-all.sh. Measured both directions against a fake clock (lease.sh takes
# LEASE_UPTIME_FILE): 100.90 -> age=0, 101.05 -> age=1, same lock.
#
# A7 asserts the rule collapses it. A7b is the PRE-FIX arm: it applies the OTHER three rules
# only and asserts the two readings still differ -- without it, A7 would pass on a normalize()
# that returned a constant, and nothing would show the defect was ever real. A7c is the control
# in the other direction: the version number, the commit COUNT and the step numbers are what
# the quest is ASSERTING, so a rule that ate them would be worse than the flake it fixed.
python3 -B - "$REPO/bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import quest_normalize as qn

held0 = "   a second instance of the same worker stands down: HELD-BY-OTHER age=0"
held1 = "   a second instance of the same worker stands down: HELD-BY-OTHER age=1"
fails = 0

if qn.normalize(held0) == qn.normalize(held1) and "age=" in qn.normalize(held0):
    print("  A7 PASS: a lease age of 0 and of 1 normalize to the same line")
else:
    print("  A7 FAIL: the lease age is not flattened — %r vs %r"
          % (qn.normalize(held0), qn.normalize(held1)))
    fails += 1

def without_age(line):
    line = qn.SANDBOX_RE.sub("$TMPDIR/hello-party.SANDBOX", line)
    line = qn.UUID_RE.sub("00000000-0000-0000-0000-000000000000", line)
    return qn.COMMIT_RE.sub("commit SHA", line)

if without_age(held0) != without_age(held1):
    print("  A7b PASS: PRE-FIX arm — without the age rule the same lock reads as drift")
else:
    print("  A7b FAIL: PRE-FIX arm did not fire; this battery cannot show the defect was real")
    fails += 1

load_bearing = [
    "  The tool now answers --version with: 0.1.0",
    "  The party made 2 commits to get there: the gate refused the first one.",
    "   PASS `tool.sh --version` prints: 0.1.0",
]
untouched = [l for l in load_bearing if qn.normalize(l) == l]
if len(untouched) == len(load_bearing):
    print("  A7c PASS: CONTROL — the version, the commit count and the step text are untouched")
else:
    for l in load_bearing:
        if qn.normalize(l) != l:
            print("  A7c FAIL: a rule ate text the quest is asserting: %r -> %r" % (l, qn.normalize(l)))
    fails += 1

sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then arms=$((arms+3)); else arms=$((arms+3)); fails=$((fails+1)); fi

# A8/A8b: THE TWO HALVES ACTUALLY MEET. A7 proves the rule flattens an age and A4 proves the
# committed fixture matches a fresh run -- but both can pass while the rule never reaches the
# recorded line, which is the shape where a unit arm and an integration arm are each green and
# the bug is in the join. So force the boundary crossing in a COPY of the repo (lease.sh made
# to report age+1, i.e. what it prints when the two claims straddle a rollover) and run the
# real `--check`. Note what it compares against: record-quest.sh finds its fixture by its own
# location, so inside the copy that is the copy of THIS CHECKOUT's fixture (working tree, not
# HEAD). A4 is what pins the checkout's fixture to a fresh run; A8 pins the boundary case.
#
# A8b is the control: the SAME forced copy with the age rule removed must DRIFT. Without it,
# A8 would also pass on a --check that had stopped comparing lines at all.
force_boundary() { # force_boundary <dest> <strip-age-rule:0|1>
  cp -R "$REPO"/. "$1"/
  python3 - "$1/lifecycle/lease.sh" "$1/bin/quest_normalize.py" "$2" <<'PY'
import sys
lease, norm, strip = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(lease).read()
old = 'echo "HELD-BY-OTHER age=$age$(awake_clock_note)"'
if t.count(old) != 1:
    sys.stderr.write("SETUP: expected exactly one HELD-BY-OTHER print, found %d\n" % t.count(old))
    sys.exit(2)
open(lease, "w").write(t.replace(old, 'echo "HELD-BY-OTHER age=$((age+1))$(awake_clock_note)"'))
if strip == "1":
    s = open(norm).read()
    rule = '    line = AGE_RE.sub("age=N", line)\n'
    if rule not in s:
        sys.stderr.write("SETUP: the age rule is not where this arm expects it\n")
        sys.exit(2)
    open(norm, "w").write(s.replace(rule, ""))
PY
}

B8=$(mktemp -d) && [ -n "$B8" ] || { bad "A8 SETUP: mktemp failed"; B8=; }
if [ -n "$B8" ] && force_boundary "$B8" 0 2>"$B8/setup.err"; then
  if bash "$B8/bin/record-quest.sh" --check >"$B8/out" 2>&1; then
    ok "A8 a run that straddles a one-second lease rollover is NOT drift (end to end)"
  else
    bad "A8 a boundary-crossing run still reports DRIFT — the flake is not fixed on the real path"
    sed 's/^/    /' "$B8/out"
  fi
else
  bad "A8 SETUP: could not force the boundary crossing"; sed 's/^/    /' "$B8/setup.err"
fi
[ -n "$B8" ] && rm -rf "$B8"

B8B=$(mktemp -d) && [ -n "$B8B" ] || { bad "A8b SETUP: mktemp failed"; B8B=; }
if [ -n "$B8B" ] && force_boundary "$B8B" 1 2>"$B8B/setup.err"; then
  if bash "$B8B/bin/record-quest.sh" --check >"$B8B/out" 2>&1; then
    bad "A8b CONTROL: with the age rule removed a boundary-crossing run passed — --check is inert"
    sed 's/^/    /' "$B8B/out"
  elif grep -q '^DRIFT' "$B8B/out"; then
    ok "A8b CONTROL: with the age rule removed the same run DOES drift (the defect was real)"
  else
    # A nonzero exit that is NOT drift (an import error, a crashed quest) compared nothing, and
    # reading it as the control firing would make an inert --check look armed.
    bad "A8b CONTROL: --check failed for a reason other than DRIFT — it compared nothing"
    sed 's/^/    /' "$B8B/out"
  fi
else
  bad "A8b SETUP: could not force the boundary crossing"; sed 's/^/    /' "$B8B/setup.err"
fi
[ -n "$B8B" ] && rm -rf "$B8B"

# A9/A9b/A9c: THE PAGE IS A PURE FUNCTION OF THE FIXTURE. A6 only counts events, so a page that
# was rendered from an older fixture -- or hand-edited after rendering -- passed it. Render twice
# into a scratch dir: the two must be byte-identical (A9), the committed page must be byte-identical
# to them (A9b: the README's "fails the suite if either one drifts"), and a one-word change to a
# COPY of the fixture must change the render (A9c: the control; without it A9b passes on a renderer
# that ignores its input).
R9=$(mktemp -d)
bash "$REPO/bin/render-replay.sh" "$R9/a.html" >/dev/null 2>"$R9/err" \
  && bash "$REPO/bin/render-replay.sh" "$R9/b.html" >/dev/null 2>>"$R9/err"
if [ -s "$R9/a.html" ] && cmp -s "$R9/a.html" "$R9/b.html"; then
  ok "A9 two renders of the same fixture are byte-identical"
else
  bad "A9 render is not deterministic (or failed)"; sed 's/^/    /' "$R9/err"
fi
if [ -s "$R9/a.html" ] && cmp -s "$R9/a.html" "$REPLAY"; then
  ok "A9b committed replay/index.html is exactly what the fixture renders to"
else
  bad "A9b replay/index.html has drifted from its fixture — run bin/render-replay.sh"
  diff "$REPLAY" "$R9/a.html" | head -20 | sed 's/^/    /'
fi
mkdir -p "$R9/copy/bin" "$R9/copy/fixtures"
cp "$REPO/bin/render-replay.sh" "$R9/copy/bin/"
sed 's/The quest is posted/The quest is announced/' "$FIXTURE" > "$R9/copy/fixtures/recorded-quest.json"
if bash "$R9/copy/bin/render-replay.sh" "$R9/c.html" >/dev/null 2>&1 && [ -s "$R9/c.html" ] \
   && ! cmp -s "$R9/c.html" "$R9/a.html" && grep -q "The quest is announced" "$R9/c.html"; then
  ok "A9c CONTROL: a changed fixture changes the render"
else
  bad "A9c CONTROL: a changed fixture did not change the render"
fi
rm -rf "$R9"

# A10/A11/A12: THE PAGE'S OWN CONTRACT. A10: one self-contained file -- nothing fetched from
# anywhere (no src/href/url()/@import, no http). A11: the accessibility floor -- a language, a
# reduced-motion rule, every control labelled, and every text colour token at WCAG AA (4.5:1)
# against every surface it is drawn on. A12: the refusal and the fix are marked, on the steps the
# fixture itself puts them, and the fix comes after the refusal.
python3 - "$FIXTURE" "$REPLAY" <<'PY'
import json, re, sys
fx = json.load(open(sys.argv[1])); page = open(sys.argv[2]).read(); fails = 0
def report(ok, msg):
    global fails
    print("  %s %s" % (msg.split(":")[0], ("PASS:" if ok else "FAIL:") + msg.split(":", 1)[1]))
    fails += 0 if ok else 1

ext = re.findall(r'(?i)(https?://|\bsrc\s*=|\bhref\s*=|url\(|@import|<link\b|<iframe\b)', page)
report(not ext, "A10: page requests nothing external%s" % ("" if not ext else " — found %r" % ext))

problems = []
if not re.search(r'<html lang="[a-z]', page): problems.append("no lang")
if "prefers-reduced-motion" not in page: problems.append("no reduced-motion rule")
for m in re.finditer(r'<input\b[^>]*>|<select\b[^>]*>', page):
    tag = m.group(0); i = re.search(r'id="([^"]+)"', tag)
    if 'aria-label=' not in tag and not (i and 'for="%s"' % i.group(1) in page):
        problems.append("unlabelled control %s" % tag[:40])
for m in re.finditer(r'<button\b[^>]*>(.*?)</button>', page, re.S):
    if not re.sub(r'<span aria-hidden="true">.*?</span>|<[^>]+>|&[a-z#0-9]+;', '', m.group(1)).strip():
        problems.append("button with no text")
tok = dict(re.findall(r'--([a-z-]+):(#[0-9a-f]{6})', page))
def lum(h):
    c = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True); return (la + 0.05) / (lb + 0.05)
texts = ["fg", "muted", "board", "worker", "researcher", "gate", "voice", "red", "green"]
surfaces = ["bg", "panel", "term", "refuse-bg", "fix-bg"]
worst = None
for t in texts:
    for s in surfaces:
        if t not in tok or s not in tok: problems.append("missing token --%s/--%s" % (t, s)); continue
        r = ratio(tok[t], tok[s]); worst = min(worst or r, r)
        if r < 4.5: problems.append("--%s on --%s is %.2f:1" % (t, s, r))
for bg in ("#232b36", "#2e3846", "#34404f"):  # button, button hover, current step
    if bg not in page or ratio(tok.get("fg", "#000000"), bg) < 4.5: problems.append("button text on %s" % bg)
report(not problems, "A11: lang, reduced motion, labelled controls, AA contrast (worst %.2f:1)%s"
       % (worst or 0, "" if not problems else " — " + "; ".join(problems)))

steps = json.loads(re.search(r"const STEPS = (\[.*?\]);\s*\n", page, re.S).group(1))
ref = [s["n"] for s in steps if s["beat"] == "refuse"]; fix = [s["n"] for s in steps if s["beat"] == "fix"]
heads, cur, want_ref, want_fix = {}, None, None, None
for e in fx["events"]:
    m = re.match(r"^\x1b\[1m(\d+)\. (.*)\x1b\[0m$", e["line"])
    if m: cur = int(m.group(1)); heads[cur] = m.group(2); continue
    if want_ref is None and e["line"].strip().startswith("NO "): want_ref = cur
if want_ref is not None:
    want_fix = next((n for n in sorted(heads) if n > want_ref and re.search(r"\bworker\b", heads[n].lower())), None)
lines_refuse = len(re.findall(r'class="ln k-refuse', page))
report(ref == [want_ref] and fix == [want_fix] and want_fix is not None and lines_refuse >= 1,
       "A12: the refusal is marked on step %s and the fix on step %s (page: %r / %r, %d refusal lines)"
       % (want_ref, want_fix, ref, fix, lines_refuse))
sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then arms=$((arms+3)); else arms=$((arms+3)); fails=$((fails+1)); fi

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
exit $((fails ? 1 : 0))
