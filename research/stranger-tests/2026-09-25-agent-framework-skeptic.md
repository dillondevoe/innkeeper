# Stranger test: Innkeeper, 2026-09-25

First look, no prior context. I came in wanting three answers: does the queue survive a
crash, can two agents grab the same job, and what happens when you kill an agent mid-task.

## 1. README

It doesn't dodge. It states up front that a lease stops double-claiming ("a second instance
of that worker stands down"), that a gate re-runs the tool rather than trusting the diff,
and that merges happen "exactly once, and a second merge is refused." There's a whole
second section, "Then kill a worker," that walks through two real `kill -9`s and states the
outcome for each. It also owns its weaknesses in public: it says the batteries share
repo-level state and go red under concurrent `run-all.sh` runs, it names a macOS-vs-Linux
gap it shipped and later caught, and it says replay, the tavern view, and "the lease's
second half" aren't built. That's more self-incrimination than most READMEs volunteer.
Verifiable claims: exit codes, the refusal step, the merge-once step, gitleaks gating a
battery, the RED-under-concurrency claim. I ran all of them except deliberately trying two
concurrent `run-all.sh` (out of scope for one pass).

## 2. `bin/hello-party.sh`

Exit 0, wall time 0.985s, ran clean the first time. Output shows every beat the README
promises: quest posted, lease claimed, a second worker instance told `HELD-BY-OTHER`,
researcher briefing, worker's first commit, gate output verbatim — `` `tool.sh --version`
exited 0 but printed NOTHING `` — then `-> REFUSED`, a second commit, `PASS`, `MERGED
.../version-flag.out`, then a second merge attempt printing `ALREADY-MERGED ... by=worker`.
Yes, you can tell the gate refused once and the worker fixed it — it's in plain text, not
inferred. Yes, "merges exactly once" is directly visible, including the refusal of the
second merge attempt, not just asserted in prose.

## 3. `bash tests/run-all.sh`

One run, alone, nothing else touching the repo. Verdict: `suite: 18/20 batteries green
(expected 19), red=1 cannot-run=1`, exit 1.

- `CANNOT-RUN bin-port-gate-selftest.sh` — gitleaks isn't installed. Matches the README's
  stated behavior exactly (no verdict rendered, named reason, counts as a fail).
- `RED bus-merge-selftest.sh` — three FAILs, all under one arm group (M15/M15b/D0-control).

That RED matters because the README's only documented cause of red is *two suites running
at once*. This was one suite, one pass. I reran `bus-merge-selftest.sh` alone three more
times: red all three, identical failure. Not a flake.

Read the test: M15 does `chmod a-w state/merged` to simulate a destination merge.sh can't
write to, then expects `commit` to hard-fail with "did NOT happen" and rc=1 — the arm
guarding against a bug where an unwritable dir gets silently reported `ALREADY-MERGED`
(i.e., "your work is safe" when nothing was written). It got `MERGED` instead, then
`ALREADY-MERGED ... by=voice` on the second call. Root cause: this container runs as root,
and root ignores a plain `chmod a-w`, so the "genuinely unwritable" precondition the whole
arm depends on never holds — `merge.sh`'s `ln "$src" "$d"` on line 94 just succeeds. The
test isn't lying about what it checks — it's a real, well-reasoned hard-error case — it's
just silently assuming a non-root reader, which a laptop demo usually is and a container or
CI runner usually isn't.

I also read `lifecycle-lease-selftest.sh` (A12) and `bin-murder-quest-selftest.sh`. The
lease test forks 8 real background processes at a free lease, 10 rounds, and asserts
exactly one gets `CLAIMED` each round — an actual race, not a mock. The murder-quest
selftest is the most convincing file in the repo: past the output-shape checks, it mutates
a copy of `merge.sh` (e.g. `ln` → `ln -f`, so last-writer-wins) and asserts the demo goes
red against the mutant, with a documented history of this harness being vacuous twice
before (mutant built outside `bus/` so it never actually ran; a zero-byte guard nobody
exercised) and fixed each time. That's the kind of paranoia I want to see, and it's the
strongest evidence that "merges exactly once" is a tested property, not a story.

## 4. `bin/murder-quest.sh`

Documented in the README, so I ran it. Exit 0, 7.35s. Two real SIGKILLs, both confirmed in
output. Act 1 (killed before commit): partial ignored, takeover after lease staleness,
exactly one merge. Act 2 (killed after commit, before release): takeover tries to redo the
work, second commit refused by name, result is still the dead worker's bytes, credited to
the worker that actually did it. Matches the README claim word for word, checkmarks all
green.

## 5. Verdict

What is this: a shell-only job queue with leases, a "gate re-runs the tool, doesn't trust
the diff" step, and an exactly-once merge, built to demo against real `kill -9` rather than
narrated failure. The one thing it claims over Claude Code's built-in agent teams: crash
survival with an exactly-once guarantee backed by a real lease and a real merge lock, plus a
gate that verifies by execution — I haven't used built-in agent teams enough to know if they
already do this, so I can't confirm the differentiator, only that this repo's version of it
held up under an actual kill in my one run. I'd believe the bigger claim after two things:
someone else's fresh clone showing the same murder-quest result, and that `bus-merge` RED
either fixed or the README updated to say "root breaks this arm" instead of only blaming
concurrency. Verdict: **not a toy** — the mutation testing and the real SIGKILLs are doing
actual work — but it shipped with a known-red battery on a plain, non-concurrent run in a
common environment (root), and the README's explanation for red batteries doesn't cover the
one I hit. Call it "neat, but read the fine print before you trust the merge test."

## 6. Rough edges

- `bus-merge-selftest.sh` red on a single, non-concurrent run as root — see above.
- No `docs/` directory despite the README structure implying more than SCHEMA.md.
- No `--help` on any `bin/*.sh` — `--help` just runs the full demo instead of printing usage.
- `tests/portability-selftest.sh` is itself GNU-grep-and-sed based; it polices other scripts
  for BSD-incompatibility but nothing in the repo checks itself the same way on first run —
  you only find out by literally being on a Mac.
- Jargon that's never defined for a first-time reader: "lane," "brain," "voice," "gate,"
  "party" as a technical term distinct from "quest." The README uses them fluently but
  never glosses them; SCHEMA.md wasn't part of my read (out of scope) so I can't say if it
  helps.
- The concurrency warning in the README ("run the suite once at a time") is honest but is
  also doing some work to explain away reds in general — I hit one it doesn't cover.

## 7. Single highest-value change

Fix or gate the `bus-merge-selftest.sh` M15 arm for root (skip with a named CANNOT-RUN when
`id -u` is 0, the same pattern already used for missing gitleaks) so a fresh clone in a
container — which is a completely normal way to first meet a CLI tool — doesn't open with an
unexplained RED that contradicts the README's own stated cause of red batteries.
