#!/usr/bin/env bash
# Tests queue-state.sh — the in-flight report.
#
# The column that has to be right is FRESHNESS. GitHub reports a stale pull
# request as mergeable because strict status checks are off, so this report is
# the only place the staleness is visible before landing. Two of the cases below
# exist for that one column: a PR that is behind must not read as current, and a
# comparison that could not be made must not read as current either.
set -euo pipefail

# contains <haystack> <needle> — substring test, done in the shell.
#
# NOT `printf '%s' "$h" | grep -qF -- "$n"`. These files set `pipefail`, and
# grep -q exits at its first match while printf is still writing; printf dies of
# SIGPIPE and 141 becomes the pipeline's status. In an `if !` assertion that
# turns a found string into a failed test, which is merely noisy — but in the
# "must NOT appear" helpers it turns a found string into a PASS, which is a test
# that cannot fail. Script output is small today. That is not a guarantee.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
SCRIPT=./queue-state.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

REPO=example/repo
FIX="$WORK/fix"
# The mergeable retry waits between reads; the fixtures answer at once.
export MC_MERGEABLE_SLEEP=0

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "backbone": "serialized-claim",
  "requireApproval": true,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": []
}
JSON

# node_json <number> <title> <body> <branch> <closing issues, comma list> — one
# pull request as the claims read returns it. python writes the JSON, so a body
# with quotes or new lines is escaped correctly.
node_json() {
	MC_N="$1" MC_T="$2" MC_B="$3" MC_BR="$4" MC_C="$5" bash -c '. ./lib/gh.sh; mc_py -c "
import json, os
e = os.environ
print(json.dumps({\"number\": int(e[\"MC_N\"]), \"title\": e[\"MC_T\"], \"body\": e[\"MC_B\"],
    \"isDraft\": False, \"headRefName\": e[\"MC_BR\"], \"updatedAt\": \"2026-09-12T00:00:00Z\",
    \"closingIssuesReferences\": {\"nodes\": [{\"number\": int(x)} for x in e[\"MC_C\"].split(\",\") if x]}}))
"'
}

# page_of <node>... — one page of the claims read.
page_of() {
	local IFS=,
	printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}\n' "$*"
}

reset_fixture() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"
	printf '10\tFresh work\tfalse\twork-10\t\n' >"$FIX/openprs.txt"
	printf 'sha10\n' >"$FIX/sha10.txt"
	printf '0\n' >"$FIX/behind0.txt"
	printf 'CI passed\tsuccess\n' >"$FIX/checks-ok.txt"
	# The claims read and this machine's worktrees. By default nobody
	# claims anything and no worktree exists here.
	page_of "$(node_json 10 'Fresh work' '' work-10 '')" >"$FIX/claims.json"
	: >"$FIX/worktrees"
	printf 'echo live\n' >"$FIX/probe.sh"
	# The Dependabot lister's page. By default none is open.
	page_of >"$FIX/deps.json"
	printf '{"check_runs":[{"status":"completed","conclusion":"success"}]}' >"$FIX/deps-runs.json"
	printf '{"statuses":[]}' >"$FIX/deps-status.json"
	cat >"$FIX/routes" <<ROUTES
api graphql -f owner=example -f name=repo -f query=*	deps.json
api --paginate repos/$REPO/commits/depsha*	deps-runs.json
api repos/$REPO/commits/depsha*	deps-status.json
api graphql --paginate *	claims.json
api --paginate repos/$REPO/pulls?state=open*	openprs.txt
api repos/$REPO/pulls/10*	sha10.txt
api repos/$REPO/compare/main...sha10*	behind0.txt
api --paginate repos/$REPO/commits/sha10/check-runs*	checks-ok.txt
api repos/$REPO/commits/sha10/status*	EMPTY
ROUTES
}

run() {
	local name="$1"
	shift
	local out status want
	set +e
	out=$(MC_CONFIG="${MC_TEST_CONFIG:-$WORK/config.json}" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" \
		bash "$SCRIPT" 2>&1)
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

# run_absent looks only at the pull request ROWS. The footer explains what the
# word "current" means, so searching the whole page would find it there and the
# test would fail on its own prose.
run_absent() {
	local name="$1" unwanted="$2" out
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" \
		bash "$SCRIPT" 2>&1 | grep '^  #')
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

# The row for one pull request, so a value in another row or the footer cannot
# satisfy an assertion about this one.
row_of() {
	MC_CONFIG="${MC_TEST_CONFIG:-$WORK/config.json}" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" \
		bash "$SCRIPT" 2>&1 | grep "^  #$1 " || true
}

# expect_row <name> <pr> <substring>
expect_row() {
	local r
	r=$(row_of "$2")
	if contains "$r" "$3"; then
		echo "ok: $1"
		pass=$((pass + 1))
	else
		echo "FAIL: $1 — row #$2 did not contain: $3"
		printf '    %s\n' "$r"
		fail=$((fail + 1))
	fi
}

# expect_row_absent <name> <pr> <substring>
expect_row_absent() {
	local r
	r=$(row_of "$2")
	if [ -n "$r" ] && ! contains "$r" "$3"; then
		echo "ok: $1"
		pass=$((pass + 1))
	else
		echo "FAIL: $1 — row #$2 is missing, or contained: $3"
		printf '    %s\n' "$r"
		fail=$((fail + 1))
	fi
}

# --------------------------------------------------------------------------
# 1. The ordinary case: open, current, green, claim free.
# --------------------------------------------------------------------------
reset_fixture
run "a fresh green PR reads ready, current, ok" "#10" "ready" "current" "ok" "Claim: free"

# --------------------------------------------------------------------------
# 2. Behind the default branch. This is the reported bug, seen from the report.
# --------------------------------------------------------------------------
reset_fixture
printf '3\n' >"$FIX/behind0.txt"
printf 'true\n' >"$FIX/mergeable.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run "a PR behind main says so" "behind 3"
run_absent "a PR behind main does not read as current" "current"

# A branch that is behind AND conflicts runs no CI, so its old green stays on
# the page. The column must say CONFLICT, not "behind 3" with "ok" beside it.
printf 'false\n' >"$FIX/mergeable.txt"
run "a conflict is explained in the footer" "rebase by hand"
run_absent "a PR behind main that conflicts is not called merely behind" "behind 3"
# The row itself, not the page: the footer also says CONFLICT.
expect_row "a PR behind main that conflicts says CONFLICT in its row" 10 " CONFLICT "
# And its old green is not shown as one: the checks tested a head that cannot
# merge. The fixture's checks pass, so "ok" is what a missed case would print.
expect_row "a conflicting PR's checks read stale" 10 " stale "
expect_row_absent "a conflicting PR's old green is not shown as ok" 10 " ok "

# Could not ask: the row keeps "behind 3", which already stops a landing, and
# is never upgraded to anything that reads as fine.
reset_fixture
printf '3\n' >"$FIX/behind0.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tFAIL\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
# A failed read is not blamed on GitHub being slow: the footer allows for both.
run "an unreadable mergeable keeps behind N, and the footer names it" "behind 3" \
	"Conflict state not read for: #10." "the read failed"
run_absent "an unreadable mergeable is not reported as a conflict" "CONFLICT"

# Right after a landing GitHub answers null until it has recomputed. The
# report asks again, so the first run after a landing still finds the conflict.
reset_fixture
printf '3\n' >"$FIX/behind0.txt"
printf 'null\n' >"$FIX/mergeable-null.txt"
printf 'false\n' >"$FIX/mergeable.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tSEQ:mergeable-null.txt,mergeable.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
expect_row "a conflict GitHub had not computed yet is found on the retry" 10 " CONFLICT "

# Never computed: "behind 3" stays, and the footer says the question went
# unanswered rather than letting the row pass for a plain behind.
reset_fixture
printf '3\n' >"$FIX/behind0.txt"
printf 'null\n' >"$FIX/mergeable-null.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable-null.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run "a mergeable never computed keeps behind N, and the footer names it" "behind 3" \
	"Conflict state not read for: #10."

# A clean answer is not reported as unanswered.
reset_fixture
printf '3\n' >"$FIX/behind0.txt"
printf 'true\n' >"$FIX/mergeable.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
# || true: a crash is reported below as a missing row, not by aborting the suite.
out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
	MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" \
	bash "$SCRIPT" 2>&1) || true
case "$out" in
*"behind 3"*"Conflict state not read"*)
	echo "FAIL: a clean answer was reported as unanswered"
	fail=$((fail + 1))
	;;
*"behind 3"*)
	echo "ok: a clean answer is not reported as unanswered"
	pass=$((pass + 1))
	;;
*)
	echo "FAIL: a clean behind PR did not read behind 3"
	printf '%s\n' "$out" | sed 's/^/    /'
	fail=$((fail + 1))
	;;
esac

# A current branch cannot conflict, so the report does not spend a call asking.
reset_fixture
run "a current PR still reads current" "current"
case "$(cat "$FIX/calls.log")" in
*".mergeable"*)
	echo "FAIL: a current PR was asked whether it merges"
	fail=$((fail + 1))
	;;
