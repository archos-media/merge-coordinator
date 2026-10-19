---
argument-hint: "[pull request number] [--skip-deps]"
description: Mark a pull request ready for review once nothing sharing its files is already running CI — the moment CI starts, so it is the moment the line is checked.
---

Take pull request **$ARGUMENTS** out of draft.

1. Run:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ready.sh" <number>
   ```

   With no number it uses the pull request for the branch checked out here.

2. **It may refuse, and a refusal is the useful answer.** It refuses when
   another pull request that is already ready touches ground this one touches.
   Do not work around that — leave this one a draft and land the other first.

   A draft runs no CI and cannot go stale, so waiting costs nothing. Two ready
   pull requests over the same files cost a whole extra suite between them:
   whichever lands second has main move underneath it, so its merge group
   builds a tree nothing has tested and a CI cache keyed on the tree cannot
   avoid it.

   **It stops first while a Dependabot pull request is waiting.** Ask the user,
   naming each one it lists: "Dependabot PR #N (what it bumps, how old, its CI)
   is waiting. Land it first?" Yes: `/merge-deps N`, then run this again.
   Later: run this again with `--skip-deps`. That lasts one run. `--force` does
   not get past this stop, so do not reach for it.

3. It also refuses when it could not work out what is ahead. That is not the
   same answer as "nothing is ahead" and is never treated as one. Run
   `scripts/overlap.sh <number>` to see what it can read.

4. `--force` marks it ready anyway and says so in the output. Use it when the
   two pull requests genuinely do not interact and the file overlap is
   incidental — and say in the pull request why.

5. Report to the user whether it went ready, or who it is waiting on.

Nothing here is about whether the work is finished. That is your call. This
only answers whether *now* is the cheap moment to start spending CI on it.
