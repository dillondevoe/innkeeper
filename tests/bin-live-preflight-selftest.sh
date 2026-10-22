#!/usr/bin/env bash
# bin-live-preflight-selftest.sh — battery for bin/live-preflight.sh
#
# THE ARM THAT CARRIES THIS FILE IS L6, AND IT ASSERTS AN ABSENCE. Every other arm here
# checks that the gate answers correctly; L6 checks that answering cost nothing. A gate on
# spending that confirms authorisation by spending is the defect this whole file exists to
# prevent, and it is INVISIBLE in every other arm -- a preflight that quietly called the
# model on each invocation would pass L1 through L5 and L7 unchanged, while billing the
# reader for every "REFUSED" it printed. So the stub CLI appends to a ledger on every
# execution and L6 asserts the ledger does not exist.
#
# Every refusal arm names WHICH refusal fired rather than reading rc alone: this gate has
# six distinct ways to return 1, and an arm that only sees the exit code stays green if
# they collapse into one (an earlier guard shadowing the branch under test).
#
# L2 and L2b are the permitting twins. Without them a gate that refused unconditionally --
# the easiest way to be wrong here, and the one that looks most responsible -- passes every
# refusal arm in the file.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
PRE="$REPO/bin/live-preflight.sh"

EXPECT_ARMS=16
fails=0; arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL${2:+ :: $2}"; }

# mktemp -d, never a named directory under /tmp: a verifier that inherits an ambient
# directory cannot certify a tool whose job is to read its environment.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The stub CLI. It RECORDS the fact of its own execution and says nothing useful, because
# the only question any arm here asks of it is whether it ran at all.
LEDGER="$WORK/spent.log"
STUB="$WORK/claude"
cat > "$STUB" <<STUBEOF
#!/bin/sh
echo "called \$*" >> "$LEDGER"
echo '{"result":"stub","total_cost_usd":0.0}'
STUBEOF
chmod +x "$STUB"

# run <arm> — runs the gate with the environment the caller set, capturing rc and output.
# Every arm goes through the real entry point; nothing here sources the script or calls an
# internal function, because the conditions under test ARE the environment at that entry.
# bash by ABSOLUTE path. L3 empties PATH to prove the gate cannot find a CLI, and `env`
# resolves the command it is given against the PATH it was handed -- so a bare `bash` there
# fails with rc 127 before the gate runs at all, and the arm reports a refusal that never
# happened. An arm that passes for the wrong reason is one thing; this one failed for the
# wrong reason, which is the same defect wearing the other sign.
BASH_ABS=$(command -v bash) || { echo "no bash on PATH"; exit 2; }
OUT=""; RC=0
run() { OUT=$(env "$@" "$BASH_ABS" "$PRE" 2>&1); RC=$?; }

BASEOK=(INNKEEPER_LIVE=1 "INNKEEPER_CLAUDE=$STUB")

echo "bin-live-preflight-selftest: the gate on spending"

# --- L1: the default is refusal, and it names the opt-in --------------------------------
run INNKEEPER_LIVE= "INNKEEPER_CLAUDE=$STUB"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'no opt-in'; then
  ok "L1-no-opt-in-refuses"
else bad "L1-no-opt-in-refuses" "rc=$RC out=[$OUT]"; fi

# --- L2 / L2b: THE PERMITTING TWINS ------------------------------------------------------
run "${BASEOK[@]}"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^CLEAR'; then
  ok "L2-fully-armed-env-is-CLEAR"
else bad "L2-fully-armed-env-is-CLEAR" "rc=$RC out=[$OUT]"; fi

run "${BASEOK[@]}" INNKEEPER_LIVE_MAX_USD=0.25
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '0\.25'; then
  ok "L2b-explicit-budget-is-CLEAR-and-echoed"
else bad "L2b-explicit-budget-is-CLEAR-and-echoed" "rc=$RC out=[$OUT]"; fi

