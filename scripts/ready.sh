#!/usr/bin/env bash
# Mark a pull request ready for review, once the CI line is clear.
#
# This is the sanctioned counterpart to guard-ready.sh, the way land.sh is to
# guard-merge.sh: the hook refuses the shortcut, and this is the path it points
# at. Before it acts it checks the title, the issue claim and the Dependabot
# stop, then asks the main question — is any pull request out of draft on
# ground this one shares — and marks it ready only when the answer is no. Out of
# draft means its CI is paid for or running. On a refusal it says where each of
# those pull requests stands, so the reader can tell a live one from an idle one.
#
# WHY WAITING IS CHEAPER THAN NOT WAITING. A draft runs no CI,
# so a pull request that waits spends nothing and cannot go stale. Two ready
# pull requests touching the same files cost a full extra suite between them:
# whichever lands second has main move underneath it, so its merge group builds
# a tree nothing has tested and a CI cache keyed on the tree cannot avoid it.
# Waiting turns two-and-a-bit suites into two.
#
# Usage:  ready.sh                 the pull request for the current branch
#         ready.sh 42              that one
#         ready.sh 42 --force      say it anyway, and say why in the output
#         ready.sh 42 --skip-deps
#                                  the user said "later" to the Dependabot pull
#                                  requests waiting; go on without landing them
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# Before anything else, and in THIS shell rather than in a subshell that cannot
# stop the script. See mc_require_config in lib/gh.sh.
mc_require_config

pr=""
force=0
skip_deps=0
for arg in "$@"; do
	case "$arg" in
	--force) force=1 ;;
	--skip-deps) skip_deps=1 ;;
	-*) mc_die "unknown option $arg" ;;
	*) pr="$arg" ;;
	esac
done

if [ -z "$pr" ]; then
	pr=$(mc_gh pr view --json number --jq '.number' 2>/dev/null || true)
fi
[ -n "$pr" ] || mc_die "could not tell which pull request. Give the number: ready.sh <number>"

draft=$(mc_gh pr view "$pr" --json isDraft --jq '.isDraft' 2>/dev/null || true)
if [ "$draft" = "false" ]; then
	echo "merge-coordinator: #$pr is already ready for review. Nothing to do."
	exit 0
fi
[ "$draft" = "true" ] || mc_die "could not read whether #$pr is a draft, so it stays one."

# The squash commit on main takes the pull request TITLE, and a title cannot be
# changed on main after the merge. register.sh uses the branch name as the title
# when it gets no --title, and it has dropped a --title that it was given. So a
# title that is only the branch name stops here. --force does not step over it:
# the fix is one command, and --force is for the CI line.
#
# The comparison ignores case, "-", "_" and "/", a leading "#<issue> " (the form
# register.sh writes) and a leading "worktree-" (the prefix EnterWorktree adds).
title_line=$(mc_gh pr view "$pr" --json title,headRefName --jq '[.title, .headRefName] | @tsv' 2>/dev/null) ||
	mc_die "could not read the title of #$pr, so it stays a draft."
