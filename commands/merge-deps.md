---
argument-hint: <pr-number>
description: Review one Dependabot pull request — what moves, its release notes, its checks — decide safe, unsafe or needs a fix-up, record it, and act on it.
---

Review Dependabot pull request **$ARGUMENTS**. Run this when the user has said
yes to "land it first?" after ready or land stopped on a waiting Dependabot pull
request.

1. Gather the facts:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/deps.sh" <number>
   ```

   It prints each package that moves (from, to, major / minor / patch), the
   files it changes and the diff of each manifest, the fix-ups and pairings this repository's config names,
   whether the branch is behind, the required checks on the exact head, and
   Dependabot's description, which holds the release notes.

2. Judge it. Read the release notes and the changelog for every package that
   moves. Look for breaking changes, dropped runtime or platform versions, and
   changed defaults, and check them against how this repository uses the
   package. A major bump is not unsafe on its own, and a patch bump is not safe
   on its own. Then decide one of:

   - **safe** — nothing in the notes breaks this repository, and the required
     checks passed.
   - **unsafe** — something in the notes breaks it, and fixing that is not a
     small change.
   - **needs a fix-up** — the bump is fine, but the branch needs a change it does
     not carry: a fix-up the script names as one to run (one it reports as
     carried is already in the pull request, unless the required checks show
     what it carries is incomplete), a paired package that must move with it,
     or a small code change.

   Red checks are evidence, not a verdict. Find out why they failed before you
   decide. A check listed as MISSING can also be a read that failed: look at
   the pull request's checks before you call it absent.

3. Record the verdict, with one line saying why and the head sha the facts
   printed on their last line:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/deps.sh" <number> --record safe|unsafe|fixup "<why>" <sha>
   ```

   It refuses when the pull request has moved since you read it. Read the
   facts again and judge the new head.

   This posts one comment and sets one label (`deps:safe`, `deps:unsafe` or
   `deps:needs-fixup`). A verdict does not stop the pull request from waiting.
   Only landing or closing it does.

4. Act on it:

   - **safe** — `/merge-land <number>`. Dependabot opens its pull requests as
     ready, so there is no ready step. If it is behind and must be brought up
     to date, comment `@dependabot rebase` and wait for the new head; do not
     use `--update-branch`, which pushes a merge commit to the Dependabot
     branch and stops Dependabot rebasing it. Where the repository requires an approval
     and the user has none to give, `--admin` applies as for any solo pull
     request, and it is still the user's call.
   - **unsafe** — comment the Dependabot command that closes it and stops it
     coming back: `@dependabot ignore this major version` or
     `@dependabot ignore this dependency`. For a grouped pull request:
     `@dependabot ignore <package> major version` or
     `@dependabot ignore <package>`.
   - **needs a fix-up** — do not push to the Dependabot branch. Bring the user
     three options and let them choose: push the fix-up to the branch and land
     it; take the bump into a session's own pull request; or leave it for later.

5. Then go back to what was stopped. Re-run ready or land. If other Dependabot
   pull requests are still waiting, ask the user again about those.

Report the verdict, its reason, and what was done about it.
