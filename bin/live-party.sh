#!/usr/bin/env bash
# live-party.sh — THE SAME QUEST, WITH REAL MODEL CALLS. This is 2b.
#
#   bin/live-party.sh            run it in a fresh sandbox
#   bin/live-party.sh --keep     leave the sandbox on disk for inspection
#
# Same quest, same toy repo, same gate script as bin/hello-party.sh. The difference is the
# worker and the researcher: there they are shell scripts, here they are model calls.
#
# THE GATE STAYS THE SCRIPT. A model does not get to grade a model in the demo. If the judge
# and the judged are the same kind of thing, a passing run tells you the two agreed, which is
# not the claim anyone wants. roles/gate.sh runs the tool and reads what it printed.
#
# THIS RUN'S CLAIM IS NARROWER THAN THE SCRIPTED RUN'S, AND THAT IS DELIBERATE.
# hello-party.sh asserts a REFUSAL happens, because its attempt 1 is wrong on purpose and
# its D1/D2 control arms make that wrongness load-bearing. A real model asked to add a
# --version flag will most likely do it correctly the first time. Two ways to react:
#
#   (a) engineer a first attempt that fails -- and manufacture the refusal the scripted run
#       already proves honestly. That is a reenactment, and D1/D2 exist precisely to stop
#       the scripted run from becoming one. Doing it here would be worse, not better.
#   (b) claim less. This run asserts that THE LOOP IS CLOSED: the gate's verdict governs,
#       a refusal is followed by a repair driven by the REASON TEXT AND NOTHING ELSE, and a
#       pass is accepted as a pass. Then it REPORTS WHICH PATH IT TOOK.
#
# (b). So a first-time pass is a legitimate outcome of this script and never a FATAL, and
# the path taken is printed at the end where nobody has to infer it from the step numbers.
# The deterministic proof of the refusal path remains bin/hello-party.sh, which costs
# nothing and runs on every machine.
#
# NOTHING HERE DECIDES WHETHER SPENDING IS ALLOWED. bin/live-preflight.sh does, and it is
# called twice over: once below, so a refusal arrives before any setup, and again inside
# roles/claude-call.sh at each charge, so running a role directly is gated too.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$REPO/bus/actor.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

say "0. The gate on spending"
"$HERE/live-preflight.sh" | sed 's/^/   /' || {
  echo "   (nothing was spent, and no sandbox was made)" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "this quest works on a real git repo and git is not installed"

# ${TMPDIR%/} -- macOS exports TMPDIR WITH a trailing slash, so the unstripped form prints
# paths like /var/folders/.../T//live-party.xxxx. Harmless, and it is the first thing a
# stranger sees.
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}"/live-party.XXXXXX) || die "cannot make a sandbox"
SANDBOX=${SANDBOX%/}
[ "$KEEP" = 1 ] || trap 'rm -rf "$SANDBOX"' EXIT
export INNKEEPER_BUS="$SANDBOX/bus"
export INNKEEPER_HOME="$SANDBOX"
export INNKEEPER_PARTY="${INNKEEPER_PARTY:-$REPO/party.yaml}"
export INNKEEPER_QUESTS="$SANDBOX/quests"
export INNKEEPER_LEDGER="$SANDBOX/ledger.tsv"
mkdir -p "$INNKEEPER_BUS/comms" "$INNKEEPER_BUS/queues" "$SANDBOX/state" "$SANDBOX/quests"
: > "$INNKEEPER_LEDGER"

LANES=$(bash "$ACTOR" lanes) || die "actor.sh refused to name the lanes"
[ -n "$LANES" ] || die "the roster names no lanes -- nobody can take this quest"
role_lane() { local b; for b in $LANES; do
    [ "$(bash "$ACTOR" field "$b" role 2>/dev/null)" = "$1" ] && { echo "$b"; return 0; }
  done; return 1; }
W=$(role_lane worker)     || die "the roster has no worker -- nobody can do the work"
G=$(role_lane gate)       || die "the roster has no gate -- nothing would be checked"
R=$(role_lane researcher) || die "the roster has no researcher"

say "1. A tool that needs a version flag"
TOY="$SANDBOX/work"; mkdir -p "$TOY"
cat > "$TOY/tool.sh" <<'TOOL'
#!/bin/sh
# greet -- a very small tool.
# ---ARGS---
echo "hello, tavern"
TOOL
git -C "$TOY" init -q || die "could not init the work repo"
git -C "$TOY" config user.email quest@innkeeper.local
git -C "$TOY" config user.name  "The Party"
# Signing off inside the sandbox repo only -- see the long note in bin/hello-party.sh. A
# demo must not hand a stranger's signing key a commit it made in a temp directory.
git -C "$TOY" config commit.gpgsign false
git -C "$TOY" config tag.gpgsign false
git -C "$TOY" add -A >/dev/null && git -C "$TOY" commit -q -m "the tool, before the quest" \
  || die "could not make the first commit"
BASE=$(git -C "$TOY" rev-parse HEAD) || die "could not read the baseline commit"
note "work repo: $TOY"
note "and --version:   [$(sh "$TOY/tool.sh" --version 2>/dev/null)]  <- it ignores the flag entirely. That is the job."