# --- L3: opted in, no binary anywhere ----------------------------------------------------
# PATH is emptied as well as INNKEEPER_CLAUDE, or a real CLI on the developer's PATH makes
# this arm pass for the wrong reason on their machine and fail on a fresh clone.
run INNKEEPER_LIVE=1 INNKEEPER_CLAUDE= PATH=/nonexistent
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'no model CLI found'; then
  ok "L3-no-binary-refuses-by-name"
else bad "L3-no-binary-refuses-by-name" "rc=$RC out=[$OUT]"; fi

# --- L4: pointed at a real file that is not executable -----------------------------------
# The plausible mistake: a downloaded binary whose mode bit was never set. It EXISTS, so a
# check written as `[ -f ]` alone passes it and the failure surfaces mid-quest instead.
NOEXEC="$WORK/notexec"; : > "$NOEXEC"; chmod 644 "$NOEXEC"
run INNKEEPER_LIVE=1 "INNKEEPER_CLAUDE=$NOEXEC"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'not executable'; then
  ok "L4-non-executable-binary-refuses-by-name"
else bad "L4-non-executable-binary-refuses-by-name" "rc=$RC out=[$OUT]"; fi

# --- L4b: pointed at a directory ---------------------------------------------------------
run INNKEEPER_LIVE=1 "INNKEEPER_CLAUDE=$WORK"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'not a file'; then
  ok "L4b-directory-refuses-by-name"
else bad "L4b-directory-refuses-by-name" "rc=$RC out=[$OUT]"; fi

# --- L5: the opt-in is EXACT -------------------------------------------------------------
# The whole point of the strict predicate. `true` and `yes` are what a person types when
# they are enabling something else entirely; a truthy test spends their money for them.
l5=0
for v in true yes 0 TRUE 1x " 1"; do
  run "INNKEEPER_LIVE=$v" "INNKEEPER_CLAUDE=$STUB"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'no opt-in' || { l5=1; echo "    [$v] was accepted"; }
done
[ "$l5" = 0 ] && ok "L5-opt-in-is-exactly-1" || bad "L5-opt-in-is-exactly-1" "a truthy value opted in"

# --- L6: THE GATE ON SPENDING SPENDS NOTHING ---------------------------------------------
# Load-bearing. Every invocation above pointed INNKEEPER_CLAUDE at a stub that records its
# own execution; the CLEAR arms did too, so this covers the permitting path and not only
# the refusing one. If the ledger exists, the gate called the model to answer a question
# about whether it was allowed to call the model.
if [ ! -e "$LEDGER" ]; then
  ok "L6-preflight-never-executed-the-CLI"
else bad "L6-preflight-never-executed-the-CLI" "it ran it $(wc -l < "$LEDGER" | tr -d ' ') time(s): $(cat "$LEDGER")"; fi

# --- L6b: ...and the arm above is capable of failing --------------------------------------
# Without this, L6 also passes on a stub that was never installed, a ledger path that no
# writer could reach, or a `run` that never executed anything. An absence assertion needs a
# substrate: prove the ledger DOES appear when something genuinely runs the stub.
"$STUB" --probe >/dev/null 2>&1
if [ -s "$LEDGER" ]; then
  ok "L6b-the-ledger-does-record-a-real-call"
else bad "L6b-the-ledger-does-record-a-real-call" "the stub cannot record; L6 proved nothing"; fi
rm -f "$LEDGER"

# --- L7: a bad ceiling refuses rather than falling back -----------------------------------
l7=0
# The empty string is in this list on purpose and it is the interesting one: a ceiling
# variable that is SET AND EMPTY is what a failed command substitution leaves behind
# (`INNKEEPER_LIVE_MAX_USD=$(compute_budget)` when compute_budget died). `${v:-default}`
# reads that as "unset" and quietly installs the default -- which is the exact silent
# substitution the gate's own header forbids, committed by the gate. Three states, not two.
for v in "one dollar" "1.0.0" "" "1,00"; do
  run "${BASEOK[@]}" "INNKEEPER_LIVE_MAX_USD=$v"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'not a number' || { l7=1; echo "    [$v] was accepted as a ceiling"; }
