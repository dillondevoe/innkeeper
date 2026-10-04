# Contributing

## Sign-off (DCO)

Contributions are accepted under the project's MIT license. Certify the
[Developer Certificate of Origin](https://developercertificate.org/) by signing off every commit:

    git commit -s

which adds a `Signed-off-by: Your Name <you@example.com>` trailer. Use a truthful identity.
Do not add attribution trailers that are not true.

## Tests

Run the whole suite and read the one-line verdict:

    bash tests/run-all.sh

It needs `gitleaks` on `PATH` (or `INNKEEPER_GITLEAKS`), or the port-gate battery reports
CANNOT-RUN, which fails the suite. The runner's own battery is run directly:
`bash tests/run-all-selftest.sh`.

**Run one suite at a time.** The batteries share repo-level `state/`, so two concurrent runs
produce failures neither produces alone (see the README). Likewise run a single battery
directly with `bash tests/<name>-selftest.sh`, not several at once.

Every script is paired with a battery under `tests/`; add or extend one with your change. The
batteries make no model call and spend nothing; keep it that way.

## Pull requests

Keep them small and single-purpose. Say what changed, why, and how you verified it. See
[LIMITS.md](LIMITS.md) before touching anything on the spend path (`roles/claude-call.sh`,
`bin/live-preflight.sh`) or the merge path (`bus/merge.sh`).
