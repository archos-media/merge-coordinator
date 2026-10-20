#!/usr/bin/env bash
# What is in flight right now: every open PR, whether it is fresh, whether its
# required checks actually passed on its current head, and who holds the claim.
#
# THE MIDDLE COLUMN CHANGES WITH `backbone`, because the thing worth reporting
# does.
#
# On serialized-claim it is FRESHNESS. Where `strict_required_status_checks_policy`
# is false (GitHub's default), GitHub will happily report a PR as mergeable when
# its green run was produced against a main that no longer exists. "behind N"
# means exactly that: N commits have landed since this PR was tested, and its
# green says nothing about the tree it would produce. A branch that is behind
# and also conflicts reads CONFLICT instead.
#
# On github-merge-queue it is MERGE. The queue rebuilds and retests against the
# real base, so "behind N" is not a problem and reporting it as one is how every
# session ends up rebasing for nothing. What still stops a landing is a branch
# git cannot merge, so that is what the column shows.
#
# The check column is read per required name on the head commit, through
# mc_require_checks — so a cancelled run, a run on an older commit, and a check
# that never appeared all read as "not passing" rather than as silence.
#
# The one thing that is NOT reported as a problem there is a draft whose checks
# all skipped: drafts run no CI here, so that is the design working. It reads
# "no CI". A READY pull request in the same state still reads SKIPPED.
#
# Usage:  queue-state.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# Before anything else, and in THIS shell rather than in a subshell that cannot
# stop the script. See mc_require_config in lib/gh.sh.
mc_require_config

base=$(mc_cfg_get defaultBranch)
backbone=$(mc_cfg_get backbone)
landing_label=$(mc_cfg_get labels.landing)
blocked_label=$(mc_cfg_get labels.blocked)
rebase_label=$(mc_cfg_get labels.needsRebase)

echo "merge-coordinator: open pull requests against $base   (backbone: $backbone)"
echo

rows=$(mc_open_prs)
if [ -z "$rows" ]; then
	echo "  nothing open."
	exit 0
fi

holder=""
# Pull requests behind the base whose conflict state GitHub did not give.
unread=""

# Two columns about people, not commits.
#
# ISSUE comes from claims.sh, which reads every open pull request in one call.
# It is the same answer the issue claim check gives on GitHub. When it cannot be
# read, the column shows "?", the footer says so, and the rest of the report
# still prints.
#
# SESSION comes from this machine's worktrees and their locks. See
# mc_session_state in lib/gh.sh.
claims_ok=1
claims=$(bash "$here/claims.sh" 2>/dev/null) || claims_ok=0
worktrees=$(mc_worktrees)

# issue_for <number> — the ISSUE column for one pull request.
issue_for() {
	local n col verdict
	if [ "$claims_ok" -ne 1 ]; then
		echo "?"
		return 0
	fi
	while IFS=$'\t' read -r n col verdict; do
		if [ "$n" = "$1" ]; then
			printf '%s\n' "$col"
			return 0
		fi
	done <<CLAIMS
$claims
CLAIMS
	echo "-"
}

# The middle column answers whichever question the backbone makes load-bearing.
# On a queue "behind 3" is not a problem to report — the queue rebuilds and
# retests — so the column reports whether git can merge the branch at all, which
# is the thing that does stop a landing there.
if [ "$backbone" = "github-merge-queue" ]; then
	middle="MERGE"
else
	middle="FRESHNESS"
fi
printf '  %-6s %-9s %-11s %-9s %-9s %-11s %s\n' "PR" "STATE" "$middle" "CHECKS" "ISSUE" "SESSION" "TITLE"

# all_checks_skipped <mc_require_checks output> — true when it reported at
# least one required check and every one of them skipped.
#
# Read line by line rather than `printf | grep -q`. These scripts set pipefail,
# and grep -q closes the pipe at its first match, so the writer dies of SIGPIPE
# and 141 becomes the pipeline's status. Used in a negated test that turns a
# match into "no match" — the same trap the test file's own contains() and the
# awk in mc_require_checks are written against.
#
# The prefixes are anchored at the start of the line, so a check NAMED "ok to
# merge" cannot make its own SKIPPED line look like a passing one. The
# continuation lines under MISSING and NONE are indented past all of these and
# match nothing, which is what we want.
all_checks_skipped() {
	local line skipped=0
	while IFS= read -r line; do
		case "$line" in
		"  SKIPPED "*) skipped=$((skipped + 1)) ;;
		"  ok "* | "  MISSING "* | "  RUNNING "* | "  CANCELLED "* | "  FAILED "* | "  NONE "*)
			return 1
			;;
		esac
	done <<EOF
$1
EOF
	[ "$skipped" -gt 0 ]
}