title=${title_line%%$'\t'*}
head_ref=${title_line#*$'\t'}
plain() {
	printf '%s' "$1" | tr 'A-Z_/-' 'a-z   ' | sed -E 's/^#[0-9]+ +//; s/^worktree +//; s/  +/ /g; s/^ +//; s/ +$//'
}
if [ -z "$(plain "$title")" ] || [ "$(plain "$title")" = "$(plain "$head_ref")" ]; then
	mc_die "#$pr has no real title: '$title' is the branch name.
  The squash commit on main takes the title, and main cannot be changed after the merge.
  Set it:        gh pr edit $pr --title \"<one sentence that says what changed>\"
  Read it back:  gh pr view $pr --json title
  It stays a draft."
fi

# A refused issue claim stops this before CI, and --force does not step over it.
# --force is for the CI line. A duplicate claim is a different problem, and the
# required issue claim check would block the merge anyway.
repo=$(mc_repo)
labels=$(mc_gh api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")' 2>/dev/null) ||
	mc_die "could not read the labels of #$pr, so it stays a draft."
dup_label=$(mc_dup_label)
case ",$labels," in
*",$dup_label,"*) mc_die "#$pr carries $dup_label: another open pull request already claims its issue.
  Read the issue claim comment on #$pr and resolve the claim first. It stays a draft." ;;
esac

# A Dependabot pull request waiting stops this, and --force does not step over
# it: the question is the user's, land the bump first or later.
# mc_deps_gate in lib/gh.sh.
mc_deps_gate "$pr" "$skip_deps" 0 || exit 1

# describe_ahead <number> — one line on where a pull request ahead of this one
# stands.
#
# overlap.sh counts every pull request that is out of draft. That includes one
# that is green and idle, an idle Dependabot branch, and one that merged seconds
# ago. The refusal used to name bare numbers, so every session looked each one
# up by hand before it could tell a live blocker from a stale one. This line
# is that lookup. It reports; it does not decide.
describe_ahead() {
	local n="$1" owner name row state queued updated author head run run_status run_result who
	owner=${repo%%/*}
	name=${repo#*/}
	# isInMergeQueue exists only in GraphQL. Fields are joined on a comma, and
	# jq writes the placeholders, because an empty field collapses a tab split.
	row=$(mc_gh api graphql -F n="$n" -f owner="$owner" -f name="$name" \
		-f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){state isInMergeQueue updatedAt headRefOid author{login}}}}' \
		--jq '.data.repository.pullRequest | [.state, (.isInMergeQueue|tostring), .updatedAt, (.author.login // "unknown"), .headRefOid] | join(",")' \
		2>/dev/null) || row=""
	IFS=, read -r state queued updated author head <<EOF
$row
EOF
	who="Author $author, last updated $updated."
	case "$state" in
	MERGED) echo "  #$n merged after the list was read. Run ready.sh again." ;;
	CLOSED) echo "  #$n was closed after the list was read. Run ready.sh again." ;;
	OPEN)
		if [ "$queued" = "true" ]; then
			echo "  #$n is in the merge queue. It lands soon; wait for it."
			return 0
		fi
		# The newest CI run on the head commit, by run id. NOT a check rollup
		# by name: a PR just marked ready still carries its draft's skipped
		# twin under the same check names, and that reads as finished.
		run=$(mc_gh api "repos/$repo/actions/workflows/$(mc_cfg_get ciWorkflow)/runs" \
			-X GET -f head_sha="$head" -f event=pull_request \
			--jq '.workflow_runs | if length == 0 then "none," else (max_by(.id) | [.status, (.conclusion // "")] | join(",")) end' \
			2>/dev/null) || run=""
		IFS=, read -r run_status run_result <<EOF
$run
EOF
		case "$run_status,$run_result" in
		completed,success) echo "  #$n is green and not in the queue. $who" ;;
		completed,skipped | none,) echo "  #$n has not started its CI yet. $who" ;;
		completed,*) echo "  #$n finished its CI as '$run_result' and is not in the queue. $who" ;;
		queued,* | in_progress,* | waiting,* | pending,* | requested,*) echo "  #$n has CI running. $who" ;;
		*) echo "  #$n: could not read its CI. $who" ;;
		esac
		;;
	# gh can print its error on stdout, so anything else is "could not look".
	*) echo "  #$n: could not read its state." ;;
	esac
}

# Under --skip-deps the Dependabot pull requests the user put off are not ahead
# either, or the overlap check would refuse next, naming the same ones.
except=()
if [ -n "$MC_DEPS_WAITING" ]; then
	except=("--except=$(printf '%s' "$MC_DEPS_WAITING" | tr ' ' ',')")
fi

set +e
ahead=$(bash "$here/overlap.sh" "$pr" --ci-ahead ${except[@]+"${except[@]}"} 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
	echo "merge-coordinator: no pull request out of draft shares ground with #$pr. Marking it ready."
	mc_gh pr ready "$pr"
	echo "  #$pr is ready for review. CI starts now, and it should be the only pass it needs."
	exit 0
fi

# Everything below this line is a refusal. --force turns it into a warning, and
# never into silence: a forced flip is exactly the one somebody will want to
# find in the log afterwards.
if [ "$status" -eq 1 ]; then
	# Numbers only. overlap.sh's warnings arrive on the same stream.
	numbers=""
	while IFS= read -r line; do
		case "$line" in
		'' | *[!0-9]*) ;;
		*) numbers="$numbers $line" ;;
		esac
	done <<EOF
$ahead
EOF
	echo "merge-coordinator: #$pr shares ground with pull request(s) that are out of draft:$numbers" >&2
	for n in $numbers; do
		describe_ahead "$n" >&2
	done
	echo "  Whichever of you lands second has main move underneath it, so its merge" >&2
	echo "  group builds a tree nothing has tested and pays for a second full suite." >&2
	echo "  Leaving #$pr a draft costs nothing. Run 'overlap.sh $pr' to see what you share." >&2
else
	echo "merge-coordinator: could not work out what is ahead of #$pr." >&2
	printf '%s\n' "$ahead" | sed 's/^/  /' >&2
	echo "  Not looking and finding nothing are different answers. This one is 'could not look'." >&2
fi

if [ "$force" -eq 1 ]; then
	echo >&2
	echo "  --force given. Marking #$pr ready anyway." >&2
	mc_gh pr ready "$pr"
	exit 0
fi

echo >&2
echo "  Add --force to do it anyway." >&2
exit 1
