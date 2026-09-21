#!/usr/bin/env bash
# roles-voice-selftest.sh — the closing summary must not tell the human a story.
#
# roles/voice.sh's own header promises that every number it prints is read back out of the
# world. For a long time the WORDS beside one of those numbers were not: the clause "the
# gate refused the first one" was hard-coded, true of bin/hello-party.sh (where attempt 1 is
# wrong on purpose) and false of any run where the gate passed first time. The first live
# run was exactly that, and the voice announced "1 commits to get there: the gate refused
# the first one" to a human who had just watched it pass.
#
# THE TWO ARMS ARE A PAIR AND NEITHER MEANS ANYTHING ALONE. V1 asserts the one-commit run
# does NOT claim a refusal; V2 asserts the two-commit run STILL DOES. Without V2, a voice
# that simply deleted the clause would pass V1 and lose the demo's whole point.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}"/voice.XXXXXX); TMP=${TMP%/}
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; ARMS=0
ok()  { ARMS=$((ARMS+1)); PASS=$((PASS+1)); printf '  %s — PASS\n' "$1"; }
bad() { ARMS=$((ARMS+1)); FAIL=$((FAIL+1)); printf '  %s — FAIL :: %s\n' "$1" "$2"; }
EXPECT_ARMS=3

mkrepo() { # mkrepo <dir> <n-quest-commits> -> prints the baseline sha
  local d=$1 n=$2 i
  mkdir -p "$d"
  printf '#!/bin/sh\nVERSION=1.2.3\ncase "${1:-}" in --version) echo "$VERSION"; exit 0;; esac\necho hi\n' > "$d/tool.sh"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.local; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false; git -C "$d" config tag.gpgsign false
  git -C "$d" add -A >/dev/null; git -C "$d" commit -q -m base >/dev/null
  git -C "$d" rev-parse HEAD > "$d/.base"
  for i in $(seq 1 "$n"); do
    echo "# $i" >> "$d/tool.sh"
    git -C "$d" add -A >/dev/null; git -C "$d" commit -q -m "attempt $i" >/dev/null
  done
  cat "$d/.base"
}

echo "roles-voice-selftest: the closing summary reads the world, including the adjectives"

# --- V1: one commit means the gate did not refuse anything -------------------------------
D="$TMP/v1"; B=$(mkrepo "$D" 1)
OUT=$(bash "$REPO/roles/voice.sh" q "$D" /dev/null "$B" 2>&1)
if grep -q 'passed it first time' <<<"$OUT" && ! grep -q 'refused the first one' <<<"$OUT"; then
  ok "V1-one-commit-does-not-claim-a-refusal"
else bad "V1-one-commit-does-not-claim-a-refusal" "out=[$OUT]"; fi

# --- V2: two commits DO mean the gate refused the first -- the clause must survive --------
D="$TMP/v2"; B=$(mkrepo "$D" 2)
OUT=$(bash "$REPO/roles/voice.sh" q "$D" /dev/null "$B" 2>&1)
if grep -q 'refused the first one' <<<"$OUT" && grep -q 'made 2 commits' <<<"$OUT"; then
  ok "V2-two-commits-still-report-the-refusal"
else bad "V2-two-commits-still-report-the-refusal" "out=[$OUT]"; fi

# --- V3: a count git cannot produce must not be narrated either --------------------------
# `?` is what the count falls back to when rev-list fails. A caption chosen by a case
# statement has a default branch, and the default branch is where a confident sentence
# about an unknown quantity would live.
D="$TMP/v3"; mkdir -p "$D"
printf '#!/bin/sh\necho hi\n' > "$D/tool.sh"
OUT=$(bash "$REPO/roles/voice.sh" q "$D" /dev/null deadbeef 2>&1)
if grep -q 'cannot be read' <<<"$OUT" && ! grep -q 'refused the first one' <<<"$OUT" \
   && ! grep -q 'passed it first time' <<<"$OUT"; then
  ok "V3-an-unreadable-count-gets-no-story"
else bad "V3-an-unreadable-count-gets-no-story" "out=[$OUT]"; fi

echo
if [ "$ARMS" -ne "$EXPECT_ARMS" ]; then
  echo "roles-voice-selftest: ARM COUNT $ARMS, expected $EXPECT_ARMS — an arm was skipped or added"
  exit 1
fi
echo "roles-voice-selftest: $PASS/$ARMS passed (expected $EXPECT_ARMS arms)"
[ "$FAIL" -eq 0 ] || exit 1
