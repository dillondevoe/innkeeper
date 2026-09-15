#!/usr/bin/env bash
# lease.sh — singleton lease for one brain's lane.
#
# Why it exists: a done-marker is an existence check. Two instances of the same brain that both
# read the inbox before either writes its marker will both act, and can reach conflicting verdicts.
# The lease closes that window: one live instance holds the lane, a second booting instance sees
# HELD-BY-OTHER and stands down.
#
#   lease.sh claim            -> CLAIMED <nonce> | HELD-BY-OTHER age=<s>
#   lease.sh renew <nonce>    -> RENEWED | NOT-HOLDER
#   lease.sh release <nonce>  -> RELEASED | NOT-HOLDER
#   lease.sh status           -> FREE | HELD age=<s> nonce=<n> | STALE age=<s> nonce=<n> [(previous boot)]
#
# Lock: $INNKEEPER_HOME/state/<brain>.lease, brain = $PARTY_BRAIN. Never hand-edit it.
# A lease is STALE when older than LEASE_TTL (default 1800s), OR when it was claimed under a
# different boot: a process cannot hold a lease across a reboot, and a TTL alone left a dead
# holder's lease blocking relaunches for its remaining minutes. Unknown boot (0) degrades to TTL.
#
# Port note: the source read the lock and then wrote it with nothing in between, so two instances
# booting together could both CLAIM — the race the lease exists to close. Every read-decide-write
# here runs inside a mkdir mutex (portable: no flock on macOS).
set -euo pipefail

: "${INNKEEPER_HOME:?INNKEEPER_HOME not set}"
: "${PARTY_BRAIN:?PARTY_BRAIN not set}"
TTL=${LEASE_TTL:-1800}
DIR=$INNKEEPER_HOME/state
LOCK=$DIR/$PARTY_BRAIN.lease
MUTEX=$LOCK.mutex
mkdir -p "$DIR"

boot_epoch() {
  local b=""
  b=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/^\{ *sec *= *([0-9]+).*/\1/p') || b=""
  [ -n "$b" ] || b=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null) || b=""
  echo "${LEASE_BOOT_EPOCH:-${b:-0}}"
}
BOOT=$(boot_epoch)

new_nonce() {
  uuidgen 2>/dev/null && return
  cat /proc/sys/kernel/random/uuid 2>/dev/null && return
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; echo
}

# Mutex. A holder that died inside the critical section leaves the dir; it is broken after 10s,
# far longer than any critical section here takes.
lock_mutex() {
  local i=0
  until mkdir "$MUTEX" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -ge 100 ]; then
      local m; m=$(stat -c %Y "$MUTEX" 2>/dev/null || stat -f %m "$MUTEX" 2>/dev/null || echo 0)
      if [ $(( $(date +%s) - m )) -ge 10 ]; then rmdir "$MUTEX" 2>/dev/null || true; i=0; continue; fi
      echo "CANNOT-ASSESS mutex busy" >&2; exit 2
    fi
    sleep 0.05
  done
  trap 'rmdir "$MUTEX" 2>/dev/null || true' EXIT
}

read_lock() { [ -f "$LOCK" ] && head -1 "$LOCK" 2>/dev/null || true; }
lock_fields() {
  ts=${1%% *}; local rest=${1#* }; nonce=${rest%% *}
  lboot=${rest#* }
  [ "$lboot" = "$nonce" ] && lboot=0   # two-field lock: no boot recorded
  return 0
}
lock_is_stale() {
  local age=$(( now - ts ))
  [ "$age" -ge "$TTL" ] && return 0
  [ "$lboot" != 0 ] && [ "$BOOT" != 0 ] && [ "$lboot" != "$BOOT" ] && return 0
  return 1
}
write_lock() { local t; t=$(mktemp "$DIR/.lease.XXXXXX"); echo "$now $1 $BOOT" >"$t"; mv -f "$t" "$LOCK"; }

case "${1:-}" in
  claim)
    lock_mutex; now=$(date +%s)
    existing=$(read_lock)
    if [ -n "$existing" ]; then
      lock_fields "$existing"
      if ! lock_is_stale; then echo "HELD-BY-OTHER age=$(( now - ts ))"; exit 0; fi
    fi
    n=$(new_nonce); write_lock "$n"; echo "CLAIMED $n" ;;
  renew|release)
    want=${2:?$1 needs the nonce}
    lock_mutex; now=$(date +%s)
    existing=$(read_lock); nonce=""
    [ -n "$existing" ] && lock_fields "$existing"
    if [ "$nonce" != "$want" ]; then echo "NOT-HOLDER"; exit 0; fi
    if [ "$1" = renew ]; then write_lock "$want"; echo "RENEWED"; else rm -f "$LOCK"; echo "RELEASED"; fi ;;
  status)
    now=$(date +%s); existing=$(read_lock)
    if [ -z "$existing" ]; then echo "FREE"; exit 0; fi
    lock_fields "$existing"; age=$(( now - ts ))
    if lock_is_stale; then
      prev=""; [ "$lboot" != 0 ] && [ "$lboot" != "$BOOT" ] && prev=" (previous boot)"
      echo "STALE age=$age nonce=$nonce$prev"
    else
      echo "HELD age=$age nonce=$nonce"
    fi ;;
  *) echo "usage: lease.sh claim|renew <nonce>|release <nonce>|status" >&2; exit 2 ;;
esac
