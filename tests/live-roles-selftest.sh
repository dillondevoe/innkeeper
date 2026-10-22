#!/usr/bin/env bash
# live-roles-selftest.sh — the battery for 2b's live half.
#
# IT MAKES NO MODEL CALL AND SPENDS NOTHING. Every arm points INNKEEPER_CLAUDE at a stub
# that reads the prompt on stdin and prints the same JSON shape the real CLI prints. That is
# not a convenience: a battery that calls the real CLI would charge the operator every time
# anyone ran the suite, and -- worse -- it would pass identically whether the code worked or
# not on a machine where the binary happened to be absent, because "no binary" and "refused"
# would both be non-zero. The stub makes the charge path OBSERVABLE instead: it records
# every invocation, so an arm can assert a call did NOT happen.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}"/live-roles.XXXXXX); TMP=${TMP%/}
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; ARMS=0
ok()  { ARMS=$((ARMS+1)); PASS=$((PASS+1)); printf '  %s — PASS\n' "$1"; }
bad() { ARMS=$((ARMS+1)); FAIL=$((FAIL+1)); printf '  %s — FAIL :: %s\n' "$1" "$2"; }
EXPECT_ARMS=18

# --- the stub CLI -----------------------------------------------------------------------
# $STUB_MODE picks the behaviour; $STUB_CALLS records that it ran at all.
mkstub() {
  cat > "$TMP/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
[ -n "${STUB_CALLS:-}" ] && echo "called" >> "$STUB_CALLS"
tool=$(printf '%s' "$prompt" | grep -o '/[^ ]*/tool\.sh' | head -1)
case "${STUB_MODE:-edit}" in
  edit)     awk 'NR==1{print; print "VERSION=9.9.9"; next} {print}' "$tool" > "$tool.n" && mv -f "$tool.n" "$tool"
            printf '{"result":"added a version","total_cost_usd":0.0125}\n' ;;
  noedit)   printf '{"result":"I chose not to change anything","total_cost_usd":0.0125}\n' ;;
  nocost)   awk 'NR==1{print; print "VERSION=9.9.9"; next} {print}' "$tool" > "$tool.n" && mv -f "$tool.n" "$tool"
            printf '{"result":"added a version"}\n' ;;
  brief)    printf '{"result":"the tool at %s declares no version","total_cost_usd":0.002}\n' "$tool" ;;
  offtopic) printf '{"result":"some other program entirely","total_cost_usd":0.002}\n' ;;
  boom)     echo "the CLI fell over" >&2; exit 3 ;;
esac
STUB
  chmod +x "$TMP/claude"
}
mkstub

mktoy() { # mktoy <dir>
  local d=$1; mkdir -p "$d"
  printf '#!/bin/sh\n# greet\n# ---ARGS---\necho hello\n' > "$d/tool.sh"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.local; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false; git -C "$d" config tag.gpgsign false
  git -C "$d" add -A >/dev/null; git -C "$d" commit -q -m base >/dev/null
}

BASEENV=(INNKEEPER_LIVE=1 "INNKEEPER_CLAUDE=$TMP/claude")

echo "live-roles-selftest: the live half of 2b, with no live call"

