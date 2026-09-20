#!/usr/bin/env bash
# recycle.sh <brain> <session> — end a brain's session at a clean boundary, with FLAG SAFETY.
#
#   recycle.sh <brain> <session>     write the recycle flag and send the exit
#   recycle.sh --selftest
#
# The boundary is a WRITE-AHEAD sequence, and its order is the whole safety property:
#   1. resolve the multiplexer binary for THIS host  — or FAIL before any write
#   2. verify the target session exists              — or FAIL before any write
#   3. warn if no launcher consumes the flag name about to be written
#   4. clear the compaction flag this recycle consumes
#   5. write the recycle flag (the LAST write of the boundary)
#   6. send the exit — and IF THAT FAILS, REMOVE THE FLAG AGAIN
#   7. only after the exit is away: reset the tick counter
#
# WHY 1 AND 2 COME BEFORE ANY WRITE. In the source mesh this sequence lived as a literal
# copied into nine skill files, and one fleet edit shipped it with an absolute path to the
# multiplexer that exists on one operating system and not the other. On the other host,
# step 5 wrote the flag and step 6 died `command not found` — leaving exactly the
# unconsumed flag that blinds the restart path, while every log line still read like a
# clean boundary. The write-ahead order that makes a CRASH safe is what made that failure
# silent. So the exit is one tested artifact, not a literal, and nothing is written until
# the two things that can fail have succeeded.
#
# WHY 3 IS A WARN AND NOT A FAIL. The flag name is the contract between this script and a
# launcher that is a different program, and it is hand-typed at the call site. A name no
# launcher reads is a flag that is never consumed and never reported. But a party whose
# launchers live somewhere this roster does not list would then be unable to exit at all,
# and blocking every boundary is worse than a wrong name: WARN, loudly, and write anyway.
# Comment lines are STRIPPED before matching — a launcher that names a flag in a comment
# ("not <other>.flag") would otherwise satisfy the grep with the exact wrong name.
#
# WHY 7 IS LAST. The counter reset means "this brain got a fresh context". A failed exit
# did not produce one, and a brain that is still alive at high pressure must stay DUE.
# Resetting before the exit would zero the pressure of a session that then kept running.
set -u

R=$(cd "$(dirname "$0")/.." && pwd -P)
if [ "${1:-}" = "--selftest" ]; then exec bash "$R/tests/lifecycle-recycle-selftest.sh"; fi
BRAIN_IN="${1:?usage: recycle.sh <brain> <session>}"
SESS="${2:?usage: recycle.sh <brain> <session>}"

: "${INNKEEPER_HOME:=$R}"
ACTOR="$R/bus/actor.sh"
STATE="${INNKEEPER_HOME}/state"
LOGDIR="${STATE}/logs"
MUX="${INNKEEPER_MUX:-}"

if ! ROSTER=$(bash "$ACTOR" roster 2>&1); then
  echo "recycle.sh: FAIL — roster unreadable: ${ROSTER}" >&2; exit 2
fi
BRAIN=$(bash "$ACTOR" resolve "$BRAIN_IN") || BRAIN="$BRAIN_IN"

FLAG="$STATE/recycle-${BRAIN}.flag"
CFLAG="$STATE/compacted-${SESS}.flag"
# Per-host log file. A single shared log appended by several machines is a file that
# replication will conflict, and each conflict copy drops the losing arm's newest lines
# out of the evidence trail of the guard that wrote them.
HOST="$(hostname -s 2>/dev/null || echo unknown)"
mkdir -p "$LOGDIR" 2>/dev/null
LOG="$LOGDIR/recycle.${HOST}.log"
logline() {
  printf '%s [%s] brain=%s session=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HOST" "$BRAIN" "$SESS" "$1" >> "$LOG"
}

# 1. The multiplexer, resolved for this host. PATH first, then the usual absolute homes,
#    so neither a login shell's PATH nor one OS's install prefix is assumed.
if [ -z "$MUX" ]; then
  MUX="$(command -v tmux 2>/dev/null || true)"
  for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [ -z "$MUX" ] && [ -x "$c" ] && MUX="$c"
  done
