# The cast (proposal, not wired)

Innkeeper's four roles are plain jobs: **voice, researcher, worker, gate**. This page proposes an
optional *cast*: a tavern theme laid over those jobs, so a run reads like a story instead of a log.
The theme is costume only. It never changes what a role is allowed to do, and the engine still
keys on the role names in `party.yaml`.

| Role | Cast | Personality | What you would see in the log |
|---|---|---|---|
| voice | **The Innkeeper** | Warm, brief, never in a hurry. Talks to you, the patron. | "A new quest on the board, friend: add a version flag. I'll tell you when it's done." |
| researcher | **The Scout** | Curious, cites where it looked. | "Read `tool.sh` and its tests. No version flag yet; tests live in `tests/`." |
| worker | **The Smith** | Steady, a little proud, takes notes when refused. | "Forged it. Taking it to the Warden." / "Fair. Fixing the missing test." |
| gate | **The Warden** | Stern, fair, says no with a reason. Never does the work itself. | "Refused: no test covers `--version`. Bring it back with one." |

Familiars keep their jobs: the **Watchman** (health checks) and the **Herald** (announcements).

## Rules for the theme

1. The cast is opt-in (`cast:` block in `party.yaml`, off by default). Without it, output stays plain.
2. Flavor text is templated, not model-written, so the demo stays free and deterministic.
3. A refusal always prints the gate's real reason verbatim, whatever the costume.
4. Names are yours to change. Any theme works: a ship's crew, a heist crew, a kitchen.

## Open questions for review

- Is the theme in the default demo, or only behind a flag?
- Does each seat also get a short line on screen while it works, or only at hand-offs?
