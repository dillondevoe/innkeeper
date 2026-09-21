#!/usr/bin/env bash
# hello-party.sh — ONE QUEST, END TO END, WATCHED. This is the product.
#
#   bin/hello-party.sh            run the quest in a fresh sandbox
#   bin/hello-party.sh --keep     leave the sandbox on disk for inspection
#
# A stranger runs this and watches a party of four take a real job and finish it: a quest is
# posted; a worker claims it under a lease; it produces a change; the GATE REFUSES IT ONCE,
# with a reason; the worker reads the reason and fixes it; the gate passes; the result merges
# exactly once; the voice tells the human. No model is called, nothing leaves the machine,
# and everything happens inside a sandbox this script creates and removes.
#
# WHY THE REFUSAL IS THE POINT. A demo where the work is right the first time proves only
# that a happy path exists. The interesting claim -- the one that makes this a party and not
# a script -- is that a wrong answer is CAUGHT and REPAIRED without a human in the loop. So
# attempt 1 is wrong the way real work is wrong (see roles/worker.sh: it adds the flag and
# forgets the value, so the tool exits 0 and prints an empty line), and the gate runs the
# tool rather than reading its source, which is the only way to catch that.
#
# THE FAILURE OF THIS SCRIPT MUST NOT LOOK LIKE ITS SUCCESS. Its predecessor (now bin/smoke.sh)
# printed a clean-looking party when a missing `tac` silently emptied the roster. So every step
# below asserts its own outcome and exits non-zero, and the two that matter most -- the gate's
# NO and the gate's later PASS -- are asserted to have HAPPENED, not merely to have been called.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ACTOR="$REPO/bus/actor.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

command -v git >/dev/null 2>&1 || { echo "FATAL: this quest works on a real git repo and git is not installed" >&2; exit 2; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}"/hello-party.XXXXXX) || { echo "cannot make a sandbox" >&2; exit 2; }
SANDBOX=${SANDBOX%/}
[ "$KEEP" = 1 ] || trap 'rm -rf "$SANDBOX"' EXIT
export INNKEEPER_BUS="$SANDBOX/bus"
export INNKEEPER_HOME="$SANDBOX"
export INNKEEPER_PARTY="${INNKEEPER_PARTY:-$REPO/party.yaml}"
export INNKEEPER_QUESTS="$SANDBOX/quests"
mkdir -p "$INNKEEPER_BUS/comms" "$INNKEEPER_BUS/queues" "$SANDBOX/state" "$SANDBOX/quests"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# Names come from the roster, positionally. Nothing here types a party member's name --
# party.yaml promises nothing keys on those strings, and bin/ is scanned for address grammar.
LANES=$(bash "$ACTOR" lanes) || die "actor.sh refused to name the lanes"
[ -n "$LANES" ] || die "the roster names no lanes -- nobody can take this quest"
lane_of() { bash "$ACTOR" list lanes 2>/dev/null | grep -x -- "$1" >/dev/null && echo "$1"; }
role_lane() { # role_lane <role> -> the lane whose ROLE field is this
  local b; for b in $LANES; do
    [ "$(bash "$ACTOR" field "$b" role 2>/dev/null)" = "$1" ] && { echo "$b"; return 0; }
  done; return 1
}
W=$(role_lane worker)     || die "the roster has no worker -- nobody can do the work"
G=$(role_lane gate)       || die "the roster has no gate -- nothing would be checked"
V=$(role_lane voice)      || die "the roster has no voice -- nobody would tell you"
R=$(role_lane researcher) || die "the roster has no researcher"

# ---------------------------------------------------------------- the work repo
say "0. A tool that needs a version flag"
TOY="$SANDBOX/work"; mkdir -p "$TOY"
cat > "$TOY/tool.sh" <<'TOOL'
#!/bin/sh
# greet -- a very small tool.
# ---ARGS---
echo "hello, tavern"
TOOL
git -C "$TOY" init -q                          || die "could not init the work repo"
git -C "$TOY" config user.email quest@innkeeper.local
git -C "$TOY" config user.name  "The Party"
# COMMIT SIGNING IS TURNED OFF *IN THIS SANDBOX REPO*, AND IT IS NOT A CONVENIENCE.
# A fresh `git init` inherits the user's GLOBAL config, so on a machine with
# `commit.gpgsign = true` the party's very first commit goes out to a signing agent --
# and on the first Mac this ran on it died there ("No SSH private key found", rc 1) before
# the quest had done anything at all. A demo that asks a stranger's signing key to
# authorise commits it made in a temp directory is wrong even when it works. These are
# repo-local settings inside the sandbox; the user's own git config is never read for
# identity here and never written anywhere.
git -C "$TOY" config commit.gpgsign false
git -C "$TOY" config tag.gpgsign false
git -C "$TOY" add -A >/dev/null && git -C "$TOY" commit -q -m "the tool, before the quest" \
  || die "could not make the first commit"
BASE=$(git -C "$TOY" rev-parse HEAD) || die "could not read the baseline commit"
note "work repo: $TOY  (a real git repo, inside the sandbox)"
note "today it answers: $(sh "$TOY/tool.sh")"
# The line below used to say "<- nothing", and the run printed `[hello, tavern]` right
# beside it: the tool has no argument handling at all, so it greets you whatever you ask
# it. A caption that contradicts the output two characters to its left is the same defect
# class as a gate that reads the diff -- it describes the work instead of reading it.
note "and --version:   [$(sh "$TOY/tool.sh" --version 2>/dev/null)]  <- it ignores the flag entirely. That is the job."