while IFS=$'\t' read -r number title draft head labels; do
	[ -z "$number" ] && continue

	state="ready"
	case ",$labels," in
	*",$landing_label,"*)
		state="LANDING"
		holder="$number"
		;;
	esac
	case ",$labels," in
	*",$blocked_label,"*) state="blocked" ;;
	esac
	case ",$labels," in
	*",$rebase_label,"*) state="rebase" ;;
	esac
	[ "$draft" = "true" ] && state="draft"

	sha=$(mc_pr_head_sha "$number")

	if [ "$backbone" = "github-merge-queue" ]; then
		# One read, no waiting. This is a report, so an uncomputed answer is
		# printed as uncomputed rather than waited out — but it is still never
		# printed as "clean".
		case "$(mc_mergeable "$number")" in
		CLEAN) freshness="clean" ;;
		CONFLICTING) freshness="CONFLICT" ;;
		*) freshness="UNKNOWN" ;;
		esac
	else
		behind=$(mc_behind_by "$sha" 2>/dev/null || echo "?")
		if [ "$behind" = "0" ]; then
			freshness="current"
		elif [ "$behind" = "?" ]; then
			freshness="UNKNOWN"
		else
			freshness="behind $behind"
			# A branch that is behind may also conflict, and then GitHub runs
			# no CI on it, so its last green stays on the page. "behind N"
			# reads as "rebase and re-run"; CONFLICT says the rebase needs
			# hands. A branch that is current cannot conflict, so only this
			# case asks.
			#
			# Settled, with one retry: GitHub resets the answer to null when
			# the base moves, and right after a landing is when this report
			# is run. Still UNKNOWN keeps "behind N", which already stops a
			# landing, and the footer names the pull request.
			case "$(mc_mergeable_settled "$number" 2 2>/dev/null)" in
			CONFLICTING) freshness="CONFLICT" ;;
			CLEAN) ;;
			*) unread="$unread #$number" ;;
			esac
		fi
	fi

	if checks=$(mc_require_checks "$sha" 2>/dev/null); then
		verdict="ok"
	else
		# The first non-ok line names the worst thing found. The full text is
		# printed by land.sh, which is where it matters.
		# sed -n '1p' rather than head -1: head closes the pipe as soon as it
		# has its line, and pipefail turns the writer's SIGPIPE into the
		# pipeline's status. See the note on the release guard in land.sh.
		verdict=$(printf '%s\n' "$checks" | grep -v '^  ok ' | sed -n '1p' |
			awk '{print $1}')
		[ -z "$verdict" ] && verdict="FAILED"

		# A draft runs no CI on this repository by design, so every one of
		# its required checks concludes "skipped". FAILED then reports a
		# healthy branch as broken — and because every registered-but-
		# unstarted branch is a draft, the whole column reads FAILED and
		# stops distinguishing anything.
		#
		# Only when EVERY check skipped. A draft that ran something and
		# failed it still says so, and so does a ready pull request whose
		# checks all skipped: that one is the skip-propagation failure,
		# where a run reports green having compiled nothing, and it stays
		# loud as SKIPPED.
		if [ "$draft" = "true" ] && all_checks_skipped "$checks"; then
			verdict="no CI"
		fi
	fi

	issue=$(issue_for "$number")
	session=$(mc_session_state "$head" "$worktrees")

	short="$title"
	[ "${#short}" -gt 40 ] && short="${short:0:37}..."
	printf '  %-6s %-9s %-11s %-9s %-9s %-11s %s\n' "#$number" "$state" "$freshness" "$verdict" "$issue" "$session" "$short"
done <<EOF
$rows
EOF

# The open Dependabot pull requests, under the table. While one waits,
# ready.sh and land.sh stop other work and ask whether to land it first.
deps=$(mc_deps_notice)
if [ -n "$deps" ]; then
	echo
	printf '%s\n' "$deps" | sed 's/^/  /'
fi

echo
echo "  ISSUE: #N claims it. ~N only names it in the title. DUP #N is refused by the"
echo "  issue claim check, because an older open pull request claims N."
if [ "$claims_ok" -ne 1 ]; then
	echo "  ISSUE reads ? because the open pull requests could not be read for claims."
	echo "  Run claims.sh to see why."
fi
echo "  SESSION looks at this machine only. '-' means no worktree here, not that"
echo "  nobody holds it. 'dead' means a lock names a process that is gone."

echo
if [ -n "$holder" ]; then
	if [ "$backbone" = "github-merge-queue" ]; then
		echo "  Claim: #$holder is mid-landing. On a queue that does not stop anything else —"
		echo "  the claim is a lock on that one pull request, and the queue holds up to five."
	else
		echo "  Claim: #$holder holds $landing_label. Nothing else may land until it clears."
	fi
else
	echo "  Claim: free — no PR holds $landing_label."
fi

if [ "$backbone" = "serialized-claim" ]; then
	echo
	echo "  No merge queue on this repository yet, so 'current' plus 'ok' above is"
	echo "  the whole guarantee, and it is only true at the moment it was read."
	echo "  Re-run this immediately before landing; land.sh does that itself."
	echo "  CONFLICT means git cannot merge the branch, so it runs no CI: rebase by hand."
	if [ -n "$unread" ]; then
		echo "  Could not tell whether$unread conflicts: GitHub had not worked it out."
		echo "  Re-run this in a few seconds."
	fi
else
	echo
	echo "  The merge queue tests each pull request against $base plus everything ahead"
	echo "  of it, so a branch being behind is not a problem and does not need a rebase."
	echo "  CONFLICT is the one that does: the queue cannot merge what git will not."
fi

echo
echo "  Ordering: overlap.sh          Landing: /merge-land <number>"
