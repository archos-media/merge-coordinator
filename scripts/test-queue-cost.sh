#!/usr/bin/env bash
# Tests queue-cost.sh — the report that says what a land paid.
#
# THE ASSERTIONS THAT MATTER ARE THE HONESTY ONES. This script exists because a
# fail-closed gate spent three days reporting a reason that was fiction, and a
# report about that gate which invents its own answers is worse than none. So
# the weight below is on the three ways it could lie:
#
#   - a job log it could not read must not read as "the job did not run"
#   - no merge-group run at all must not read as "the land was free"
#   - a draft's skipped run must not read as a suite that was paid for
#
# Same fixture-gh harness as the other suites. It does not implement --jq, so a
# response file holds what gh would print after the filter — these cases prove
# the logic around each call, not the filter inside it.
set -euo pipefail

# contains — substring test in the shell. NOT `printf | grep -qF`: this file
# sets pipefail, grep -q exits at its match, printf dies of SIGPIPE, and 141
# becomes the pipeline's status. In a "must NOT appear" helper that turns a
# found string into a PASS — an assertion that cannot fail.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
SCRIPT=./queue-cost.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

REPO=example/repo
FIX="$WORK/fix"

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "backbone": "github-merge-queue",
  "requireApproval": false,
  "ciWorkflow": "ci.yml",
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": []
}
JSON

# A land that went the way it is supposed to: one pull-request suite, one merge
# group, and the gate hit so the merge group did no work.
reset_fixture() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"
	printf 'headsha1\n' >"$FIX/head.txt"
	printf '900\t2026-08-29T10:00:00Z\t2026-08-29T10:07:12Z\tsuccess\n' >"$FIX/prruns.txt"
	printf '901\t2026-08-29T10:20:00Z\t2026-08-29T10:20:31Z\tsuccess\n' >"$FIX/mgruns.txt"
	printf '5551\n' >"$FIX/jobs.txt"
	{
		echo "2026-08-29T10:20:20Z ci-proven-tree: this run builds tree abc123 (commit deadbeef)"
		echo "2026-08-29T10:20:25Z ci-proven-tree: HIT - tree already proven by headsha1. This run may skip the work."
	} >"$FIX/joblog.txt"
	cat >"$FIX/routes" <<ROUTES
