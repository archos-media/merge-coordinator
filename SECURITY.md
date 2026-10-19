# Security policy

## Supported versions

Only the latest release. A fix ships as a new release: an installed plugin
gets it with `claude plugin update merge-coordinator@merge-coordinator`, and a
pinned copy by re-vendoring (`vendor.sh <tag>`).

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this
repository, then **Report a vulnerability**. Please don't open a public issue.

Include the plugin version, what you ran, what happened, and the smallest
reproduction you have. Reports that read as unreviewed AI output are closed.
Without a reproduction, a report may wait for one.

## What counts

- A way for data the scripts read from GitHub (a pull request's title, body,
  branch name, labels, file paths or comments) to run a command, or to change
  what a landing does.
- A way for a pull request's own content to change what the example workflows
  do. `issue-claim-others.example.yml` runs on `pull_request_target`, and is
  written never to check out pull request code.
- A token or credential written to output, comments or logs.

## What does not

The hooks are guardrails for agents, not a security boundary. They run on your
machine, inside Claude Code, and `MERGE_COORDINATOR_OVERRIDE=1` steps over them
by design. A command that gets past a guard is a bug: open an ordinary issue.
To enforce a rule for everyone, use your repository's branch rules on GitHub.

## What the plugin sends, and where

Every network call is `gh` or `git`, run as you, to GitHub: to the
repositories you point it at, and to this repository when it checks for a
newer release (`vendor-status.sh`) or makes a pinned copy (`vendor.sh`). It
reads no token itself and sends nothing anywhere else.