*)
	echo "ok: a current PR is not asked whether it merges"
	pass=$((pass + 1))
	;;
esac

# --------------------------------------------------------------------------
# 3. A comparison that could not be made is UNKNOWN, never current. Not looking
#    and finding nothing are different answers.
# --------------------------------------------------------------------------
reset_fixture
printf 'api repos/%s/compare/main...sha10*\tFAIL\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run "an unreadable comparison reads UNKNOWN" "UNKNOWN"
run_absent "an unreadable comparison does not read as current" "current"

# --------------------------------------------------------------------------
# 4. A cancelled run is not a pass here either.
# --------------------------------------------------------------------------
reset_fixture
printf 'CI passed\tcancelled\n' >"$FIX/checks-ok.txt"
run "a cancelled check does not read ok" "CANCELLED"

reset_fixture
printf 'gitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
run "a check that never ran does not read ok" "MISSING"

# --------------------------------------------------------------------------
# 5. Labels and drafts.
# --------------------------------------------------------------------------
reset_fixture
printf '10\tLanding now\tfalse\twork-10\tmerge:landing\n' >"$FIX/openprs.txt"
run "the claim holder is named" "LANDING" "Claim: #10 holds"

reset_fixture
printf '10\tStale\tfalse\twork-10\tmerge:needs-rebase\n' >"$FIX/openprs.txt"
run "a PR told to rebase shows it" "rebase"

