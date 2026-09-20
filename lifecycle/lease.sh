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
#     `age` is the age the verdict was MADE on: awake-seconds when both this host and the lock
#     carry an awake clock, wall-seconds otherwise. Printing any other number would hand the
#     reader a figure that contradicts the verdict standing next to it.
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

# THE LAPTOP-SLEEP CASE. TTL was measured on the wall clock, and the wall clock keeps running
# while the machine is suspended. A MacBook that sleeps for an hour wakes with every lease older
# than any TTL we would pick, so a second instance sees STALE and claims a lane whose holder is
# alive and mid-task -- two live holders, which is the exact thing this file exists to prevent.
# The holder cannot defend itself: it was frozen, so it could not renew.
#
# The fix is to age a lease on a clock that does not advance while suspended. Linux CLOCK_MONOTONIC
# (via /proc/uptime) excludes suspend by definition, which is precisely the property wanted here.
# An awake clock is only comparable within one boot -- it resets to zero on reboot -- but that is
# exactly the case the boot-epoch check below already handles first, so the two rules compose.
#
# WHERE THERE IS NO AWAKE CLOCK we fall back to the wall clock and the old behaviour, and the lock
# records WHICH clock it was written with rather than writing a 0 that reads like "awake for zero
# seconds". Absent and zero are different facts; collapsing them would silently give a portable
# build the bug this comment describes.
#
# DIRECTION OF FAILURE, deliberately chosen: this makes leases expire LATER, never earlier. Holding
# a dead holder's lane too long blocks a relaunch -- visible, and recoverable by waiting or by the
# boot check. Expiring a LIVE holder's lane hands two workers the same task and corrupts quietly.
# When a clock is uncertain, the safe error is to keep the lane held.
#
# NO AWAKE CLOCK IS KNOWN FOR DARWIN YET, AND THE OBVIOUS CANDIDATE IS WORSE THAN NOTHING.
# `python3 -c 'import time; print(int(time.monotonic()))'` returns **0** on macOS 26, which this
# code would store and later read as "awake for zero seconds" -- so every lease would compute
# age 0 and NEVER go stale. That is the absent-is-not-zero collapse above, arriving through the
# fix for it. Measured on a macOS host: CLOCK_MONOTONIC equals wall-seconds-since-kern.boottime exactly
# (2672134 both), so it counts sleep and is just a wall clock; CLOCK_UPTIME_RAW read 12s HIGHER
# than that, which no sleep-excluding clock can do. Neither is a candidate, and neither test
# discriminates anyway on a machine that has not slept: the question can only be settled by
# reading a clock before and after a real suspend. Until someone does, Darwin has no awake clock
# here and SAYS SO -- see awake_clock_note() below. A stated limit is shippable; a silent one is
# not, and a guessed one is the bug wearing the fix's clothes.
awake_seconds() {
  local a="${LEASE_AWAKE_S:-}"
  [ -n "$a" ] && { echo "$a"; return; }
  # The path is a variable so a test can reproduce a host WITHOUT an awake clock by pointing it
  # at one that does not exist -- travelling this exact branch rather than asserting the verdict
  # it is supposed to produce. LEASE_AWAKE_S= (empty) does NOT do that: it falls straight through
  # to here and finds Linux's real /proc/uptime, so an arm written that way passes on macOS and
  # is vacuous on Linux, which is the substrate asymmetry this whole file just paid for.
  a=$(awk '{print int($1)}' "${LEASE_UPTIME_FILE:-/proc/uptime}" 2>/dev/null) || a=""
  echo "$a"   # empty means NO AWAKE CLOCK ON THIS HOST -- not "zero seconds awake"
}
AWAKE=$(awake_seconds)

# The limit, said out loud wherever a verdict is printed. Empty when the host HAS an awake clock,
# so it costs nothing on Linux and cannot be mistaken for a warning about something else.
awake_clock_note() {
  [ -n "$AWAKE" ] && return
  printf ' [no awake clock on this host: it cannot tell sleep from death, so leases age on the WALL clock and a suspended holder loses its lane]'
}

new_nonce() {
  # SCHEMA.md specifies the nonce as lowercase hex, and two of these three sources emit it
  # that way -- but macOS `uuidgen` returns UPPERCASE. A reader matching the documented
  # shape then rejects a nonce this very function produced, on one platform only. Normalise
  # at the single producer rather than widening every consumer's pattern.
  local n
  n=$(uuidgen 2>/dev/null) \
    || n=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) \
    || n=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [ -n "$n" ] || { echo "lease.sh: no entropy source produced a nonce" >&2; return 1; }
  printf '%s\n' "$n" | tr 'A-F' 'a-f'
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
# Fields: ts nonce [boot [awake]]. Older locks carry two or three; a missing field is 0/"" and
# is read as ABSENT, never as the value zero.
lock_fields() {
  local f1 f2 f3 f4 rest
  read -r f1 f2 f3 f4 rest <<<"$1"
  ts=$f1; nonce=$f2; lboot=${f3:-0}; lawake=${f4:-}
  return 0
}
# Sets `age` to the age the verdict was actually made on, so the number a caller prints can never
# contradict the verdict beside it.
lock_is_stale() {
  # A reboot is decided first and on its own: a process cannot hold a lease across one, and after a
  # reboot the awake clock below is not comparable with the one in the lock.
  if [ "$lboot" != 0 ] && [ "$BOOT" != 0 ] && [ "$lboot" != "$BOOT" ]; then
    age=$(( now - ts )); return 0
  fi
  if [ -n "$lawake" ] && [ -n "$AWAKE" ]; then
    age=$(( AWAKE - lawake ))
    [ "$age" -lt 0 ] && age=0   # an awake clock that went backwards within one boot: trust the holder
  else
    age=$(( now - ts ))
  fi
  [ "$age" -ge "$TTL" ] && return 0
  return 1
}
write_lock() { local t; t=$(mktemp "$DIR/.lease.XXXXXX"); echo "$now $1 $BOOT $AWAKE" >"$t"; mv -f "$t" "$LOCK"; }

case "${1:-}" in
  claim)
    lock_mutex; now=$(date +%s)
    existing=$(read_lock)
    if [ -n "$existing" ]; then
      lock_fields "$existing"
      if ! lock_is_stale; then echo "HELD-BY-OTHER age=$age$(awake_clock_note)"; exit 0; fi
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
    lock_fields "$existing"
    if lock_is_stale; then
      prev=""; [ "$lboot" != 0 ] && [ "$lboot" != "$BOOT" ] && prev=" (previous boot)"
      echo "STALE age=$age nonce=$nonce$prev$(awake_clock_note)"
    else
      echo "HELD age=$age nonce=$nonce$(awake_clock_note)"
    fi ;;
  *) echo "usage: lease.sh claim|renew <nonce>|release <nonce>|status" >&2; exit 2 ;;
esac
