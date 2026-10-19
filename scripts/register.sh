#!/usr/bin/env bash
# Registration: make this session visible to every other one, before it has
# anything to land.
#
# The Register layer has been named in SKILL.md since the first day and has
# never done anything. Ordering is built from each pull request's CHANGED
# FILES, so a session that has not written the code yet contributes nothing to
# it, and two sessions can plan the same files for hours with no way to see
# each other. That is not hypothetical: it happened to this tool on the night
# of 25 August 2026, twice.
#
# This opens the draft pull request that makes a session visible, and carries
# the issue it claims and the paths it expects to touch in a block that the
# ordering analysis and the issue-claim check read:
#
#   <!-- merge-coordinator:footprint
#   issue: 12
#   web/src/**
#   -->
#
# Things it is careful about.
#
#   - It is IDEMPOTENT. Run it again and it updates the block on the pull
#     request that already exists. Nothing here opens a second one.
#   - A declared path is a PREDICTION. overlap.sh reports it and never orders on
#     it, and it never replaces the real file list. Being wrong in the body of
#     a pull request must not be able to reorder somebody else's work.
#   - The issue CLAIM is not a prediction. The issue-claim check refuses a second
#     open pull request that claims the same issue. With no --issue, the
#     number comes from the branch name, and it says so, because a guess can be
#     wrong.
#
# Usage:
#   register.sh                        register this branch, declaring no paths
#   register.sh web/src/** go/feed/**  register, declaring these paths
#   register.sh --issue 12             claim this issue
#   register.sh --issue 12 --part-of 40
#                                      claim it as planned work beside #40
#   register.sh --title "..."          set the title as well
#   register.sh --dry-run              print what it would do, change nothing
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# Before anything else, and in THIS shell rather than in a subshell that cannot
# stop the script. See mc_require_config in lib/gh.sh.
mc_require_config

OPEN_MARK="<!-- merge-coordinator:footprint"
CLOSE_MARK="-->"

title=""
paths=""
issue=""
part_of=""
dry_run=0

# number_arg <option> <value> — the value, when it is a number.
number_arg() {
	case "$2" in
	"" | *[!0-9]*) mc_die "$1 needs a number, not '$2'." ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
	--title)
		[ $# -ge 2 ] || mc_die "--title needs a value."
		title="$2"
		shift 2
		;;
	--issue | --part-of)
		[ $# -ge 2 ] || mc_die "$1 needs a number."
		number_arg "$1" "$2"
		if [ "$1" = "--issue" ]; then issue="$2"; else part_of="$2"; fi
		shift 2
		;;
	--dry-run)
		dry_run=1
		shift
		;;
	--help | -h)
		sed -n '2,40p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	-*)
		mc_die "unknown option $1"
		;;
	*)
		paths="$paths$1
"
		shift
		;;
	esac
done

# Same shape as land.sh, and local for the same reason: a dry run has to reach
# every write, or it proves nothing about the one that matters.
mc_do() {
	if [ "$dry_run" -eq 1 ]; then
		echo "would run: $*"
		return 0
	fi
	"$@"
}

repo=$(mc_repo)
base=$(mc_cfg_get defaultBranch)
branch=$(git rev-parse --abbrev-ref HEAD)

if [ "$branch" = "$base" ] || [ "$branch" = "HEAD" ]; then
	mc_die "refusing to register $branch. Registration is for a branch of your own;
  on $base there is nothing to declare and nothing to open a pull request for."
fi

# --------------------------------------------------------------------------
# The issue claim
# --------------------------------------------------------------------------
# An explicit --issue wins. Without one, the branch name gives the number when
# it holds exactly one. The line records where the number came from, so a
# person reading the pull request can see that it was a guess.
issue_explicit=0
issue_source=""
if [ -n "$issue" ]; then
	issue_explicit=1
else
	issue=$(mc_issue_from_name "$branch")
	[ -n "$issue" ] && issue_source=" (from branch name)"
fi

issue_line=""
if [ -n "$issue" ]; then
	issue_line="issue: $issue"
	[ -n "$part_of" ] && issue_line="$issue_line part-of #$part_of"
	issue_line="$issue_line$issue_source"