reset_fixture
printf '10\tRegistering\ttrue\twork-10\t\n' >"$FIX/openprs.txt"
run "a draft reads as a draft" "draft"

# A draft runs no CI on this repository, so every one of its checks concludes
# "skipped". Reporting that as FAILED said a healthy branch was broken, and
# since every registered-but-unstarted branch is a draft, the column read
# FAILED for all of them and distinguished nothing.
reset_fixture
printf '10\tRegistering\ttrue\twork-10\t\n' >"$FIX/openprs.txt"
printf 'CI passed\tskipped\n' >"$FIX/checks-ok.txt"
run "a draft whose checks all skipped reads no CI" "no CI"
run_absent "a draft whose checks all skipped is not called a failure" "FAILED"

# The other half, and the reason this is not simply "ignore skipped": a READY
# pull request in the same state is the skip-propagation failure, where a run
# reports green having compiled nothing. That one stays loud.
reset_fixture
printf '10\tReady but nothing ran\tfalse\twork-10\t\n' >"$FIX/openprs.txt"
printf 'CI passed\tskipped\n' >"$FIX/checks-ok.txt"
run "a ready PR whose checks all skipped stays loud" "SKIPPED"
run_absent "a ready PR whose checks all skipped is not excused" "no CI"

# And the forgiveness is only for an all-skipped set. A draft that ran
# something and failed it still says so.
reset_fixture
printf '10\tDraft with a real failure\ttrue\twork-10\t\n' >"$FIX/openprs.txt"
printf 'CI passed\tfailure\n' >"$FIX/checks-ok.txt"
run "a draft with a real failure still reads FAILED" "FAILED"

