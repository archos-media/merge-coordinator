# Changelog

Every release of merge-coordinator, newest first. A release is a tag
`vN.N.N` matching `version` in `.claude-plugin/plugin.json`, and its heading
here is `## [vN.N.N]`, the form this repository's own release guard looks for.
The section under it is published as that tag's GitHub Release, and CI
fails a pull request whose version has no section.

## [v0.5.4]

- **Fixed:** without a merge queue, `/merge-status` showed a pull request that
  was behind and conflicted with the base as "behind N", with its old green
  beside it. A conflicting branch runs no CI, so that green meant nothing. The
  column now reads `CONFLICT`, and the footer says it needs a rebase by hand.

## [v0.5.3]

- **Docs:** the README opens with a short demo: two pull requests write the
  same changelog block, one lands as a release, and the plugin stops the other
  until its entry is re-added by hand.

## [v0.5.2]

- **Tests:** all three usage-error cases for `claim-gate.sh --reconcile` in
  `test-claims.sh` now check that nothing is re-run. Only the first checked it
  before.

## [v0.5.1]

- **Fixed:** `config.example.json` and the adoption guide now include
  `ciWorkflow`, the file name of the workflow that runs CI on pull requests.
  `/merge-ready` and the report after a land both read it, and a config copied
  from the example used to lack it. A new suite, `test-config-keys.sh`, fails
  when a script requires a key the example leaves out.
- **Changed:** the report after a land (`queue-cost.sh`) no longer reads a job
  named "Already proven" for cache lines. That job belonged to one repository's
  CI; everywhere else the report printed "could not read" for every merge
  group. It still reports the minutes on the pull request and on the queue.
- **Changed:** `actions/checkout` is pinned to v7.0.1 (Node 24) in this
  repository's workflow and in both example workflows.
- **Docs:** the adoption guide no longer says "here" about measurements taken on
  another repository; the test loop in the README and CONTRIBUTING now exits
  non-zero when a suite fails; small corrections in the skill and commands.

## [v0.5.0]

The first public release, under the Apache License 2.0.

- **Register:** a draft pull request opened when work starts, declaring the
  paths it expects to touch, so other sessions see it before any code exists
  (`/merge-register`, and by itself on entering a worktree).
- **Order:** `/merge-ready` takes a pull request out of draft only once no
  other ready one touches the same files or hotspots. `/merge-status` shows
  everything in flight, whose checks really passed, and who holds the claim.
- **Land:** `/merge-land` runs an idempotent sequence: preflight, claim,
  freshness, verify on the exact head commit, land through GitHub's merge
  queue or by squash, check the newest release heading survived, and tell
  every open pull request the landing affected, with the reason.
- **Dependabot:** a waiting Dependabot pull request stops other readies and
  landings until the session asks; `/merge-deps` reviews one and acts on it.
- **Hooks:** a bare `gh pr merge`, a non-draft `gh pr create` and a bare
  `gh pr ready` are refused in a repository that has opted in; a worktree for
  an issue another pull request has claimed is refused; a pinned copy of the
  plugin in another repository cannot be edited, and a session is told when
  one is behind the latest release.
- **Issue claims:** example workflows that fail a second pull request for an
  issue another one already claims.
- **Pinned copies:** `vendor.sh` and `check-vendored.sh`, for repositories
  whose CI or other agents need the scripts.
- **Checks:** offline test suites for every script, `probe-live.sh` for the
  GitHub API reads, and CI that validates the plugin and installs it clean.
