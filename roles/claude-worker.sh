#!/usr/bin/env bash
# claude-worker.sh — roles/worker.sh's live twin. SAME CLI, SAME OUTPUT CONTRACT.
#
#   claude-worker.sh <toyrepo> first
#   claude-worker.sh <toyrepo> fix <reasonfile>
#
# THE SCRIPTED WORKER IS WRONG ON ATTEMPT 1 ON PURPOSE. THIS ONE IS NOT, AND MUST NOT BE.
# The scripted quest exists to demonstrate the refusal and the reason-driven repair, and it
# does that deterministically. If this file nudged a real model toward the same mistake so
# the live run would "show the same thing", the demonstration would be a reenactment -- the
# exact fake that hello-party.sh's D1/D2 control arms exist to prevent. So attempt 1 here is
# the honest task, stated plainly, and the model is very likely to get it right first time.
#
# What the live run therefore claims is NARROWER, and bin/live-party.sh says so out loud:
# the loop is CLOSED (the gate's verdict governs, and if it refuses, the repair is driven by
# the reason text), and the run reports which path it took. It never requires a refusal.
#
# `fix` is the path that carries the real weight, because it is the one where the model is
# given the gate's words and nothing else to go on.
set -uo pipefail
repo=${1:?usage: claude-worker.sh <toyrepo> <first|fix> [reasonfile]}
step=${2:?usage: claude-worker.sh <toyrepo> <first|fix> [reasonfile]}
tool="$repo/tool.sh"
[ -f "$tool" ] || { echo "claude-worker: no tool at $tool" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
. "$here/claude-call.sh"

prompt=$(mktemp) || exit 2
trap 'rm -f "$prompt"' EXIT

case "$step" in
first)
  brief=${3:-}
  { cat <<PROMPT
Edit the shell script at $tool so that running \`sh $tool --version\` prints the tool's
version and exits 0. Change nothing else about what the tool does.

Edit the file in place. Do not create a new file, do not run git, do not commit.
PROMPT
    [ -n "$brief" ] && [ -f "$brief" ] && { echo; echo "A researcher on your party left you this brief:"; echo; cat "$brief"; }
  } > "$prompt"
  msg="add a --version flag"
  ;;
fix)
  reason=${3:?usage: claude-worker.sh <toyrepo> fix <reasonfile>}
  [ -f "$reason" ] || { echo "claude-worker: no reason file at $reason -- refusing to guess" >&2; exit 2; }
  # THE REASON IS THE WHOLE INPUT. The model is not told what the bug is, is not told what
  # the repair is, and is not told the gate's implementation. It is told what the gate SAID.
  # That is the property the live run is here to test: does the loop close on the reason, or
  # does it close because a human already knew the answer and wrote it into the prompt?
  cat > "$prompt" <<PROMPT
Your change to $tool was submitted to the party's gate and the gate REFUSED it. These are
the gate's words, in full:

$(cat "$reason")

Read $tool, work out from the refusal above what is wrong, and fix it. Edit the file in
place. Do not create a new file, do not run git, do not commit.
PROMPT
  msg="repair after the gate refused"
  ;;
*) echo "claude-worker: unknown step [$step]" >&2; exit 2 ;;
esac

before=$(git -C "$repo" rev-parse HEAD)
INNKEEPER_ROLE=worker claude_call "$prompt" "$repo" >/dev/null || {
  echo "claude-worker: the call failed; the repo was not touched by me." >&2
  exit 1
}

# A MODEL THAT EDITED NOTHING MUST NOT PRODUCE A COMMIT-SHAPED RESULT. `git commit` on a
# clean tree exits non-zero, so without this the failure would surface as "worker: git
# commit failed" -- a git problem, which is the wrong diagnosis entirely and the one that
# sends the next reader into git instead of into the transcript.
if git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet; then
  echo "claude-worker: the model made NO EDIT. There is nothing to submit to the gate." >&2
  exit 1
fi

git -C "$repo" add -A >/dev/null || { echo "claude-worker: git add failed" >&2; exit 2; }
git -C "$repo" commit -q -m "$msg" >/dev/null || { echo "claude-worker: git commit failed" >&2; exit 2; }
after=$(git -C "$repo" rev-parse --short HEAD)
[ "$(git -C "$repo" rev-parse HEAD)" != "$before" ] || { echo "claude-worker: HEAD did not move" >&2; exit 2; }
echo "$after"
