#!/usr/bin/env bash
# gate.sh — runs the acceptance check and says YES or NO, with a reason a worker can act on.
#
#   gate.sh <toyrepo>     -> "PASS" | "NO <reason>"   (rc 0 pass, rc 1 refuse, rc 2 cannot run)
#
# THE CHECK IS A REAL EXECUTION OF THE TOOL, NOT AN INSPECTION OF ITS SOURCE. Grepping for
# the string `--version` would pass the first attempt below, which adds the flag and prints
# NOTHING -- the exact defect this gate exists to catch. A gate that reads the diff instead
# of running the artifact is checking that the work was ATTEMPTED, not that it works.
#
# AND THE EXIT CODE IS NOT THE CHECK. `tool.sh --version` exits 0 while printing an empty
# line, because a shell function that prints nothing still succeeds. This is the fail-open
# shape the whole repo is organised around: the plausible mistake must not render as a pass.
# So the gate asserts on the OUTPUT, and says which of the two it got.
set -uo pipefail
repo=${1:?usage: gate.sh <toyrepo>}
tool="$repo/tool.sh"
[ -f "$tool" ] || { echo "NO the tool is missing at $tool -- nothing to check"; exit 2; }

out=$(sh "$tool" --version 2>/dev/null); rc=$?

if [ "$rc" -ne 0 ]; then
  echo "NO \`tool.sh --version\` exited $rc. The flag is not recognised at all."
  exit 1
fi
if [ -z "$out" ]; then
  echo "NO \`tool.sh --version\` exited 0 but printed NOTHING. The flag is wired up and has"
  echo "   no value to print, so it succeeds while telling the user nothing. Give it a"
  echo "   version string and print that."
  exit 1
fi
case "$out" in
  *[0-9].[0-9]*) echo "PASS \`tool.sh --version\` prints: $out" ;;
  *) echo "NO \`tool.sh --version\` printed [$out], which carries no version number."; exit 1 ;;
esac