# ---------------------------------------------------------------- the quest
say "1. The quest is posted"
QUEST=version-flag
bash "$REPO/bus/quest.sh" new "$QUEST" \
  --title "Add a --version flag to the tool and tell me when it is merged" \
  --brief "The tool ignores every argument. Give it a --version flag that prints a real version number, and tell me when it is merged." \
  --origin "bin/hello-party.sh" >/dev/null || die "quest.sh refused to open the quest"
note "$QUEST: state=$(bash "$REPO/bus/quest.sh" field "$QUEST" state)"

say "2. A worker claims it -- under a lease, so a second one would stand down"
LEASE="$REPO/lifecycle/lease.sh"
claim=$(PARTY_BRAIN=$W bash "$LEASE" claim 2>&1) || die "the worker could not take a lease: $claim"
case "$claim" in CLAIMED*) ;; *) die "expected a fresh lease, got: $claim";; esac
note "lease: $claim"
# THE SECOND CLAIMANT IS A SECOND INSTANCE OF THE SAME WORKER, NOT A DIFFERENT ROLE.
# This step first asked the gate to claim and asserted it would be refused -- and it was
# NOT, correctly: the lease is per-BRAIN lifecycle state, so every lane holds its own and
# two different lanes claiming is exactly right. The run said so immediately. What the
# lease actually prevents is the split brain -- the same seat running twice, which is the
# failure the murder quest is built around.
second=$(PARTY_BRAIN=$W bash "$LEASE" claim 2>&1) || true
case "$second" in HELD-BY-OTHER*) note "a second instance of the same worker stands down: $second";;
  *) die "the lease let a SECOND instance of one worker in: $second";; esac
bash "$REPO/bus/quest.sh" claim "$QUEST" "$W" >/dev/null || die "quest.sh refused the claim"
note "$QUEST: state=$(bash "$REPO/bus/quest.sh" field "$QUEST" state) lane=$(bash "$REPO/bus/quest.sh" field "$QUEST" lane)"

say "3. The researcher reads the tool and briefs the worker"
BRIEF="$SANDBOX/brief.txt"
bash "$REPO/roles/researcher.sh" "$TOY" "$BRIEF" | sed 's/^/   /' || die "the researcher failed"

say "4. The worker does the work -- attempt 1"
sha1=$(bash "$REPO/roles/worker.sh" "$TOY" first) || die "the worker could not make attempt 1"
note "commit $sha1: $(git -C "$TOY" log -1 --format=%s)"

say "5. The gate checks it -- by RUNNING the tool, not by reading the diff"
REASON="$SANDBOX/refusal.txt"
if bash "$REPO/roles/gate.sh" "$TOY" > "$REASON" 2>&1; then
  cat "$REASON"
  die "the gate PASSED attempt 1. It was supposed to be caught: the flag prints nothing."
fi
sed 's/^/   /' "$REASON"
grep -q '^NO ' "$REASON" || die "the gate refused without saying NO -- a refusal nobody can read"
note "-> REFUSED. This is the step the whole quest exists to show."

say "6. The worker reads the refusal and fixes it -- attempt 2"
sha2=$(bash "$REPO/roles/worker.sh" "$TOY" fix "$REASON") || die "the worker could not repair it"
[ "$sha2" != "$sha1" ] || die "attempt 2 produced no new commit"
note "commit $sha2: $(git -C "$TOY" log -1 --format=%s)"

say "7. The gate checks again"
PASSOUT="$SANDBOX/pass.txt"
bash "$REPO/roles/gate.sh" "$TOY" > "$PASSOUT" 2>&1 || { sed 's/^/   /' "$PASSOUT"; die "the gate refused the repair too"; }
sed 's/^/   /' "$PASSOUT"
grep -q '^PASS ' "$PASSOUT" || die "the gate exited 0 without saying PASS"

say "8. The result merges -- exactly once"
att=$(bash "$REPO/bus/merge.sh" begin "$QUEST" "$W") || die "merge.sh refused to stage an attempt"
dir=${att#ATTEMPT }
[ -d "$dir" ] || die "merge.sh named a staging dir that does not exist: $dir"
{ echo "quest: $QUEST"; echo "commit: $sha2"; echo "version: $(sh "$TOY/tool.sh" --version)"; } > "$dir/result.txt"
m1=$(bash "$REPO/bus/merge.sh" commit "$QUEST" "$W" "$dir/result.txt") || die "the merge refused"
note "$m1"
case "$m1" in MERGED*) ;; *) die "expected MERGED, got: $m1";; esac
# The exactly-once claim is ASSERTED, not assumed: a second commit must be refused.
att2=$(bash "$REPO/bus/merge.sh" begin "$QUEST" "$G") || die "merge.sh refused a second staging"
dir2=${att2#ATTEMPT }
cp "$dir/result.txt" "$dir2/result.txt" 2>/dev/null || echo x > "$dir2/result.txt"
m2=$(bash "$REPO/bus/merge.sh" commit "$QUEST" "$G" "$dir2/result.txt") || true
case "$m2" in ALREADY-MERGED*) note "a second merge is refused: $m2";;
  *) die "the result merged TWICE: $m2";; esac
DEST=$(bash "$REPO/bus/merge.sh" dest "$QUEST")

say "9. The quest closes"
bash "$REPO/bus/quest.sh" state "$QUEST" done >/dev/null || die "quest.sh refused to close the quest"
note "$QUEST: state=$(bash "$REPO/bus/quest.sh" field "$QUEST" state)"
PARTY_BRAIN=$W bash "$LEASE" release >/dev/null 2>&1 || true

say "10. The voice tells you"
bash "$REPO/roles/voice.sh" "$QUEST" "$TOY" "$DEST" "$BASE" || die "the voice failed"

[ "$KEEP" = 1 ] && echo "sandbox kept at $SANDBOX" || echo "(sandbox removed; --keep to inspect it)"
