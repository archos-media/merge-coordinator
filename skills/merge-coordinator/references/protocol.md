# The landing protocol

Every step below is re-runnable. `land.sh` reads the world each time rather than
carrying state, so a refused run leaves nothing to clean up except the claim,
which it releases on its way out.

## States a pull request moves through

```
  registered ──► ready ──► claimed ──► fresh ──► verified ──► landed
   (draft)         │          │          │           │           │
                   │          │          │           │           └─► notify overlapping PRs
                   │          │          │           └─► refused: a check is missing,
                   │          │          │               running, cancelled or failed
                   │          │          └─► refused: head tested against an older base
                   │          └─► refused: another PR holds the claim
                   └─► refused: draft, closed, blocked, or unapproved
```

## Step 1 — preflight

Refuses a PR that is closed, a draft, carries the blocked label, or has no
approving review when the config says one is required.

A draft is a *registration*, not a candidate. It exists so other sessions can
see the footprint before there is anything to land.

**Unapproved, and one human.** Nobody can approve their own pull request, so a
single-maintainer repository with `required_approving_review_count: 1` can only
land through `--admin`. `land.sh --admin` is therefore a first-class path: it
steps over the review requirement and **nothing else**. Steps 3 to 7 still run.
This is deliberate — the reason people reach past a tool is that the tool has no
door, and then they skip the six steps that mattered along with the one that
did not.

## Step 2 — claim

Adds the landing label, then reads back every open PR holding it.

**Labels are not atomic.** Two sessions can add the label in the same second and
both believe they hold it. So the read-back is the real decision: the lowest PR
number wins, and the loser removes its own label and stops. That is a resolution
rather than a hope, but it is not a lock — a session that ignores this script
and merges by hand defeats it. The PreToolUse hook is what makes that hard.

**The read-back has to see its own write first.** A label listing that does not
yet contain the label just written is stale, and a stale listing here reads
exactly like "nobody else is claiming" — the one conclusion this step must never
reach by accident. So step 2 waits for its own number to appear before the list
is used for anything, and refuses if it never does.

This is not hypothetical. The read-back originally used `issues?labels=`, which
answers from a search index that lags the write: measured against the repository
this was built for on 25 August 2026, the label was invisible to it at t=0 and correct at t=5, while
`gh pr list --label` had it immediately. The read-back runs milliseconds after
the write, so it returned an empty list every time — the tie-break above was
dead code, and the empty list made the `grep` behind it exit 1 under `pipefail`,
killing the script with no message at all, right after it had taken a claim.

Stuck claim: `land.sh <number> --release-claim`.

## Step 3 — freshness

`compare/<base>...<head>` and refuse anything with `behind_by > 0`.

This is the step the whole plugin exists for. `strict_required_status_checks_policy`
is `false`, so GitHub reports a stale PR as mergeable and its old green check
sits there looking like evidence. It is not evidence: that run never saw the
tree the merge would produce.

Two ways out:

- **Rebase in your own worktree** and force-with-lease. `land.sh` prints the
  commands and does not run them: several sessions share one checkout, and a
  script that ran git somewhere it could not see would be the concurrency bug it
  is meant to prevent.
- **`--update-branch`**, which asks GitHub to update the branch remotely. This
  is **refused when the PR touches a hotspot**, because update-branch resolves
  by merging, and a clean merge is precisely the dangerous case there.

Either way the checks re-run and `land.sh` has to be run again. That is not a
failure; it is the sequence working.

## Step 4 — verify

For each name in `requiredChecks`, find that check on **this** commit and read
its conclusion.

- `success` — ok.
- not completed — refuse. Waiting is not passing.
- `cancelled` — refuse. A run superseded by a later push is cancelled, and
  `gh run watch --exit-status` returns **0** for it. Nothing here uses that
  command.
- absent — refuse. A required check with no run on this commit is a failure, not
  silence. If the run finished in two to four seconds with no steps, the reason
  is usually a billing wall, and it exists only in the annotations:
  `gh api repos/<owner>/<name>/check-runs/<job_id>/annotations`.

Both the check-runs API and the older commit-status API are read, because a
required context can live on either and looking at one of them would produce a
confident wrong answer.

## Step 5 — land

