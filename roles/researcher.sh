#!/usr/bin/env bash
# researcher.sh — answers ONE question about the tool, from the tool, and writes the answer
# where the worker will read it.
#
#   researcher.sh <toyrepo> <outfile>
#
# The question: where does this tool's version string have to come from? The answer is not
# invented here -- it is read out of the tool itself, so if the toy repo changes, the brief
# changes with it. A role that answers from memory is a role that goes stale silently, and
# in 2b this same script is replaced by a model that must be held to the same standard.
set -uo pipefail
repo=${1:?usage: researcher.sh <toyrepo> <outfile>}
out=${2:?usage: researcher.sh <toyrepo> <outfile>}
tool="$repo/tool.sh"
[ -f "$tool" ] || { echo "researcher: no tool at $tool" >&2; exit 2; }

# The declared version lives in exactly one place. Finding it is the research.
line=$(grep -n '^VERSION=' "$tool") || true
if [ -n "$line" ]; then
  echo "researcher: the tool already declares a version at $tool:${line%%:*}" > "$out"
else
  cat > "$out" <<'BRIEF'
researcher: the tool declares NO version anywhere. A --version flag therefore needs two
things, not one: a version value to print, and a branch that prints it. A flag added
without the value prints an empty line and still exits 0, which looks like success.
BRIEF
fi
cat "$out"
