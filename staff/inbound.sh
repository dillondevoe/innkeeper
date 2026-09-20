#!/usr/bin/env bash
# inbound.sh [comms-dir] — what arrived for this brain, in THREE tiers, not one.
#
#   PARTY_BRAIN=<name> inbound.sh            read $INNKEEPER_COMMS (or the roster's bus/comms)
#   PARTY_BRAIN=<name> inbound.sh <dir>
#   inbound.sh --selftest
#
# THE THESIS, AND IT IS THE ONLY REASON THIS FILE IS NOT A ONE-LINE `ls`:
# DISPATCH KEYS ON FILENAMES, SO THE ROUTING GLOB MUST STAY NARROW — in a party whose
# lanes spend real resources, a matching filename is a TRIGGER. But READING costs nothing,
# so the reader can afford to be wide. NOTIFY-PATH WIDE, EXECUTE-PATH NARROW. Collapsing
# the two is the mistake that makes an inbox either deaf or trigger-happy, and there is no
# single width that is both.
#
# The source mesh measured the deaf half before writing its version: 15 archived comms named
# the brain in the body `to:` with a filename no glob could ever match, and 14 more put the
# name in the filename but not in an ADDRESSING position. The most load-bearing one reached
# its reader through a hand-written pointer in a state file — that is, through no mechanism
# at all.
#
# WHAT THIS DOES NOT DO. It owns no address grammar; `bus/actor.sh is-actor` is the one
# parser, and a second copy of a routing rule drifts from the dispatcher it is supposed to
# mirror. The source's own inline copy mis-read a LIVE comm because its hardcoded roster was
# missing a brain the dispatcher had. If the sibling is missing this FAILS LOUD rather than
# falling back: a silent fallback here is a deaf inbox, the exact class this file exists to end.
set -uo pipefail
: "${PARTY_BRAIN:?PARTY_BRAIN not set — an inbox with no owner cannot be read}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$REPO/bus/actor.sh"
[ -r "$ACTOR" ] || { echo "FATAL: $ACTOR missing — inbound cannot run, and a deaf inbox is worse than an error" >&2; exit 1; }

case "${1:-}" in --selftest) exec bash "$REPO/tests/staff-inbound-selftest.sh";; esac

# The bus path comes from `actor.sh bus` — the ONE roster reader. This file used to carry
# its own copy of that sed; so did two others, and all three silently defaulted to a local
# `bus/` when the roster was unreadable. actor.sh refuses instead.
#
# THE RC IS CONSUMED AT THE ASSIGNMENT, NOT INSIDE A HELPER. A helper that `exit`s on
# refusal exits only the command-substitution SUBSHELL: the caller gets the empty string,
# runs on, and the first thing it does with an empty $BUS is `mkdir -p /queues`. That is
# the same collapse of "it refused" into "it answered empty" that this repo's roster guard
# was written for, and the first version of this very comment shipped above code that
# committed it.
if [ -n "${1:-}" ]; then CD=$1
elif [ -n "${INNKEEPER_COMMS:-}" ]; then CD=$INNKEEPER_COMMS
else
  _b=$(bash "$ACTOR" bus) || { echo "FATAL: actor.sh refused to name the bus (unreadable roster?)" >&2; exit 2; }
  [ -n "$_b" ] || { echo "FATAL: actor.sh named an empty bus path" >&2; exit 2; }
  CD=$_b/comms
fi
# NORMALISE trailing slashes. `find` prints its START POINT verbatim, so a `dir/` argument
# carries the slash into every expansion below and `${f##*/}` yields the EMPTY STRING — the
# entry then vanishes from tier 1 in silence. Strip once, here, so every call site downstream
# sees the shape it would have gotten from basename.
while [ "${CD%/}" != "$CD" ] && [ -n "${CD%/}" ]; do CD="${CD%/}"; done
[ -d "$CD" ] || { echo "FATAL: comms dir not found: $CD" >&2; exit 1; }
DONE="$CD/_done"

ME=$(bash "$ACTOR" resolve "$PARTY_BRAIN" 2>/dev/null || echo "$PARTY_BRAIN")
# Every spelling that addresses me, so the body scans below can match an alias the writer used.
# Read through actor.sh; this file never opens the roster.
# Extract only the CANDIDATE tokens from the alias line and let `actor.sh resolve` decide which
# of them are me. Parsing the from/to PAIRING here would be a second grammar for the thing this
# file just refused to re-implement, and it would agree with actor.sh right up until one changed.
NAME_RE="$ME"
for a in $(bash "$ACTOR" roster 2>/dev/null | sed -n 's/^aliases:[[:space:]]*//p' \
           | tr -c 'A-Za-z0-9_-' ' ' | tr ' ' '\n' | sed '/^$/d' | sort -u); do
  [ "$a" = from ] || [ "$a" = to ] && continue
  [ "$(bash "$ACTOR" resolve "$a" 2>/dev/null)" = "$ME" ] || continue
  [ "$a" = "$ME" ] && continue
  NAME_RE="$NAME_RE|$a"
