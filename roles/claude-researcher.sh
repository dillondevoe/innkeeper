#!/usr/bin/env bash
# claude-researcher.sh — roles/researcher.sh's live twin. SAME CLI, SAME OUTPUT CONTRACT.
#
#   claude-researcher.sh <toyrepo> <outfile>
#
# The scripted researcher answers one question about the tool BY READING THE TOOL, and its
# header says a model replacing it "must be held to the same standard." That standard is
# what this file has to carry across: the brief is not allowed to be invented. So the model
# is given the repo and told to answer from the file, and the check below is structural --
# a brief that does not mention the tool by path did not read it.
set -uo pipefail
repo=${1:?usage: claude-researcher.sh <toyrepo> <outfile>}
out=${2:?usage: claude-researcher.sh <toyrepo> <outfile>}
tool="$repo/tool.sh"
[ -f "$tool" ] || { echo "claude-researcher: no tool at $tool" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
. "$here/claude-call.sh"

prompt=$(mktemp) || exit 2
trap 'rm -f "$prompt"' EXIT
cat > "$prompt" <<PROMPT
Read the shell script at $tool.

Answer exactly one question, in at most four lines of plain text: if this tool were to grow
a --version flag, where would the version string it prints have to come from?

Answer from the file you just read, not from what such tools usually do. Name the path, and
name the line number if the value already exists. Do not edit anything. Do not add the flag.
PROMPT

INNKEEPER_ROLE=researcher claude_call "$prompt" "$repo" > "$out" || {
  echo "claude-researcher: the call failed; no brief was written." >&2
  exit 1
}

# Structural check, not a grade. This asks whether the brief is ABOUT the tool at hand --
# something a filename can answer -- and deliberately does not ask whether the answer is
# correct, because that is the gate's job and the gate is a script.
if ! grep -q 'tool\.sh' "$out"; then
  echo "claude-researcher: the brief never names $tool, so it is not an answer about this" >&2
  echo "claude-researcher: tool. Refusing to hand it to the worker." >&2
  cat "$out" >&2
  exit 1
fi
cat "$out"
