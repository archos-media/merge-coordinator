#!/usr/bin/env bash
# What did this land actually pay for CI?
#
# WHY THIS EXISTS. Every expensive part of this plugin fails closed: an
# unreadable answer becomes "no", and the work goes ahead. That is the right
# safety rule and it has one cost — a gate that never fires and a gate that
# always fires produce the same experience from outside. Nothing in the tool
# ever said what a land cost, so nothing could tell the two apart.
#
# It went wrong exactly that way. The repository this was built for shipped a
# CI cache keyed on the tree (its `ci-proven-tree` step) on 27 August 2026, to
# stop each land paying two full suites. Measured on 29 August:
# it had returned a miss on THIRTEEN OF THIRTEEN lands and had never once
# worked. The reason it gave was fiction — the job had no `checks: read`, so
# the call it made 403'd every time, and an unread answer was reported as a
# considered one. Three days, about three hundred CI-minutes, and the only
# signal was a line in a job log nobody reads after a green merge.
#
# So this script reads that line and puts it where a land already looks.
# land.sh --post-merge calls it. A systematic miss now shows up on the next
# land instead of after three days.
#
# WHAT IT DOES NOT DO. It does not judge and it does not fail. A land that
# paid twice is not an error — sometimes the tree really did change and the
# second suite was the point. It reports, and the operator decides.
#
# IT SAYS "COULD NOT LOOK" OUT LOUD. Same rule as the gate it watches: an API
# call that fails is never reported as an absence. A missing merge-group run
# means "this did not land through the queue", not "this was free".
#
# Usage:  queue-cost.sh 42
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# In THIS shell, not a subshell. See mc_require_config in lib/gh.sh — a config
# read inside a command substitution can only kill the substitution, which is
# how a missing config once produced phantom pull request numbers.
mc_require_config

pr="${1:-}"
[ -n "$pr" ] || mc_die "usage: queue-cost.sh <pr-number>"

repo=$(mc_repo)
workflow=$(mc_cfg_get ciWorkflow)

echo "merge-coordinator: what #$pr paid to land   ($workflow in $repo)"
echo

# Minutes between two ISO 8601 timestamps, one decimal place. Through mc_py
# because python on this machine writes CRLF otherwise, and a value carrying a
# trailing \r compares equal to nothing.
minutes_between() {
	MC_A="$1" MC_B="$2" mc_py -c '
import os, sys
from datetime import datetime
def parse(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))
try:
    a, b = parse(os.environ["MC_A"]), parse(os.environ["MC_B"])
except Exception:
    sys.stdout.write("?")
else:
    sys.stdout.write("%.1f" % ((b - a).total_seconds() / 60.0))
'
}

# The `ci-proven-tree:` lines out of one run's "Already proven" job.
#
# Reads the ONE job's log, not the run's. `gh run view --log` downloads every
# job's output, which for a full suite is megabytes to find four lines.
#
# Prints nothing and returns 1 when it cannot look. The caller must not print
# an absence for that — see the header.
proven_lines() {
	local run_id="$1" job_id log
	job_id=$(mc_gh api "repos/$repo/actions/runs/$run_id/jobs" \
		--jq '.jobs[] | select(.name == "Already proven") | .id' 2>/dev/null | head -1) || return 1
	[ -n "$job_id" ] || return 1
	log=$(mc_gh api "repos/$repo/actions/jobs/$job_id/logs" 2>/dev/null) || return 1
	# grep, never `grep -q`, and never in a pipeline whose producer can be
	# killed early: this file sets pipefail. A match that exits first turns
	# SIGPIPE into the pipeline's status and reads as "no match".
	printf '%s\n' "$log" | grep -F 'ci-proven-tree:' | sed 's/^.*ci-proven-tree: /       ci-proven-tree: /' || true
}

