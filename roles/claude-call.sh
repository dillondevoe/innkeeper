#!/usr/bin/env bash
# claude-call.sh — THE ONE PLACE A MODEL CALL IS MADE, AND THE ONLY PLACE MONEY IS SPENT.
#
# Sourced, not run:  . "$(dirname "$0")/claude-call.sh"
# Then:              claude_call <prompt-file> <workdir>   -> stdout is the model's text
#
# Three duties, and they are here together on purpose:
#
#   1. THE PREFLIGHT RUNS AT THE SPEND SITE, NOT ONLY AT THE TOP OF THE QUEST.
#      bin/live-party.sh calls the preflight before it starts, which is right and is not
#      enough: roles/claude-worker.sh is an executable a person can run directly, and a
#      gate that only guards the front door is advisory for every other door. So the
#      refusal lives here, where the charge is, and the top-level call becomes the early
#      warning rather than the control.
#
#   2. THE COST IS EXTRACTED FROM THE CALL THAT INCURRED IT. `--output-format json` returns
#      `total_cost_usd` for that invocation. We read it there and append it to the ledger
#      immediately. A cost totalled later from a log, or estimated from token counts, is a
#      reconstruction; this is the number the CLI itself reported for the call we made.
#
#   3. ONE LINE PER CALL, NAMING THE ROLE. A single total for a quest cannot say which role
#      spent it, and "the worker is expensive" is the first question anyone asks.
#
# WHAT THIS DOES NOT DO: it does not judge the model's output. The gate is roles/gate.sh and
# stays a script for the whole of 2b -- a model does not get to grade a model in the demo.
set -uo pipefail

_cc_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

claude_call() {
  local promptfile=${1:?claude_call <promptfile> <workdir>}
  local workdir=${2:?claude_call <promptfile> <workdir>}
  local role=${INNKEEPER_ROLE:-unknown}

  [ -f "$promptfile" ] || { echo "claude-call: no prompt at $promptfile" >&2; return 2; }

  # (1) refuse here, at the charge.
  local pre
  pre=$("$_cc_here/../bin/live-preflight.sh" 2>&1) || {
    echo "claude-call: the preflight REFUSED, so no model call was made and nothing was spent." >&2
    echo "$pre" >&2
    return 1
  }

  # (1b) THE CEILING GOVERNS HERE, BECAUSE THIS IS WHERE THE MONEY MOVES.
  # The preflight resolves and validates the number and is gone before anything is spent.
  # Until this block existed, nothing compared spend to it: the first live run cost $0.9569
  # against a $1.00 ceiling and the gate reported that ceiling as `ok` the whole way. The
  # number is read back from --budget rather than respelled here, so the two halves cannot
  # drift apart.
  #
  # IT REFUSES TO START A CALL, WHICH IS NOT THE SAME AS CAPPING ONE. A call's cost is known
  # only once it returns, so the last call admitted can carry the total past the ceiling.
  # That residual is stated in the refusal text rather than left for someone to discover
  # from a bill, and it is why the ceiling wants headroom, not precision.
  local ceiling spent
  ceiling=$("$_cc_here/../bin/live-preflight.sh" --budget) || {
    echo "claude-call: the budget ceiling does not resolve, so nothing may be spent." >&2
    return 1
  }
  # A BROKEN METER STOPS THE QUEST, BECAUSE A CEILING OVER AN UNKNOWN TOTAL IS NOT A
  # CEILING. If any earlier call recorded UNKNOWN, the running total is a LOWER BOUND, and
  # comparing a lower bound against a ceiling admits calls whose true total may already be
  # past it -- the enforcer under-counts, silently, in the direction that spends. There is
  # no arithmetic fix: the number is genuinely not known. So the quest stops here and says
  # why. (Note that summing UNKNOWN as 0 and skipping it give the SAME total, which is what
  # makes this a stopping condition rather than a parsing one.)
  if [ -n "${INNKEEPER_LEDGER:-}" ] && [ -f "${INNKEEPER_LEDGER}" ] \
     && awk -F'\t' '$3 == "UNKNOWN" {found=1} END {exit !found}' "$INNKEEPER_LEDGER"; then
    echo "claude-call: REFUSED. An earlier call in this quest reported no cost, so the" >&2
    echo "claude-call: running total is a LOWER BOUND and the ceiling cannot govern it." >&2
    echo "claude-call: A ceiling compared against an under-count admits calls it should" >&2
    echo "claude-call: refuse, so this quest stops rather than spending past a limit it" >&2
    echo "claude-call: can no longer measure." >&2
    return 1
  fi

  if [ -n "${INNKEEPER_LEDGER:-}" ] && [ -f "${INNKEEPER_LEDGER}" ]; then
    spent=$(awk -F'\t' '$3 ~ /^[0-9.]+$/ {t+=$3} END {printf "%.6f", t+0}' "$INNKEEPER_LEDGER")
    if awk -v s="$spent" -v c="$ceiling" 'BEGIN{exit !(s+0 >= c+0)}'; then
      echo "claude-call: REFUSED. This quest has already spent \$$spent against a ceiling of" >&2
      echo "claude-call: \$$ceiling, so no further call may START. (A call already in flight" >&2
      echo "claude-call: cannot be capped -- its cost is only known once it returns, so the" >&2
      echo "claude-call: total may sit slightly above the ceiling rather than exactly on it.)" >&2
      echo "claude-call: Raise INNKEEPER_LIVE_MAX_USD if this is the cost you meant to pay." >&2
      return 1
    fi
  fi

  local bin=${INNKEEPER_CLAUDE:-claude}
  local raw rc
  raw=$("$bin" -p \
        --output-format json \
        --max-turns "${INNKEEPER_MAX_TURNS:-12}" \
        --permission-mode acceptEdits \
        --allowedTools "Read,Edit,Write,Glob,Grep" \
        --add-dir "$workdir" \
        < "$promptfile" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "claude-call: the CLI exited $rc. It may or may not have spent -- the ledger records" >&2
    echo "claude-call: only what the CLI reported, and a failed call reports nothing." >&2
    echo "$raw" >&2
    return "$rc"
  fi

  # (2)+(3) the cost, from this call, with the role, now.
  #
  # jq is not assumed to exist. python3 is already a hard dependency of nothing here, so
  # parse with either and REFUSE if neither -- a cost we cannot read is not a cost of zero,
  # and silently writing 0 would make an unmetered run look like a free one.
  local text cost
  if command -v jq >/dev/null 2>&1; then
    text=$(printf '%s' "$raw" | jq -r '.result // empty')
    cost=$(printf '%s' "$raw" | jq -r '.total_cost_usd // empty')
  elif command -v python3 >/dev/null 2>&1; then
    text=$(printf '%s' "$raw" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",""))')
    cost=$(printf '%s' "$raw" | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d.get("total_cost_usd"); print("" if c is None else c)')
  else
    echo "claude-call: neither jq nor python3 is here, so the call's cost cannot be read." >&2
    echo "claude-call: refusing to record 0 -- an unread cost is not a zero cost." >&2
    return 2
  fi

  if [ -z "$cost" ]; then
    echo "claude-call: the CLI returned no total_cost_usd for this call. Recording it as" >&2
    echo "claude-call: UNKNOWN rather than as 0, so the quest total says so." >&2
    cost=UNKNOWN
  fi

  if [ -n "${INNKEEPER_LEDGER:-}" ]; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$role" "$cost" >> "$INNKEEPER_LEDGER"
  fi

  printf '%s\n' "$text"
}
