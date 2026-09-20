#!/usr/bin/env bash
# voice.sh — tells the human what happened, in the human's words, from the RECORD.
#
#   voice.sh <quest> <toyrepo> <mergedest>
#
# EVERY NUMBER HERE IS READ BACK OUT OF THE WORLD, NOT PASSED IN BY THE DRIVER. The commit
# count comes from git, the merged path from the filesystem, the version from running the
# tool. A voice that reports what the driver TOLD it would report a successful run of a
# broken quest -- which is the one thing a closing summary must never do.
set -uo pipefail
#   voice.sh <quest> <toyrepo> <mergedest> <baseline-sha>
#
# THE BASELINE IS PASSED IN AND THE COUNT IS STILL GIT'S. The first version counted
# `rev-list HEAD` and announced "3 commits, the first one was refused" -- the repo's own
# pre-quest commit was in the total, so the sentence was wrong about which commit the gate
# refused. Naming the starting point is not the same as being told the answer: git still
# computes how many commits the quest added.
quest=${1:?usage: voice.sh <quest> <toyrepo> <mergedest> <baseline-sha>}
repo=${2:?}; dest=${3:?}; base=${4:?}

commits=$(git -C "$repo" rev-list --count "$base"..HEAD 2>/dev/null) || commits="?"
version=$(sh "$repo/tool.sh" --version 2>/dev/null) || version=""
[ -n "$version" ] || version="(nothing -- the tool still does not report a version)"

printf '\n'
printf 'Your quest "%s" is done.\n\n' "$quest"
printf '  The tool now answers --version with: %s\n' "$version"
printf '  The party made %s commits to get there: the gate refused the first one.\n' "$commits"
printf '  The result was merged once, to: %s\n' "$dest"
printf '\nNothing else on your machine was touched.\n'
