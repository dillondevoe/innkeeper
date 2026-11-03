#!/usr/bin/env bash
# render-replay.sh — turn fixtures/recorded-quest.json into replay/index.html.
#
# The page is a terminal-style player: it prints the SAME lines bin/hello-party.sh printed, in
# the same order, with play/pause, step, scrub and two paces ("story", the default, slow enough
# to read; "recorded", the fixture's own timestamps). Nothing in the transcript is invented — it
# is the recorded fixture rendered, the same collect-then-render split as the mesh-viz page
# (task 376). What the page ADDS is labelling, all derived from the fixture's own text below:
# which party member a step belongs to (from the step heading) and what kind of event a line is
# (from the verdict words the tools print: NO / PASS / MERGED / CLAIMED / state=). The legend
# and step list are page chrome, not transcript.
#
# The output is a pure function of the fixture: no clock, no randomness, no environment, so two
# renders are byte-identical and tests/bin-record-quest-selftest.sh can compare the committed
# page with a fresh render. One self-contained file: inline CSS and JS, no framework, and a
# Content-Security-Policy that forbids every external request.
# Re-run this whenever bin/record-quest.sh writes a new fixture.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FIXTURE="$REPO/fixtures/recorded-quest.json"
OUT_DIR="$REPO/replay"
OUT="$OUT_DIR/index.html"

[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing — run bin/record-quest.sh first" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required to render the replay page. Install python3, then re-run." >&2; exit 2; }
mkdir -p "$OUT_DIR"

python3 - "$FIXTURE" "$OUT" <<'PY'
import json, re, sys, html

fixture_path, out_path = sys.argv[1], sys.argv[2]
fixture = json.load(open(fixture_path))

BOLD_ON, BOLD_OFF = "\x1b[1m", "\x1b[0m"
HEADING_RE = re.compile(r"^(\d+)\. (.*)$")
ROLES = ("worker", "researcher", "gate", "voice")

# The recorded lines carry real ANSI bold (\x1b[1m ... \x1b[0m) from hello-party.sh's own
# output -- translate just that one pair to <strong>, escape everything else, so the page
# shows exactly what a stranger's terminal showed.
def to_html(line):
    return html.escape(line).replace(BOLD_ON, "<strong>").replace(BOLD_OFF, "</strong>")

def role_of(heading):
    # The first party member the heading names owns the step; a step naming none (the job
    # board, the merge) belongs to the inn itself -- the files, not a member.
    words = re.findall(r"[a-z]+", heading.lower())
    return next((w for w in words if w in ROLES), "inn")

def kind_of(text, in_verdict):
    s = text.strip()
    if s.startswith("NO ") or "-> REFUSED" in s or (in_verdict == "no" and s):
        return "no"
    if s.startswith("PASS "):
        return "pass"
    if "MERGED" in s:
        return "merge"
    if s.startswith("lease:") or "HELD-BY-OTHER" in s:
        return "lease"
    if "state=" in s:
        return "state"
    if s.startswith("commit "):
        return "commit"
    return "text" if s else "blank"

events, steps = [], []
step, role, verdict, refused_seen = -1, "inn", None, False
for e in fixture["events"]:
    line = e["line"]
    plain = line.replace(BOLD_ON, "").replace(BOLD_OFF, "")
    m = HEADING_RE.match(plain) if line.startswith(BOLD_ON) else None
    if m:
        step, role, verdict = int(m.group(1)), role_of(m.group(2)), None
        # The worker step right after a refusal is the fix: the second half of the beat.
        fix = role == "worker" and refused_seen and not any(s["fix"] for s in steps)
        steps.append({"n": step, "title": m.group(2), "role": role, "fix": fix, "verdict": None})
        kind = "heading"
    else:
        kind = kind_of(plain, verdict)
        if kind == "no":
            verdict, refused_seen = "no", True
        elif kind == "blank":
            verdict = None
        if kind in ("no", "pass") and steps:
            steps[-1]["verdict"] = kind
    events.append({"t": e["t"], "step": step, "role": role, "kind": kind, "html": to_html(line)})

