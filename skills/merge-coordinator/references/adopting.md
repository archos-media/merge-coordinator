# Adopting this in another repository

The plugin holds nothing about any particular repository. Everything specific
lives in one config file. Adoption is: install the plugin once, write the
config, create three labels.

## 1. The plugin

It lives in its own repository, `archos-media/merge-coordinator`, which is also
its marketplace. Install it once per machine, at user scope, and every project
has it:

```
claude plugin marketplace add archos-media/merge-coordinator
claude plugin install merge-coordinator@merge-coordinator --scope user
```

Installed everywhere is safe because it is inert by default. In a repository
with no `.github/merge-coordinator.json` every hook exits at once and every
script refuses to run, so a project that has not adopted it sees nothing.

Updates do not arrive on their own for a marketplace like this one: run
`claude plugin update merge-coordinator@merge-coordinator`.

## 1b. A copy in the repository, when something other than Claude needs it

**Only Claude Code sessions see an installed plugin.** A GitHub Actions runner
(the issue-claim check) and an agent from another vendor (AGENTS.md pointing at
`register.sh`) do not. A repository that needs either carries a pinned copy:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/vendor.sh" v0.5.3     # from inside the repository
```

That copies the release into `tools/merge-coordinator/`, writes
`.github/merge-coordinator.vendor` (the release, its commit, and the blob of
every file), and stages both. Commit them on a branch. Workflows then call
`tools/merge-coordinator/scripts/...`.

To move a copy to a new release, run the same command, from the INSTALLED
plugin, never the copy's own `tools/merge-coordinator/scripts/vendor.sh`: the
copy is deleted, that script with it, before the new one is written.
`vendor.sh` refuses to run from inside the copy it would replace.

For the issue claim check, copy `issue-claim.example.yml` and
`issue-claim-others.example.yml` from the plugin to
`.github/workflows/issue-claim.yml` and `issue-claim-others.yml`. The first
checks each pull request; the second re-checks the others whose verdict that
one's claim changed, and the refused ones when a pull request closes. Once
copied the files are the repository's own: a release that changes a template
says so, and the copy is updated by hand.

Never put the copy under `.claude/skills/`: Claude Code loads a plugin it finds
there, and it would run beside the installed one, every hook twice. `vendor.sh`
refuses.

A copy cannot drift, by construction:

- **Edited in place:** add one step to CI,
  `bash tools/merge-coordinator/scripts/check-vendored.sh`. It compares the copy
  with the stamp, offline, and names every changed, added or missing file. The
  plugin's `guard-vendored-edit.sh` refuses a Claude edit inside the copy before
  it happens. A change belongs in this repository, then a release, then
  `vendor.sh <new tag>`.
- **Left behind:** when a session starts in, or enters a worktree of, a
  repository with a copy, `vendor-status.sh` says if a newer release exists, or
  if the installed plugin is behind. A session that starts in a folder that is
  not a repository gets the same for each repository one folder below it that
  carries a copy.
  Silent when current; never silent when it could not check.

The copy's own test suites do not need to run in the consuming repository:
they ran here, against this release, before it was tagged.

## 2. The config

Copy `config.example.json` to `.github/merge-coordinator.json` and edit it.

- **`requiredChecks`** must be the exact check names your branch protection
  requires, character for character. Get them from the ruleset, not from
  memory: a typo here means the name is never found, and a name that is never
  found is treated as a failure, so a typo shows up as "this will never land"
  rather than as a silent pass. That direction is intended.
- **`ciWorkflow`** — the file name of the workflow that runs CI on pull
  requests (`ci.yml`, not its display name). `/merge-ready` reads its runs to
  say where a pull request ahead of yours stands, and the report after a land
  reads them to say what the land cost.
- **`backbone`** — `github-merge-queue` only once the queue actually exists
  (see below). Setting it early is worse than leaving it: `gh pr merge --auto`
  against a repository with no queue merges as soon as the checks pass, which
  skips the speculative test the setting is claiming to use.
- **`hotspots`** — the paths where a *clean* textual merge is the dangerous
  case. Ask what is generated (`vendor/`, lockfiles, `dist/`), what is numbered
  at merge time (migrations), and what is appended to by everybody
  (`CHANGELOG.md`, a registry file). Write down *why* for each: the reason is
  what lets someone argue with the rule later instead of just deleting it.
- **`requireApproval`** — match what protection actually requires.
- **`outOfQueueCi`** — optional, and only needed once you stop running CI on a
  push to the default branch (see below). It names the workflow files to fire
  after landing merges a PR *itself*, with no queue in front of it. Leave the
  key out and nothing is fired.
- **`dependabot`** — optional. `/merge-deps` reads it when it reviews a
  Dependabot pull request. `fixups` names a command that must run when a file
  changes. `pairings` names two packages that must move together:

  ```json
  "dependabot": {
    "fixups":   [{ "when": "go/go.mod", "run": "cd go && go mod vendor", "produces": "vendor/**", "why": "vendored modules must match go.mod" }],
    "pairings": [{ "package": "next", "with": "eslint-config-next", "why": "keep the lint config on the same major as next" }]
  }
  ```

  `when` is matched against the whole path from the repository root, so
  `go.mod` means a go.mod at the root; `**/go.mod` means one in any folder
  below the root (not the root itself). `*` crosses directories, as in
  `hotspots`. `/merge-deps` names each fix-up whose `when` matched nothing, so
  a pattern that never matches shows, and judges each file that matched on
  its own.

  `produces`, optional, names the files the fix-up writes, in the same glob
  form, read from the folder of the file that matched `when`: above,
  `vendor/**` means `go/vendor/**`. Dependabot regenerates some outputs in
  the same commit as the manifest: where a repository commits `vendor/`, a
  `go.mod` bump brings it too. When the pull request already changes a file
  matching `produces`, `/merge-deps` reports the fix-up as carried rather
  than as one to run. The file that matched `when` and lock files
  (`go.sum`, `package-lock.json` and the like) never count, since Dependabot
  changes them on every bump. Without `produces`, `/merge-deps` names the
  fix-up as one to run on every bump that touches `when`, even when the bump
  already carries its output, and the session is led to record needs-fixup
  for nothing. So give `produces` for any output Dependabot may write itself,
  as narrow as the files the command writes. "Carried" trusts that what came
  along is complete; a required check that fails on a stale output (in Go,
  a build with `-mod=vendor`) is what backs that up.

  Leave the block out and the Dependabot stop still works. `/merge-deps` then
  reports no fix-ups and no pairings.

## 2b. Registration

Nothing to configure. `register.sh` opens the draft pull request and
`hooks/hooks.json` fires it from a `PostToolUse` matcher on `EnterWorktree`; a
repository that creates branches some other way should point that matcher at
whatever its sessions actually run, or drop the hook and let people run
`/merge-register` by hand.

One thing to know before turning it on: **it opens a pull request per worktree**,
including throwaway ones. That is cheap only if drafts run no CI — see section 5.
Turn that on first, or registration becomes the largest CI bill in the
repository rather than the thing that prevents one.

## 3. The labels

Three, named in the config:

| Label | Means |
|---|---|
| `merge:landing` | this PR holds the claim; nothing else may land |
| `merge:blocked` | somebody stopped this on purpose |
| `merge:needs-rebase` | something landed underneath it |

And three more that `/merge-deps` creates the first time it records a verdict on
a Dependabot pull request. They are fixed names, not config:

| Label | Means |
|---|---|
| `deps:safe` | reviewed; safe to land |
| `deps:unsafe` | reviewed; close it and tell Dependabot to ignore it |
| `deps:needs-fixup` | reviewed; the bump needs a change it does not carry |

A verdict does not stop the pull request from holding up other work. Only
landing it or closing it does.

## 4. Without a merge queue

GitHub's merge queue is not available to every repository or plan. Without it,
set `backbone: serialized-claim` and the guarantee narrows to:

> the claim keeps anything else from landing while step 3 proves this head is
> current and step 4 proves the named checks passed on it.

That covers the reported problem — a landing invalidating another session's
green — but it does **not** cover the case a queue exists for: a merge that is
individually fine and broken in combination with the one before it. Those show
up as a red build on the default branch afterwards, not as a refused merge.

If a queue is available, turning it on takes three things, and it does not work
with one missing:

1. `merge_group:` added to the `on:` trigger of every workflow producing a
   required check. Without it the queue waits for a check that will never run.
2. The concurrency group must not cancel merge-group runs. A `cancel-in-progress`
   expression written as `github.ref != 'refs/heads/main'` evaluates **true** for
   a `gh-readonly-queue/...` ref, so the queue's own run gets cancelled and the
   queue hangs. Gate on `github.event_name == 'pull_request'` instead.
3. Any path-classifier reading `github.event.pull_request.base.sha ||
   github.event.before` gets **neither** under `merge_group`, so the diff base is
   empty and the job falls back to running everything, on every queue entry. Add
   `github.event.merge_group.base_sha`. This is a cost bug rather than a
   correctness one, and on a metered Actions budget it is the one that hurts.

Then, once the queue is carrying the merges:

4. **A `push:` trigger on the default branch has become a duplicate.** The queue
   tested the exact tree the merge produces; the push run tests that same tree
   again and learns nothing. It does not cover the intermediate commits of a
   batch either — it only ever sees the final head. On the repository this
   plugin was built for, that was 192 CI-minutes in one day, about 30% of the
   total, for no information.

   Before dropping it, check that nothing *consumes* a green run on the default
   branch — a deploy keyed to a successful CI run, a badge, a scheduled job
   reading the last conclusion. Then set `outOfQueueCi` to cover the merges that
   skip the queue, which is the whole reason the trigger looked load-bearing.

## 5. Drafts, and the check that passes with nothing behind it

A draft PR is registration, not a request to test anything, and testing every
push to one is often the largest avoidable cost. Two changes turn it off:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
```

and, on **every** job, `if: github.event_name != 'pull_request' ||
github.event.pull_request.draft == false`. Marking the PR ready fires
`ready_for_review`, so the first real run happens the moment the PR asks to be
read.

**The trap is the aggregate job.** A gate that requires every upstream job to
have "passed or been skipped" is the standard way to write one, and it is
correct — a job skipped by a path filter must not block. Put the draft condition
on the build jobs alone and that gate still runs, sees everything skipped, and
reports **`success` on a pull request that tested nothing** — a conclusion no
reader and no tool can tell apart from a real green.

So the condition goes on the aggregate job too, including the one that reports
the required check.

**What that actually produces, measured rather than assumed.** A job that a
job-level `if` skips still publishes a check run: conclusion `skipped`, status
`completed`. Turning CI off for drafts does not make the checks disappear. On a
draft in the repository this plugin was built for, all seven of its check runs
are present and every one of them is `skipped`;
`gh pr checks` prints `skipping`. The gain is not silence, it is that `skipped`
is visibly not `success` — `land.sh` step 4 refuses it as "a check that is
missing, running, cancelled or failed is not a pass", and so does anyone reading
the pull request.

**Branch protection blocks on it too, measured on that repository rather than
assumed.** With its required check `CI passed` reporting `skipped` on the head and the other
required check already green, the pull request read `mergeStateStatus=BLOCKED`;
when that same check turned `success` with nothing else changed, it read `CLEAN`.
The two non-required jobs still running at the first reading cannot account for
it. So on that ruleset a skipped required check is not a pass.

That is the behaviour you want, and it is worth confirming on your own
repository rather than inheriting the claim: the rule that a skipped check
satisfies protection is widely repeated, and if it held, a pull request
marked ready would be mergeable in the window before its first real run
registers. It is also why the condition must go on the aggregate job. Left off,
that job reports `success` — a real pass, which every protection rule accepts
and no reader can distinguish from a tested one.

## 6. Check it works

**Run `scripts/probe-live.sh` first.** The `test-*.sh` suites are offline,
and the stand-in `gh` does not implement `--jq` — so every value they assert on
is one no filter ever selected. The probe runs the same helpers against your
real repository with no stand-in, which is the only way those filters get
checked. It is read-only: every call is a GET, and it labels, comments, merges
and creates nothing. It is safe to run with work in flight.

Its expectations about your history live in your repository, not in the
plugin. Copy `probe.example.json` to `.github/merge-coordinator-probe.json` and
point it at your own history: a merged PR whose file count is now fixed and
whose head is green, a commit from before your first workflow existed, a PR
that declares a footprint and one that does not. Any key you leave out is
reported N/M, so a half-filled file runs; it just proves less. Run the probe
from inside the repository: it probes whichever one you are standing in.

**Read the third column.** An assertion passes, fails, or is `N/M` — not
measurable. Pinning an expectation to history that has already happened does not
make it permanent: GitHub collects a commit that no branch reaches, and check-run
data expires on its own retention, so a fixture can stop being readable with
nothing having regressed. A few assertions need live state instead — an open
pull request carrying a label — which is simply absent on a quiet day. Those are
listed at the end with what to repoint, they are counted apart from the failures,
and they do not set the exit status. **`N/M` is not a pass:** nothing was
measured. It only means that a red line, when you see one, is worth reading —
which is the whole point of the split.

Where the two can be told apart, the probe keeps "I could not look" apart from "I
looked and it was not there". A check-state read that comes back empty for a
commit the runs API says ran something is a broken read, and it still fails.

It earns its keep. Run against the repository it was built for, it found that the release guard reported
**every** heading missing: `printf | grep -qF` under `set -o pipefail` returns
141, because grep matched, stopped, and closed the pipe under a printf still
writing a megabyte. Every fixture was thirty bytes and passed.

Then, and only then — do not trust a dry run. On a throwaway branch prefix:

1. Two branches editing the same file. Land one; confirm the other is labelled
   and commented within the same run.
2. Two branches with disjoint files. `overlap.sh` must call them independent and
   both must land without either invalidating the other.
3. A branch touching a hotspot alongside another that touches the same hotspot
   but shares no file. `overlap.sh` must still serialize them.
4. Land something underneath an open PR and confirm step 3 catches the staleness
   instead of trusting the old green.
5. Point step 4 at a **cancelled** run and confirm it reports failure.