- `backbone: github-merge-queue` — `gh pr merge --auto --squash`. The queue
  builds `main` + everything ahead of this PR into a temporary
  `gh-readonly-queue/...` branch and tests **that**, which is the one guarantee
  no amount of pre-merge checking can give. CI must opt in with a `merge_group:`
  trigger or the queue waits forever. The merge has not happened when this
  returns, so steps 6 and 7 cannot have run: once the queue lands it, run
  `land.sh <n> --post-merge` to get them. That flag needs the pull request
  **merged**, not merely closed — one closed without merging produced no
  commit, so it has no release heading to check and invalidated nobody.
- `backbone: serialized-claim` — squash directly. Steps 3 and 4 have just proved
  freshness and green on this exact head, and the claim has kept anything else
  from landing in between. That is a narrower guarantee than the queue's, and it
  is only as good as the claim being respected.

**When landing merged it itself, nothing has tested the result.** That is the
`serialized-claim` bullet above, and it is also every `--admin` merge on a
repository with no queue. No merge group built the tree that merge produced. On
a repository that also stopped answering a push to the default branch, nothing
tests it at all. `outOfQueueCi` names the workflows to fire in exactly that
case: each one is run against the default branch and the result is printed. On
the queue path it fires nothing, because the merge group already tested that
exact tree and a second run only repeats it.

Leave the key out and nothing is fired, which is what a repository still running
CI on push wants. A config the script **cannot read** is a different answer and
is never printed the same way: it warns. A caller that cannot tell "the key is
absent" from "I could not look" does nothing at all when the config is broken,
and reports that as normal.

## Step 6 — release

Drops the claim, deletes the branch, then asserts the default branch still
contains a heading for the newest tag.

**Why this exists.** A pull request was opened before a release was cut and
edited the same `## [Unreleased]` block. Both sides inserted under one heading, git resolved it
cleanly, GitHub reported MERGEABLE, CI was green, and the squash merge reverted
the release heading. The tag survived; only the file on `main` was wrong, and
nothing noticed.

The file is read from the API and **CRLF is stripped before matching**. A file
stored with Windows line endings otherwise fails the match for a reason that has
nothing to do with the merge.

If the assertion fails the script exits non-zero and says so. Fix it in a
follow-up PR before anything else lands.

## Step 7 — notify

For every other open PR, compare its file list against the merged one. Where
they intersect — or where both sit in the same hotspot — add the needs-rebase
label and comment the reason.

**This is the step that answers the original complaint.** Without it, the other
session learns it was invalidated at its next red CI run, an hour later, with no
explanation attached. With it, the PR carries the reason at the moment it
happens.

## Registration (`register.sh`)

Opens the draft pull request that makes a branch visible, carrying the paths it
expects to touch in a block the ordering analysis reads:

```
<!-- merge-coordinator:footprint
web/src/**
-->
```

It is idempotent: run it again and it rewrites that block on the pull request
that already exists, leaving everything a person wrote around it alone. GitHub
refuses a pull request with no commits between base and head, so a branch that
has none gets an empty commit — which a squash merge drops.

**Why it had to be built.** The Register layer has been named here since the
first day and did nothing at all. Ordering is built from each pull request's
CHANGED FILES, so a session that has not written the code yet contributes to no
rule; a freshly opened draft printed REGISTERED and that was the whole of it.
Two sessions could plan the same files for hours with no way to see each other,
and on the night of 25 August 2026 two of them did, to this tool, twice.

A `PostToolUse` hook on `EnterWorktree` fires it when a session enters a new
worktree. The hook always exits 0: one that can halt a session because GitHub
was slow gets deleted rather than respected, and then the layer is dormant
again. Measured before it was built, with a `Bash` matcher registered alongside
as a control so that "the hook did not fire" could be told apart from "settings
were not reloaded": a matcher does fire on a tool that is not Bash, and a
**refused** tool call fires nothing at all.

## Issue claims (`claims.sh`, `claim-gate.sh`, `guard-claim.sh`)

A pull request **claims** an issue in one of two ways: an `issue: N` line in its footprint block, or
GitHub's own closing reference (`Closes #N`, or a link in the Development sidebar). Any agent writes
the second one without knowing this tool exists, which is why it counts. A title that only names an
issue is a **mention**, and it is never refused. Plan PRs and phase PRs name their issue all the time:
73 pairs in the 958 PRs this was measured on.

`register.sh` writes the claim. `--issue N` sets it. Without that, a single 3–5 digit number in the
branch name gives it, and the line says `(from branch name)`. An update keeps the claim already in
the block unless `--issue` is given again.

When two open pull requests claim the same issue, **the lowest number holds it** and each newer one is
a duplicate. A claim declared as `issue: N part-of #M` is planned work beside another pull request,
and it is never refused.

