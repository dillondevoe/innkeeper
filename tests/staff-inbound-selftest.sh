#!/usr/bin/env bash
# staff-inbound-selftest.sh — battery for staff/inbound.sh
#
# The thing under test is a READER, so almost every arm is an assertion about which TIER a
# file lands in — not whether it was seen. "It appeared somewhere in the output" is the
# vacuous version of every check below, and it would stay green if all three tiers collapsed
# into one, which is the specific defect this tool exists to prevent. Every arm names its tier.
#
# And the tool's own empty-body control gets a control: an arm that BREAKS the sweep and
# asserts the output says NOT A READING. A self-check nobody has ever seen fail is a claim.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
IN="$REPO/staff/inbound.sh"

EXPECT_ARMS=25
fails=0; arms=0
ok()  { arms=$((arms+1)); echo "  $1 — PASS"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); echo "  $1 — FAIL${2:+ :: $2}"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/comms/_done"
export INNKEEPER_HOME="$W" INNKEEPER_PARTY="$W/party.yaml" INNKEEPER_COMMS="$W/comms"
cat > "$W/party.yaml" <<'YAML'
party:
  name: Test Party
  bus: BUSDIR
brains:
  - { name: rabbot, role: voice,  recycle_after: 12 }
  - { name: geist,  role: gate,   recycle_after: 6 }
  - { name: page,   role: worker, recycle_after: 8 }
addressees: [teague]
aliases:
  - { from: cleric, to: rabbot }
YAML
sed -i "s|BUSDIR|$W|" "$W/party.yaml"

C="$W/comms"
mk() { # mk <basename> <to-line> [cc-line]
  { echo "---"; echo "from: geist"; echo "$2"; [ $# -ge 3 ] && echo "$3"; echo "---"; echo "body"; } > "$C/$1"
}
run() { PARTY_BRAIN="${2:-rabbot}" bash "$IN" "${1:-}" 2>&1; }
# tier_of <output> <basename> -> the tier heading the name appeared under, or NONE.
tier_of() {
  awk -v n="$2" '
    /^=== TIER /   { t=$3 }
    /^--- act:/    { t="" }
    index($0, n) && t != "" && $0 !~ /^=== / { print t; found=1; exit }
    END { if (!found) print "NONE" }' <<< "$1"
}
echo "staff-inbound-selftest:"

# ---- A. the three tiers must be THREE, and each arm names which one ---------------------
mk "geist-to-rabbot-P2-routable-2026-09-20.md"  "to: [rabbot]"
mk "notes-body-addressed-2026-09-20.md"          "to: [rabbot]"
mk "geist-to-page-P2-cc-me-2026-09-20.md"        "to: [page]" "cc: [rabbot]"
out=$(run)
[ "$(tier_of "$out" P2-routable)"     = 1  ] && ok "A1 a routable filename is TIER 1"    || bad "A1 a routable filename is TIER 1" "$(tier_of "$out" P2-routable)"
[ "$(tier_of "$out" body-addressed)"  = 2  ] && ok "A2 body-only addressing is TIER 2"   || bad "A2 body-only addressing is TIER 2" "$(tier_of "$out" body-addressed)"
[ "$(tier_of "$out" cc-me)"           = 3  ] && ok "A3 cc-only is TIER 3"                || bad "A3 cc-only is TIER 3" "$(tier_of "$out" cc-me)"
# A4 CONTROL: the tier parser must be able to say NONE. Without it, a tier_of that returned
# its first argument for anything would make A1-A3 pass on a wholly broken reader.
[ "$(tier_of "$out" definitely-not-present-anywhere)" = NONE ] \
  && ok "A4 CONTROL: tier_of reports NONE for an absent name" || bad "A4 CONTROL: tier_of never says NONE"
# A5: and the three tiers are DISTINCT files. If the reader collapsed them, A1-A3 could still
# pass by listing every comm under every heading.
# Count ONLY the indented listing lines. The first cut grepped the whole output for
# "routable", which is a substring of UNROUTABLE in the tier-2 heading and of "unroutable:"
# in the summary — it counted 5 for three files. A grep for a literal also matches the tool's
# own prose ABOUT that literal, and headings are where such prose lives.
c1=$(grep -E '^  [a-z]' <<< "$out" | grep -c 'P2-routable\|body-addressed\|cc-me')
[ "$c1" = 3 ] && ok "A5 each comm appears exactly ONCE across all tiers" || bad "A5 comms appear $c1 times, expected 3"

# ---- B. the execute/notify width split — the whole thesis ------------------------------
# B1/B2 are the pair. Same brain, same body address, DIFFERENT filename: one dispatches and
# one cannot. If the reader used one width for both, exactly one of these two arms breaks.
[ "$(tier_of "$out" P2-routable)" != "$(tier_of "$out" body-addressed)" ] \
  && ok "B1 identical body addressing, different tiers (widths are not shared)" \
  || bad "B1 the two widths collapsed into one"
# B2 PERMITTING TWIN for the tier-2 warning: tier 2 empty must NOT print the sender warning.
mkdir -p "$W/quiet/_done"; printf -- '---\nfrom: geist\nto: [rabbot]\n---\nb\n' > "$W/quiet/geist-to-rabbot-P2-only-2026-09-20.md"
qout=$(run "$W/quiet")
case "$qout" in *"TIER 2 NON-EMPTY"*) bad "B2 TWIN: no tier-2 hits means no sender warning" "$qout";;
  *) ok "B2 TWIN: no tier-2 hits means no sender warning";; esac