done

# `is-actor` is a SUBPROCESS, so every tier below filters on cheap tests first. Tiers 1 and 3
# test disposal before the predicate; tier 2 tests disposal and recency before it. That ordering
# is semantics-preserving by case analysis — a pending file reaches the same tests in either
# order — and it is the difference between a scan that runs in a second and one that spawns a
# process per archived file.
acts() { bash "$ACTOR" is-actor "$ME" "$1" >/dev/null 2>&1; }
pending() { [ -f "$DONE/${1##*/}" ] && return 1 || return 0; }
# My own outbound matches a broadcast glob, so without this guard tier 1 lists my own writing as
# arrivals and every "reply to the sender" line points back at me.
mine() { case "${1##*/}" in "$ME"-to-*) return 0;; *) return 1;; esac; }

t1=0; t1b=0; t2=0; t3=0; cpm=0

echo "=== TIER 1 — routable, ACT (the filename dispatches) ==="
while IFS= read -r f; do
  b=${f##*/}
  pending "$f" || continue
  mine "$b" && continue
  acts "$b" || continue
  t1=$((t1+1))
  # A ZERO-BYTE COMM IS DELIVERED, LISTED, AND INDISTINGUISHABLE FROM ONE YOU HAVE NOT READ.
  # Annotate, do NOT dispose: the body may still be written or re-sent, and a stub would close
  # the window on a comm nobody has ever read. Tell the sender instead — the defect is theirs.
  if [ -s "$f" ]; then echo "  $b"
  else echo "  $b   [!] 0 BYTES — filename only; do NOT dispose, tell the sender"; fi
done < <(find "$CD" -maxdepth 1 -name '*-to-*.md' 2>/dev/null)
[ "$t1" -eq 0 ] && echo "  (none)"

echo "=== TIER 1b — window-closed: full content already in _done/ (READ; may be handled) ==="
# `_done/` is shared by every reader, so the FIRST brain to dispose a broadcast closes the
# delivery window for everyone who ticks later. Zero-byte stubs are markers and are skipped;
# a NON-EMPTY file that arrived in _done recently is a comm this brain may never have seen.
# -ctime, not -mtime: a move preserves mtime, so a comm written last week and disposed today
# evades an mtime window entirely. ctime bumps on the rename itself.
while IFS= read -r f; do
  b=${f##*/}
  mine "$b" && continue
  [ -s "$f" ] || continue
  acts "$b" || continue
  t1b=$((t1b+1)); echo "  $b"
done < <(find "$DONE" -maxdepth 1 -ctime -1 -name '*-to-*.md' 2>/dev/null)
[ "$t1b" -eq 0 ] && echo "  (none)"

# One batch find for the recent set, rather than a find per file.
# THE DELIMITER IS NOT A DETAIL — NEWLINE-JOINING IS FORGEABLE. A file literally named
# $'X.md\nY.md' puts a bare "X.md" line into the set, and an unrelated week-old X.md then tests
# as recent. Found in the source by an agent built to break it, after three hand-picked cases
# all passed. -print0 mapped to \1: NUL cannot live in a bash variable, and \1 in a filename is
# pathological where a newline is merely rare.
RECENT=$'\1'"$(find "$CD" -maxdepth 1 -name '*.md' -mtime -1 -print0 2>/dev/null | tr '\0' '\1')"$'\1'
is_recent() { case "$RECENT" in *$'\1'"$1"$'\1'*) return 0;; *) return 1;; esac; }

# A `to:` line, with parentheticals and an inline `cc:` tail removed — both are cc, not address.
# HERE-STRINGS, NOT PIPES. Under `pipefail`, a `... | grep -q` that matches EARLY sends SIGPIPE
# to its producer and the pipeline returns 141, so a `|| continue` guard DROPS a real hit. The
# source lost cc'd comms to exactly this and its tier 3 count fell from 18 to 1.
addr_to() { sed -E 's/\([^)]*\)//g; s/[[:space:]]+[Cc][Cc]:.*$//' <<< "$1"; }

