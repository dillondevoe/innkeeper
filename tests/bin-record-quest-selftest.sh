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

EXPECT_ARMS=21
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

# A9/A9b: THE COMMITTED PAGE IS A FRESH RENDER OF THE COMMITTED FIXTURE. A6 only counts events,
# so a page whose markup, labels or player drifted from what render-replay.sh now writes would
# still pass it. Render twice in a COPY: the two renders must be byte-identical (the render is a
# pure function of the fixture) and equal to the committed page. A9b is the control: change one
# fixture line in a copy and the fresh render must DIFFER from the committed page, so A9 cannot
# pass by comparing a file with itself.
R9=$(mktemp -d)
cp -R "$REPO"/. "$R9"/
if bash "$R9/bin/render-replay.sh" >/dev/null 2>&1 && cp "$R9/replay/index.html" "$R9/first.html" \
   && bash "$R9/bin/render-replay.sh" >/dev/null 2>&1; then
  if ! cmp -s "$R9/first.html" "$R9/replay/index.html"; then
    bad "A9 two renders of the same fixture differ — the render is not deterministic"
  elif ! cmp -s "$R9/replay/index.html" "$REPLAY"; then
    bad "A9 committed replay/index.html is not a fresh render of the fixture — run bin/render-replay.sh"
  else
    ok "A9 two renders are byte-identical and equal the committed replay/index.html"
  fi
else
  bad "A9 bin/render-replay.sh failed in a copy of the repo"
fi
python3 - "$R9/fixtures/recorded-quest.json" <<'PY'
import json, sys
p = sys.argv[1]; f = json.load(open(p))
f["events"][1]["line"] = f["events"][1]["line"].replace("version flag", "version banner")
json.dump(f, open(p, "w"), indent=2)
PY
if bash "$R9/bin/render-replay.sh" >/dev/null 2>&1 && ! cmp -s "$R9/replay/index.html" "$REPLAY" \
   && grep -q "version banner" "$R9/replay/index.html"; then
  ok "A9b CONTROL: a changed fixture renders a page that differs from the committed one"
else
  bad "A9b CONTROL: a changed fixture did not change the render — A9 compares nothing"
fi
rm -rf "$R9"

# A10/A11: THE PAGE'S OWN CONTRACT. A10: one self-contained file — a CSP that forbids external
# requests, and no URL, external script/stylesheet or network API in the markup. A11: the
# labelling the page exists for is derived from the fixture, not lost — the gate's refusal and
# the pass are both marked in the step list and on the transcript lines, the fix step is marked,
# and the controls the page promises (play, step, scrub, pace, reduced motion) are present.
python3 - "$REPLAY" <<'PY'
import json, re, sys
page = open(sys.argv[1]).read()
fails = 0
external = re.findall(r"""(?:https?:)?//[a-z0-9.-]+\.[a-z]{2,}|<link\b|<script\s+[^>]*src=|\bfetch\(|XMLHttpRequest|WebSocket|@import""", page, re.I)
if "Content-Security-Policy" in page and "default-src 'none'" in page and not external:
    print("  A10 PASS: self-contained — CSP default-src 'none', no external references")
else:
    print("  A10 FAIL: page can make external requests: csp=%s refs=%r"
          % ("default-src 'none'" in page, external[:5])); fails += 1
steps = json.loads(re.search(r"const STEPS = (\[.*?\]);\n", page).group(1))
verdicts = [(s["n"], s["verdict"]) for s in steps if s["verdict"]]
need = ['id="playBtn"', 'id="prevBtn"', 'id="nextBtn"', 'type="range" id="scrub"', 'aria-label="Position',
        'id="pace"', "prefers-reduced-motion", 'aria-live="polite"', '<html lang="en">']
missing = [n for n in need if n not in page]
if (len(verdicts) == 2 and verdicts[0][1] == "no" and verdicts[1][1] == "pass"
        and verdicts[0][0] < verdicts[1][0] and "ln k-no r-gate" in page
        and "ln k-pass r-gate" in page and "r-worker fix" in page and not missing):
    print("  A11 PASS: refusal (step %d) then pass (step %d) marked; fix step and controls present"
          % (verdicts[0][0], verdicts[1][0]))
