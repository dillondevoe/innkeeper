# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately using GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a
public issue or pull request for a suspected vulnerability, and do not send reports by email.

Include what you ran, what you expected, what happened, and the commit you tested.

## Scope notes

- Innkeeper is an alpha, single-author prototype. There is no supported-versions matrix; fixes
  land on `main`.
- The live run grants the `claude` CLI `--permission-mode acceptEdits` with the tools
  `Read,Edit,Write,Glob,Grep` and `--add-dir <workdir>` (see `roles/claude-call.sh`). A hostile
  prompt can modify files in that working directory. See [LIMITS.md](LIMITS.md).
- Never put credentials in quests, party files or issues. If you find a committed secret, report
  it privately as above.