Three callers read `claims.sh`, so they cannot disagree:

- **`.github/workflows/issue-claim.yml` runs `claim-gate.sh`** on every pull request event, drafts
  included. A duplicate fails the `issue claim` check, gets the `merge:duplicate-claim` label, and
  gets one comment that is edited on later runs. A read that fails also fails the check. A pull
  request's claim can change another's verdict (an older one claims the issue later, or a holder is
  reopened), so every pull request event also runs a second workflow, `issue-claim-others.yml`, on
  `pull_request_target`: GitHub runs that for a pull request with a merge conflict, where it runs no
  `pull_request` workflow, and gives it a token that can re-run checks on a fork's pull request too.
  It re-runs the check on every open pull request whose label disagrees with its verdict, the one
  whose event fired included (`--reconcile`). On a close, it re-runs it on those and on every one that carries the label
  (`--after-close`), so a refused one goes green when its holder leaves. A check that has not finished
  is waited for, then re-run, unless a newer check or a new head commit has replaced it; a re-run that
  fails puts a note on the pull request it was for and fails the job. Runs are found by the pull
  request's head commit, branch and repository together (`mc_claim_runs`, checked live by
  `probe-live.sh`). Re-running a check re-runs `issue-claim.yml` alone, so
  re-runs never set off more. On `merge_group` it passes at once. The plugin ships both workflows as
  `issue-claim.example.yml` and `issue-claim-others.example.yml`.
- **`guard-claim.sh`** is a `PreToolUse` hook on `EnterWorktree`. It refuses a worktree whose name
  carries a claimed issue number, before any work is done twice, and shows whether the holder's
  session is live. It fails open: the check on GitHub is the gate.
- **`queue-state.sh`** shows an ISSUE column (`#N`, `~N`, `DUP #N`) and a SESSION column (`live`,
  `dead`, `unlocked`, `-`) read from this machine's worktree locks.

`land.sh` and `ready.sh` both refuse a pull request that carries the label. `ready.sh --force` does
not step over it.

## Dependabot gate (`deps-open.sh`, `deps.sh`)

A Dependabot pull request that is waiting stops other work from going ready or landing, and the
session asks the user whether to land it first. Before this, sessions ran `ready.sh --force` past
open Dependabot pull requests a dozen times in one repository's land log. The bumps sat until
Dependabot closed them at 168 hours and replaced them in its next weekly run.

**The lister.** `deps-open.sh` reads every open pull request through GraphQL, in pages, not a search
(search lags its writes). A Dependabot pull request is one whose author is a `Bot` with login
`dependabot` (or `dependabot[bot]`). The bot goes by three names: GraphQL says `dependabot`, REST says `dependabot[bot]`,
and `gh pr list --json author` says `app/dependabot`. A filter written against the wrong one matches
nothing. A pull request carrying the blocked label is left out. One in the merge queue, or holding
the landing label, is listed as **landing**. Every other one is **waiting**. Each row carries its
age, the CI on its head (passed, running, failed, skipped, none, or "could not read": a failed
read is never shown as failed, and a head where every check skipped is never shown as passed), and
the `/merge-deps` verdict label if any. `--no-ci` leaves the CI out, which makes it one query: the
raw `gh pr ready` guard and the new-worktree hook use it, because they run against a deadline. It exits 3 and prints nothing when it could not
look.

**The stop.**

| Where | When | Gets past it |
|---|---|---|
| `ready.sh` | after the title and duplicate-claim checks, before the overlap check | `--skip-deps`, `MERGE_COORDINATOR_OVERRIDE=1` |
| `land.sh` | before step 1; not for `--post-merge` or `--release-claim` | `--skip-deps`, `MERGE_COORDINATOR_OVERRIDE=1` |
| `guard-ready.sh` | a raw `gh pr ready`, under its own 20 s limit (`MC_DEPS_TIMEOUT`) | `MERGE_COORDINATOR_OVERRIDE=1`; "later" goes through `ready.sh --skip-deps` |

It stops when a waiting Dependabot pull request exists, and when the lister could not look.
`mc_deps_gate` does not read `--force` or `--admin`, so neither gets past it. A landing one stops
nothing. Neither does the pull request being readied or landed when it is a Dependabot pull request
itself, and that holds when the lister could not look: the pull request is then read directly. `land.sh --dry-run` reports what it would stop on and walks on. Under `--skip-deps` a failed
look is only reported: there is no question left to ask.

`guard-merge.sh` is unchanged. It allows a merge only when the pull request holds the landing label,
and `land.sh` adds that label after this stop.

