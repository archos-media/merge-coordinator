---
argument-hint: "[paths you expect to touch]"
description: Register this branch so other sessions can see it — opens the draft PR and declares the paths this task expects to touch.
---

Register the current branch, declaring **$ARGUMENTS**.

1. Run:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh" <paths>
   ```

   Pass one glob per path, the way the hotspot table writes them — `web/src/**`,
   `go/feed/**`, `.github/workflows/ci.yml`. Declare the directories the task
   will work in, not every file you think you will edit: a declaration is read
   as a warning to another session, and a broad one is more useful than a
   precise one that turns out to be wrong.

2. It is safe to run again. The second run edits the block on the pull request
   that already exists and never opens a second one, so re-run it whenever the
   shape of the task changes.

3. The pull request it opens is a **draft on purpose**. It says the branch is
   claimed, not that it is finished. In a repository whose CI skips drafts,
   it costs no CI either.

4. Report the pull request number to the user, and say what was declared.

If `overlap.sh` then reports that another pull request declared the same
ground, that is a conversation, not a queue position — it never changes the
landing order. Say who else is there and what they said they would touch.
