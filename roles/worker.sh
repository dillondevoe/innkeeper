#!/usr/bin/env bash
# worker.sh — does the work, once per attempt, as a real commit in a real repo.
#
#   worker.sh <toyrepo> first   add the --version flag (attempt 1)
#   worker.sh <toyrepo> fix <reasonfile>   read the gate's reason and repair (attempt 2)
#
# ATTEMPT 1 IS WRONG ON PURPOSE, AND IT IS WRONG THE WAY REAL WORK IS WRONG. It adds the
# flag, the branch, and the exit -- everything a diff reviewer looks for -- and prints an
# unset variable. `echo "$VERSION"` with VERSION unset prints an empty line and exits 0, so
# the tool reports success and says nothing. Nobody has to pretend to make this mistake.
#
# ATTEMPT 2 READS THE GATE'S REASON. It does not simply apply a known-good patch: the
# branch it takes is selected by what the reason SAYS, so a gate that refuses for a
# different cause sends the worker somewhere else. In 2b a model reads this same text.
set -uo pipefail
repo=${1:?usage: worker.sh <toyrepo> <first|fix> [reasonfile]}
step=${2:?usage: worker.sh <toyrepo> <first|fix> [reasonfile]}
tool="$repo/tool.sh"
[ -f "$tool" ] || { echo "worker: no tool at $tool" >&2; exit 2; }

commit() { # commit <message>
  git -C "$repo" add -A >/dev/null || { echo "worker: git add failed" >&2; exit 2; }
  git -C "$repo" commit -q -m "$1" >/dev/null || { echo "worker: git commit failed" >&2; exit 2; }
  git -C "$repo" rev-parse --short HEAD
}

case "$step" in
first)
  # The flag, the branch, the exit -- and no value. This is attempt 1.
  awk '/^# ---ARGS---$/ {
         print "case \"${1:-}\" in"
         print "  --version) echo \"$VERSION\"; exit 0 ;;"
         print "esac"
         next
       } { print }' "$tool" > "$tool.new" || { echo "worker: could not edit the tool" >&2; exit 2; }
  [ -s "$tool.new" ] || { echo "worker: the edited tool came out EMPTY -- refusing to install it" >&2; exit 2; }
  mv -f "$tool.new" "$tool"
  commit "add a --version flag"
  ;;
fix)
  reason=${3:?usage: worker.sh <toyrepo> fix <reasonfile>}
  [ -f "$reason" ] || { echo "worker: no reason file at $reason -- refusing to guess" >&2; exit 2; }
  # THE BRANCH IS CHOSEN BY THE REASON. A worker that ignores the refusal and applies its
  # favourite patch would pass this run and teach nothing about whether the loop closes.
  if grep -q 'no value to print' "$reason"; then
    printf '%s\n' "$(sed '1i\
VERSION=0.1.0' "$tool")" > "$tool.new" || { echo "worker: could not edit the tool" >&2; exit 2; }
    [ -s "$tool.new" ] || { echo "worker: the edited tool came out EMPTY -- refusing to install it" >&2; exit 2; }
    mv -f "$tool.new" "$tool"
    commit "give --version a version to print (gate refused: it printed nothing)"
  else
    echo "worker: the gate refused for a reason I have no repair for:" >&2
    cat "$reason" >&2
    exit 1
  fi
  ;;
*) echo "worker: unknown step [$step]" >&2; exit 2 ;;
esac
