#!/usr/bin/env bash
# watchman.sh — the familiar that keeps looking while the paid roles are idle.
#
#   bin/watchman.sh once                          one look; print what changed
#   bin/watchman.sh watch [--every S] [--rounds N]   keep looking (default every 5s, forever)
#
# WHAT IT IS FOR. The Innkeeper is a model call: it judges, and every turn costs money. The
# Watchman is a plain script: it costs nothing, so it can look all the time. It wakes the
# Innkeeper only when something has CHANGED. The free part watches; the part that costs money
# only runs when there is something to judge. That split is how a party stays cheap.
#
# WHAT IT LOOKS AT:
#   stale-lease   a quest is `claimed`, and the lane holding it has a STALE lease
#                 (lifecycle/lease.sh decides staleness; this script never re-derives it).
#                 The holder died or hung; the quest will sit forever unless someone notices.
#   spend-near-ceiling   the live ledger ($INNKEEPER_LEDGER) has reached 80% of
#                 INNKEEPER_LIVE_MAX_USD (default 3.00). Only checked when a ledger exists.
#
# WHAT IT NEVER DOES. It does not reassign a quest, release a lease, or stop a call. It
# notices and reports; deciding belongs to the Innkeeper. A watcher that also acts is a second,
# unsupervised worker, and the gate never sees its work.
#
# HOW IT WAKES. Each finding is a file in $INNKEEPER_BUS/wake/<kind>.<subject>. A new finding
# prints `WAKE <kind> <subject> <detail>` once and writes its file; the same finding on the next
# look prints nothing (the file is already there), so a stuck quest wakes the Innkeeper once,
# not every five seconds. When the condition goes away the file is removed and `CLEARED` is
# printed, so the same problem coming back later wakes it again. A look that finds no change
# prints `quiet`.
#
# Never calls a model, never touches the network. Exit 0 on a look (findings are not errors),
# 2 when the bus cannot be read.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
QUEST="$REPO/bus/quest.sh"
LEASE="$REPO/lifecycle/lease.sh"
NEAR_PCT=80

usage() { echo "usage: watchman.sh once | watch [--every S] [--rounds N]" >&2; exit 2; }
[ -n "${INNKEEPER_BUS:-}" ] || { echo "watchman: INNKEEPER_BUS is not set" >&2; exit 2; }
WAKE="$INNKEEPER_BUS/wake"
mkdir -p "$WAKE" || { echo "watchman: cannot write $WAKE" >&2; exit 2; }

# Print the findings that hold RIGHT NOW, one "<kind>.<subject>\t<detail>" per line.
findings() {
  local list id state lane _ st
  list=$(bash "$QUEST" list --state claimed) || { echo "watchman: cannot list quests" >&2; return 2; }
  while read -r id state lane _; do
    [ -n "$id" ] || continue
    st=$(PARTY_BRAIN=$lane bash "$LEASE" status 2>/dev/null) || st=""
    case "$st" in
      STALE*) printf 'stale-lease.%s\tquest=%s holder=%s (%s)\n' "$id" "$id" "$lane" "$st" ;;
    esac
  done <<< "$list"

  if [ -n "${INNKEEPER_LEDGER:-}" ] && [ -f "$INNKEEPER_LEDGER" ]; then
    local ceiling=${INNKEEPER_LIVE_MAX_USD-3.00}
    awk -F'\t' -v c="$ceiling" -v p="$NEAR_PCT" '
      $3 ~ /^[0-9.]+$/ {t += $3}
      END { if (c+0 > 0 && t >= c * p / 100)
              printf "spend-near-ceiling.live\tspent=%.4f ceiling=%.2f\n", t, c }' "$INNKEEPER_LEDGER"
  fi
}

look() {
  local now key detail changed=0 f
  now=$(findings) || return 2
  # New findings: wake once.
  while IFS=$'\t' read -r key detail; do
    [ -n "$key" ] || continue
    if [ ! -e "$WAKE/$key" ]; then
      printf '%s\n' "$detail" > "$WAKE/$key"
      echo "WAKE ${key%%.*} ${key#*.} $detail"
      changed=1
    fi
  done <<< "$now"
  # Findings that no longer hold: clear, so a recurrence wakes again.
  for f in "$WAKE"/*; do
    [ -e "$f" ] || continue
    key=$(basename "$f")
    if ! printf '%s\n' "$now" | cut -f1 | grep -qxF "$key"; then
      rm -f "$f"
      echo "CLEARED ${key%%.*} ${key#*.}"
      changed=1
    fi
  done
  [ "$changed" = 1 ] || echo "quiet"
}

case "${1:-}" in
  once) look ;;
  watch)
    shift; every=5; rounds=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --every)  every=${2:-}; shift 2 ;;
        --rounds) rounds=${2:-}; shift 2 ;;
        *) usage ;;
      esac
    done
    i=0
    while :; do
      look || exit $?
      i=$((i+1)); [ "$rounds" -gt 0 ] && [ "$i" -ge "$rounds" ] && break
      sleep "$every"
    done ;;
  *) usage ;;
esac
