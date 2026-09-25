# Stranger test: non-technical founder, first contact

**Persona:** startup founder, pays for Claude Max, can paste terminal commands, cannot debug
them. Looking for "a team of AI agents that works while I sleep and tells me when it needs
me." Gives up the moment a command fails without saying what to do next.

## 1. Reading the README

First sentence I got lost on: the tagline — "Turn your laptop into a tavern for Claude Code
agents. Give the party a quest, watch it ship, and make camp." I don't know what a "tavern"
is here (a folder? a process?), what a "party" is, or what "make camp" means as an action.

First sentence I stopped caring about: "Two workers are really `kill -9`'d mid-quest — one
before it commits its work, one *after* committing but before it could tell anyone." Probably
a real, clever guarantee, but by line 71 of 80 I've lost track of what a "worker," "quest,"
and "lease" are well enough to follow a story about killing one on purpose.

Words and my best guess at each: **tavern** = the whole system running on my machine;
**quest** = a task given to the agents; **party** = the group of four agent processes;
**gate** = an automated check that can reject work; **voice** = whatever prints my summary;
**lease** = a lock so two workers don't grab the same job; **bus** = internal messaging
between scripts; **herald** = something that prints status; **sandbox** = a temp folder so
nothing touches my real files (confirmed correct by the output); **battery** = a group of
tests (confirmed by running the suite). **camp** and **arms** ("failing arms inline") I never
resolved.

## 2. Running `bin/hello-party.sh`

Exit code 0, ~0.9 seconds. It's a 10-step narrated story ending with "Your quest
'version-flag' is done... Nothing else on your machine was touched."

It did tell me a check failed and got auto-fixed ("the gate refuses it... the worker reads
the refusal and fixes it"). But it read like a movie trailer, not a demo I ran myself —
there's no real task of mine in it, and I can't tell how I'd hand it *my* job instead of the
canned one. If it had failed, there's no error and no "run this next" — I'd be stuck. I also
tried `bin/hello-party.sh --help` expecting usage instructions; it just re-ran the entire
demo again, ignoring the flag. First scary moment: it never tells me when it doesn't
understand what I typed.

## 3. Running `bash tests/run-all.sh`

Verdict: `suite: 18/20 batteries green (expected 19), red=1 cannot-run=1`, exit code 1.

One battery was CANNOT-RUN because I lack a tool called `gitleaks` — the README warned me
about this one, so no panic. But `bus-merge-selftest.sh` came back RED with FAIL lines full of
internal names (`M15-nonexistent-dest-is-a-hard-error`, `D0-unmutated-control`) that mean
nothing to me. This is where I'd actually give up. No "known flaky, ignore it," no link to a
fix. The README does warn that running two suites at once causes spurious reds — but I ran it
once, alone, exactly as told, and it still went red. I can't tell if my machine is broken,
the software is broken, or this is normal on a fresh clone.

## 4. What is this, honestly?

A demo of a task-queue system for coordinating multiple Claude Code agent processes on one
machine, with locking, an approval gate, and safe retries if a process gets killed. It is not
yet a product I can point at my own work — the demo task is hard-coded (add a `--version`
flag to a toy script). No pricing anywhere, no install steps beyond `git clone`, no hint what
I'd change to point it at a real repo. It says "no model is called" in this demo, so I can't
even guess real-world cost. Could I use it tonight? No — I'd need someone technical to wire
it to a real task, and the red test would make me nervous to try.

**Verdict: close the tab.** Not because the idea is bad — the killed-worker recovery and the
refuse-then-fix gate are exactly what I want from "agents while I sleep" — but a fresh clone
should not have a red test, there's no pricing, no path from toy demo to my project, and no
help when I get lost.

## 5. Assumed knowledge, scary output, wanted a picture

Assumed I know git, what a lock/lease is, and what a CI-style gate does. Assumed I know a
`--version` flag "should" print something and exit 0 — that's the whole premise of the
demo's failure case. Scariest/most meaningless output: the FAIL lines with IDs like
`M15b-...`, and "expected 19" batteries with no explanation of where 19 comes from. I wanted
a picture instead of text constantly — a single diagram of "quest → worker → gate → merge →
voice" with the four roles as boxes would have saved the whole first read of the README.

## 6. The one change that would help most

Add a 30-second diagram or short screen recording right after the tagline, before any prose,
showing the four roles as boxes and a quest moving between them — so the words the README
already uses (quest, gate, voice) attach to a picture before I run anything, instead of me
learning eleven new nouns from text alone first.