**"Later" lasts one command.** `--skip-deps` leaves no comment and no record. `ready.sh` also passes
the Dependabot pull requests it was told to put off to `overlap.sh --except=`. Without that, the
overlap check would refuse next, naming the same one, and "later" would turn back into `--force`.
Only the waiting ones are left out. One that is landing still counts as ahead.

**`/merge-deps N`.** `deps.sh N` gathers the facts: each package that moves (from the table and the
"Updates" lines of a grouped pull request, the "Bumps" line of a single one, or the title), from and
to versions, major / minor / patch, the files it changes, the configured fix-ups and pairings that
apply (each file that matches a fix-up is judged on its own; one whose `produces` output, read from
that file's folder, the pull request already changes is reported as carried, not as one to run), the diff of each manifest (lock files left out), how far it is behind, the required checks
on the exact head, and Dependabot's description with its release notes. The session judges. `deps.sh N --record safe|unsafe|fixup "<why>"` sets one
of `deps:safe`, `deps:unsafe` and `deps:needs-fixup` (created on first use, replacing an older one)
and posts one comment naming the head it judged. Given the head sha the facts printed, `--record`
refuses when the pull request has moved since. **A verdict does not stop the pull request from waiting.** Only landing or
closing it does.

**The notice.** `register-hook.sh` (as JSON context, because a hook's plain output never reaches
the session), `register.sh` after its registration report, and `queue-state.sh` under its table list the
open Dependabot pull requests. All three are best effort: a failed look prints "could not check
Dependabot pull requests" with the reason, and the command still succeeds. None open prints
nothing. The hook gives the look 15 s (`MC_DEPS_TIMEOUT`) and runs it `--no-ci`: a hook that runs
past its own timeout is killed and says nothing at all.

## Ordering (`overlap.sh`)

Three ways two PRs are entangled, and one thing that is reported and never
ordered:

1. **Textual** — their changed-file sets intersect.
2. **Hotspot** — both touch a configured hotspot path, *even with no file in
   common*. A merge queue cannot see this: it tests for conflicts, and a hotspot
   is the case where the merge is clean and still wrong.
3. **Dependency** — one head is an ancestor of the other, so the second contains
   the first and must follow it.

**`backbone` decides what a textual overlap costs.** On `serialized-claim` all
three force an order: nothing re-tests between a green run and the merge, so
anyone sharing a file with the merge went stale. On `github-merge-queue` only 2
and 3 force an order — the queue rebuilds and retests against the real base, so
two branches editing one file are both covered and neither has to go first. The
overlap is still reported, under its own heading, with no waiting attached.

Entangled PRs form a chain that lands one at a time. Everything else is
independent and may land in any order.

Chains rank by: hotfix first (`sev:critical`, or a title starting `hotfix` or
`revert`), then whatever unblocks the most other work, then oldest.

**It reads file names, not diffs.** Two PRs editing opposite ends of one file are
reported as entangled even though git would merge them silently. That direction
is chosen: a false "wait" costs minutes, a false "go ahead" costs a release
heading.

**A `rule: alone` hotspot entangles its PR with everything open**, not only with
PRs matching the same pattern. `.github/workflows/**` is the example — a workflow
edit changes what every other run in flight means.

### Declared paths

The fourth signal, and the only one that exists before the code does. A pull
request that declared a footprint is matched two ways: against the real files of
every other pull request, and against what every other pull request declared.
The second is the case the layer exists for — two registrations with no commits,
where the three rules above have nothing to read.

Declarations are computed after the ordering edges and outside the function that
builds them, so nothing can put one into a chain even by accident. **They union
with the real file list and never replace it**: a pull request that declares
`web/**` while actually changing `auth/handler.go` still chains on
`auth/handler.go`. A prediction that could remove a real finding would be worse
than having no prediction at all.

Glob against glob is compared as text in both directions, which catches an
identical declaration and one nested inside a broader one. It is not true glob
intersection and does not pretend to be.

## Testing seams

| Variable | Replaces |
|---|---|
| `MC_CONFIG` | the path to `.github/merge-coordinator.json` |
| `MC_GH` | the `gh` binary — a fixture script replaying canned JSON |
| `MC_OVERLAP_INPUT` | the gathered records, so the ordering analysis runs with no network at all |
| `MC_NOW` | the clock `deps-open.sh` measures ages against |

Every rule runs identically under these; they replace the inputs, never the
logic. `scripts/test-*.sh` uses them.
