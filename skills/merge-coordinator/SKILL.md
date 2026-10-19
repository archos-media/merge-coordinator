---
name: merge-coordinator
description: Follow before merging any pull request, and before starting work that several sessions might touch at once. Covers landing order, the claim label, why a green check on a stale head means nothing, and the paths where a clean textual merge is the dangerous case (the repository's configured hotspots). Applies only in a repository that has .github/merge-coordinator.json. Use when about to merge, land, or enqueue a PR, when deciding what to land next, or when a PR has gone stale.
---

# Merge coordination

Several sessions land pull requests into one branch. When one lands, another
session's green CI stops meaning anything — the run that passed never saw the
new default branch. GitHub will not say so unless branch protection requires
branches to be up to date before merging, so a stale PR still reports as
mergeable.

**Check the repository uses it first.** Everything below applies only where
`.github/merge-coordinator.json` exists at the repository root. Without it the
hooks stand aside and the scripts refuse to run; say so rather than improvise
the sequence by hand. To adopt it, follow `references/adopting.md`.

**A `tools/merge-coordinator/` folder is a pinned copy, not source.** Never
edit it (a hook refuses, and CI's `check-vendored.sh` fails). Changes go to the
coordinator repository, a release, then `vendor.sh <tag>`.

Three layers handle it. Only the middle one is this plugin.

| Layer | Question | Mechanism |
|---|---|---|
| Register | who is touching what, right now | `/merge-register`, or the worktree hook |
| Order | who lands next, what may land in parallel | this plugin |
| Land | is this commit actually safe | the merge queue, or the claim label |

## Before you start work

Run **`/merge-register <paths you expect to touch>`**. It opens a draft PR
carrying those paths, which is the only way another session can see you before
you have written anything. Where drafts run no CI (`references/adopting.md`
section 5), that costs one API call.
`/merge-status` lists drafts as REGISTERED.

Entering a worktree fires this for you, declaring nothing. That makes the branch
visible; it does not say where you are working. Run the command with paths as
soon as you know them, and again when the shape of the task changes.

**A declaration is a prediction, and is treated as one.** It adds a warning and
never removes one, and it never changes the landing order. Being wrong in a PR
body cannot reorder somebody else's work.

**The issue claim is not a prediction.** Registration writes `issue: N` into
the block, from `--issue N` or from a single issue number in the branch name.
The `issue claim` check, in a repository that runs the issue-claim workflow,
fails a second open PR that claims the same issue, and
a hook refuses a worktree named for a claimed issue before it exists. Planned
work beside another PR declares `register.sh --issue N --part-of M`.
`scripts/claims.sh --issue N` shows who holds an issue.

## Before you take it out of draft

Run **`/merge-ready <number>`**. Marking a pull request ready is the moment CI
starts — a draft runs nothing — so it is the moment worth checking, and a
PreToolUse hook refuses a bare `gh pr ready` for the same reason it refuses a
bare `gh pr merge`.

It refuses when another pull request that is *already* ready touches ground
this one touches. Whoever is running CI keeps their turn; everybody sharing
their files waits as a draft, which costs nothing and cannot go stale. Two
ready pull requests over the same files cost a whole extra suite between them —
whichever lands second has main move underneath it, so its merge group builds a
tree nothing has tested.

Pull requests with **nothing in common are not serialized**. They both run CI
once and both land off a cached merge group. The line only exists where the
work actually collides.

## When a Dependabot pull request is waiting

Ready and land both stop while a Dependabot pull request is open and waiting.
The raw `gh pr ready` hook stops too. The notice on entering a worktree, after
`/merge-register` and in `/merge-status` lists them, so you usually know before the stop does. **Stop and ask the
user**, naming each one: "Dependabot PR #90 (Go bump, 3 days old, CI green)
is waiting. Land it first?"

- **Yes:** `/merge-deps 90`. It reviews the bump and records safe, unsafe or
  needs a fix-up. Safe lands with `/merge-land`. Unsafe is closed with a
  Dependabot ignore command. A fix-up goes back to the user as options, and
  nothing is pushed to the Dependabot branch. Then re-run what was stopped.
- **Later:** re-run with `--skip-deps` (`ready.sh N --skip-deps`,
  `land.sh N --skip-deps`). It lasts one command. The next ready or land asks
  again.

`--force` and `--admin` do not get past this stop. `--skip-deps` is the way
past, once the user has said later. A Dependabot pull request already landing (in
the merge queue, or holding the landing label) stops nothing. Landing a
Dependabot pull request is never stopped by the others. If the coordinator
could not read the open pull requests, it stops and says "could not check". Try
again, or ask the user.

Before this stop, sessions forced past these pull requests again and again, and
Dependabot closed them unlanded after a week.

## Before you merge

Run `/merge-land <number>`. Do not run `gh pr merge` yourself — a PreToolUse
hook refuses it, and it refuses it because every step the sequence performs is
one that a bare merge skips.

The sequence is seven steps and is safe to re-run from any point: preflight,
claim, freshness, verify, land, release, notify. `references/protocol.md` has
each one, what it refuses, and how to recover.

## The three things that look fine and are not

1. **A green check on a stale head.** The run passed against a default branch
   that no longer exists. Step 3 refuses this on `serialized-claim`. GitHub does
   not. **On `github-merge-queue` this is not a fault at all** — the queue
   rebuilds and retests against the real base, so step 3 refuses a *conflict*
   instead, and refusing staleness there just buys a rebase and a full CI run
   for nothing.
2. **A clean merge of a hotspot file.** Two PRs inserting under the same
   heading merge with no conflict and lose one entry — that is how
   a release heading was reverted while CI was green and GitHub said
   MERGEABLE. The hotspot table in `.github/merge-coordinator.json` names every
   path where this is true, and step 6 asserts the release heading survived.
   **A merge queue does not help here and never will**: it merges cleanly and is
   exactly as wrong.
3. **A second CI pass that looks like diligence.** A pull request runs CI on
   the pull request and again on the merge group, and on the repository this was
   built for 28 of 30 measured merge groups built a tree the pull request run had
   already tested — the same git tree object, not a similar one. A proven-tree
   gate in the repository's own CI (a step that looks up an earlier green run
   for the same tree) finds that earlier green and skips the rebuild. The two in thirty where main really had moved still run
   everything, and keeping those rare is what `/merge-ready` is for.
4. **A cancelled run reported as success.** `gh run watch --exit-status`
   returns 0 for a run that a later push superseded. Nothing here uses it;
   step 4 reads named check conclusions on the exact head commit, and a check
   it cannot find is a failure, never an absence of news.

## Commands

| Command | Does |
|---|---|
| `/merge-register` | declare the paths this branch expects to touch |
| `/merge-ready N` | take N out of draft, once nothing sharing its files is running CI |
| `/merge-status` | everything open: freshness, checks, who holds the claim |
| `/merge-land N` | the landing sequence for PR N |
| `/merge-deps N` | review Dependabot PR N, record safe / unsafe / needs a fix-up, act on it |
| `scripts/deps-open.sh` | the open Dependabot pull requests, one per line |
| `scripts/overlap.sh` | full ordering analysis — chains and what may go in parallel |
| `scripts/overlap.sh N` | just what blocks N, and what N blocks |
| `scripts/overlap.sh N --ci-ahead` | machine mode: who is already running CI over N's ground |

## When something has gone wrong

- **A PR is labelled `merge:needs-rebase`.** Something landed underneath it.
  The comment on the PR names what overlapped. Rebase, force-with-lease, let
  the checks re-run.
- **The claim is stuck on a PR nobody is landing.** `land.sh <that number>
  --release-claim`.
- **You genuinely have to merge outside the sequence.** Prefix the command with
  `MERGE_COORDINATOR_OVERRIDE=1`. It is meant to be reachable; a control that
  cannot be stepped over in an emergency gets deleted instead of respected.
  Say in the PR why. **Then fire the workflows the merge skipped.** An override
  merge does not run the landing sequence at all, so nothing fires the
  `outOfQueueCi` workflows for it; the hook prints the exact `gh workflow run`
  commands as it lets the merge through.

`references/protocol.md` — the full state machine and every failure mode.
`references/adopting.md` — putting this in a new repository: config, labels,
probe fixtures, CI, and running without a merge queue.
