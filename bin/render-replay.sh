#!/usr/bin/env bash
# render-replay.sh — turn fixtures/recorded-quest.json into replay/index.html.
#
# The page is a terminal-style player: it prints the SAME lines bin/hello-party.sh printed,
# at the SAME pace they were printed, with play/pause/restart. Nothing on the page is
# invented — it is the recorded fixture rendered, the same collect-then-render split as
# the mesh-viz page (task 376). Re-run this whenever bin/record-quest.sh writes a new fixture.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FIXTURE="$REPO/fixtures/recorded-quest.json"
OUT_DIR="$REPO/replay"
OUT="$OUT_DIR/index.html"

[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing — run bin/record-quest.sh first" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }
mkdir -p "$OUT_DIR"

python3 - "$FIXTURE" "$OUT" <<'PY'
import json, sys, html

fixture_path, out_path = sys.argv[1], sys.argv[2]
fixture = json.load(open(fixture_path))

# The recorded lines carry real ANSI bold (\x1b[1m ... \x1b[0m) from hello-party.sh's own
# output -- translate just that one pair to <strong>, escape everything else, so the page
# shows exactly what a stranger's terminal showed.
def to_html(line):
    escaped = html.escape(line)
    return escaped.replace("\x1b[1m", "<strong>").replace("\x1b[0m", "</strong>")

events = [{"t": e["t"], "html": to_html(e["line"])} for e in fixture["events"]]
events_json = json.dumps(events)

page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Innkeeper — recorded quest replay</title>
<style>
  :root { --bg: #0b0d10; --fg: #d8dee4; --dim: #6b7380; --accent: #58d68d; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    display: flex; flex-direction: column; align-items: center; padding: 24px 16px;
  }
  h1 { font-size: 15px; color: var(--dim); font-weight: 400; margin: 0 0 14px; }
  h1 code { color: var(--accent); }
  #term {
    width: 100%; max-width: 760px; min-height: 420px; background: #000;
    border: 1px solid #22262c; border-radius: 8px; padding: 18px 20px;
    white-space: pre-wrap; font-size: 13px; line-height: 1.55; overflow-y: auto;
  }
  #term strong { color: var(--accent); font-weight: 600; }
  #controls { margin-top: 14px; display: flex; gap: 10px; }
  button {
    background: #1b1f26; color: var(--fg); border: 1px solid #2c313a; border-radius: 6px;
    padding: 7px 16px; font-family: inherit; font-size: 13px; cursor: pointer;
  }
  button:hover { background: #262b33; }
  button:disabled { opacity: 0.4; cursor: default; }
  #caption { margin-top: 10px; color: var(--dim); font-size: 12px; }
</style>
</head>
<body>
<h1>Recorded quest &mdash; a canned run of <code>bin/hello-party.sh</code>, replayed at its own pace. No model call, no login, no cost.</h1>
<div id="term"></div>
<div id="controls">
  <button id="playBtn">Play</button>
  <button id="restartBtn">Restart</button>
</div>
<div id="caption">0 / 0 lines</div>
<script>
const EVENTS = __EVENTS_JSON__;
const term = document.getElementById('term');
const playBtn = document.getElementById('playBtn');
const restartBtn = document.getElementById('restartBtn');
const caption = document.getElementById('caption');

let idx = 0, playing = false, timer = null, startWall = 0, startT = 0;

function render() {
  term.innerHTML = EVENTS.slice(0, idx).map(e => e.html).join('\\n');
  term.scrollTop = term.scrollHeight;
  caption.textContent = idx + ' / ' + EVENTS.length + ' lines';
}

function scheduleNext() {
  if (idx >= EVENTS.length) { playing = false; playBtn.textContent = 'Play'; return; }
  const target = EVENTS[idx].t;
  const wait = Math.max(0, (target - startT) * 1000 - (performance.now() - startWall));
  timer = setTimeout(() => {
    idx += 1;
    render();
    scheduleNext();
  }, wait);
}

function play() {
  if (idx >= EVENTS.length) { idx = 0; }
  playing = true;
  playBtn.textContent = 'Pause';
  startWall = performance.now();
  startT = idx < EVENTS.length ? EVENTS[idx].t : 0;
  scheduleNext();
}

function pause() {
  playing = false;
  playBtn.textContent = 'Play';
  clearTimeout(timer);
}

playBtn.addEventListener('click', () => { playing ? pause() : play(); });
restartBtn.addEventListener('click', () => { pause(); idx = 0; render(); play(); });

render();
play();
</script>
</body>
</html>
"""
page = page.replace("__EVENTS_JSON__", events_json)
open(out_path, "w").write(page)
print("wrote %s (%d events)" % (out_path, len(events)))
PY
