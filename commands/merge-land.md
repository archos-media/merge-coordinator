---
argument-hint: <pr-number> [--admin] [--update-branch] [--skip-deps]
description: Run the landing sequence for a pull request — claim, freshness, verify, land, release guard, and tell every PR the merge invalidates.
---

Land pull request **$ARGUMENTS** through the merge coordinator.

1. Check the ordering first, so you are not landing something that should wait:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/overlap.sh" <number>
   ```

   If it says the PR waits on others, tell the user which ones and stop. Do not
   land out of order without being asked to.

2. Run the sequence:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/land.sh" <number>
   ```

   Pass through any flags the user gave.

3. The script refuses rather than guesses. Read what it printed and act on it:

   - **stale head** — it prints the rebase commands. Run them in *your own
     worktree*, never in the shared checkout, then re-run the script. For a PR
     touching no hotspot, `--update-branch` has GitHub do it.
   - **a check missing, running, cancelled or failed** — do not re-run the
     script hoping. Find out why. A run that ended in seconds with no steps is
     usually a billing wall, and the reason is only in the annotations.
   - **another PR holds the claim** — say whose it is and stop.
   - **no approving review** — say so. `--admin` is available and still runs
     every other step, but it is the user's call, not yours.
   - **a Dependabot pull request is waiting** — ask the user, naming each one:
     land it first? Yes: `/merge-deps <number>`, then land this one. Later:
     re-run with `--skip-deps`, which lasts one run. `--admin` does not get past
     this stop.

4. On the merge-queue backbone the script hands the pull request over and
   returns before it merges. Steps 6 and 7 have not run at that point. Once
   the queue lands it, run:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/land.sh" <number> --post-merge
   ```

   Skipping this leaves the release-heading assertion unmade and tells none of
   the pull requests the merge invalidated.

5. When it lands, report: what landed, which PRs it invalidated (the script
   names them), and whether the release-heading assertion passed. If that
   assertion failed, say so first — it means the merge reverted a release
   heading on the default branch and needs fixing before anything else lands.

Never work around a refusal by running `gh pr merge` yourself.
