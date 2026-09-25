# Stranger test: skeptical senior backend dev (2026-09-25)

Commit `e934742`; Linux, bash 5.2, root, no gitleaks.

## Findings first

1. **The suite is RED on a clean clone, and not only because of gitleaks.** `bus-merge-selftest.sh` fails arms M15, M15b and D0. The test uses `chmod a-w` to make a directory unwritable, and root ignores that. So as root (Docker, CI) the suite fails. The README doesn't say so.
2. **The README's numbers are wrong.** It says a fresh clone without gitleaks gives "16/17 and rc=1". What I got: `suite: 18/20 batteries green (expected 19), red=1 cannot-run=1`. "20 of expected 19" looks broken even if it's intended (the runner's own battery is counted and then skipped).
3. **The README never says what this is or why I'd want it.** The first line is a metaphor ("a tavern for Claude Code agents"). After that it jumps straight into leases, gates and herald ordering. Nothing tells me the problem it solves compared with Claude Code subagents or agent teams.
4. **The demo is a script, not agents.** `hello-party.sh` calls no model, and the README says so, which is honest. But the "researcher" and "worker" are canned steps. It shows the protocol (lease, gate, merge-once), not whether agents behave well inside it.
5. **`--help` is ignored.** `bin/hello-party.sh --help` just runs the demo. `bin/live-cost.sh --help` treats `--help` as a quest name: "no ledger at --help".

## 1. README

- **First confusing sentence:** "Turn your laptop into a tavern for Claude Code agents." I can't tell what it does from that.
- **Where I stopped caring:** the `bin/smoke.sh` paragraph ("four brains boot... the herald prints them in roster order"). It's internal wiring, shown before I care. The concurrency and portability history belongs in CONTRIBUTING.
- **Words I had to guess:** tavern, party, quest, lease, lane, gate, port gate, voice, brains, bus, herald, roster, camp, battery, arm, "the lease's second half". There's no glossary.

## 2. `bin/hello-party.sh`

- rc=0, 0.99 s. Ten numbered steps: the quest is posted; a lease is claimed (a second claimant gets `HELD-BY-OTHER age=0`); the researcher briefs; attempt 1 is committed; the gate prints `-> REFUSED` ("exited 0 but printed NOTHING"); attempt 2 is committed; `PASS ... prints: 0.1.0`; the merge happens and a second merge gets `ALREADY-MERGED`; then a plain-English summary, and the sandbox is removed.
- **Did I understand it?** Mostly. The refusal-then-fix is very clear, and it's the best part of the repo.
- **Meaningless or alarming output:** raw UUIDs for the lease, `HELD-BY-OTHER age=0`, `lane=worker`, and `/tmp/hello-party.XXXX/...` paths for a merge target that was already deleted when the script ended. The gate's verdict prefix is `NO`, which reads like a typo next to `PASS`. It also prints ANSI bold codes when output isn't a terminal.

## 3. `bash tests/run-all.sh`

rc=1 after 104 s. Verdict line: `suite: 18/20 batteries green (expected 19), red=1 cannot-run=1`.
- CANNOT-RUN: `bin-port-gate-selftest.sh` (gitleaks not on PATH). The README warns about this.
- RED: `bus-merge-selftest.sh`, arms M15, M15b and D0. Caused by running as root (see finding 1).

## 4. Verdict, in my voice

**What is it?** Bash scripts for coordinating several Claude Code instances: file-based task records, exclusive leases, a gate that runs the output before merging, merge-exactly-once, and crash recovery.
**Who is it for?** Someone who has already watched parallel agents step on each other or report work done that wasn't, and who wants proof rather than vibes.
**Why not built-in subagents or agent teams?** The README never says. My guess is durability (leases survive a `kill -9`) and a gate that executes the result instead of trusting the agent's summary. That's a real pitch, buried.
**Cost:** the demo is free and needs no setup. The live path (`live-party.sh`) needs `INNKEEPER_LIVE=1` and has a $3.00 budget ceiling, which I appreciated. The README never mentions live runs, dollar costs or setup time. I had to find `live-*` in `bin/`.
**Star, try, or close?** Close the tab, maybe star it first. The testing is careful (tests that deliberately break the code to check that the suite notices; a CANNOT-RUN counts as a failure). But the README gives me no way to point it at my own repo, and the suite is red out of the box.

## 5. Rough edges

- Suite RED as root (see finding 1). Containers and CI often run as root.
- There's no `docs/`. `live-*.sh` and `port-gate.sh` aren't mentioned in the README.
- gitleaks is required for a green suite, and there's no install hint (`brew install gitleaks`) for Mac users, the likely audience.
- The suite takes about 100 s, and two concurrent runs give false reds (the README admits this).
- macOS: by the README's own account, it's checked only by a grep that looks for GNU-only commands, not by running on a Mac. Treat it as untested.
- Over-promise: "watch it ship" and "a party of four" suggest agents are working. The demo is scripted, with no model, and "four" never shows up as four visible actors in the output.

## 6. The one change

Rewrite the first screen of the README: one plain sentence on the problem ("parallel Claude Code agents clobber each other and claim unverified work; this adds leases, an execute-the-result gate and merge-once"), then `hello-party.sh`, then a three-line "run it on your own repo" section with the live-run cost. Move the wiring, portability and concurrency notes lower down.