fi
if [ -z "$MUX" ] || [ ! -x "$MUX" ]; then
  logline "FAIL no-multiplexer (no flag written)"
  echo "recycle.sh: FAIL — no multiplexer binary on this host; recycle flag NOT written" >&2
  exit 3
fi

# 2. The session.
if ! "$MUX" has-session -t "=$SESS" 2>/dev/null; then
  logline "FAIL no-such-session mux=$MUX (no flag written)"
  echo "recycle.sh: FAIL — session '$SESS' not found; recycle flag NOT written" >&2
  exit 4
fi

# 3. Does anything consume the flag we are about to write? The launcher globs come from
#    the roster, which is the one line a party edits when a brain lives in another repo.
consumed=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  case "$g" in "~"/*) g="$HOME/${g#~/}" ;; esac
  for f in $g; do
    [ -f "$f" ] || continue
    if sed 's/[[:space:]]*#.*$//' "$f" 2>/dev/null | command grep -qF -- "recycle-${BRAIN}.flag"; then
      consumed=1; break
    fi
  done
  [ "$consumed" = 1 ] && break
done <<EOF
$(bash "$ACTOR" list launchers 2>/dev/null)
EOF
if [ "$consumed" != 1 ]; then
  logline "WARN no-launcher-consumes recycle-${BRAIN}.flag (flag written anyway — wrong brain name?)"
  echo "recycle.sh: WARN — no launcher consumes recycle-${BRAIN}.flag; wrong brain name? (flag written anyway)" >&2
fi

# 4 + 5. The compaction flag is consumed BY this recycle; the recycle flag is the last write.
mkdir -p "$STATE" 2>/dev/null
rm -f "$CFLAG"
: > "$FLAG"

# 6. The exit. A failure here must not leave the flag behind.
if ! "$MUX" send-keys -t "=$SESS:" C-u "${INNKEEPER_EXIT_KEYS:-/exit}" Enter 2>/dev/null; then
  rm -f "$FLAG"
  logline "FAIL send-keys rc!=0 mux=$MUX (flag REMOVED)"
  echo "recycle.sh: FAIL — exit could not be sent; recycle flag removed so the restart path stays sighted" >&2
  exit 5
fi

# A session with background work armed answers the exit with a confirmation picker rather
# than exiting. POLL for it and confirm the moment it renders — a fixed sleep either lands
# BEFORE the picker (which is the original wedge) or wastes the difference on a fast box.
# If the deadline passes with no picker, send one key anyway: a no-op on an empty prompt,
# and the log says which of the two happened, so a wedge is diagnosable from the log alone.
(
  seen=""; i=0
  while [ "$i" -lt "${INNKEEPER_CONFIRM_DEADLINE:-20}" ]; do
    sleep 1; i=$((i + 1))
    if "$MUX" capture-pane -p -t "=$SESS:" 2>/dev/null | command grep -q "${INNKEEPER_CONFIRM_RE:-Enter to confirm}"; then
      seen="$i"; break
    fi
  done
  "$MUX" send-keys -t "=$SESS:" Enter 2>/dev/null
  if [ -n "$seen" ]; then logline "confirm sent after ${seen}s (picker seen)"
  else logline "confirm sent at deadline (no picker seen — no-op on an empty prompt)"; fi
) &

# 7. The counter. Never fatal: the exit is already committed, and the counter's own fail
#    direction is toward recycling, so a reset that did not happen costs one early boundary.
if TK_OUT="$(bash "$R/lifecycle/ticks.sh" "$BRAIN" reset 2>&1 | tr '\n' ' ')"; then
  logline "ticks ${TK_OUT#ticks: }"
else
  logline "WARN ticks reset FAILED: ${TK_OUT}"
fi

logline "OK exit-sent mux=$MUX flag=$(basename "$FLAG")"
echo "recycle.sh: OK — exit queued into session '$SESS'; $(basename "$FLAG") written"
exit 0