else:
    print("  A11 FAIL: verdicts=%r missing=%r" % (verdicts, missing)); fails += 1
sys.exit(fails)
PY
rc=$?; arms=$((arms+2)); [ $rc -eq 0 ] || fails=$((fails+rc))

# A12/A12b: CONTRAST, MEASURED FROM THE PAGE'S OWN CSS. Every colour the stylesheet paints with is
# classified by the property it is used in: `color:` is text, `background:` is a surface, and
# border/outline/accent-color are non-text marks (role bars, button and terminal borders, focus
# ring, slider). currentColor borders are the text colour, already held to the text floor. Every
# text colour is checked against EVERY surface (stricter than the real nesting) by WCAG 2.x
# relative-luminance contrast, 4.5:1 for text and 3:1 for non-text, and the worst pairs are printed.
# A12b is the control: the same check on a COPY with one colour dimmed must go red.
CONTRAST_PY=$(cat <<'PY'
import re, sys
page = open(sys.argv[1]).read()
css = "\n".join(re.findall(r"<style>(.*?)</style>", page, re.S))
tok = dict(re.findall(r"--([a-z-]+):\s*(#[0-9a-fA-F]{6})\b", css))
groups = {"text": {}, "surface": {}, "non-text": {}}
for prop, v in re.findall(r"(?<![-\w])(color|background(?:-color)?|border(?:-[a-z]+)*|outline|accent-color)\s*:\s*([^;}]+)", css):
    g = "text" if prop == "color" else "surface" if prop.startswith("background") else "non-text"
    for var, lit in re.findall(r"var\(--([a-z-]+)\)|(#[0-9a-fA-F]{6})\b", v):
        groups[g]["--" + var if var else lit] = tok.get(var) if var else lit
def lum(h):
    c = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def ratio(a, b):
    hi, lo = sorted((lum(a), lum(b)), reverse=True); return (hi + 0.05) / (lo + 0.05)
problems, worst = [], {}
for g, floor in (("text", 4.5), ("non-text", 3.0)):
    for n, h in groups[g].items():
        for s, sh in groups["surface"].items():
            if not h or not sh: problems.append("unresolved colour %s / %s" % (n, s)); continue
            r = ratio(h, sh)
            if g not in worst or r < worst[g][0]: worst[g] = (r, n, s)
            if r < floor: problems.append("%s %s on %s is %.2f:1 (needs %.1f:1)" % (g, n, s, r, floor))
if len(groups["text"]) < 5 or len(groups["surface"]) < 3 or len(groups["non-text"]) < 3:
    problems.append("too few colours found %r — the CSS parse is broken" % {g: len(v) for g, v in groups.items()})
print("%d text / %d surface / %d non-text colours; worst text %s; worst non-text %s" % (
    len(groups["text"]), len(groups["surface"]), len(groups["non-text"]),
    *("%.2f:1 %s on %s" % worst[g] if g in worst else "none" for g in ("text", "non-text"))))
for p in problems: print("    " + p)
sys.exit(1 if problems else 0)
PY
)
if out=$(python3 -c "$CONTRAST_PY" "$REPLAY" 2>&1); then
  ok "A12 contrast: every text pair >= 4.5:1, every non-text pair >= 3:1 — $out"
else
  bad "A12 contrast below WCAG AA — $out"
fi
C12=$(mktemp -d)
sed 's/--dim: #a7b0bc;/--dim: #5a626c;/' "$REPLAY" > "$C12/dimmed.html"
if cmp -s "$C12/dimmed.html" "$REPLAY"; then
  bad "A12b CONTROL SETUP: the --dim token was not found to dim"
elif out=$(python3 -c "$CONTRAST_PY" "$C12/dimmed.html" 2>&1); then
  bad "A12b CONTROL: a copy with --dim dimmed to #5a626c still passed — A12 measures nothing"
else
  ok "A12b CONTROL: a copy with --dim dimmed to #5a626c is caught ($(echo "$out" | grep -m1 'text --dim' | sed 's/^ *//'))"
fi