done
[ "$l7" = 0 ] && ok "L7-unparseable-ceiling-refuses" || bad "L7-unparseable-ceiling-refuses" "a bad ceiling passed"

# --- L8: the stated limit is STATED --------------------------------------------------------
# The limit is the reason this gate is honest rather than merely cheap. If a future edit
# makes it silent, the gate starts implying it checked authorisation.
run "${BASEOK[@]}"
if printf '%s' "$OUT" | grep -q 'NOT CHECKED'; then
  ok "L8-the-unverifiable-condition-is-named-in-the-output"
else bad "L8-the-unverifiable-condition-is-named-in-the-output" "out=[$OUT]"; fi

# --- L9: usage ------------------------------------------------------------------------------
OUT=$(env "${BASEOK[@]}" "$BASH_ABS" "$PRE" --what 2>&1); RC=$?
if [ "$RC" = 2 ]; then ok "L9-unknown-flag-is-usage-rc2"
else bad "L9-unknown-flag-is-usage-rc2" "rc=$RC"; fi

# --- L10: a refusal says nothing was spent ---------------------------------------------------
run INNKEEPER_LIVE= "INNKEEPER_CLAUDE=$STUB"
if printf '%s' "$OUT" | grep -q 'Nothing has been spent'; then
  ok "L10-refusal-states-that-nothing-was-spent"
else bad "L10-refusal-states-that-nothing-was-spent" "out=[$OUT]"; fi

# --- L11: --budget is the ONE resolver, and the report reads the same number -----------------
# The ceiling is resolved here and ENFORCED in roles/claude-call.sh, which calls `--budget`
# rather than re-deriving the default. Two halves spelling one rule in two languages is this
# repo's oldest scar. L11 pins that they agree: whatever --budget prints is the number the
# human-readable report shows.
B=$(env INNKEEPER_LIVE_MAX_USD=0.25 "$BASH_ABS" "$PRE" --budget 2>&1); RCB=$?
run "${BASEOK[@]}" INNKEEPER_LIVE_MAX_USD=0.25
if [ "$RCB" = 0 ] && [ "$B" = "0.25" ] && printf '%s' "$OUT" | grep -q 'budget ceiling: \$0\.25'; then
  ok "L11-budget-mode-and-the-report-agree"
else bad "L11-budget-mode-and-the-report-agree" "rc=$RCB budget=[$B]"; fi

# --- L11b: --budget takes the default when the ceiling is UNSET -----------------------------
B=$(env -u INNKEEPER_LIVE_MAX_USD "$BASH_ABS" "$PRE" --budget 2>&1); RCB=$?
if [ "$RCB" = 0 ] && [ "$B" = "3.00" ]; then ok "L11b-unset-ceiling-resolves-to-the-default"
else bad "L11b-unset-ceiling-resolves-to-the-default" "rc=$RCB budget=[$B]"; fi

# --- L11c: --budget REFUSES what the report refuses ------------------------------------------
# A resolver that printed a fallback here while the report refused would hand the enforcer a
# ceiling the gate had already rejected: enforcement against a number nobody approved, with
# the report still reading correctly.
B=$(env INNKEEPER_LIVE_MAX_USD="one dollar" "$BASH_ABS" "$PRE" --budget 2>&1); RCB=$?
if [ "$RCB" != 0 ]; then ok "L11c-budget-mode-refuses-an-unparseable-ceiling"
else bad "L11c-budget-mode-refuses-an-unparseable-ceiling" "rc=$RCB budget=[$B]"; fi

echo
if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "bin-live-preflight-selftest: ARM COUNT $arms, expected $EXPECT_ARMS — an arm was skipped or added"
  exit 1
fi
if [ "$fails" = 0 ]; then echo "bin-live-preflight-selftest: $arms/$arms passed (expected $EXPECT_ARMS arms)"; exit 0
else echo "bin-live-preflight-selftest: $fails of $arms arms FAILED"; exit 1; fi
