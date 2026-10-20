---
description: What is in flight — every open PR, whether it is fresh, whether its checks really passed, and who holds the landing claim.
---

Report the merge state of this repository.

1. Run the queue state script:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/queue-state.sh"
   ```

2. Then run the ordering analysis:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/overlap.sh"
   ```

   With an argument (`overlap.sh 42`) it reports only what blocks that PR and
   what that PR blocks.

3. Report both to the user as one answer: what may land now, what is waiting and
   on what, and anything that is stale, conflicting or red. Lead with the recommendation —
   which PR to land next and why — rather than with the table. A Dependabot
   pull request listed under the table as waiting stops every other ready and
   land until it lands or closes, or the user says later (`--skip-deps`, one
   run), so name it in the recommendation.

Do not merge anything as part of this command. Landing is `/merge-land`.