pr view 1200*	head.txt
run list --repo $REPO --workflow ci.yml --event pull_request*	prruns.txt
run list --repo $REPO --workflow ci.yml --event merge_group*	mgruns.txt
api repos/$REPO/actions/runs/*/jobs*	jobs.txt
api repos/$REPO/actions/jobs/5551/logs*	joblog.txt
ROUTES
}

run() {
	local name="$1"
	shift
	local out status want
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		bash "$SCRIPT" 1200 2>&1)
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		echo "FAIL: $name — exited $status"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			echo "FAIL: $name — output did not contain: $want"
			printf '%s\n' "$out" | sed 's/^/    /'
			fail=$((fail + 1))
			return
		fi
	done
	echo "ok: $name"
	pass=$((pass + 1))
}

run_absent() {
	local name="$1" unwanted="$2" out
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		bash "$SCRIPT" 1200 2>&1)
	set -e
	if contains "$out" "$unwanted"; then
		echo "FAIL: $name — output contained what it must not: $unwanted"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# --------------------------------------------------------------------------
# The happy path
# --------------------------------------------------------------------------
reset_fixture
run "a hit is reported as a hit" "HIT - tree already proven"
reset_fixture
run "one merge group is counted once" "7.2 on the pull request"
reset_fixture
run_absent "one merge group does not claim the base moved" "the base moved underneath it"

# --------------------------------------------------------------------------
# The base moving while the pull request sat in the queue (more than one
# merge-group run)
# --------------------------------------------------------------------------
reset_fixture
{
	printf '901\t2026-08-29T10:20:00Z\t2026-08-29T10:27:24Z\tsuccess\n'
	printf '902\t2026-08-29T10:14:00Z\t2026-08-29T10:21:24Z\tsuccess\n'
} >"$FIX/mgruns.txt"
run "two merge groups for one pull request are called out" "2 merge-group runs for one pull request"

# --------------------------------------------------------------------------
# THE HONESTY CASES
# --------------------------------------------------------------------------
# An unreadable job log must say it could not look. If this ever reads as "the
# job did not run" it has become the bug it was written to catch.
reset_fixture
printf 'FAIL\n' >"$FIX/jobs.txt"
cat >"$FIX/routes" <<ROUTES
pr view 1200*	head.txt
run list --repo $REPO --workflow ci.yml --event pull_request*	prruns.txt
run list --repo $REPO --workflow ci.yml --event merge_group*	mgruns.txt
api repos/$REPO/actions/runs/*/jobs*	FAIL
api repos/$REPO/actions/jobs/*/logs*	joblog.txt
ROUTES
run "an unreadable proven job says could not look" "could not read the 'Already proven' job"
reset_fixture
cat >"$FIX/routes" <<ROUTES
pr view 1200*	head.txt
run list --repo $REPO --workflow ci.yml --event pull_request*	prruns.txt
run list --repo $REPO --workflow ci.yml --event merge_group*	mgruns.txt
api repos/$REPO/actions/runs/*/jobs*	FAIL
api repos/$REPO/actions/jobs/*/logs*	joblog.txt
ROUTES
# The discrimination that matters, and the one the first version of this test
# got wrong. Asserting on "did not run" matched the script's OWN sentence
# explaining the distinction — a guard matching its own documentation, which is
# an assertion that cannot fail. What actually has to be true is that an
# unreadable job does not take the other branch: "logged nothing about the
# tree" is the answer for a job that ran and said nothing, and it must never be
# printed for a job nobody could read.
run_absent "an unreadable proven job is not reported as an empty one" "logged nothing about the tree"

# No merge group at all. The land did not go through the queue — which is not
# the same as costing nothing, and must never print as a total of zero.
reset_fixture
: >"$FIX/mgruns.txt"
run "no merge group says it did not land through the queue" "It did not land through the queue"
reset_fixture
: >"$FIX/mgruns.txt"
run_absent "no merge group never reports a free land" "This land cost 0"

# A draft's run concludes skipped and cost nothing. Counting it would make a
# draft look like a paid suite and hide the real duplicate.
reset_fixture
printf '900\t2026-08-29T10:00:00Z\t2026-08-29T10:00:04Z\tskipped\n' >"$FIX/prruns.txt"
run "a skipped pull-request run is not a paid suite" "no pull-request run of ci.yml"
reset_fixture
printf '900\t2026-08-29T10:00:00Z\t2026-08-29T10:00:04Z\tskipped\n' >"$FIX/prruns.txt"
run_absent "a skipped run is not added to the total" "on the pull request,"

# A listing that FAILED is not a listing that came back empty. Both used to
# print "No merge-group run", which was once wrong: the run was there.
reset_fixture
route_first() {
	printf '%s\t%s\n' "$1" "$2" | cat - "$FIX/routes" >"$FIX/routes.new"
	mv "$FIX/routes.new" "$FIX/routes"
}
route_first "run list --repo $REPO --workflow ci.yml --event merge_group*" FAIL
run "a failed merge-group listing says it could not look" "could not list the merge-group runs"
reset_fixture
route_first "run list --repo $REPO --workflow ci.yml --event merge_group*" FAIL
run_absent "and it does not say there was no merge-group run" "No merge-group run for"

reset_fixture
route_first "run list --repo $REPO --workflow ci.yml --event pull_request*" FAIL
run "a failed pull-request listing says it could not look" "could not list the pull-request runs"
reset_fixture
route_first "run list --repo $REPO --workflow ci.yml --event pull_request*" FAIL
run_absent "and it does not say no run did any work" "that did any work"

# --------------------------------------------------------------------------
echo
echo "test-queue-cost: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