case "$out" in *"TIER 2 NON-EMPTY"*) ok "B3 a tier-2 hit DOES print the sender warning";;
  *) bad "B3 a tier-2 hit DOES print the sender warning" "$out";; esac

# ---- C. self-echo, disposal, aliases ---------------------------------------------------
mk "rabbot-to-geist-P2-my-own-outbound-2026-09-20.md" "to: [geist]"
out=$(run)
[ "$(tier_of "$out" my-own-outbound)" = NONE ] && ok "C1 my own outbound is not an arrival" \
  || bad "C1 my own outbound listed as inbound" "$(tier_of "$out" my-own-outbound)"
# C2 PERMITTING TWIN: the SAME name from another sender must still arrive. Without this, C1
# passes for a reader that drops every comm mentioning my name.
mk "geist-to-rabbot-P2-not-my-own-outbound-2026-09-20.md" "to: [rabbot]"
out=$(run)
[ "$(tier_of "$out" not-my-own-outbound)" = 1 ] && ok "C2 TWIN: the same shape from another sender arrives" \
  || bad "C2 TWIN: a real arrival was swallowed by the self-echo guard"
: > "$C/_done/geist-to-rabbot-P2-routable-2026-09-20.md"
out=$(run)
[ "$(tier_of "$out" P2-routable)" = NONE ] && ok "C3 a disposed comm drops out of tier 1" \
  || bad "C3 disposal ignored"
# C4: an ALIAS in the body `to:` still addresses me. A raw string compare would miss it.
mk "notes-alias-addressed-2026-09-20.md" "to: cleric"
out=$(run)
[ "$(tier_of "$out" alias-addressed)" = 2 ] && ok "C4 an alias in body to: is tier 2, not invisible" \
  || bad "C4 alias not resolved" "$(tier_of "$out" alias-addressed)"
# C5 CONTROL for C4: a name that is NOT mine must not match. Otherwise C4 passes on a
# reader that treats every to: line as addressing everyone.
mk "notes-addressed-to-teague-2026-09-20.md" "to: teague"
out=$(run)
[ "$(tier_of "$out" addressed-to-teague)" = NONE ] && ok "C5 CONTROL: another brain's name does not address me" \
  || bad "C5 CONTROL: reader matches any to: line" "$(tier_of "$out" addressed-to-teague)"
# C6: a parenthetical cc is a cc, not an address -> tier 3, never tier 2.
mk "notes-paren-cc-2026-09-20.md" "to: page (cc: rabbot — for awareness)"
out=$(run)
[ "$(tier_of "$out" paren-cc)" = 3 ] && ok "C6 a parenthetical cc reads as cc (tier 3)" \
  || bad "C6 parenthetical cc misread" "$(tier_of "$out" paren-cc)"

