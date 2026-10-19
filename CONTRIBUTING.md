# Contributing

## How this code is made

Most of merge-coordinator is written by AI agents (Claude, by Anthropic),
working as Archotron, Archos Media's agent setup. A person at Archos Media
decides what is built and what lands.
Commits name the model that helped in a `Co-Authored-By:` line.

## What is welcome

- **Bug reports with a reproduction.** These help most. Use the bug form.
- **Small fixes with a test.** One change per pull request.
- **Anything larger: an issue first.** The scope is kept narrow on purpose
  (GitHub, Claude Code, the landing sequence and what it needs), so agree on
  the change before building it.

AI-assisted contributions are welcome on three conditions:

1. Say so, with an `Assisted-by:` or `Co-Authored-By:` line in the commit.
2. A person has read the change and run it.
3. That person answers for it in review.

Pull requests and reports that read as unreviewed AI output are closed.

## Making a change

- **Run the offline suites** before you push. They need bash, git, Python 3
  and `gh` on the path, but no network and no GitHub login. On Windows, use
  Git Bash.

  ```sh
  for t in scripts/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
  ```

- **Raise the version.** Every change to a file outside the top-level
  `README.md` and `.github/` raises `version` in `.claude-plugin/plugin.json`,
  because an installed plugin updates only when that number changes. CI fails
  a pull request that doesn't (`scripts/check-version-bump.sh`).
- **Add a line to `CHANGELOG.md`**, under the `## [vN.N.N]` heading for the
  version you set, adding the heading if your change raised the version (the
  heading alone on its line: no date after it). That
  section becomes the version's GitHub Release, and CI fails a pull request
  whose version has none.
- **Changed a `--jq` filter?** Run `scripts/probe-live.sh` from inside a
  repository that has adopted the plugin. It is read-only, and it is the only
  check that talks to the real GitHub API.
- **No carriage returns.** Files are stored with LF line endings, and CI
  refuses a CR anywhere: a stray one has broken a guard on Linux before while
  every suite passed on Windows.

Pull requests here land through the plugin's own landing sequence
(`/merge-land`).

## Licence

Contributions are made under the [Apache License 2.0](LICENSE): anything
you submit for inclusion is licensed under it (section 5), with no further
terms.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