echo "=== TIER 2 — [!] ADDRESSED to me, but UNROUTABLE (no glob could ever deliver it) ==="
while IFS= read -r f; do
  b=${f##*/}; mine "$b" && continue
  pending "$f" || { is_recent "$f" || continue; }
  acts "$b" && continue
  local_to=$(grep -m1 -iE '^to:' "$f" 2>/dev/null || true)
  grep -qiE "($NAME_RE)" <<< "$(addr_to "$local_to")" || continue
  if pending "$f"; then t2=$((t2+1)); echo "  $b"; echo "      $local_to"; fi
done < <(find "$CD" -maxdepth 1 -name '*.md' 2>/dev/null)
[ "$t2" -eq 0 ] && echo "  (none)"

echo "=== TIER 3 — cc only: awareness, NO obligation ==="
while IFS= read -r f; do
  pending "$f" || continue
  b=${f##*/}; mine "$b" && continue
  acts "$b" && continue
  local_to=$(grep -m1 -iE '^to:' "$f" 2>/dev/null || true)
  local_cc=$(grep -m1 -iE '^cc:' "$f" 2>/dev/null || true)
  grep -qiE "($NAME_RE)" <<< "$(addr_to "$local_to")" && continue
  grep -qiE "($NAME_RE)" <<< "$local_cc $local_to" || continue
  t3=$((t3+1)); echo "  $b"
done < <(find "$CD" -maxdepth 1 -name '*.md' 2>/dev/null)
[ "$t3" -eq 0 ] && echo "  (none)"

# COPY-MARK DETECTOR. A disposal stub is `touch`, never `cp` — a NON-EMPTY twin in _done/ whose
# original is still in root means someone copied instead of stubbing, and that is precisely the
# false-positive population tier 1b's `-s` test discriminates on. Lossless to normalise to zero.
# The batch find must reproduce a glob loop EXACTLY, and `-type f ! -size 0` does not: a shell
# glob skips leading-dot names while find matches them (a stray dotfile twin raised a false alarm
# in the source), and `[ -s ]` follows symlinks and is true for directories where `-type f` is not.
while IFS= read -r t; do
  [ -n "$t" ] || continue
  [ -s "$t" ] && [ -f "$CD/${t##*/}" ] && cpm=$((cpm+1))
done < <(find "$DONE" -maxdepth 1 -name '*.md' ! -name '.*' 2>/dev/null)

# EMPTY-BODY SWEEP, WITH A LIVE CONTROL — AND THE CONTROL IS THE POINT OF THE WHOLE SECTION.
# `empty-body: 0` and "the sweep is broken" print the same character. So the sweep is handed a
# planted empty file in a temp root it must find, and if that control does not come back the
# count is reported as NOT A READING rather than as zero. An absence claim needs substrate; this
# is the substrate, created fresh on every run so it cannot go stale.
# The control proves the MECHANISM and never the COVERAGE — it says the find works, not that it
# was pointed at everything worth scanning. Widening the root is a separate decision.
CTL=$(mktemp -d "${TMPDIR:-/tmp}/inbound-ctl.XXXXXX"); : > "$CTL/control-to-nobody-CONTROL.md"
emall=$(find "$CD" "$CTL" -maxdepth 1 -type f -name '*.md' -size 0 2>/dev/null); rm -rf "$CTL"
em=$(printf '%s\n' "$emall" | command grep -v -- '-CONTROL\.md$' | command grep -c . || true)
printf '%s\n' "$emall" | command grep -q -- '-CONTROL\.md$' && emc=ok || emc=BROKEN

echo "--- act:$t1  window-closed:$t1b  unroutable:$t2  fyi:$t3  copy-marks:$cpm  empty-body:$em (control:$emc) ---"
[ "$emc" = BROKEN ] && echo "[!] EMPTY-BODY CONTROL DID NOT FIRE — the sweep is broken; empty-body:$em is NOT a reading."
[ "$em" -gt 0 ] && printf '%s\n' "$emall" | command grep -v -- '-CONTROL\.md$' | sed "s|^$CD/||; s|^|[!] EMPTY BODY (0 bytes; the sender's writer truncated or never wrote): |"
[ "$cpm" -gt 0 ] && echo "[!] COPY-MARKS ($cpm): non-empty _done twins whose original is still present — normalise to zero (cmp -s first)."
[ "$t2" -gt 0 ] && echo "[!] TIER 2 NON-EMPTY: tell each sender that FILENAME addressing failed — the body reached nobody's glob."
exit 0