# ---- D. the empty-body sweep AND its control ------------------------------------------
: > "$C/geist-to-rabbot-P2-zero-bytes-2026-09-20.md"
out=$(run)
case "$out" in *"0 BYTES"*zero-bytes*) ok "D1 a 0-byte comm is annotated in tier 1";;
  *) bad "D1 a 0-byte comm is annotated in tier 1" "$out";; esac
case "$out" in *"empty-body:1 (control:ok)"*) ok "D2 the sweep counts it and its control fired";;
  *) bad "D2 sweep count/control" "$(grep -- '--- act:' <<< "$out")";; esac
case "$out" in *"do NOT dispose"*) ok "D3 the annotation says do NOT dispose";;
  *) bad "D3 the annotation says do NOT dispose";; esac
# D4 — THE CONTROL'S CONTROL. Break the sweep and assert the tool says NOT A READING rather
# than printing a clean zero. A self-check that has never been seen to fail is a claim, and
# `empty-body: 0` is byte-identical whether the sweep worked or never ran.
brk="$REPO/staff/.inbound-mutant-$$.sh"
trap 'rm -rf "$W"; rm -f "$brk"' EXIT
sed 's|-size 0 2>/dev/null|-size 0 -name "NOTHING-MATCHES-THIS" 2>/dev/null|' "$IN" > "$brk"
bout=$(PARTY_BRAIN=rabbot bash "$brk" 2>&1); rm -f "$brk"
# The mutant must have REACHED the sweep. Without this, a mutant that died at an earlier guard
# would satisfy D4 by printing nothing at all, and D4 would certify a control it never ran.
case "$bout" in *"--- act:"*) ok "D4a the mutant reached the summary line (it did not die early)";;
  *) bad "D4a the mutant died before the sweep — D4/D5 would be vacuous" "$bout";; esac
case "$bout" in *"CONTROL DID NOT FIRE"*) ok "D4 CONTROL^2: a broken sweep reports NOT A READING";;
  *) bad "D4 CONTROL^2: broken sweep printed a clean count" "$(grep -- '--- act:' <<< "$bout")";; esac
case "$bout" in *"empty-body:0"*) ok "D5 ...and the broken sweep's count really was 0 (so 0 alone proves nothing)";;
  *) bad "D5 broken sweep count" "$(grep -- '--- act:' <<< "$bout")";; esac

# ---- E. copy-marks, and refusals that name themselves ----------------------------------
printf 'not a stub\n' > "$C/_done/geist-to-rabbot-P2-not-my-own-outbound-2026-09-20.md"
out=$(run)
case "$out" in *"COPY-MARKS (1)"*) ok "E1 a non-empty _done twin with root present is a copy-mark";;
  *) bad "E1 copy-mark not detected" "$(grep -- '--- act:' <<< "$out")";; esac
rm -f "$C/_done/geist-to-rabbot-P2-not-my-own-outbound-2026-09-20.md"
out=$(run)
case "$out" in *"COPY-MARKS"*) bad "E2 TWIN: a zero-byte stub is NOT a copy-mark" "$out";;
  *) ok "E2 TWIN: a zero-byte stub is NOT a copy-mark";; esac
# E3/E4: the two fatal refusals must each name THEMSELVES, not merely return 1.
e=$(PARTY_BRAIN= bash "$IN" 2>&1); case "$e" in *PARTY_BRAIN*) ok "E3 no brain names PARTY_BRAIN";; *) bad "E3 no brain names PARTY_BRAIN" "$e";; esac
e=$(run "$W/no-such-dir"); case "$e" in *"comms dir not found"*) ok "E4 a missing comms dir says so";; *) bad "E4 missing dir" "$e";; esac
# E5: a trailing slash must not silently empty every basename.
out=$(run "$C/")
[ "$(tier_of "$out" not-my-own-outbound)" = 1 ] && ok "E5 a trailing slash does not erase tier 1" \
  || bad "E5 trailing slash broke basename expansion"

if [ "$arms" -ne "$EXPECT_ARMS" ]; then
  echo "ARM COUNT: ran $arms, expected $EXPECT_ARMS — an arm was skipped or added."
  fails=$((fails+1))
fi
echo "staff-inbound-selftest: $((arms-fails))/$arms passed (expected $EXPECT_ARMS arms)"
exit $((fails ? 1 : 0))
