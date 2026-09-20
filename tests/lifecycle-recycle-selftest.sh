#!/usr/bin/env bash
# lifecycle-recycle-selftest.sh — battery for lifecycle/recycle.sh.
#
# The property under test is an ORDER, not an output: nothing is written until the two
# steps that can fail have succeeded, and a failed exit leaves no flag behind. An order
# is invisible in a success log, so every failing arm here is PAIRED WITH A PERMITTING
# TWIN — the same invocation with the one fault removed — because "no flag" also holds
# when the script did nothing at all, and an arm that cannot tell those apart is green
# for the wrong reason.
#
# The multiplexer is a STUB on PATH via INNKEEPER_MUX, scripted per arm. Real tmux is
# never touched: a battery that ends live sessions on the host that runs it is a battery
# nobody runs twice.
set -u
R=$(cd "$(dirname "$0")/.." && pwd -P)
IMPL="${RECYCLE_IMPL:-$R/lifecycle/recycle.sh}"
EXPECT_ARMS=23
n=0; pass=0
arm() {  # arm <name> <want-rc|-> <got-rc> [<pattern> <text>]
  n=$((n+1)); local name="$1" wrc="$2" grc="$3" ok=1
  if [ "$wrc" != "-" ] && [ "$wrc" != "$grc" ]; then ok=0; local why="rc=$grc want $wrc"; fi
  if [ "$#" -ge 5 ]; then
    case "$5" in $4) ;; *) ok=0; why="got [$5] want $4" ;; esac
  fi
  if [ "$ok" = 1 ]; then pass=$((pass+1)); else echo "FAIL $name: ${why}"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/launchers"

# A stub multiplexer. Behaviour per verb is read from files in $WORK, so one arm can make
# has-session fail while another makes send-keys fail, with no second stub to drift.
MUX="$WORK/mux"; cat > "$MUX" <<'MS'
#!/usr/bin/env bash
W="$(dirname "$0")"
echo "$*" >> "$W/mux.calls"
case "$1" in
  has-session)   exit "$(cat "$W/rc.has-session" 2>/dev/null || echo 0)" ;;
  send-keys)     exit "$(cat "$W/rc.send-keys"   2>/dev/null || echo 0)" ;;
  capture-pane)  cat "$W/pane" 2>/dev/null; exit 0 ;;
esac
exit 0
MS
chmod +x "$MUX"

cat > "$WORK/party.yaml" <<PY
brains:
  - {name: geist,  lane: gate,  recycle_after: 6}
  - {name: rabbot, lane: voice, recycle_after: 12}
# An alias is its own section with from:/to: — NOT an inline alias: field on the row. The
# first cut of this fixture used the inline spelling; actor.sh never reads it, so resolve
# returned the token unchanged and B8 failed. The fixture, not the code: a fixture that
# spells the roster in a second dialect is the same defect the port exists to remove.
aliases:
  - {from: cleric, to: rabbot}
launchers: [$WORK/launchers/start-*.sh]
PY

# run <brain> <session> — a fresh state dir per arm, so no arm inherits another's flags.
run() {
  ST="$WORK/home"; rm -rf "$ST"; mkdir -p "$ST/state"; rm -f "$WORK/mux.calls"
  OUT=$(INNKEEPER_PARTY="$WORK/party.yaml" INNKEEPER_HOME="$ST" INNKEEPER_MUX="$MUX" \
        INNKEEPER_CONFIRM_DEADLINE=1 TICKS_DIR="$ST/state/ticks" \
        bash "$IMPL" "$1" "$2" 2>&1); RC=$?
}
flags() { ls "$ST/state" 2>/dev/null | command grep -c '^recycle-.*\.flag$'; }

# ---- 1. The multiplexer gate (step 1) --------------------------------------------------
ST="$WORK/home"; rm -rf "$ST"; mkdir -p "$ST/state"
OUT=$(INNKEEPER_PARTY="$WORK/party.yaml" INNKEEPER_HOME="$ST" INNKEEPER_MUX="$WORK/nope" \
      bash "$IMPL" geist s1 2>&1); RC=$?
arm B1-no-mux-fails            3 "$RC" '*no multiplexer*' "$OUT"
arm B1b-no-mux-writes-no-flag  - 0 '0' "$(flags)"
# The twin: identical call, mux present. Without it, B1b is green for a script that exits
# at line 1 — "no flag written" is also what a broken script produces.
rm -f "$WORK/rc.has-session" "$WORK/rc.send-keys"
run geist s1
arm B1c-twin-mux-present-ok    0 "$RC" '*OK*exit queued*' "$OUT"
arm B1d-twin-writes-the-flag   - 0 '1' "$(flags)"

