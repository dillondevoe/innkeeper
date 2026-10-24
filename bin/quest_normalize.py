"""quest_normalize — the one spelling of "this part of a quest line is per-run noise".

bin/record-quest.sh captures bin/hello-party.sh's stdout into fixtures/recorded-quest.json
and `--check` compares a fresh run's lines against that committed fixture. Some of what the
quest prints differs on every run with NOTHING changed -- a sandbox path from `mktemp -d`, a
lease nonce, a commit hash, a lease age in whole seconds. Left alone, each of those reads as
DRIFT, which would make the fixture an unreproducible artifact and the check a liar.

WHY THIS IS A MODULE AND NOT A FUNCTION INSIDE THE RECORDER. The rule has two consumers --
the recorder that writes the fixture and the battery that has to prove the rule is live -- and
two halves spelling one rule in two languages, with no test that they agree, is a defect
waiting for whitespace. They import this; nobody re-types a regex.

Each rule below replaces a value that varies run to run with a fixed placeholder, so the
fixture records the quest's STRUCTURE. A rule must never flatten something the quest is
asserting: the version number, the commit COUNT, and the step numbers are all load-bearing
text and are deliberately not touched here.
"""

import re

# `mktemp -d` picks the suffix and $TMPDIR picks the root, so the whole prefix goes, not just
# the random tail: a fixture recorded on a Mac (/var/folders/.../T/) must match a fresh run in
# Linux CI (/tmp).
SANDBOX_RE = re.compile(r"[^\s'\"]*/hello-party\.[A-Za-z0-9]{6,}")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
COMMIT_RE = re.compile(r"\bcommit [0-9a-f]{7,40}\b")

# THE LEASE AGE. lifecycle/lease.sh ages a lock in WHOLE seconds (on Linux, int of
# /proc/uptime; on Darwin, CLOCK_UPTIME_RAW), so the age it prints is a whole number of seconds. hello-party.sh claims the
# lease and then immediately claims it again to show the second instance standing down, and
# those two clock reads are ~26ms apart (measured on dellon, 5 runs) -- so the printed age is
# `age=0` unless the pair happens to straddle a one-second rollover, and then it is `age=1`.
# That is roughly a 2-3% chance per run when the box is idle and WORSE under load, which is
# exactly the signature the flake had: green 15/15 run by hand, red occasionally inside
# run-all.sh with twenty other batteries competing for the CPU.
#
# The age is a clock reading, not a claim the quest is making -- what the step demonstrates is
# that a second claimant is REFUSED, and `HELD-BY-OTHER` carries that. So the number is noise
# by the same argument as the nonce beside it. Flattening it does not weaken the check: a
# refusal that stopped happening at all would change `HELD-BY-OTHER` itself, which is still
# compared verbatim.
# STATED LIMIT: on a host with NO awake clock, lease.sh appends a `[no awake clock on this
# host: ...]` note to the same line, and nothing here flattens it, so A4 reads DRIFT there.
# Deliberately left: that note is a real warning to whoever runs the demo, and the fixture
# narrating its absence would be the fixture lying about such a host. Reproduce with
# LEASE_UPTIME_FILE=/nonexistent LEASE_PYTHON=/nonexistent bin/record-quest.sh --check.
AGE_RE = re.compile(r"\bage=\d+")


def normalize(line):
    """Replace this line's per-run values with fixed placeholders."""
    line = SANDBOX_RE.sub("$TMPDIR/hello-party.SANDBOX", line)
    line = UUID_RE.sub("00000000-0000-0000-0000-000000000000", line)
    line = COMMIT_RE.sub("commit SHA", line)
    line = AGE_RE.sub("age=N", line)
    return line