# A13/A13b: NO-JS FALLBACK. With scripts disabled the page must still show the whole transcript
# and hide the player, by CSS alone: a script in <head>, before <body>, sets html.js before first
# paint; every control sits inside a .needs-js element that `html:not(.js)` hides; no transcript
# line is hidden in the markup and no rule hides lines without the js class; a notice shows only
# without JS. A13b is the control: a copy without the <head> script, and a copy whose lines are
# rendered `hidden`, must both fail A13.
NOJS_PY=$(cat <<'PY'
import re, sys
from html.parser import HTMLParser
page = open(sys.argv[1]).read()
problems = []
head = page.split("<body", 1)[0]
if not re.search(r"<script>[^<]*document\.documentElement\.(className\s*=\s*'js'|classList\.add\('js'\))[^<]*</script>", head):
    problems.append("no script in <head> sets html.js before <body>")
css = "\n".join(re.findall(r"<style>(.*?)</style>", page, re.S))
if not re.search(r"html:not\(\.js\) \.needs-js[^{]*\{[^}]*display:\s*none", css):
    problems.append("no CSS rule hides .needs-js without the js class")
for sel, body in re.findall(r"([^{}]+)\{([^}]*)\}", css):
    if re.search(r"#term|\.ln\b", sel) and re.search(r"display:\s*none|visibility:\s*hidden", body) and "html.js" not in sel:
        problems.append("a rule hides transcript lines without JS: %s" % sel.strip())
VOID = {"input", "br", "meta", "img", "hr", "link"}
class P(HTMLParser):
    def __init__(s):
        super().__init__(); s.stack = []; s.ctl = {}; s.lines = s.hidden = 0; s.note = False
    def handle_starttag(s, tag, attrs):
        a = dict(attrs); cls = (a.get("class") or "").split()
        gated = any("needs-js" in c for c in s.stack) or "needs-js" in cls
        if tag not in VOID: s.stack.append(cls)
        if a.get("id") in ("playBtn", "prevBtn", "nextBtn", "restartBtn", "scrub", "pace", "status"): s.ctl[a["id"]] = gated
        if tag == "li" and "ln" in cls:
            s.lines += 1; s.hidden += ("hidden" in a) or gated
        if "no-js" in cls: s.note = True
    def handle_endtag(s, tag):
        if tag not in VOID and s.stack: s.stack.pop()
p = P(); p.feed(page)
ungated = sorted(k for k, v in p.ctl.items() if not v)
if len(p.ctl) != 7 or ungated: problems.append("controls shown without JS: %s (found %d of 7)" % (ungated, len(p.ctl)))
if not p.lines or p.hidden: problems.append("%d of %d transcript lines hidden in the markup" % (p.hidden, p.lines))
if not p.note: problems.append("no .no-js notice")
print("; ".join(problems) if problems else "%d lines shown statically, 7 controls gated on html.js" % p.lines)
sys.exit(1 if problems else 0)
PY
)
if out=$(python3 -c "$NOJS_PY" "$REPLAY" 2>&1); then
  ok "A13 no-JS fallback: $out (set in <head>)"
else
  bad "A13 no-JS fallback broken — $out"
fi
sed "/<script>document.documentElement.className = 'js';<\/script>/d" "$REPLAY" > "$C12/noscript.html"
sed 's/<li id="l\([0-9]*\)" class="ln /<li hidden id="l\1" class="ln /' "$REPLAY" > "$C12/hidden.html"
if ! cmp -s "$C12/noscript.html" "$REPLAY" && ! cmp -s "$C12/hidden.html" "$REPLAY" \
   && ! python3 -c "$NOJS_PY" "$C12/noscript.html" >/dev/null 2>&1 \
   && ! python3 -c "$NOJS_PY" "$C12/hidden.html" >/dev/null 2>&1; then
  ok "A13b CONTROL: a copy without the <head> script and a copy with hidden lines both fail A13"
else
  bad "A13b CONTROL: a broken no-JS copy still passed A13 (or a mutant did not apply)"
fi
rm -rf "$C12"

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "arms run: $arms (expected $EXPECT_ARMS) — $fails failure(s)"
exit $((fails ? 1 : 0))