fix_steps = {s["n"] for s in steps if s["fix"]}

def li(i, ev):
    who = ""
    if ev["kind"] == "heading":
        who = '<span class="who r-%s">%s</span>' % (ev["role"], ev["role"])
    fix = " fix" if ev["step"] in fix_steps else ""
    return '<li id="l%d" class="ln k-%s r-%s%s" data-step="%d">%s%s</li>' % (
        i, ev["kind"], ev["role"], fix, ev["step"], who, ev["html"] or " ")

def step_btn(s):
    mark = {"no": ' <span class="vd no">refused</span>', "pass": ' <span class="vd pass">pass</span>'}.get(s["verdict"], "")
    return ('<li><button type="button" class="step r-%s" data-step="%d"><span class="num">%d</span>'
            '<span class="st">%s%s</span></button></li>') % (s["role"], s["n"], s["n"], html.escape(s["title"]), mark)

page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>Innkeeper — recorded quest replay</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0e1116; --panel: #151a21; --term: #06080b; --btn: #1d232c; --line: #6b7684;
    --fg: #e8ebef; --dim: #a7b0bc; --focus: #ffd166;
    --worker: #7cc4ff; --researcher: #d4a8ff; --gate: #ffb454; --voice: #5fe0b0; --inn: #a7b0bc;
    --no: #ff9a9a; --no-bg: #2b1013; --ok: #7fe08f; --ok-bg: #0d2416;
    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  .wrap { max-width: 1120px; margin: 0 auto; padding: 24px 16px 40px; }
  h1 { font-size: 1.5rem; line-height: 1.25; margin: 0 0 6px; }
  h2 { font-size: 1rem; margin: 0 0 10px; }
  p { margin: 0 0 10px; }
  .lede { color: var(--dim); max-width: 70ch; }
  code, kbd { font-family: var(--mono); font-size: .9em; }
  kbd { border: 1px solid var(--line); border-radius: 4px; padding: 0 5px; }
  .grid { display: grid; gap: 20px; grid-template-columns: minmax(0, 1fr); margin-top: 18px; }
  @media (min-width: 900px) { .grid { grid-template-columns: minmax(0, 1fr) 320px; } }
  .panel { background: var(--panel); border-radius: 10px; padding: 16px; }
  #status { height: 3em; overflow: hidden; margin: 0 0 10px; font-weight: 600; display: flex; gap: 10px; align-items: flex-start; }
  #status .vd { flex: none; }
  #term { height: min(60vh, 520px); overflow-y: auto; background: var(--term); border: 1px solid var(--line);
    border-radius: 8px; padding: 12px 0; font: 14px/1.6 var(--mono); }
  #term ol { list-style: none; margin: 0; padding: 0; }
  .ln { white-space: pre-wrap; overflow-wrap: anywhere; min-height: 1.6em; padding: 0 14px 0 12px; border-left: 4px solid transparent; }
  .ln.r-worker { border-left-color: var(--worker); } .ln.r-researcher { border-left-color: var(--researcher); }
  .ln.r-gate { border-left-color: var(--gate); } .ln.r-voice { border-left-color: var(--voice); }
  .ln.k-heading { margin-top: 4px; }
  .ln strong { font-weight: 700; }
  .ln.k-no { background: var(--no-bg); color: var(--no); }
  .ln.k-pass, .ln.fix.k-commit { background: var(--ok-bg); color: var(--ok); }
  .ln.k-merge, .ln.k-lease, .ln.k-state, .ln.k-commit { color: var(--dim); }
  .ln.k-merge { color: var(--ok); }
  .who, .vd { display: inline-block; font: 700 11px/1.6 system-ui, sans-serif; text-transform: uppercase; letter-spacing: .06em;
    border: 1px solid currentColor; border-radius: 4px; padding: 0 5px; margin-right: 8px; vertical-align: 1px; }
  .r-worker .who, .who.r-worker, .step.r-worker .num { color: var(--worker); }
  .who.r-researcher, .step.r-researcher .num { color: var(--researcher); }
  .who.r-gate, .step.r-gate .num { color: var(--gate); }
  .who.r-voice, .step.r-voice .num { color: var(--voice); }
  .who.r-inn, .step.r-inn .num { color: var(--inn); }
  .vd.no { color: var(--no); background: var(--no-bg); } .vd.pass { color: var(--ok); background: var(--ok-bg); }
  .controls { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; align-items: center; }
  button, select { background: var(--btn); color: var(--fg); border: 1px solid var(--line); border-radius: 6px;
    min-height: 44px; padding: 0 14px; font: inherit; font-size: .95rem; cursor: pointer; }
  button:hover, select:hover { background: #262d38; }
  #playBtn { min-width: 6.5em; font-weight: 700; }
  :focus-visible { outline: 3px solid var(--focus); outline-offset: 2px; }
  .scrub { display: flex; gap: 12px; align-items: center; margin-top: 12px; }
  .scrub input { flex: 1; min-width: 0; height: 44px; accent-color: var(--gate); margin: 0; }
  #caption { flex: none; min-width: 9.5em; text-align: right; color: var(--dim); font-variant-numeric: tabular-nums; }
  .pace { display: flex; gap: 8px; align-items: center; margin-left: auto; color: var(--dim); }
  #steps { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
  .step { width: 100%; text-align: left; display: flex; gap: 10px; align-items: flex-start; padding: 8px 10px;
    background: transparent; border-color: transparent; line-height: 1.35; }
  .step .num { flex: none; width: 1.8em; font: 700 .95rem/1.35 var(--mono); }
  .step[aria-current="step"] { background: var(--btn); border-color: var(--line); }
  .step.later { color: var(--dim); }
  .legend { margin: 0; display: grid; gap: 8px; }
  .legend dt { font-weight: 700; } .legend dd { margin: 0 0 4px; color: var(--dim); }
  .panel + .panel { margin-top: 20px; }
  .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
  footer { margin-top: 24px; color: var(--dim); font-size: .9rem; }
  @media (max-width: 520px) { #term { font-size: 13px; } #status { height: 4.5em; } .pace { margin-left: 0; } }
  @media (max-width: 360px) { #status { height: 6em; } }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; scroll-behavior: auto !important; } }
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>A recorded quest, replayed</h1>
  <p class="lede">A captured run of <code>bin/hello-party.sh</code>: four party members add a <code>--version</code> flag to a tiny tool. Watch step 5 &mdash; the gate runs the tool, refuses the first attempt, and the worker fixes it. No model call, no login, no cost.</p>
</header>
<div class="grid">
<main class="panel">
  <h2 class="sr" id="nowLabel">Now showing</h2>
  <p id="status" aria-live="polite"></p>
  <div id="term" tabindex="0" role="region" aria-label="Quest transcript"><ol>
__LINES__
  </ol></div>
  <div class="controls" role="group" aria-label="Playback">
    <button type="button" id="playBtn" aria-keyshortcuts="Space">Play</button>
    <button type="button" id="prevBtn" aria-keyshortcuts="ArrowLeft">&larr; Prev step</button>
    <button type="button" id="nextBtn" aria-keyshortcuts="ArrowRight">Next step &rarr;</button>
    <button type="button" id="restartBtn">Restart</button>
    <label class="pace">Pace <select id="pace"><option value="story">Story</option><option value="recorded">Recorded (__DURATION__ s)</option></select></label>
  </div>
  <div class="scrub">
    <input type="range" id="scrub" min="0" max="__N__" step="1" value="__N__" aria-label="Position in transcript, in lines">
    <span id="caption">__N__ / __N__ lines</span>
  </div>
</main>
<aside>
  <nav class="panel" aria-labelledby="stepsH"><h2 id="stepsH">Steps</h2><ol id="steps">
__STEPS__
  </ol></nav>
  <section class="panel" aria-labelledby="whoH"><h2 id="whoH">Who&rsquo;s at the table</h2><dl class="legend">
    <dt><span class="who r-worker">worker</span></dt><dd>Claims the quest under a lease and makes the change as a real git commit.</dd>
    <dt><span class="who r-researcher">researcher</span></dt><dd>Reads the tool itself and briefs the worker on what the change needs.</dd>
    <dt><span class="who r-gate">gate</span></dt><dd>Runs the tool and says PASS or NO, with a reason the worker can act on. It is not the worker, so it can refuse.</dd>
    <dt><span class="who r-voice">voice</span></dt><dd>Tells you the outcome, with every number read back from git and the disk.</dd>
    <dt><span class="who r-inn">inn</span></dt><dd>Not a member: the files on disk &mdash; the job board, the lease and the merge record.</dd>
  </dl></section>
  <section class="panel" aria-labelledby="whatH"><h2 id="whatH">What the lines mean</h2><dl class="legend">
    <dt><code>state=open | claimed | done</code></dt><dd>The quest&rsquo;s file on the job board moved to that state.</dd>
    <dt><code>CLAIMED</code> / <code>HELD-BY-OTHER</code></dt><dd>A lease was taken; a second claimant saw it held and stood down.</dd>
    <dt><code>commit</code></dt><dd>The worker committed an attempt (green: the fix after a refusal).</dd>
    <dt><span class="vd no">no</span> <code>NO &hellip; REFUSED</code></dt><dd>The gate refused the attempt and wrote why.</dd>
    <dt><span class="vd pass">pass</span> <code>PASS</code></dt><dd>The gate ran the tool and the check held.</dd>
    <dt><code>MERGED</code> / <code>ALREADY-MERGED</code></dt><dd>The result landed once; a second merge was refused.</dd>
  </dl></section>
</aside>
</div>
<footer>
  <p>Keys (with the transcript or page focused): <kbd>Space</kbd> play/pause, <kbd>&larr;</kbd>/<kbd>&rarr;</kbd> previous/next step, <kbd>Home</kbd>/<kbd>End</kbd> start/end. The slider steps one line at a time.</p>
  <p>Built by <code>bin/render-replay.sh</code> from <code>fixtures/recorded-quest.json</code>. With reduced motion requested, the replay does not start on its own and opens on the full transcript.</p>
</footer>
</div>
<script>
const EVENTS = __EVENTS_JSON__;
const STEPS = __STEPS_JSON__;
const $ = id => document.getElementById(id);
const term = $('term'), lines = term.querySelectorAll('.ln'), stepBtns = document.querySelectorAll('.step');
const playBtn = $('playBtn'), scrub = $('scrub'), caption = $('caption'), status = $('status'), pace = $('pace');
const N = EVENTS.length;
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
// stepEnd[k]: lines visible once step k is fully shown.
const stepEnd = STEPS.map(s => EVENTS.reduce((end, e, i) => e.step === s.n ? i + 1 : end, 0));
let idx = 0, playing = false, timer = null, lastStep = null;

function curStep() { return idx ? EVENTS[idx - 1].step : -1; }

function render() {
  lines.forEach((li, i) => { li.hidden = i >= idx; });
  term.scrollTop = term.scrollHeight;
  scrub.value = idx;
  const cur = curStep(), s = STEPS.find(x => x.n === cur);
  caption.textContent = idx + ' / ' + N + ' lines';
  scrub.setAttribute('aria-valuetext', 'line ' + idx + ' of ' + N + (s ? ', step ' + s.n : ''));
  stepBtns.forEach(b => {
    const n = +b.dataset.step;
    if (n === cur) b.setAttribute('aria-current', 'step'); else b.removeAttribute('aria-current');
    b.classList.toggle('later', n > cur);
  });
  // Announce once per step, and again when its verdict appears -- not once per line.
  const shown = s && s.verdict && EVENTS.slice(0, idx).some(e => e.step === cur && e.kind === s.verdict) ? s.verdict : '';
  const key = cur + shown;
  if (key !== lastStep) {
    lastStep = key;
    status.innerHTML = '';
    if (!s) { status.textContent = 'Press Play to start the quest.'; return; }
    if (shown) {
      const v = document.createElement('span');
      v.className = 'vd ' + shown; v.textContent = shown === 'no' ? 'refused' : 'pass';
      status.append(v);
    }
    status.append('Step ' + s.n + ' of ' + STEPS[STEPS.length - 1].n + ': ' + s.title);
  }
}

// Story pace: slow enough to read, and it holds on the refusal. Recorded pace: the fixture's
// own timestamps (the whole quest took under a second).
function delay(i) {
  if (pace.value === 'recorded') return i ? Math.max(0, (EVENTS[i].t - EVENTS[i - 1].t) * 1000) : 0;
  const prev = i ? EVENTS[i - 1] : null;
  if (prev && prev.kind === 'no' && EVENTS[i].kind !== 'no') return 2400;
  if (prev && prev.kind === 'pass') return 1000;
  return EVENTS[i].kind === 'heading' ? 700 : 110;
}

function tick() {
  if (idx >= N) { pause(); return; }
  timer = setTimeout(() => { idx += 1; render(); tick(); }, delay(idx));
}
function play() {
  if (idx >= N) { idx = 0; render(); }
  playing = true; playBtn.textContent = 'Pause'; tick();
}
function pause() { playing = false; playBtn.textContent = 'Play'; clearTimeout(timer); }
function seek(i) { pause(); idx = Math.max(0, Math.min(N, i)); render(); }
function next() { seek(stepEnd.find(e => e > idx) ?? N); }
function prev() { seek([...stepEnd].reverse().find(e => e < idx) ?? 0); }

playBtn.addEventListener('click', () => { playing ? pause() : play(); });
$('nextBtn').addEventListener('click', next);
$('prevBtn').addEventListener('click', prev);
$('restartBtn').addEventListener('click', () => { seek(0); play(); });
scrub.addEventListener('input', () => seek(+scrub.value));
pace.addEventListener('change', () => { if (playing) { clearTimeout(timer); tick(); } });
stepBtns.forEach((b, k) => b.addEventListener('click', () => seek(stepEnd[k])));
document.addEventListener('keydown', ev => {
  const t = ev.target;
  if (ev.altKey || ev.ctrlKey || ev.metaKey || (t !== document.body && t !== term)) return;
  const act = { ' ': () => (playing ? pause() : play()), ArrowRight: next, ArrowLeft: prev,
                Home: () => seek(0), End: () => seek(N) }[ev.key];
  if (act) { ev.preventDefault(); act(); }
});

if (reduce) { idx = N; render(); } else { idx = 0; render(); play(); }
</script>
</body>
</html>
"""
duration = "%.2f" % (fixture["events"][-1]["t"] if fixture["events"] else 0)
page = (page.replace("__LINES__", "\n".join(li(i, ev) for i, ev in enumerate(events)))
            .replace("__STEPS__", "\n".join(step_btn(s) for s in steps))
            .replace("__DURATION__", duration)
            .replace("__N__", str(len(events)))
            .replace("__STEPS_JSON__", json.dumps([{"n": s["n"], "title": s["title"], "verdict": s["verdict"]} for s in steps]))
            .replace("__EVENTS_JSON__", json.dumps([{k: ev[k] for k in ("t", "step", "kind")} for ev in events])))
open(out_path, "w").write(page)
print("wrote %s (%d events, %d steps)" % (out_path, len(events), len(steps)))
PY