# --------------------------------------------------------------------------
# 6. Nothing open.
# --------------------------------------------------------------------------
reset_fixture
: >"$FIX/openprs.txt"
run "an empty list says so plainly" "nothing open."

# --------------------------------------------------------------------------
# 7. The merge-queue backbone reports a different middle column.
#
# Same pull request, same fixture, different question: "behind 0" is not what
# stops a landing on a queue, so the column shows whether git can merge it.
# --------------------------------------------------------------------------
sed 's/"serialized-claim"/"github-merge-queue"/' "$WORK/config.json" >"$WORK/config-queue.json"
grep -q 'github-merge-queue' "$WORK/config-queue.json" ||
	{ echo "FAIL: the queue fixture config was not written"; exit 1; }

reset_fixture
printf 'true\n' >"$FIX/mergeable-clean.txt"
printf 'false\n' >"$FIX/mergeable-conflict.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable-clean.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
MC_TEST_CONFIG="$WORK/config-queue.json" \
	run "a queue reports MERGE, not FRESHNESS" "MERGE" "clean" "merge queue tests each pull request"
MC_TEST_CONFIG="$WORK/config-queue.json" \
	run "a queue does not report a branch as behind" "#10"
MC_TEST_CONFIG="$WORK/config-queue.json" \
	expect_row "a clean PR's checks still read ok on a queue" 10 " ok "

reset_fixture
printf 'true\n' >"$FIX/mergeable-clean.txt"
printf 'false\n' >"$FIX/mergeable-conflict.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable-conflict.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
MC_TEST_CONFIG="$WORK/config-queue.json" \
	run "a conflicting PR is called out on a queue" "CONFLICT"
MC_TEST_CONFIG="$WORK/config-queue.json" \
	expect_row "a conflicting PR's checks read stale on a queue" 10 " stale "

# And the serialized wording must NOT appear on a queue — that footer tells a
# session the freshness column is the whole guarantee, which it is not here.
reset_fixture
printf 'true\n' >"$FIX/mergeable-clean.txt"
printf 'api repos/%s/pulls/10 --jq .mergeable\tmergeable-clean.txt\n' "$REPO" >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
out=$(MC_CONFIG="$WORK/config-queue.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
	bash "$SCRIPT" 2>&1)
case "$out" in
*"No merge queue on this repository"*)
	echo "FAIL: a queue still printed the no-queue footer"
	fail=$((fail + 1))
	;;
*)
	echo "ok: a queue does not print the no-queue footer"
	pass=$((pass + 1))
	;;
esac

# --------------------------------------------------------------------------
# 8. ISSUE and SESSION.
# --------------------------------------------------------------------------
BLOCK5='<!-- merge-coordinator:footprint
issue: 5
-->'

reset_fixture
expect_row "a PR that claims nothing reads - in ISSUE" 10 " -  "

reset_fixture
page_of "$(node_json 10 'Fresh work' "$BLOCK5" work-10 '')" >"$FIX/claims.json"
expect_row "a declared claim reads #N" 10 "#5"

reset_fixture
page_of "$(node_json 10 'Plan the thing (#7)' '' work-10 '')" >"$FIX/claims.json"
expect_row "a title mention reads ~N, not a claim" 10 "~7"

# Two claims on one issue. The older one holds it, and the newer one says DUP.
reset_fixture
printf '10\tOlder\tfalse\twork-10\t\n11\tNewer\tfalse\twork-11\t\n' >"$FIX/openprs.txt"
printf 'sha11\n' >"$FIX/sha11.txt"
cat >>"$FIX/routes" <<ROUTES
api repos/$REPO/pulls/11*	sha11.txt
api repos/$REPO/compare/main...sha11*	behind0.txt
api --paginate repos/$REPO/commits/sha11/check-runs*	checks-ok.txt
api repos/$REPO/commits/sha11/status*	EMPTY
ROUTES
page_of "$(node_json 10 Older "$BLOCK5" work-10 '')" "$(node_json 11 Newer '' work-11 5)" >"$FIX/claims.json"
expect_row "the newer of two claims reads DUP" 11 "DUP #5"
expect_row_absent "the older of two claims is not DUP" 10 "DUP"

