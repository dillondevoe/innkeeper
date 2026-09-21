#!/usr/bin/env bash
# live-preflight.sh — MAY THIS MACHINE RUN THE QUEST WITH A REAL MODEL, AND AT WHOSE EXPENSE?
#
#   bin/live-preflight.sh          report; rc 0 = the live run may proceed
#   bin/live-preflight.sh --selftest
#
#   rc 0 CLEAR    every condition met; the live run may proceed
#   rc 1 REFUSED  a condition is not met, and the line says which and how to meet it
#   rc 2 usage
#
# WHY THIS EXISTS. `bin/hello-party.sh` calls no model, touches no network and costs
# nothing, so a stranger can run it by reflex and a suite can run it in a loop. The live
# run is the opposite of all three: it SPENDS THE OPERATOR'S MONEY on somebody else's
# account, silently, in an amount nobody has told them yet. Everything in this repo is
# organised around the plausible mistake not rendering as a pass; here the plausible
# mistake is a battery, a suite, a CI job or a curious reader reaching a live run by
# running everything in `bin/`, and the cost arriving on a bill weeks later.
#
# SO THE DEFAULT IS REFUSAL AND THE OPT-IN IS EXACT. `INNKEEPER_LIVE` must be the single
# character `1`. Not `true`, not `yes`, not any non-empty string -- a loose predicate is
# how a variable exported for something else, or left in a shell from an hour ago, turns
# into an unattended charge. A conservative reading costs one word to correct; the other
# direction is not correctable at all once it has run.
#
# AND THIS FILE MUST NOT SPEND ANYTHING TO DO ITS JOB. The obvious way to check that the
# model is reachable and authorised is to ask it something small. That makes the gate on
# spending a thing that spends -- and worse, it spends BEFORE the opt-in has been read, on
# every invocation, including the ones whose whole purpose is to answer "no". So this file
# verifies only that the binary EXISTS and is EXECUTABLE, and says out loud that it cannot
# verify authorisation without a call. That is a STATED limit; the version of this check
# that silently confirms auth by spending is the unstated one. Selftest arm L6 runs a stub
# that records every execution and asserts the count is ZERO, so the limit is armed rather
# than promised.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)

case "${1:-}" in
  --selftest) exec bash "$REPO/tests/bin-live-preflight-selftest.sh";;
  "") ;;
  *) sed -n '2,8p' "$0"; exit 2;;
esac

rc=0
refuse() { printf 'REFUSED %s\n' "$1"; printf '   FIX: %s\n' "$2"; rc=1; }
ok()     { printf 'ok      %s\n' "$1"; }

# ---------------------------------------------------------------- the opt-in
# Read FIRST, and reported first, because it is the only condition whose absence is not a
# fault: a machine that has not opted in is a machine behaving correctly.
if [ "${INNKEEPER_LIVE:-}" = "1" ]; then
  ok "opt-in: INNKEEPER_LIVE=1 -- this run may spend money on your account"
else
  refuse "no opt-in. The live run calls a real model and bills a real account." \
          "export INNKEEPER_LIVE=1 for the shell you run it in. It is deliberately not a
        flag: a flag is something a script can pass for you."
fi

# ---------------------------------------------------------------- the binary
# INNKEEPER_CLAUDE first, because the CLI is commonly installed somewhere that is on an
# interactive PATH and not on the PATH a script inherits -- which is the difference between
# "not installed" and "I could not find it", and they have different fixes.
CLAUDE=${INNKEEPER_CLAUDE:-}
if [ -z "$CLAUDE" ]; then CLAUDE=$(command -v claude 2>/dev/null) || CLAUDE=""; fi
if [ -z "$CLAUDE" ]; then
  refuse "no model CLI found on PATH and INNKEEPER_CLAUDE is unset." \
          "install the CLI, or point INNKEEPER_CLAUDE at it. An interactive shell finding
        it proves nothing about the PATH a script inherits."
elif [ ! -f "$CLAUDE" ]; then
  refuse "INNKEEPER_CLAUDE points at something that is not a file: $CLAUDE" \
          "point it at the CLI itself, not at a directory or a dangling link."
elif [ ! -x "$CLAUDE" ]; then
  refuse "the model CLI is not executable: $CLAUDE" \
          "chmod +x it, or point INNKEEPER_CLAUDE at the real binary."
else
  ok "model CLI: $CLAUDE"
fi

# ---------------------------------------------------------------- the budget
# A CEILING THAT IS NOT A NUMBER IS NOT A CEILING. An unparseable value here must refuse
# rather than fall back to the default: silently substituting the default for a typo'd
# ceiling is how a run intended to be capped at a cent gets the dollar.
# `${VAR-default}`, NOT `${VAR:-default}`. UNSET means "I did not choose a ceiling" and
# takes the default; SET AND EMPTY means a choice was made and came out blank, which is
# what a failed command substitution leaves behind. Collapsing those two into one is the
# silent substitution this block refuses two lines above.
BUDGET=${INNKEEPER_LIVE_MAX_USD-1.00}
case "$BUDGET" in
  ''|*[!0-9.]*|*.*.*|.|'.'*[!0-9]*)
    refuse "INNKEEPER_LIVE_MAX_USD is not a number: [$BUDGET]" \
            "give it a plain decimal (e.g. 1.00), or unset it to take the 1.00 default." ;;
  *) ok "budget ceiling: \$$BUDGET (INNKEEPER_LIVE_MAX_USD)" ;;
esac

# ---------------------------------------------------------------- the work repo needs git
command -v git >/dev/null 2>&1 \
  && ok "git present -- the quest works on a real repo" \
  || refuse "git is not installed." "install git; the quest commits to a real repository."

# ---------------------------------------------------------------- the stated limit
printf '\n'
printf 'NOT CHECKED (and not checkable here): whether that CLI is AUTHORISED.\n'
printf '   The only way to find out is to call the model, which is the spend this gate\n'
printf '   exists to authorise. An unauthorised CLI therefore fails in the live run, not\n'
printf '   here, and it fails before the first commit.\n'

if [ "$rc" = 0 ]; then printf '\nCLEAR -- the live run may proceed.\n'
else printf '\nREFUSED -- the live run must not start. Nothing has been spent.\n'; fi
exit $rc