say "2. The quest is posted, and a worker claims it under a lease"
QUEST=version-flag-live
bash "$REPO/bus/quest.sh" new "$QUEST" \
  --title "Add a --version flag to the tool and tell me when it is merged" \
  --brief "The tool ignores every argument. Give it a --version flag that prints a real version number, and tell me when it is merged." \
  --origin "bin/live-party.sh" >/dev/null || die "quest.sh refused to open the quest"
LEASE="$REPO/lifecycle/lease.sh"
claim=$(PARTY_BRAIN=$W bash "$LEASE" claim 2>&1) || die "the worker could not take a lease: $claim"
case "$claim" in CLAIMED*) ;; *) die "expected a fresh lease, got: $claim";; esac
note "lease: $claim"
bash "$REPO/bus/quest.sh" claim "$QUEST" "$W" >/dev/null || die "quest.sh refused the claim"

say "3. The researcher reads the tool and briefs the worker -- A MODEL CALL"
BRIEF="$SANDBOX/brief.txt"
bash "$REPO/roles/claude-researcher.sh" "$TOY" "$BRIEF" | sed 's/^/   /' || die "the researcher failed"

say "4. The worker does the work -- attempt 1 -- A MODEL CALL"
sha1=$(bash "$REPO/roles/claude-worker.sh" "$TOY" first "$BRIEF") || die "the worker could not make attempt 1"
note "commit $sha1: $(git -C "$TOY" log -1 --format=%s)"
note "the tool now answers --version: [$(sh "$TOY/tool.sh" --version 2>/dev/null)]"

say "5. The gate checks it -- THE GATE IS THE SCRIPT, and it RUNS the tool"
REASON="$SANDBOX/refusal.txt"
PATH_TAKEN=
if bash "$REPO/roles/gate.sh" "$TOY" > "$REASON" 2>&1; then
  sed 's/^/   /' "$REASON"
  grep -q '^PASS ' "$REASON" || die "the gate exited 0 without saying PASS"
  PATH_TAKEN="PASSED-FIRST-TIME"
  sha2=$sha1
  note "-> PASSED on attempt 1. Not a failure of this run: see the header. The refusal"
  note "   path is demonstrated deterministically by bin/hello-party.sh."
else
  sed 's/^/   /' "$REASON"
  grep -q '^NO ' "$REASON" || die "the gate refused without saying NO -- a refusal nobody can read"
  note "-> REFUSED."

  say "6. The worker is given the REFUSAL AND NOTHING ELSE, and repairs it -- A MODEL CALL"
  sha2=$(bash "$REPO/roles/claude-worker.sh" "$TOY" fix "$REASON") || die "the worker could not repair it"
  [ "$sha2" != "$sha1" ] || die "attempt 2 produced no new commit"
  note "commit $sha2: $(git -C "$TOY" log -1 --format=%s)"

  say "7. The gate checks again"
  PASSOUT="$SANDBOX/pass.txt"
  bash "$REPO/roles/gate.sh" "$TOY" > "$PASSOUT" 2>&1 || { sed 's/^/   /' "$PASSOUT"; die "the gate refused the repair too"; }
  sed 's/^/   /' "$PASSOUT"
  grep -q '^PASS ' "$PASSOUT" || die "the gate exited 0 without saying PASS"
  PATH_TAKEN="REFUSED-THEN-REPAIRED"
fi

say "8. The result merges -- exactly once"
att=$(bash "$REPO/bus/merge.sh" begin "$QUEST" "$W") || die "merge.sh refused to stage an attempt"
dir=${att#ATTEMPT }
[ -d "$dir" ] || die "merge.sh named a staging dir that does not exist: $dir"
{ echo "quest: $QUEST"; echo "commit: $sha2"; echo "version: $(sh "$TOY/tool.sh" --version)"; } > "$dir/result.txt"
m1=$(bash "$REPO/bus/merge.sh" commit "$QUEST" "$W" "$dir/result.txt") || die "the merge refused"
case "$m1" in MERGED*) note "$m1";; *) die "expected MERGED, got: $m1";; esac
att2=$(bash "$REPO/bus/merge.sh" begin "$QUEST" "$G") || die "merge.sh refused a second staging"
dir2=${att2#ATTEMPT }
cp "$dir/result.txt" "$dir2/result.txt" 2>/dev/null || echo x > "$dir2/result.txt"
m2=$(bash "$REPO/bus/merge.sh" commit "$QUEST" "$G" "$dir2/result.txt") || true
case "$m2" in ALREADY-MERGED*) note "a second merge is refused: $m2";;
  *) die "the result merged TWICE: $m2";; esac
DEST=$(bash "$REPO/bus/merge.sh" dest "$QUEST")

say "9. The quest closes, and the voice tells you"
bash "$REPO/bus/quest.sh" state "$QUEST" done >/dev/null || die "quest.sh refused to close the quest"
PARTY_BRAIN=$W bash "$LEASE" release >/dev/null 2>&1 || true
bash "$REPO/roles/voice.sh" "$QUEST" "$TOY" "$DEST" "$BASE" || die "the voice failed"

say "10. What it cost"
bash "$HERE/live-cost.sh" "$INNKEEPER_LEDGER" | sed 's/^/   /'

say "PATH TAKEN: $PATH_TAKEN"
note "the claim this run makes: the loop is closed -- the gate's verdict governed, and a"
note "refusal (if there was one) was repaired from the reason text alone."
[ "$KEEP" = 1 ] && echo "sandbox kept at $SANDBOX" || echo "(sandbox removed; --keep to inspect it)"