# ---- 2. The session gate (step 2) ------------------------------------------------------
echo 1 > "$WORK/rc.has-session"
run geist ghost
arm B2-no-session-fails        4 "$RC" "*session 'ghost' not found*" "$OUT"
arm B2b-no-session-no-flag     - 0 '0' "$(flags)"
arm B2c-no-session-no-send     - 0 '0' "$(command grep -c '^send-keys' "$WORK/mux.calls" 2>/dev/null || true)"
rm -f "$WORK/rc.has-session"

# ---- 3. The rollback (step 6) ----------------------------------------------------------
# The arm the whole write-ahead order exists for: the exit failed, so the flag must be gone.
echo 1 > "$WORK/rc.send-keys"
run geist s1
arm B3-send-fail-rc            5 "$RC" '*flag removed*' "$OUT"
arm B3b-send-fail-rolls-back   - 0 '0' "$(flags)"
arm B3c-send-fail-counter-kept - 0 '' "$(ls "$ST/state/ticks" 2>/dev/null)"   # step 7 never ran
rm -f "$WORK/rc.send-keys"

# ---- 4. The compaction flag (step 4) ---------------------------------------------------
ST="$WORK/home"; rm -rf "$ST"; mkdir -p "$ST/state"; : > "$ST/state/compacted-s1.flag"
OUT=$(INNKEEPER_PARTY="$WORK/party.yaml" INNKEEPER_HOME="$ST" INNKEEPER_MUX="$MUX" \
      INNKEEPER_CONFIRM_DEADLINE=1 TICKS_DIR="$ST/state/ticks" bash "$IMPL" geist s1 2>&1); RC=$?
arm B4-compaction-flag-cleared - 0 '0' "$(ls "$ST/state" | command grep -c '^compacted-')"
arm B4b-and-recycle-flag-set   - 0 '1' "$(flags)"

# ---- 5. The launcher WARN (step 3) -----------------------------------------------------
rm -f "$WORK/launchers"/*.sh
run geist s1
arm B5-no-launcher-warns       0 "$RC" '*WARN*no launcher consumes*' "$OUT"
arm B5b-warn-still-writes      - 0 '1' "$(flags)"          # WARN, not FAIL: the flag is written
printf 'exec: rm -f state/recycle-geist.flag\n' > "$WORK/launchers/start-geist.sh"
run geist s1
arm B6-consumed-no-warn        0 "$RC" '*' "$OUT"
case "$OUT" in *"no launcher consumes"*) echo "FAIL B6b-consumed-silent: warned anyway";; *) pass=$((pass+1));; esac; n=$((n+1))
# THE COMMENT ARM. A launcher whose only mention of the flag is prose warning against it
# satisfies a naive grep with the exact wrong name — the fail-open that looks like a pass.
printf '# do NOT use state/recycle-geist.flag here\nexec: true\n' > "$WORK/launchers/start-geist.sh"
run geist s1
arm B7-comment-only-still-warns 0 "$RC" '*WARN*no launcher consumes*' "$OUT"

# ---- 6. Alias resolution — one brain, one flag ------------------------------------------
printf 'exec: rm -f state/recycle-rabbot.flag\n' > "$WORK/launchers/start-rabbot.sh"
run cleric s1
arm B8-alias-flag-is-canonical - 0 'recycle-rabbot.flag' "$(ls "$ST/state" | command grep '^recycle-')"
arm B8b-alias-no-warn          0 "$RC" '*' "$OUT"
case "$OUT" in *"no launcher consumes"*) echo "FAIL B8c-alias-consumed: warned on the canonical name";; *) pass=$((pass+1));; esac; n=$((n+1))

# ---- 7. Step 7 runs, and only on success ------------------------------------------------
arm B9-counter-reset-on-ok     - 0 'rabbot.json' "$(ls "$ST/state/ticks" 2>/dev/null)"
arm B10-log-is-per-host        - 0 "recycle.$(hostname -s 2>/dev/null || echo unknown).log" \
                                   "$(ls "$ST/state/logs" 2>/dev/null)"
arm B11-log-records-ok         - 0 '*OK exit-sent*' "$(cat "$ST/state/logs"/*.log 2>/dev/null)"

if [ "$pass" = "$EXPECT_ARMS" ] && [ "$n" = "$EXPECT_ARMS" ]; then
  echo "lifecycle-recycle-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"; exit 0
fi
echo "lifecycle-recycle-selftest: $pass/$n passed (expected $EXPECT_ARMS arms)"; exit 1