# A claims read that fails is ?, and never a plain "-" that reads as nobody.
reset_fixture
printf 'api graphql --paginate *\tFAIL\n' >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run "an unreadable claims read says why, and the report still prints" "#10" "could not be read for claims"
expect_row "an unreadable claims read reads ? in ISSUE" 10 " ?  "

# SESSION, from this machine's worktrees.
reset_fixture
printf 'worktree /w/a\nHEAD aaa\nbranch refs/heads/work-10\nlocked claude session a (pid 4242)\n\n' >"$FIX/worktrees"
expect_row "a locked worktree with a live Claude pid reads live" 10 "live 4242"

reset_fixture
printf 'worktree /w/a\nHEAD aaa\nbranch refs/heads/work-10\nlocked claude session a (pid 4242)\n\n' >"$FIX/worktrees"
printf 'echo dead\n' >"$FIX/probe.sh"
expect_row "a lock whose process is gone reads dead" 10 "dead 4242"

reset_fixture
printf 'worktree /w/a\nHEAD aaa\nbranch refs/heads/work-10\n\n' >"$FIX/worktrees"
expect_row "a worktree with no lock reads unlocked" 10 "unlocked"

# A worktree for work-100 is not the worktree for work-10.
reset_fixture
printf 'worktree /w/a\nHEAD aaa\nbranch refs/heads/work-100\nlocked claude session a (pid 4242)\n\n' >"$FIX/worktrees"
expect_row_absent "a branch that only starts with the same name is not matched" 10 "4242"

run "the footer says SESSION is this machine only" "this machine only"

# ---------------------------------------------------------------------------
# The Dependabot block under the table. Best effort: a failed look is one
# line, and the report still prints and exits 0.
# ---------------------------------------------------------------------------
reset_fixture
# deps_node <number> <in queue true|false> — a Dependabot pull request.
deps_node() {
	printf '{"number":%s,"title":"Bump x from 1.0.0 to 1.0.1","createdAt":"2020-01-01T00:00:00Z","isInMergeQueue":%s,"headRefOid":"depsha%s","author":{"__typename":"Bot","login":"dependabot"},"labels":{"nodes":[]}}' "$1" "$2" "$1"
}
page_of "$(deps_node 90 false)" "$(deps_node 91 true)" >"$FIX/deps.json"
run "an open Dependabot pull request is shown under the table" \
	"Dependabot pull request(s) open:" "#90 Bump x from 1.0.0 to 1.0.1 (" "CI passed)" \
	"#91 Bump x from 1.0.0 to 1.0.1 (" "landing now)" "While one waits"

# Only landing ones: they are shown, and nothing is waiting, so nothing stops.
reset_fixture
page_of "$(deps_node 91 true)" >"$FIX/deps.json"
set +e
out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
	MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" bash "$SCRIPT" 2>&1)
set -e
if contains "$out" "landing now)" && ! contains "$out" "While one waits"; then
	echo "ok: only landing ones: shown, and no word of a stop"; pass=$((pass + 1))
else
	echo "FAIL: only landing ones: shown, and no word of a stop"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi

reset_fixture
set +e
out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
	MC_WORKTREE_LIST="$FIX/worktrees" MC_PID_PROBE="$FIX/probe.sh" bash "$SCRIPT" 2>&1)
set -e
if contains "$out" "Dependabot"; then
	echo "FAIL: none open: no Dependabot block"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
else
	echo "ok: none open: no Dependabot block"; pass=$((pass + 1))
fi

reset_fixture
printf 'api graphql -f owner=*\tFAIL\n' >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run "a failed Dependabot look is one line with the reason, and the report still prints" "#10" \
	"could not check Dependabot pull requests (could not list the open pull requests of example/repo)"

echo
echo "test-queue-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