# --- C1: the preflight refuses AT THE SPEND SITE, and the call never happens -------------
# This is the load-bearing arm of the whole file. bin/live-party.sh calls the preflight up
# front, but roles/claude-worker.sh is directly executable, so the front-door check cannot
# be the control. C1 runs the ROLE with opt-in absent and asserts the stub was never
# invoked -- the gate is shown to be at the charge, not merely ahead of it.
T="$TMP/c1"; mktoy "$T"
CALLS="$TMP/c1.calls"
OUT=$(env INNKEEPER_LIVE= "INNKEEPER_CLAUDE=$TMP/claude" "STUB_CALLS=$CALLS" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$CALLS" ]; then ok "C1-no-opt-in-means-the-role-never-calls-the-CLI"
else bad "C1-no-opt-in-means-the-role-never-calls-the-CLI" "rc=$RC calls=$([ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0)"; fi

# --- C1b: THE SUBSTRATE ARM for C1 -------------------------------------------------------
# C1 asserts an ABSENCE, and an absence assertion passes for free if the recorder never
# works. C1b runs the same role fully armed and asserts the SAME recorder DOES fill up. If
# C1b ever fails, C1's pass means nothing.
T="$TMP/c1b"; mktoy "$T"
CALLS="$TMP/c1b.calls"
OUT=$(env "${BASEENV[@]}" "STUB_CALLS=$CALLS" "INNKEEPER_LEDGER=$TMP/c1b.tsv" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -f "$CALLS" ] && [ -s "$CALLS" ]; then ok "C1b-the-recorder-does-record-a-real-call"
else bad "C1b-the-recorder-does-record-a-real-call" "rc=$RC out=[$OUT]"; fi

# --- C2: one call, one ledger line, naming the role and the cost -------------------------
LED="$TMP/c2.tsv"; T="$TMP/c2"; mktoy "$T"
env "${BASEENV[@]}" "INNKEEPER_LEDGER=$LED" bash "$REPO/roles/claude-worker.sh" "$T" first >/dev/null 2>&1
# `wc -l` PADS on macOS ("       1"), so a bare string compare is RED on every Mac with a
# perfectly correct ledger. `tr -d ' '` is this tree's idiom for it already — every other count
# comparison in tests/ and bin/ has it; this line was the one that drifted.
# Counted into a variable rather than inline: `wc ... | tr ... || echo 0` would hang the `||` on
# TR's status, not wc's, so a missing ledger would yield "" and the fallback would be dead code.
C2N=$(wc -l < "$LED" 2>/dev/null | tr -d ' ')
if [ "${C2N:-0}" = 1 ] && grep -q $'\tworker\t0.0125$' "$LED"; then
  ok "C2-one-call-writes-one-ledger-line-with-role-and-cost"
else bad "C2-one-call-writes-one-ledger-line-with-role-and-cost" "ledger=[$(cat "$LED" 2>/dev/null)]"; fi

# --- C3: a cost the CLI did not report is UNKNOWN, never 0 -------------------------------
LED="$TMP/c3.tsv"; T="$TMP/c3"; mktoy "$T"
env "${BASEENV[@]}" STUB_MODE=nocost "INNKEEPER_LEDGER=$LED" bash "$REPO/roles/claude-worker.sh" "$T" first >/dev/null 2>&1
if grep -q $'\tworker\tUNKNOWN$' "$LED" 2>/dev/null; then ok "C3-an-unread-cost-is-UNKNOWN-not-zero"
else bad "C3-an-unread-cost-is-UNKNOWN-not-zero" "ledger=[$(cat "$LED" 2>/dev/null)]"; fi

# --- C4: the total, and the rule that produced it, in the output -------------------------
printf '2026-01-01T00:00:00Z\tworker\t0.0300\n2026-01-01T00:00:01Z\tresearcher\t0.0200\n' > "$TMP/c4.tsv"
OUT=$(bash "$REPO/bin/live-cost.sh" "$TMP/c4.tsv" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && grep -q '\$0\.0500' <<<"$OUT" && grep -q 'EXTRACTION RULE' <<<"$OUT" \
   && grep -q '2 model call' <<<"$OUT"; then ok "C4-the-total-ships-with-its-extraction-rule"
else bad "C4-the-total-ships-with-its-extraction-rule" "rc=$RC out=[$OUT]"; fi

# --- C5: any UNKNOWN makes the figure a stated LOWER BOUND -------------------------------
printf '2026-01-01T00:00:00Z\tworker\t0.0300\n2026-01-01T00:00:01Z\tworker\tUNKNOWN\n' > "$TMP/c5.tsv"
OUT=$(bash "$REPO/bin/live-cost.sh" "$TMP/c5.tsv" 2>&1)
if grep -q 'at least \$0\.0300' <<<"$OUT" && grep -q 'LOWER BOUND' <<<"$OUT"; then
  ok "C5-an-UNKNOWN-makes-the-total-a-stated-lower-bound"
else bad "C5-an-UNKNOWN-makes-the-total-a-stated-lower-bound" "out=[$OUT]"; fi

# --- C6: an empty ledger is a DEFECT, not a free quest -----------------------------------
: > "$TMP/c6.tsv"
OUT=$(bash "$REPO/bin/live-cost.sh" "$TMP/c6.tsv" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -qi 'defect' <<<"$OUT"; then ok "C6-an-empty-ledger-is-a-defect-not-a-bargain"
else bad "C6-an-empty-ledger-is-a-defect-not-a-bargain" "rc=$RC out=[$OUT]"; fi

# --- C7: a malformed ledger line is refused, not skipped ---------------------------------
# Skipping it would silently UNDERSTATE the cost, which is the direction that flatters.
printf '2026-01-01T00:00:00Z\tworker\t0.03\nnonsense\n' > "$TMP/c7.tsv"
OUT=$(bash "$REPO/bin/live-cost.sh" "$TMP/c7.tsv" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'REFUSING' <<<"$OUT"; then ok "C7-a-malformed-ledger-line-is-refused-not-skipped"
else bad "C7-a-malformed-ledger-line-is-refused-not-skipped" "rc=$RC out=[$OUT]"; fi

# --- C8: a CLI that fails is not a commit ------------------------------------------------
T="$TMP/c8"; mktoy "$T"; H=$(git -C "$T" rev-parse HEAD)
OUT=$(env "${BASEENV[@]}" STUB_MODE=boom "INNKEEPER_LEDGER=$TMP/c8.tsv" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && [ "$(git -C "$T" rev-parse HEAD)" = "$H" ]; then ok "C8-a-failed-call-moves-no-HEAD"
else bad "C8-a-failed-call-moves-no-HEAD" "rc=$RC head-moved=$([ "$(git -C "$T" rev-parse HEAD)" != "$H" ] && echo yes)"; fi

# --- W1: a model that edited nothing is named as such ------------------------------------
# Without the explicit check this surfaces as "git commit failed", which sends the next
# reader into git instead of into the transcript. The arm asserts the WORDING, because the
# wording is the whole of the fix.
T="$TMP/w1"; mktoy "$T"; H=$(git -C "$T" rev-parse HEAD)
OUT=$(env "${BASEENV[@]}" STUB_MODE=noedit "INNKEEPER_LEDGER=$TMP/w1.tsv" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'NO EDIT' <<<"$OUT" && ! grep -q 'git commit failed' <<<"$OUT" \
   && [ "$(git -C "$T" rev-parse HEAD)" = "$H" ]; then ok "W1-no-edit-is-reported-as-no-edit-not-as-a-git-error"
else bad "W1-no-edit-is-reported-as-no-edit-not-as-a-git-error" "rc=$RC out=[$OUT]"; fi

# --- W2: the fix step refuses without a reason file --------------------------------------
# The whole claim of the repair step is that the REASON drives it. A fix that runs with no
# reason present would be the model applying its favourite patch, which proves nothing.
T="$TMP/w2"; mktoy "$T"
CALLS="$TMP/w2.calls"
OUT=$(env "${BASEENV[@]}" "STUB_CALLS=$CALLS" bash "$REPO/roles/claude-worker.sh" "$T" fix "$TMP/nope.txt" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'refusing to guess' <<<"$OUT" && [ ! -f "$CALLS" ]; then
  ok "W2-fix-without-a-reason-refuses-before-spending"
else bad "W2-fix-without-a-reason-refuses-before-spending" "rc=$RC out=[$OUT]"; fi

# --- R1: a brief that is not about this tool is refused ----------------------------------
T="$TMP/r1"; mktoy "$T"
OUT=$(env "${BASEENV[@]}" STUB_MODE=offtopic "INNKEEPER_LEDGER=$TMP/r1.tsv" \
      bash "$REPO/roles/claude-researcher.sh" "$T" "$TMP/r1.brief" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'never names' <<<"$OUT"; then ok "R1-a-brief-that-never-names-the-tool-is-refused"
else bad "R1-a-brief-that-never-names-the-tool-is-refused" "rc=$RC out=[$OUT]"; fi

# --- R1b: THE PERMITTING TWIN. R1 must not be passing because everything is refused. -----
T="$TMP/r1b"; mktoy "$T"
OUT=$(env "${BASEENV[@]}" STUB_MODE=brief "INNKEEPER_LEDGER=$TMP/r1b.tsv" \
      bash "$REPO/roles/claude-researcher.sh" "$T" "$TMP/r1b.brief" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -s "$TMP/r1b.brief" ] && grep -q 'tool\.sh' "$TMP/r1b.brief"; then
  ok "R1b-a-brief-about-this-tool-is-accepted"
else bad "R1b-a-brief-about-this-tool-is-accepted" "rc=$RC out=[$OUT]"; fi

# --- C9: the ceiling GOVERNS -- a call does not start once the ledger has reached it ------
# The pair C9/C9b is the discriminating one. C9 alone could pass because the role refuses
# everything; C9b runs the IDENTICAL ledger under a ceiling the spend has not reached and
# asserts the call DOES happen. Only the two together say the ceiling is what decided.
T="$TMP/c9"; mktoy "$T"; LED="$TMP/c9.tsv"; CALLS="$TMP/c9.calls"
printf '2026-01-01T00:00:00Z\tworker\t1.00\n' > "$LED"
OUT=$(env "${BASEENV[@]}" INNKEEPER_LIVE_MAX_USD=1.00 "INNKEEPER_LEDGER=$LED" "STUB_CALLS=$CALLS" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'no further call may START' <<<"$OUT" && [ ! -f "$CALLS" ]; then
  ok "C9-a-reached-ceiling-stops-the-next-call"
else bad "C9-a-reached-ceiling-stops-the-next-call" "rc=$RC out=[$OUT]"; fi

T="$TMP/c9b"; mktoy "$T"; LED="$TMP/c9b.tsv"; CALLS="$TMP/c9b.calls"
printf '2026-01-01T00:00:00Z\tworker\t1.00\n' > "$LED"
OUT=$(env "${BASEENV[@]}" INNKEEPER_LIVE_MAX_USD=5.00 "INNKEEPER_LEDGER=$LED" "STUB_CALLS=$CALLS" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -s "$CALLS" ]; then ok "C9b-the-SAME-ledger-under-a-higher-ceiling-does-call"
else bad "C9b-the-SAME-ledger-under-a-higher-ceiling-does-call" "rc=$RC out=[$OUT]"; fi

# --- C9c: a BROKEN METER stops the quest, even with the ceiling nowhere near --------------
# The first version of this arm asserted UNKNOWN was not summed as 0 -- which no code could
# ever fail, because adding 0 and skipping the line give the identical total. The arm was
# unfalsifiable and would have shipped green forever.
# What is real is the DIRECTION: an unreadable cost makes the running total a lower bound,
# so the ceiling silently stops governing. This arm gives the quest a ceiling of $5.00
# against $0.10 of known spend -- room to spare, so C9b's "room permits a call" says the
# refusal below cannot be about the ceiling being reached -- and asserts it refuses anyway.
T="$TMP/c9c"; mktoy "$T"; LED="$TMP/c9c.tsv"; CALLS="$TMP/c9c.calls"
printf '2026-01-01T00:00:00Z\tworker\t0.10\n2026-01-01T00:00:01Z\tworker\tUNKNOWN\n' > "$LED"
OUT=$(env "${BASEENV[@]}" INNKEEPER_LIVE_MAX_USD=5.00 "INNKEEPER_LEDGER=$LED" "STUB_CALLS=$CALLS" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'LOWER BOUND' <<<"$OUT" && [ ! -f "$CALLS" ]; then
  ok "C9c-a-broken-meter-stops-the-quest-even-with-ceiling-to-spare"
else bad "C9c-a-broken-meter-stops-the-quest-even-with-ceiling-to-spare" "rc=$RC out=[$OUT]"; fi

# --- C10: AN UNSET LEDGER REFUSES, BEFORE THE CLI RUNS -----------------------------------
# Both enforcers (UNKNOWN-stop, ceiling) read the ledger, so with INNKEEPER_LEDGER unset they
# were skipped and the call ran UNMETERED and UNCAPPED -- live-party.sh exporting it was the
# caller being careful, not the tool refusing. C10 runs the role with the variable unset and
# asserts it refuses BY NAME and the stub never ran. C1b is C10's permitting twin (same role,
# ledger set, stub DOES run); C10b covers the other half: set, but its directory unwritable.
T="$TMP/c10"; mktoy "$T"; CALLS="$TMP/c10.calls"
OUT=$(env -u INNKEEPER_LEDGER "${BASEENV[@]}" "STUB_CALLS=$CALLS" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'INNKEEPER_LEDGER' <<<"$OUT" && [ ! -f "$CALLS" ]; then
  ok "C10-unset-ledger-refuses-by-name-and-the-CLI-never-runs"
else bad "C10-unset-ledger-refuses-by-name-and-the-CLI-never-runs" "rc=$RC calls=$([ -f "$CALLS" ] && echo yes || echo no) out=[$OUT]"; fi

T="$TMP/c10b"; mktoy "$T"; CALLS="$TMP/c10b.calls"
OUT=$(env "${BASEENV[@]}" "STUB_CALLS=$CALLS" "INNKEEPER_LEDGER=$TMP/no-such-dir/c10b.tsv" \
      bash "$REPO/roles/claude-worker.sh" "$T" first 2>&1); RC=$?
if [ "$RC" -ne 0 ] && grep -q 'INNKEEPER_LEDGER' <<<"$OUT" && [ ! -f "$CALLS" ]; then
  ok "C10b-unwritable-ledger-dir-refuses-and-the-CLI-never-runs"
else bad "C10b-unwritable-ledger-dir-refuses-and-the-CLI-never-runs" "rc=$RC calls=$([ -f "$CALLS" ] && echo yes || echo no) out=[$OUT]"; fi

echo
if [ "$ARMS" -ne "$EXPECT_ARMS" ]; then
  echo "live-roles-selftest: ARM COUNT $ARMS, expected $EXPECT_ARMS — an arm was skipped or added"
  exit 1
fi
echo "live-roles-selftest: $PASS/$ARMS passed (expected $EXPECT_ARMS arms)"
[ "$FAIL" -eq 0 ] || exit 1
