#!/usr/bin/env bash
# render-replay.sh — turn fixtures/recorded-quest.json into replay/index.html.
#
#   bin/render-replay.sh             write replay/index.html
#   bin/render-replay.sh <out.html>  write somewhere else (the selftest renders twice and compares)
#
# The page is a terminal-style player for the SAME lines bin/hello-party.sh printed, with
# play/pause, step, scrub and a pace switch (a readable pace by default; the recorded pace,
# under a second end to end, on request). Nothing in the transcript is invented — it is the
# recorded fixture rendered, the same collect-then-render split as the mesh-viz page (task 376).
# What the page ADDS is labelling: which role each step belongs to (read from the step's own
# heading), what each kind of line means, and where the gate refuses and the worker fixes.
# One self-contained file: no external requests, no framework. The output is a pure function
# of the fixture, so two renders are byte-identical (tests/bin-record-quest-selftest.sh A9).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FIXTURE="$REPO/fixtures/recorded-quest.json"
OUT=${1:-"$REPO/replay/index.html"}

[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing — run bin/record-quest.sh first" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

python3 - "$FIXTURE" "$OUT" <<'PY'
import json, re, sys, html

fixture_path, out_path = sys.argv[1], sys.argv[2]
fixture = json.load(open(fixture_path))
BOLD, RESET = "\x1b[1m", "\x1b[0m"

# The recorded lines carry real ANSI bold from hello-party.sh's own output -- translate just
# that one pair to <strong>, escape everything else.
def to_html(line):
    return html.escape(line).replace(BOLD, "<strong>").replace(RESET, "</strong>")

# A step's role is read out of its own heading ("The gate checks it" -> gate). A heading that
# names no party member (posting, merging, closing) belongs to the board: the plain files.
def role_of(title):
    low = title.lower()
    for r in ("gate", "researcher", "worker", "voice"):
        if re.search(r"\b%s\b" % r, low):
            return r
    return "board"

# What kind of event a line is, from the words the quest prints. Only these get styled.
def kind_of(text, after_no):
    s = text.strip()
    if s.startswith("NO ") or "REFUSED" in s or (after_no and text.startswith("      ") and s):
        return "refuse"
    if s.startswith("PASS "): return "pass"
    if "HELD-BY-OTHER" in s or "ALREADY-MERGED" in s: return "guard"
    if s.startswith("MERGED "): return "merge"
    if s.startswith("lease: "): return "lease"
    if s.startswith("commit "): return "commit"
    if "state=" in s: return "state"
    return "text"

steps, events, rows, after_no = [], [], [], False
for i, e in enumerate(fixture["events"]):
    line = e["line"]
    m = re.match(r"^\x1b\[1m(\d+)\. (.*)\x1b\[0m$", line)
    if m:
        steps.append({"n": int(m.group(1)), "title": m.group(2), "role": role_of(m.group(2)),
                      "start": i, "beat": ""})
        kind, after_no = "step", False
    else:
        kind = kind_of(line, after_no)
        after_no = kind == "refuse"
    s = max(len(steps) - 1, 0)
    events.append({"t": e["t"], "s": s, "k": kind})
    rows.append((line, kind, s))
if not steps:
    sys.exit("FATAL: the fixture has no step headings to label")
for j, st in enumerate(steps):
    st["end"] = steps[j + 1]["start"] if j + 1 < len(steps) else len(events)

# THE BEAT: the step where the gate refuses, and the first worker step after it (the fix).
refuse = next((j for j, st in enumerate(steps) if any(k == "refuse" for _, k, s in rows if s == j)), None)
fix = None
if refuse is not None:
    steps[refuse]["beat"] = "refuse"
    fix = next((j for j in range(refuse + 1, len(steps)) if steps[j]["role"] == "worker"), None)
    if fix is not None:
        steps[fix]["beat"] = "fix"

lines_html = []
for i, (line, kind, s) in enumerate(rows):
    st = steps[s]
    cls = "ln k-%s r-%s%s" % (kind, st["role"], " b-" + st["beat"] if st["beat"] else "")
    body = to_html(line)
    if kind == "step":
        body += ' <span class="chip r-%s">%s</span>' % (st["role"], st["role"])
    lines_html.append('<div class="%s">%s</div>' % (cls, body))

chapters = "\n".join(
    '<li><button type="button" class="chap r-%s%s" data-s="%d"><span class="num">%d</span> %s</button></li>'
    % (st["role"], " b-" + st["beat"] if st["beat"] else "", j, st["n"], html.escape(st["title"]))
    for j, st in enumerate(steps))
ticks = "".join('<i class="tick%s" style="--p:%.4f"></i>'
                % (" b-" + st["beat"] if st["beat"] else "", st["end"] / len(events)) for st in steps)
if refuse is not None and fix is not None:
    beat = ("The beat to watch: in step %d the gate runs the tool and refuses the worker&rsquo;s "
            "first attempt; in step %d the worker reads the refusal and fixes it."
            % (steps[refuse]["n"], steps[fix]["n"]))
else:
    beat = "This recording has no refusal in it."

page = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Innkeeper — recorded quest replay</title>
<script>document.documentElement.classList.add('js')</script>
<style>
:root{--bg:#0e1116;--panel:#161b22;--term:#0a0c10;--line:#3d4651;--fg:#e6edf3;--muted:#a3afbc;
--board:#a3afbc;--worker:#8cc8ff;--researcher:#d0b3ff;--gate:#f5c469;--voice:#6fe0d2;
--red:#ff9c94;--green:#86e5ab;--refuse-bg:#2b1316;--fix-bg:#0f2619;--focus:#ffd75e}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
code,#term,.num,#count{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.wrap{max-width:1120px;margin:0 auto;padding:24px 16px 40px}
header h1{font-size:clamp(22px,4vw,30px);line-height:1.2;margin:0 0 8px}
header p{margin:0 0 6px;color:var(--muted);max-width:70ch}
header p.beat{color:var(--fg)}
header code{color:var(--fg)}
.grid{display:grid;gap:20px;margin-top:20px}
@media (min-width:900px){.grid{grid-template-columns:minmax(0,1fr) 320px}}
#now{display:grid;grid-template-rows:auto 3em;gap:2px;background:var(--panel);border:1px solid var(--line);
border-left-width:4px;border-radius:8px 8px 0 0;padding:10px 14px}
#now .top{display:flex;gap:10px;align-items:center;min-height:26px;color:var(--muted);font-size:14px}
#nowTitle{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-weight:600}
#now.b-refuse{background:var(--refuse-bg);border-color:var(--red)}
#now.b-fix{background:var(--fix-bg);border-color:var(--green)}
#term{position:relative;height:clamp(300px,52vh,520px);overflow-y:auto;background:var(--term);border:1px solid var(--line);
border-top:0;padding:12px 14px 16px;font-size:13.5px;line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere}
html.js #term .ln{display:none}
html.js #term .ln.on{display:block}
.ln{min-height:1.55em;border-left:3px solid transparent;padding-left:8px}
.ln.k-step{margin-top:2px}
.ln.k-step strong{color:var(--fg)}
.ln.b-refuse{background:var(--refuse-bg);border-left-color:var(--red)}
.ln.b-fix{background:var(--fix-bg);border-left-color:var(--green)}
.k-refuse{color:var(--red)} .k-pass{color:var(--green)} .k-guard{color:var(--gate)}
.ln.k-refuse,.ln.k-pass{font-weight:600}
.chip{display:inline-block;font:600 12px/1 system-ui,sans-serif;padding:3px 7px;border:1px solid currentColor;border-radius:99px;white-space:nowrap}
.r-board{--role:var(--board)} .r-worker{--role:var(--worker)} .r-researcher{--role:var(--researcher)}
.r-gate{--role:var(--gate)} .r-voice{--role:var(--voice)}
.chip{color:var(--role)}
.ln:not(.b-refuse):not(.b-fix){border-left-color:var(--role)}
#controls{background:var(--panel);border:1px solid var(--line);border-top:0;border-radius:0 0 8px 8px;padding:12px 14px}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
button,select{font:inherit;font-size:15px;color:var(--fg);background:#232b36;border:1px solid #7a8798;border-radius:6px;min-height:44px;padding:0 14px;cursor:pointer}
button:hover,select:hover{background:#2e3846}
#play{min-width:7.5em;font-weight:600}
:focus-visible{outline:3px solid var(--focus);outline-offset:2px}
#term:focus-visible{outline-offset:-3px}
.scrub{position:relative;margin:12px 0 4px}
#scrub{width:100%;margin:0;height:28px;accent-color:var(--worker)}
.ticks{position:relative;height:10px}
.tick{position:absolute;top:0;left:calc(9px + (100% - 18px) * var(--p));width:2px;height:8px;background:var(--muted)}
.tick.b-refuse{background:var(--red);width:4px;height:10px}.tick.b-fix{background:var(--green);width:4px;height:10px}
#count{color:var(--muted);font-size:14px;font-variant-numeric:tabular-nums;margin-left:auto}
label{color:var(--muted);font-size:14px}
.keys{color:var(--muted);font-size:14px;margin:8px 0 0}
kbd{font:13px ui-monospace,monospace;border:1px solid var(--line);border-radius:4px;padding:0 4px;color:var(--fg)}
aside section{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px;margin-bottom:16px}
aside h2{font-size:17px;margin:0 0 10px}
aside dl{margin:0} aside dt{margin-top:10px;font-weight:600} aside dd{margin:2px 0 0;color:var(--muted);font-size:14px}
aside dt code{font-size:14px}
ol.chaps{list-style:none;margin:0;padding:0;display:grid;gap:4px}
.chap{width:100%;text-align:left;font-size:14px;padding:6px 10px;line-height:1.35;border-left:4px solid var(--role)}
.chap.b-refuse{border-color:var(--red)} .chap.b-fix{border-color:var(--green)}
.chap[aria-current]{background:#34404f}
.num{color:var(--muted);display:inline-block;min-width:1.6em}
html:not(.js) .needs-js{display:none}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important;scroll-behavior:auto!important}}
</style>
</head>
<body>
<div class="wrap">
<header>
<h1>A recorded quest, replayed</h1>
<p>One real run of <code>bin/hello-party.sh</code>, captured line by line in <code>fixtures/recorded-quest.json</code> and played back here. No model call, no login, no cost.</p>
<p class="beat">__BEAT__</p>
</header>
<div class="grid">
<main>
<div id="now" aria-live="polite" aria-atomic="true"><div class="top"><span id="nowStep">Ready</span><span id="nowRole" class="chip" hidden></span></div><div id="nowTitle">Press Play, or step through it.</div></div>
<div id="term" tabindex="0" role="region" aria-label="Quest transcript">__LINES__</div>
<div id="controls" class="needs-js">
<div class="row">
<button type="button" id="play"><span aria-hidden="true">&#9654;&#xFE0E; </span><span id="playLabel">Play</span></button>
<button type="button" id="prev"><span aria-hidden="true">&#8249; </span>Previous step</button>
<button type="button" id="next">Next step<span aria-hidden="true"> &#8250;</span></button>
<button type="button" id="restart">Restart</button>
</div>
<div class="scrub"><input type="range" id="scrub" min="0" max="__N__" step="1" value="0" aria-label="Position in the replay, in lines"><div class="ticks" aria-hidden="true">__TICKS__</div></div>
<div class="row"><label for="pace">Pace</label><select id="pace"><option value="readable">Readable</option><option value="recorded">As recorded (__DUR__ s total)</option></select><span id="count" aria-hidden="true">0 / __N__ lines</span></div>
<p class="keys">Keys: <kbd>Space</kbd> play/pause, <kbd>&larr;</kbd> <kbd>&rarr;</kbd> previous/next step, <kbd>Home</kbd> start, <kbd>End</kbd> end.</p>
</div>
</main>
<aside>
<section aria-labelledby="h-roles"><h2 id="h-roles">Who is at the table</h2><dl>
<dt><span class="chip r-worker">worker</span></dt><dd>Claims the quest under a lease and does the work as real git commits.</dd>
<dt><span class="chip r-researcher">researcher</span></dt><dd>Reads the tool before any work starts and briefs the worker.</dd>
<dt><span class="chip r-gate">gate</span></dt><dd>Runs the tool and answers PASS or NO with a reason. It can refuse.</dd>
<dt><span class="chip r-voice">voice</span></dt><dd>Tells you what happened, read back from the record, not from the driver.</dd>
<dt><span class="chip r-board">board</span></dt><dd>Not a party member: the plain files that hold the posting, its state and the one-time merge.</dd>
</dl></section>
<section aria-labelledby="h-lines"><h2 id="h-lines">What the lines mean</h2><dl>
<dt><code>lease: CLAIMED</code></dt><dd>A worker holds the quest. Another worker that sees the lease stands down (<code class="k-guard">HELD-BY-OTHER</code>).</dd>
<dt><code>state=</code></dt><dd>The quest&rsquo;s state on the board: open, claimed, done.</dd>
<dt><code>commit SHA</code></dt><dd>A real commit. The hash is replaced so every recording reads the same.</dd>
<dt><code class="k-refuse">NO</code> &hellip; <code class="k-refuse">REFUSED</code></dt><dd>The gate refused. Its reason is what the worker reads next.</dd>
<dt><code class="k-pass">PASS</code></dt><dd>The gate ran the tool and got the right output.</dd>
<dt><code>MERGED</code> / <code class="k-guard">ALREADY-MERGED</code></dt><dd>The result lands exactly once; a second merge is refused.</dd>
<dt><code>$TMPDIR/hello-party.SANDBOX</code></dt><dd>The throwaway sandbox, its path normalized so the recording is identical on any machine.</dd>
</dl></section>
<section aria-labelledby="h-steps" class="needs-js"><h2 id="h-steps">Jump to a step</h2><ol class="chaps">
__CHAPTERS__
</ol></section>
</aside>
</div>
</div>
<script>
const EVENTS = __EVENTS_JSON__;
const STEPS = __STEPS_JSON__;
const $ = id => document.getElementById(id);
const term = $('term'), scrub = $('scrub'), pace = $('pace'), now = $('now');
const lines = Array.from(term.querySelectorAll('.ln')), N = lines.length;
const chaps = Array.from(document.querySelectorAll('.chap'));
let idx = 0, playing = false, timer = 0, shownStep = null;

// Milliseconds to wait before line i appears. "As recorded" is the fixture's own clock;
// "readable" gives each line time in proportion to its length and holds on the refusal.
function delay(i) {
  if (i === 0) return 400;
  if (pace.value === 'recorded') return Math.max(0, (EVENTS[i].t - EVENTS[i - 1].t) * 1000);
  const e = EVENTS[i], prev = EVENTS[i - 1], len = lines[i].textContent.trim().length;
  let ms = e.k === 'step' ? 900 : len ? Math.min(1800, 300 + 14 * len) : 100;
  if (prev.k === 'refuse' && e.k !== 'refuse') ms += 1800;
  return STEPS[e.s].beat ? ms * 1.4 : ms;
}
function render() {
  lines.forEach((el, j) => el.classList.toggle('on', j < idx));
  const last = lines[idx - 1];
  term.scrollTop = last ? Math.max(0, last.offsetTop + last.offsetHeight + 16 - term.clientHeight) : 0;
  const s = idx ? EVENTS[idx - 1].s : -1, st = STEPS[s];
  scrub.value = idx;
  scrub.setAttribute('aria-valuetext', 'line ' + idx + ' of ' + N + (st ? ', step ' + st.n : ''));
  $('count').textContent = idx + ' / ' + N + ' lines';
  $('playLabel').textContent = playing ? 'Pause' : idx >= N ? 'Replay' : 'Play';
  chaps.forEach((c, j) => j === s ? c.setAttribute('aria-current', 'step') : c.removeAttribute('aria-current'));
  const key = s + (idx >= N ? 'end' : '');
  if (key === shownStep) return;
  shownStep = key;
  now.className = st && st.beat ? 'b-' + st.beat : '';
  now.style.borderLeftColor = st && !st.beat ? 'var(--' + st.role + ')' : '';
  $('nowRole').hidden = !st;
  if (st) { $('nowRole').textContent = st.role; $('nowRole').className = 'chip r-' + st.role; }
  $('nowStep').textContent = st ? 'Step ' + st.n + ' of ' + STEPS[STEPS.length - 1].n + (idx >= N ? ' · replay finished' : '') : 'Ready';
  $('nowTitle').textContent = st ? st.title : 'Press Play, or step through it.';
}
function tick() {
  clearTimeout(timer);
  if (idx >= N) { playing = false; render(); return; }
  timer = setTimeout(() => { idx += 1; render(); tick(); }, delay(idx));
}
function play() { if (idx >= N) idx = 0; playing = true; render(); tick(); }
function pause() { playing = false; clearTimeout(timer); render(); }
function seek(i) { pause(); idx = Math.max(0, Math.min(N, i)); render(); }
const ends = STEPS.map(st => st.end);
function nextStep() { seek(ends.find(e => e > idx) ?? N); }
function prevStep() { seek([0].concat(ends).filter(e => e < idx).pop() ?? 0); }

$('play').addEventListener('click', () => playing ? pause() : play());
$('prev').addEventListener('click', prevStep);
$('next').addEventListener('click', nextStep);
$('restart').addEventListener('click', () => { seek(0); play(); });
scrub.addEventListener('input', () => seek(+scrub.value));
pace.addEventListener('change', () => { if (playing) tick(); });
chaps.forEach(c => c.addEventListener('click', () => seek(STEPS[+c.dataset.s].end)));
document.addEventListener('keydown', e => {
  if (e.altKey || e.ctrlKey || e.metaKey || e.target.closest('button,input,select,a')) return;
  const act = { ' ': () => playing ? pause() : play(), ArrowLeft: prevStep, ArrowRight: nextStep,
                Home: () => seek(0), End: () => seek(N) }[e.key];
  if (act) { e.preventDefault(); act(); }
});
// Reduced motion: nothing moves on its own. Show the whole transcript, paused; Play replays it.
if (matchMedia('(prefers-reduced-motion: reduce)').matches) { idx = N; render(); } else { render(); play(); }
</script>
</body>
</html>
"""
steps_json = [{k: st[k] for k in ("n", "title", "role", "beat", "end")} for st in steps]
for key, val in (("__EVENTS_JSON__", json.dumps(events)), ("__STEPS_JSON__", json.dumps(steps_json).replace("</", "<\\/")),
                 ("__LINES__", "".join(lines_html)), ("__CHAPTERS__", chapters), ("__TICKS__", ticks),
                 ("__BEAT__", beat), ("__N__", str(len(events))),
                 ("__DUR__", "%.2f" % fixture["events"][-1]["t"])):
    page = page.replace(key, val)
open(out_path, "w").write(page)
print("wrote %s (%d events, %d steps)" % (out_path, len(events), len(steps)))
PY
