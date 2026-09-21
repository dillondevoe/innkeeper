#!/usr/bin/env bash
# live-cost.sh — ONE NUMBER: WHAT ONE QUEST COST, WITH THE RULE THAT PRODUCED IT.
#
#   bin/live-cost.sh <ledger.tsv>
#
# THE EXTRACTION RULE, STATED IN THE OUTPUT AND NOT ONLY HERE:
#   For each model call the quest made, roles/claude-call.sh read `total_cost_usd` from
#   that call's own `--output-format json` response and appended one line
#   `<utc>\t<role>\t<cost>` to the ledger. This script sums those lines. Nothing is
#   estimated from token counts and nothing is reconstructed from a log afterwards.
#
# WHY THE RULE SHIPS WITH THE NUMBER. "$0.04" is not a fact anyone can check. "$0.04, being
# the sum of total_cost_usd over the 3 calls this quest made, as reported by the CLI itself"
# is. A cost figure without its extraction rule is the same shape as a green test whose
# assertion nobody can see.
#
# AN UNREADABLE COST IS NOT A ZERO COST. If any call recorded UNKNOWN, the total is printed
# as a LOWER BOUND and says so. Quietly treating an unreadable cost as 0 would make the one
# run whose metering broke look like the cheapest run there had ever been.
set -uo pipefail
ledger=${1:?usage: live-cost.sh <ledger.tsv>}
[ -f "$ledger" ] || { echo "live-cost: no ledger at $ledger -- this quest recorded no calls" >&2; exit 2; }

python3 - "$ledger" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 3:
        print(f"live-cost: REFUSING -- a ledger line is not <utc><TAB><role><TAB><cost>: {line!r}")
        sys.exit(2)
    rows.append(parts)

if not rows:
    print("live-cost: the ledger is EMPTY. No model call was made, so this quest cost nothing")
    print("live-cost: AND demonstrated nothing live. That is a defect, not a bargain.")
    sys.exit(1)

total, unknown, per = 0.0, 0, {}
for _ts, role, cost in rows:
    if cost == "UNKNOWN":
        unknown += 1
        per.setdefault(role, [0.0, 0])[1] += 1
        continue
    try:
        c = float(cost)
    except ValueError:
        print(f"live-cost: REFUSING -- {cost!r} is not a number and not UNKNOWN")
        sys.exit(2)
    total += c
    per.setdefault(role, [0.0, 0])[0] += c

bound = "at least " if unknown else ""
print(f"ONE QUEST COST: {bound}${total:.4f} USD, over {len(rows)} model call(s).")
for role in sorted(per):
    spent, unk = per[role]
    extra = f" (+{unk} call(s) whose cost the CLI did not report)" if unk else ""
    print(f"  {role:<12} ${spent:.4f}{extra}")
if unknown:
    print(f"  {unknown} call(s) reported no total_cost_usd, so the figure above is a LOWER BOUND.")
print()
print("EXTRACTION RULE: the sum of `total_cost_usd` as returned by the Claude CLI's own")
print("--output-format json for each call, recorded at the moment of the call by")
print("roles/claude-call.sh. Not estimated from tokens; not reconstructed from a log.")
PY