# --------------------------------------------------------------------------
# The pull-request half
# --------------------------------------------------------------------------
head_sha=$(mc_gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [ -z "$head_sha" ]; then
	echo "  could not read #$pr's head commit, so the pull-request half is unknown."
	pr_minutes=""
else
	# A failed listing and an empty one must not read alike. `|| true` here
	# once made both print "no run", which is an answer about the land.
	pr_listed=1
	pr_rows=$(mc_gh run list --repo "$repo" --workflow "$workflow" --event pull_request \
		--commit "$head_sha" --limit 20 \
		--json databaseId,createdAt,updatedAt,conclusion \
		--jq '.[] | [.databaseId, .createdAt, .updatedAt, .conclusion] | @tsv' 2>/dev/null) || pr_listed=0
	# gh can print its error on stdout. A failed call has no rows.
	[ "$pr_listed" -eq 1 ] || pr_rows=""

	pr_minutes=""
	while IFS=$'\t' read -r id created updated conclusion; do
		[ -z "$id" ] && continue
		# A draft's run concludes `skipped` and costs nothing. Counting it
		# would make a draft look like a suite that was paid for.
		[ "$conclusion" = "skipped" ] && continue
		mins=$(minutes_between "$created" "$updated")
		printf '  pull_request  %s  %6s min  %s\n' "${head_sha:0:8}" "$mins" "$conclusion"
		pr_minutes="$mins"
	done <<EOF
$pr_rows
EOF
	if [ "$pr_listed" -eq 0 ]; then
		echo "  could not list the pull-request runs on ${head_sha:0:8}; the API call failed."
		echo "  That is 'could not look', not 'no run'."
	elif [ -z "$pr_minutes" ]; then
		echo "  no pull-request run of $workflow on ${head_sha:0:8} that did any work."
	fi
fi

# --------------------------------------------------------------------------
# The merge-group half
# --------------------------------------------------------------------------
echo

# The queue names its branch gh-readonly-queue/<base>/pr-<number>-<base sha>.
# Matching on `/pr-<n>-` and not on `pr-<n>` keeps #42 out of #4's answer.
#
# A failed listing stops here. It used to fall through to "No merge-group run
# for #N", which is an answer about the land. Once that answer was wrong: the
# run was there.
if ! mg_rows=$(mc_gh run list --repo "$repo" --workflow "$workflow" --event merge_group \
	--limit 60 --json databaseId,headBranch,createdAt,updatedAt,conclusion \
	--jq ".[] | select(.headBranch | contains(\"/pr-$pr-\")) | [.databaseId, .createdAt, .updatedAt, .conclusion] | @tsv" 2>/dev/null); then
	echo "  could not list the merge-group runs; the API call failed."
	echo "  That is 'could not look', not 'no merge-group run'. Run queue-cost.sh $pr again."
	exit 0
fi

mg_count=0
mg_total=0
while IFS=$'\t' read -r id created updated conclusion; do
	[ -z "$id" ] && continue
	mg_count=$((mg_count + 1))
	mins=$(minutes_between "$created" "$updated")
	printf '  merge_group   run %-12s %6s min  %s\n' "$id" "$mins" "$conclusion"
	if lines=$(proven_lines "$id"); then
		if [ -n "$lines" ]; then
			printf '%s\n' "$lines"
		else
			echo "       the 'Already proven' job logged nothing about the tree."
		fi
	else
		echo "       could not read the 'Already proven' job on run $id."
		echo "       That is 'could not look', not 'it did not run'."
	fi
	mg_total=$(MC_T="$mg_total" MC_M="$mins" mc_py -c '
import os, sys
try:
    sys.stdout.write("%.1f" % (float(os.environ["MC_T"]) + float(os.environ["MC_M"])))
except Exception:
    sys.stdout.write(os.environ["MC_T"])
')
done <<EOF
$mg_rows
EOF

echo
if [ "$mg_count" -eq 0 ]; then
	echo "  No merge-group run for #$pr in the last 60."
	echo "  It did not land through the queue, or it landed long enough ago to have"
	echo "  fallen off the list. Neither of those means the land was free."
	exit 0
fi

if [ "$mg_count" -gt 1 ]; then
	echo "  $mg_count merge-group runs for one pull request — the base moved underneath it."
	echo "  Something merged to the default branch while #$pr sat in the queue. A push"
	echo "  that bypasses the queue does this; so does another land. Every run but the"
	echo "  last was thrown away."
fi

if [ -n "$pr_minutes" ]; then
	total=$(MC_A="$pr_minutes" MC_B="$mg_total" mc_py -c '
import os, sys
sys.stdout.write("%.1f" % (float(os.environ["MC_A"]) + float(os.environ["MC_B"])))
')
	echo "  This land cost $total min of CI: $pr_minutes on the pull request, $mg_total on the queue."
else
	echo "  This land cost $mg_total min of CI on the queue. The pull-request half is unknown."
fi

echo
echo "  A merge group that ran the full suite over a tree the pull request had already"
echo "  tested is the duplicate a CI cache keyed on the tree exists to remove. Read the"
echo "  ci-proven-tree line above: HIT means it worked, and a MISS names its own reason."