elif [ -n "$part_of" ]; then
	mc_die "--part-of needs an issue, and the branch name $branch does not give one. Add --issue <number>."
fi

# show_body — under --dry-run, print the body that would be written.
#
# A dry run that says "would run: gh pr edit --body-file /tmp/xyz" has told you
# nothing: the interesting half is the file, and it is deleted on the way out.
# This is also the only way to check the round trip - that what register.sh
# writes is what mc_pr_footprint can read back.
show_body() {
	[ "$dry_run" -eq 1 ] || return 0
	echo "--- body it would write ---"
	cat "$1"
	echo "--- end of body ---"
}

# write_block — the footprint block on stdout, issue claim and paths.
write_block() {
	printf '%s\n' "$OPEN_MARK"
	if [ -n "$issue_line" ]; then
		printf '%s\n' "$issue_line"
	fi
	if [ -n "$paths" ]; then
		printf '%s' "$paths"
	else
		printf '%s\n' "# No paths declared yet. Add one glob per line, then run"
		printf '%s\n' "# register.sh again to update this block."
	fi
	printf '%s\n' "$CLOSE_MARK"
}

# report_claim — say what this registration claims, and how to change it.
report_claim() {
	if [ -z "$issue" ]; then
		echo "  No issue claimed: the branch name gives no single issue number."
		echo "  To claim one: bash $here/register.sh --issue <number>"
	elif [ "$issue_explicit" -eq 1 ]; then
		echo "  Claims issue #$issue."
	else
		echo "  Claims issue #$issue, read from the branch name. If that is wrong:"
		echo "    bash $here/register.sh --issue <number>"
	fi
}

# deps_notice — the open Dependabot pull requests, after the registration report, so
# the session knows before it goes to ready its own work. register-hook.sh
# sets MC_DEPS_NOTICE=off and hands the list to the session itself, because a
# hook's plain output never reaches it.
deps_notice() {
	local said
	[ "${MC_DEPS_NOTICE:-}" = off ] && return 0
	said=$(mc_deps_notice)
	[ -n "$said" ] || return 0
	echo
	printf '%s\n' "$said"
}

# --------------------------------------------------------------------------
# Is there already one for this branch?
# --------------------------------------------------------------------------
# Asked by head branch, not by a label. The label index lags its own write by
# about five seconds here - measured 25 August, and the reason the claim
# read-back was blind for exactly the window it exists to cover.
#
# `sed -n 1p`, never `head -1`. head stops reading at its line and closes the
# pipe under a producer that is still writing; the producer dies of SIGPIPE and
# pipefail makes 141 the status of the whole pipeline. sed reads to the end.
existing=$(mc_gh pr list --repo "$repo" --head "$branch" --state open \
	--json number --jq '.[].number' | sed -n '1p' || true)

body_file=$(mktemp)
current=$(mktemp)
block=$(mktemp)
trap 'rm -f "$body_file" "$current" "$block"' EXIT

if [ -n "$existing" ]; then
	# Rewrite only the block, keeping whatever a person wrote around it.
	mc_gh api "repos/$repo/pulls/$existing" --jq '.body // ""' >"$current"
	write_block >"$block"

	# The claim already in the block survives a run with no --issue. A session
	# that corrected a wrong guess with --issue, then re-declares its paths,
	# must not get the guess back.
	MC_CURRENT="$current" MC_BLOCK="$block" MC_OUT="$body_file" \
		MC_ISSUE_EXPLICIT="$issue_explicit" mc_py -c '
import io, os

with io.open(os.environ["MC_CURRENT"], encoding="utf-8") as fh:
    body = fh.read()
with io.open(os.environ["MC_BLOCK"], encoding="utf-8") as fh:
    block = fh.read().rstrip("\n")

OPEN, CLOSE = "<!-- merge-coordinator:footprint", "-->"

def is_issue(line):
    return line.strip().lower().startswith("issue:")

start = body.find(OPEN)
if start >= 0 and os.environ["MC_ISSUE_EXPLICIT"] != "1":
    old_end = body.find(CLOSE, start + len(OPEN))
    if old_end >= 0:
        kept = [l.strip() for l in body[start + len(OPEN):old_end].splitlines() if is_issue(l)]
        if kept:
            lines = block.split("\n")
            block = "\n".join([lines[0], kept[0]] + [l for l in lines[1:] if not is_issue(l)])

