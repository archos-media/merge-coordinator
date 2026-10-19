# Changelog

Every release of merge-coordinator, newest first. A release is a tag
`vN.N.N` matching `version` in `.claude-plugin/plugin.json`, and its heading
here is `## [vN.N.N]`, the form this repository's own release guard looks for.
The section under it is published as that tag's GitHub Release, and CI
fails a pull request whose version has no section.

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