if start < 0:
    out = body.rstrip("\n") + "\n\n" + block + "\n"
else:
    end = body.find(CLOSE, start + len(OPEN))
    if end < 0:
        # Opened and never closed. Replacing to the end of the body would eat
        # whatever a person wrote after it, so this stops instead.
        raise SystemExit("merge-coordinator: the footprint block on this pull request is opened and never closed. Fix it by hand.")
    out = body[:start] + block + body[end + len(CLOSE):]

with io.open(os.environ["MC_OUT"], "w", encoding="utf-8", newline="\n") as fh:
    fh.write(out)
'

	# An EMPTY --body-file BLANKS the pull request body outright, so the test
	# and the write are one statement. There is no path here that reaches the
	# write with an empty file.
	if [ -s "$body_file" ]; then
		show_body "$body_file"
		# --title on an existing pull request used to be dropped here, with exit
		# 0 and the PR url printed. EnterWorktree always opens the PR first, so
		# that was the normal case, and the squash commit took the branch name.
		# No --title leaves the title alone: it is never reset to the branch.
		if [ -n "$title" ]; then
			mc_do mc_gh pr edit "$existing" --repo "$repo" --title "$title" --body-file "$body_file"
		else
			mc_do mc_gh pr edit "$existing" --repo "$repo" --body-file "$body_file"
		fi
	else
		mc_die "the rewritten body came out empty, so it was not written. An empty
  --body-file blanks the body of the pull request instead of leaving it alone."
	fi

	# Read the title back. An exit status is not proof that the write landed.
	if [ -n "$title" ] && [ "$dry_run" -eq 0 ]; then
		got_title=$(mc_gh pr view "$existing" --repo "$repo" --json title --jq '.title' 2>/dev/null || true)
		[ "$got_title" = "$title" ] || mc_die "the body of #$existing was updated, but its title reads '$got_title', not '$title'.
  Set it:        gh pr edit $existing --title \"$title\"
  Read it back:  gh pr view $existing --json title"
	fi

	echo "merge-coordinator: #$existing already registers $branch; declared paths updated."
	[ -z "$title" ] || echo "  Title set: $title"
	echo "  https://github.com/$repo/pull/$existing"
	deps_notice
	exit 0
fi

# --------------------------------------------------------------------------
# Nothing open for this branch yet
# --------------------------------------------------------------------------
# GitHub refuses a pull request with no commits between base and head, and a
# branch created seconds ago has none. An empty commit is the whole cost of
# being visible, and a squash merge drops it.
if [ -z "$(git log --oneline "origin/$base..HEAD" 2>/dev/null || true)" ]; then
	mc_do git commit --allow-empty -m "register: $branch

Opens the draft pull request that makes this branch visible to other sessions
before it has anything to land. Squashed away at merge."
fi

mc_do git push -u origin "$branch"

# The issue number goes first in the title, so a list of pull requests shows
# the claim without opening each one. It is still a placeholder: set a real
# title before ready.sh, because the squash commit on main uses it.
if [ -z "$title" ]; then
	title="$branch"
	[ -n "$issue" ] && title="#$issue $branch"
fi

{
	printf '%s\n\n' "Registered by the merge coordinator. **Draft on purpose** — this branch is claimed, not finished."
	printf '%s\n' "The block below is what \`overlap.sh\` reads to warn another session that it is"
	printf '%s\n' "about to work the same ground, and what the issue claim check reads to refuse a"
	printf '%s\n' "second pull request for the same issue. The paths are a prediction: they add a"
	printf '%s\n\n' "warning, never remove one, and never change the landing order."
	write_block
} >"$body_file"

if [ -s "$body_file" ]; then
	show_body "$body_file"
	mc_do mc_gh pr create --repo "$repo" --draft --base "$base" --head "$branch" \
		--title "$title" --body-file "$body_file"
else
	mc_die "the pull request body came out empty, so nothing was opened."
fi

echo "merge-coordinator: $branch is registered."
report_claim
deps_notice
