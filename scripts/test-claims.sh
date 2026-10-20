#!/usr/bin/env bash
# Tests the issue claim: the rule (claims.sh and lib/claims.py), the gate that
# GitHub runs (claim-gate.sh), the hook that refuses earlier on this machine
# (guard-claim.sh), and ready.sh's refusal.
#
# The rule is worth the most here, and two of its cases carry the reason it
# exists. A duplicate claim must be refused: a session once planned an issue a
# peer had already built. And
# a title that only NAMES an issue must not be refused: 73 pairs of planned pull
# requests did exactly that in the history this was measured on. A rule that
# fails either case is wrong in a way that costs real work.
#
# gh is stubbed through MC_GH. Nothing here touches the network.
set -euo pipefail

contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
HERE=$(pwd)
# shellcheck source=lib/gh.sh
. "$HERE/lib/gh.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; shift; printf '%s\n' "$*" | sed 's/^/    /'; fail=$((fail + 1)); }

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "backbone": "github-merge-queue",
  "requireApproval": false,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": []
}
JSON
export MC_CONFIG="$WORK/config.json"
export MC_GH="$HERE/lib/fixture-gh.sh"
FIX="$WORK/fix"
export MC_FIXTURES="$FIX"

reset_fixture() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"
	: >"$FIX/routes"
	: >"$FIX/worktrees"
	printf 'echo live\n' >"$FIX/probe.sh"
}

route() {
	printf '%s\t%s\n' "$1" "$2" >>"$FIX/routes"
}

# node <number> <title> <body> <branch> <closing issues, comma list> [draft]
node() {
	MC_N="$1" MC_T="$2" MC_B="$3" MC_BR="$4" MC_C="$5" MC_D="${6:-true}" mc_py -c '
import json, os
e = os.environ
print(json.dumps({"number": int(e["MC_N"]), "title": e["MC_T"], "body": e["MC_B"],
    "isDraft": e["MC_D"] == "true", "headRefName": e["MC_BR"], "updatedAt": "2026-09-12T00:00:00Z",
    "closingIssuesReferences": {"nodes": [{"number": int(x)} for x in e["MC_C"].split(",") if x]}}))
'
}

# page <node>... — one page of the GraphQL read.
page() {
	local IFS=,
	printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}\n' "$*"
}

# serve <page text> — the claims read returns this.
serve() {
	printf '%s\n' "$1" >"$FIX/page.json"
	route 'api graphql --paginate *' page.json
}

# claims <args> — run claims.sh, set out and status.
claims() {
	set +e
	out=$(bash "$HERE/claims.sh" "$@" 2>&1)
	status=$?
	set -e
}

# expect <name> <status> <substring>...
expect() {
	local name="$1" want_status="$2" want
	shift 2
	if [ "$status" -ne "$want_status" ]; then
		bad "$name — exited $status, wanted $want_status" "$out"
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			bad "$name — output did not contain: $want" "$out"
			return
		fi
	done
	ok "$name"
}

# expect_absent <name> <substring>
expect_absent() {
	if contains "$out" "$2"; then
		bad "$1 — output contained what it must not: $2" "$out"
	else
		ok "$1"
	fi
}

block() {
	printf '<!-- merge-coordinator:footprint\n%s\nweb/src/**\n-->\n' "$1"
}

TAB=$(printf '\t')

# --------------------------------------------------------------------------
# 1. The issue number in a worktree or branch name.
# --------------------------------------------------------------------------
check_name() {
	local got
	got=$(mc_issue_from_name "$1")
	if [ "$got" = "$2" ]; then
		ok "name '$1' gives '${2:-nothing}'"
	else
		bad "name '$1' gives '${2:-nothing}'" "got '$got'"
	fi
}
check_name worktree-plan-1467-session-claims 1467
check_name fix-1441-drift-unit 1441
check_name feature/1422_nav 1422
check_name x-12345 12345
check_name content-audit ""
check_name release-v0-8-7 ""
check_name fix-12-nav ""
check_name x-123456 ""
check_name plan-332-then-667 ""
check_name 1467 1467

# --------------------------------------------------------------------------
# 2. The rule.
# --------------------------------------------------------------------------
# 2a. Nothing claimed.
reset_fixture
serve "$(page "$(node 10 'Fresh work' '' b10 '')")"
claims --pr 10
expect "a PR with no claim is clear" 0 "#10 claims no issue"
claims
expect "the table shows - for a PR with no claim" 0 "10${TAB}-${TAB}clear"

# 2b. THE DUPLICATE CASE. One PR declares the issue, a newer one closes it.
reset_fixture
serve "$(page "$(node 10 Older "$(block 'issue: 5')" b10 '')" "$(node 12 Newer '' b12 5)")"
claims --pr 12
expect "a second claim on one issue is refused" 1 "#12 claims issue #5" "#10 (draft, branch b10"
expect "the refusal names the way to declare planned work" 1 "issue: 5 part-of #10"
claims --pr 10
expect "the older claim holds the issue" 0 "#10 claims #5"
claims
expect "the table marks the newer claim DUP" 0 "12${TAB}DUP #5${TAB}duplicate"
expect "the table shows the holder's claim" 0 "10${TAB}#5${TAB}clear"

# 2c. The holder is the LOWEST number, whatever order GitHub returns them in.
reset_fixture
serve "$(page "$(node 12 Newer '' b12 5)" "$(node 10 Older '' b10 5)")"
claims --pr 12
expect "the holder is the lowest number, not the first listed" 1 "#10 (draft"
claims --pr 10
expect "the lowest number is clear however the page is ordered" 0 "#10 claims #5"

# 2d. THE PLANNED-WORK CASE. Two titles that name one issue are not claims.
reset_fixture
serve "$(page "$(node 1450 'Plan: in-flight state (#1444)' '' b1450 '')" "$(node 1452 'A control says so (#1444)' '' b1452 '')")"
claims --pr 1452
expect "two titles that name one issue are not refused" 0 "#1452 claims no issue"
claims
expect "a title mention shows as ~N" 0 "1452${TAB}~1444${TAB}clear"

# 2e. part-of: planned work beside the holder is not refused, even when its body
#     also closes the issue.
reset_fixture
serve "$(page "$(node 10 Older '' b10 5)" "$(node 12 Phase2 "$(block 'issue: 5 part-of #10')" b12 5)")"
claims --pr 12
expect "a claim with part-of is not refused" 0 "#12 claims #5"

# 2f. Three claims: the oldest holds, and both others are refused.
reset_fixture
serve "$(page "$(node 10 A '' b10 5)" "$(node 11 B '' b11 5)" "$(node 12 C '' b12 5)")"
claims --pr 11
expect "the second of three claims is refused" 1 "#10 (draft"
claims --pr 12
expect "the third of three claims is refused by the oldest" 1 "#10 (draft"

# 2g. Text after the number does not stop the claim being read.
reset_fixture
serve "$(page "$(node 10 A "$(block 'issue: 5 (from branch name)')" b10 '')" "$(node 11 B '' b11 5)")"
claims --pr 11
expect "a claim marked from the branch name still counts" 1 "#11 claims issue #5"

# 2h. A claim line outside the footprint block is not a claim. #10 has a
# block, so the read reaches the lines, and the issue line is after the block.
reset_fixture
serve "$(page "$(node 10 A "$(block 'docs/a.md')
issue: 5" b10 '')" "$(node 11 B '' b11 5)")"
claims --pr 11
expect "an issue line outside the block is not a claim" 0 "#11 claims #5"

# 2i. A # in a title that is an open PR number is not an issue mention.
reset_fixture
serve "$(page "$(node 10 'Follow-up to (#12)' '' b10 '')" "$(node 12 X '' b12 '')")"
claims
expect "a title naming an open PR is not an issue mention" 0 "10${TAB}-${TAB}clear"

# 2j. Pages: gh writes one JSON document per page, one after another.
reset_fixture
printf '%s\n%s\n' "$(page "$(node 10 A '' b10 5)")" "$(page "$(node 12 B '' b12 5)")" >"$FIX/page.json"
route 'api graphql --paginate *' page.json
claims --pr 12
expect "a claim on the second page is compared with the first" 1 "#10 (draft"

# 2k. --issue: claimed, mentioned, nothing.
reset_fixture
serve "$(page "$(node 10 A "$(block 'issue: 5')" b10 '')" "$(node 11 'Names (#5)' '' b11 '')" "$(node 12 C '' b12 '')")"
claims --issue 5
expect "--issue lists the claim and exits 1" 1 "claim${TAB}10${TAB}b10${TAB}draft" "mention${TAB}11${TAB}b11"
claims --issue 9
expect "--issue for an unclaimed issue exits 0" 0
if [ -z "$out" ]; then ok "--issue for an unclaimed issue prints nothing"; else bad "--issue for an unclaimed issue prints nothing" "$out"; fi
reset_fixture
serve "$(page "$(node 11 'Names (#5)' '' b11 '')")"
claims --issue 5
expect "--issue with only a mention exits 0 and shows the mention" 0 "mention${TAB}11"

# 2l. Could not look is exit 3, never clear.
reset_fixture
route 'api graphql --paginate *' FAIL
claims --pr 10
expect "a failed read is exit 3" 3 "could not read the open pull requests"

reset_fixture
printf '{"errors":[{"message":"rate limited"}]}\n' >"$FIX/page.json"
route 'api graphql --paginate *' page.json
claims --pr 10
expect "a GraphQL error is exit 3" 3 "rate limited"

reset_fixture
serve "$(page "$(node 10 A '' b10 '')")"
claims --pr 99
expect "a PR that is not open is exit 3, not clear" 3 "not among the open pull requests"

reset_fixture
: >"$FIX/page.json"
route 'api graphql --paginate *' page.json
claims --pr 10
expect "an empty read is exit 3" 3 "returned nothing"

claims --pr abc
expect "a claim check with no number is a usage error" 2 "needs a number"

# --------------------------------------------------------------------------
# 3. The gate GitHub runs.
# --------------------------------------------------------------------------
MARK="<!-- merge-coordinator:issue-claim -->"

# gate <args> — claim-gate.sh --dry-run.
gate() {
	set +e
	out=$(bash "$HERE/claim-gate.sh" "$@" --dry-run 2>&1)
	status=$?
	set -e
}

dup_fixture() {
	reset_fixture
	serve "$(page "$(node 10 A '' b10 5)" "$(node 12 B '' b12 5)")"
	printf 'size:S\n' >"$FIX/labels"
	route 'api repos/example/repo/issues/12/labels --jq *' labels
	route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
}

# 3a. A duplicate: label, one comment, exit 1.
dup_fixture
gate 12
expect "the gate fails a duplicate claim" 1 "#12 claims issue #5"
expect "the gate labels a duplicate claim" 1 "--add-label merge:duplicate-claim"
expect "the gate makes sure the label exists" 1 "label create merge:duplicate-claim"
expect "the gate comments on a duplicate claim" 1 "api repos/example/repo/issues/12/comments -f body=$MARK"

# 3b. A second run edits its own comment rather than adding another.
dup_fixture
printf '555\n' >"$FIX/comment"
route 'api --paginate repos/example/repo/issues/12/comments --jq *' comment
sed -i.bak '/issues\/12\/comments --jq \*\tEMPTY/d' "$FIX/routes"
gate 12
expect "a second run edits the gate's comment" 1 "-X PATCH repos/example/repo/issues/comments/555"
expect_absent "a second run does not add another comment" "issues/12/comments -f body"

# 3c. The label is not added twice.
dup_fixture
printf 'size:S,merge:duplicate-claim\n' >"$FIX/labels"
gate 12
expect_absent "the gate does not add a label that is already there" "--add-label"

# 3d. Clear, with the label and the comment from an earlier refusal.
reset_fixture
serve "$(page "$(node 12 B '' b12 5)")"
printf 'merge:duplicate-claim\n' >"$FIX/labels"
printf '555\n' >"$FIX/comment"
route 'api repos/example/repo/issues/12/labels --jq *' labels
route 'api --paginate repos/example/repo/issues/12/comments --jq *' comment
gate 12
expect "a clear claim passes the gate" 0 "--remove-label merge:duplicate-claim"
expect "a resolved claim marks the gate's comment resolved" 0 "issues/comments/555" "resolved"

# 3e. Clear, and nothing to tidy: the gate writes nothing.
reset_fixture
serve "$(page "$(node 12 B '' b12 5)")"
printf 'size:S\n' >"$FIX/labels"
route 'api repos/example/repo/issues/12/labels --jq *' labels
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate 12
expect "a clear claim with nothing to tidy passes" 0
expect_absent "a clear claim with nothing to tidy writes nothing" "would run:"

# 3f. Could not look: the gate fails.
reset_fixture
route 'api graphql --paginate *' FAIL
route 'api repos/example/repo/issues/12/labels --jq *' EMPTY
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate 12
expect "the gate fails when it could not look" 1 "could not check the issue claim of #12"
expect_absent "the gate labels nothing when it could not look" "--add-label"

# 3g. The other pull requests: re-run the check where it is out of date.

# gate_live <args> — claim-gate.sh with its writes made, against the fixture.
# The failure paths of a re-run cannot be reached in --dry-run.
gate_live() {
	set +e
	out=$(bash "$HERE/claim-gate.sh" "$@" 2>&1)
	status=$?
	set -e
}

# A check that has not finished is polled; keep the waits short here.
export MC_RERUN_POLL=1 MC_RERUN_WAIT=2

# noted_dry <name> — a --dry-run wrote the "not re-checked" note on #12.
noted_dry() {
	if contains "$out" "issues/12/comments -f body=$MARK" && contains "$out" "not re-checked"; then
		ok "$1 is noted on the pull request it was for"
	else
		bad "$1 is noted on the pull request it was for" "$out"
	fi
}

# others_fixture <labelled: 12 or ""> <page> [run status] — #12 with head
# commit abc12 on branch b12 of example/repo, its latest issue-claim run 777
# in that status. Runs are listed id<TAB>status<TAB>branch<TAB>repository.
others_fixture() {
	reset_fixture
	serve "$2"
	if [ -n "$1" ]; then
		printf '%s\n' "$1" >"$FIX/labelled"
		route 'pr list --repo example/repo --state open --label merge:duplicate-claim --limit 1000 *' labelled
	else
		route 'pr list --repo example/repo --state open --label merge:duplicate-claim --limit 1000 *' EMPTY
	fi
	printf 'abc12\tb12\texample/repo\n' >"$FIX/sha"
	printf '777\t%s\tb12\texample/repo\n' "${3:-completed}" >"$FIX/run"
	route 'pr view 12 --repo example/repo --json headRefOid*' sha
	route 'api repos/example/repo/actions/runs?event=pull_request&head_sha=abc12&per_page=100 *' run
}
RUNS12='api repos/example/repo/actions/runs?event=pull_request&head_sha=abc12&per_page=100 *'
DUP_PAGE=$(page "$(node 10 A '' b10 5)" "$(node 12 B '' b12 5)")
CLEAR_PAGE=$(page "$(node 12 B '' b12 5)")

# An older pull request claims the issue later: the newer one's check was green
# and has no label. The older one's event must re-run it.
others_fixture "" "$DUP_PAGE"
gate --reconcile --except 10
expect "a pull request made a duplicate by another's claim is re-checked" 0 "run rerun 777"

others_fixture 12 "$CLEAR_PAGE"
gate --reconcile
expect "a labelled pull request that is now clear is re-checked" 0 "run rerun 777"

# Label and verdict agree: nothing to do.
others_fixture 12 "$DUP_PAGE"
gate --reconcile
expect "a refused pull request still refused is not re-run by --reconcile" 0 "Nothing to re-run"
expect_absent "a refused pull request still refused is not re-run by --reconcile (no rerun)" "run rerun"

others_fixture "" "$DUP_PAGE"
gate --reconcile --except 12
expect "--except leaves out the pull request whose own check is running" 0 "Nothing to re-run"

# A check that has not finished may have read the claims before they changed:
# it is waited for, then re-run. Queued and in progress alike.
for st in in_progress queued; do
	others_fixture "" "$DUP_PAGE" "$st"
	printf '777\tcompleted\tb12\texample/repo\n' >"$FIX/run_done"
	sed -i.bak '/actions\/runs/d' "$FIX/routes"
	route "$RUNS12" 'SEQ:run,run_done'
	gate --reconcile
	expect "a check that has not finished ($st) is waited for, then re-run" 0 "has not finished" "run rerun 777"
done

# A newer check started while waiting: it read the claims after they changed.
# Re-running the old one would cancel it.
others_fixture "" "$DUP_PAGE" in_progress
printf '777\tin_progress\tb12\texample/repo\n778\tin_progress\tb12\texample/repo\n' >"$FIX/run_newer"
sed -i.bak '/actions\/runs/d' "$FIX/routes"
route "$RUNS12" 'SEQ:run,run_newer'
gate --reconcile
expect "a newer check started while waiting is left to run" 0 "newer issue claim check on #12 (run 778)"
expect_absent "a newer check started while waiting: the old one is not re-run" "run rerun"

# A push while waiting: the pull request has a new head and its own new check.
others_fixture "" "$DUP_PAGE" in_progress
printf '777\tcompleted\tb12\texample/repo\n' >"$FIX/run_done"
printf 'def34\tb12\texample/repo\n' >"$FIX/sha2"
printf '780\tin_progress\tb12\texample/repo\n' >"$FIX/run780"
sed -i.bak '/actions\/runs/d; /pr view/d' "$FIX/routes"
route "$RUNS12" 'SEQ:run,run_done'
route 'api repos/example/repo/actions/runs?event=pull_request&head_sha=def34&per_page=100 *' run780
route 'pr view 12 --repo example/repo --json headRefOid*' 'SEQ:sha,sha2'
gate --reconcile
expect "a new head commit while waiting: its own check is left to run" 0 "has a new head commit since, with its own check (run 780)"
expect_absent "a new head commit while waiting: the old check is not re-run" "run rerun"

# A new head with no check of its own (a merge conflict): noted, not skipped.
others_fixture "" "$DUP_PAGE" in_progress
printf '777\tcompleted\tb12\texample/repo\n' >"$FIX/run_done"
printf 'def34\tb12\texample/repo\n' >"$FIX/sha2"
sed -i.bak '/actions\/runs/d; /pr view/d' "$FIX/routes"
route "$RUNS12" 'SEQ:run,run_done'
route 'api repos/example/repo/actions/runs?event=pull_request&head_sha=def34&per_page=100 *' EMPTY
route 'pr view 12 --repo example/repo --json headRefOid*' 'SEQ:sha,sha2'
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "a new head commit with no check of its own is a failure" 1 "no issue-claim.yml run on it"
expect_absent "a new head commit with no check of its own: the old check is not re-run" "run rerun"
noted_dry "a new head commit with no check of its own"

# The head cannot be read after waiting: not re-run blind, since the old run
# might cancel a newer check.
others_fixture "" "$DUP_PAGE" in_progress
printf '777\tcompleted\tb12\texample/repo\n' >"$FIX/run_done"
sed -i.bak '/actions\/runs/d; /pr view/d' "$FIX/routes"
route "$RUNS12" 'SEQ:run,run_done'
route 'pr view 12 --repo example/repo --json headRefOid*' 'SEQ:sha,FAIL'
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "a head that cannot be read after waiting is a failure" 1 "could not read the head commit of #12 after waiting"
expect_absent "a head that cannot be read after waiting: nothing is re-run" "run rerun"
noted_dry "a head that cannot be read after waiting"

# Two pull requests at one commit: each re-runs its own run, found by branch.
others_fixture "" "$DUP_PAGE"
printf '777\tcompleted\tb12\texample/repo\n790\tcompleted\tb99\texample/repo\n' >"$FIX/run"
gate --reconcile
expect "two pull requests at one commit: the run on this one's branch is re-run" 0 "run rerun 777"
expect_absent "two pull requests at one commit: the other's run is not re-run" "run rerun 790"

# One that never finishes in time: fail, and say so on that pull request.
others_fixture "" "$DUP_PAGE" in_progress
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "a check that never finishes is a failure" 1 "had not finished by this job's deadline (status: in_progress)"
expect_absent "a check that never finishes is not re-run" "run rerun"
noted_dry "a check that never finishes"

# Its status cannot be read while waiting: keep waiting, then fail and say why.
others_fixture "" "$DUP_PAGE" in_progress
sed -i.bak '/actions\/runs/d' "$FIX/routes"
route "$RUNS12" 'SEQ:run,FAIL'
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "a status that cannot be read while waiting is a failure" 1 "(status: ?)"
expect_absent "a status that cannot be read while waiting: nothing is re-run" "run rerun"
noted_dry "a status that cannot be read while waiting"

# The waits share one deadline: the second pull request is not given a fresh
# one, so a job with many unfinished checks ends with every one noted, not
# killed part way.
reset_fixture
serve "$(page "$(node 10 A '' b10 5)" "$(node 12 B '' b12 5)" "$(node 14 C '' b14 5)")"
route 'pr list --repo example/repo --state open --label merge:duplicate-claim --limit 1000 *' EMPTY
printf 'abc12\tb12\texample/repo\n' >"$FIX/sha12"
printf 'abc14\tb14\texample/repo\n' >"$FIX/sha14"
printf '777\tin_progress\tb12\texample/repo\n' >"$FIX/run12"
printf '779\tin_progress\tb14\texample/repo\n' >"$FIX/run14"
route 'pr view 12 --repo example/repo --json headRefOid*' sha12
route 'pr view 14 --repo example/repo --json headRefOid*' sha14
route "$RUNS12" run12
route 'api repos/example/repo/actions/runs?event=pull_request&head_sha=abc14&per_page=100 *' run14
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
route 'api --paginate repos/example/repo/issues/14/comments --jq *' EMPTY
gate --reconcile
expect "several unfinished checks: every one is noted" 1 "issues/12/comments -f body=$MARK" "issues/14/comments -f body=$MARK"
polls14=$(grep -c 'head_sha=abc14' "$FIX/calls.log")
if [ "$polls14" = 1 ]; then ok "the waits share one deadline (the second is not waited for again)"; else bad "the waits share one deadline (the second is not waited for again)" "abc14 was asked $polls14 times"; fi

# The re-run is refused because another run of this started it first.
others_fixture "" "$DUP_PAGE"
route 'run rerun 777 --repo example/repo' FAIL
printf 'queued\n' >"$FIX/now"
route 'run view 777 --repo example/repo --json status --jq .status' now
gate_live --reconcile
expect "a re-run refused because it is already re-running is not a failure" 0 "re-run by something else"
if grep -q "comments" "$FIX/calls.log"; then bad "a re-run that is already re-running leaves no note" "$(cat "$FIX/calls.log")"; else ok "a re-run that is already re-running leaves no note"; fi

# The re-run fails and its status cannot be read either: a failure, not a race.
others_fixture "" "$DUP_PAGE"
route 'run rerun 777 --repo example/repo' FAIL
route 'run view 777 --repo example/repo --json status --jq .status' FAIL
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
route 'api repos/example/repo/issues/12/comments -f body=*' EMPTY
gate_live --reconcile
expect "a failed re-run whose status cannot be read is a failure" 1 "the re-run of run 777 for #12 failed"
if grep -q "issues/12/comments -f body=$MARK" "$FIX/calls.log"; then ok "a failed re-run whose status cannot be read is noted"; else bad "a failed re-run whose status cannot be read is noted" "$(cat "$FIX/calls.log")"; fi

# The re-run fails: fail, and say so on the pull request it was for.
others_fixture "" "$DUP_PAGE"
route 'run rerun 777 --repo example/repo' FAIL
printf 'completed\n' >"$FIX/now"
route 'run view 777 --repo example/repo --json status --jq .status' now
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
route 'api repos/example/repo/issues/12/comments -f body=*' EMPTY
gate_live --reconcile
expect "a re-run that fails fails the job" 1 "the re-run of run 777 for #12 failed"
if grep -q "issues/12/comments -f body=$MARK" "$FIX/calls.log" && grep -q "not re-checked" "$FIX/calls.log"; then
	ok "a re-run that fails is noted on the pull request it was for"
else
	bad "a re-run that fails is noted on the pull request it was for" "$(cat "$FIX/calls.log")"
fi

others_fixture "" "$DUP_PAGE"
route 'run rerun 777 --repo example/repo' FAIL
route 'run view 777 --repo example/repo --json status --jq .status' now
printf 'completed\n' >"$FIX/now"
printf '555\n' >"$FIX/comment"
route 'api --paginate repos/example/repo/issues/12/comments --jq *' comment
route 'api -X PATCH repos/example/repo/issues/comments/555 *' EMPTY
gate_live --reconcile
expect "a failed re-run edits the gate's comment rather than adding one" 1
if grep -q "PATCH repos/example/repo/issues/comments/555 -f body=$MARK" "$FIX/calls.log" && ! grep -q "issues/12/comments -f body" "$FIX/calls.log"; then
	ok "a failed re-run's note replaces the gate's comment"
else
	bad "a failed re-run's note replaces the gate's comment" "$(cat "$FIX/calls.log")"
fi

# Could not read the claims: --reconcile stops, even with a labelled one it
# could otherwise re-run.
others_fixture 12 "$CLEAR_PAGE"
sed -i.bak '/api graphql/d' "$FIX/routes"
route 'api graphql --paginate *' FAIL
gate --reconcile
expect "--reconcile fails when it could not read the claims" 1 "could not read the claims"
expect_absent "--reconcile re-runs nothing when it could not read the claims" "run rerun"

# Could not list the labelled ones: both modes stop and fail.
for mode in --reconcile --after-close; do
	others_fixture "" "$DUP_PAGE"
	sed -i.bak '/pr list/d' "$FIX/routes"
	route 'pr list --repo example/repo --state open --label merge:duplicate-claim --limit 1000 *' FAIL
	gate "$mode"
	expect "$mode fails when it could not list the labelled pull requests" 1 "could not list the pull requests that carry merge:duplicate-claim"
	expect_absent "$mode re-runs nothing when it could not list the labelled" "run rerun"
done

# Each other way a re-run can fail is noted on the pull request it was for.
others_fixture "" "$DUP_PAGE"
sed -i.bak '/pr view/d' "$FIX/routes"
route 'pr view 12 --repo example/repo --json headRefOid*' FAIL
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "a head commit that cannot be read is a failure" 1 "could not read the head commit of #12"
noted_dry "a head commit that cannot be read"

others_fixture "" "$DUP_PAGE"
sed -i.bak '/actions\/runs/d' "$FIX/routes"
route "$RUNS12" FAIL
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --reconcile
expect "runs that cannot be listed are a failure" 1 "could not list the issue-claim.yml runs for #12"
noted_dry "runs that cannot be listed"

# --except matches the whole number: excepting #1 does not leave out #12.
others_fixture "" "$DUP_PAGE"
gate --reconcile --except 1
expect "--except 1 does not leave out #12" 0 "run rerun 777"

gate --reconcile --except
expect "--except with no number is refused" 1 "--except needs a pull request number"
expect_absent "a usage error re-runs nothing" "run rerun"
gate --reconcile --except abc
expect "--except with no number (abc) is refused" 1 "--except needs a pull request number"
expect_absent "a usage error (abc) re-runs nothing" "run rerun"
gate --reconcile 12
expect "--reconcile with a number is refused" 1 "takes no pull request number"
expect_absent "a usage error (a number) re-runs nothing" "run rerun"

# After a close: every labelled one, still refused or not, so its comment
# names the holder it has now.
others_fixture 12 "$DUP_PAGE"
gate --after-close
expect "after a close, a labelled check is re-run even if still refused" 0 "run rerun 777"

others_fixture "" "$DUP_PAGE"
gate --after-close
expect "after a close, an unlabelled duplicate is re-run" 0 "run rerun 777"

others_fixture "" "$CLEAR_PAGE"
gate --after-close
expect "after a close with nobody labelled or refused, nothing is re-run" 0 "Nothing to re-run"

others_fixture 12 "$CLEAR_PAGE"
sed -i.bak '/api graphql/d' "$FIX/routes"
route 'api graphql --paginate *' FAIL
gate --after-close
expect "after a close, a failed claims read still re-runs the labelled, and fails" 1 "run rerun 777" "labelled ones only"

others_fixture 12 "$CLEAR_PAGE"
sed -i.bak '/actions\/runs/d' "$FIX/routes"
route "$RUNS12" EMPTY
route 'api --paginate repos/example/repo/issues/12/comments --jq *' EMPTY
gate --after-close
expect "after a close, a PR with no run to re-run is a failure" 1 "no issue-claim.yml run"
noted_dry "a PR with no run to re-run"

# After a close, claims unreadable and nobody labelled: nothing to re-run, and
# still a failure, because it could not look for new duplicates.
others_fixture "" "$CLEAR_PAGE"
sed -i.bak '/api graphql/d' "$FIX/routes"
route 'api graphql --paginate *' FAIL
gate --after-close
expect "after a close, a failed claims read with nobody labelled still fails" 1 "could not read the claims" "labelled ones only"

# --------------------------------------------------------------------------
# 3h. The workflow templates: what claim-gate.sh relies on, read line by line
#     (whole lines, so a comment cannot stand in for the setting).
# --------------------------------------------------------------------------
TPL_CLAIM=$(tr -d '\r' <"$HERE/../issue-claim.example.yml")
TPL_OTHERS=$(tr -d '\r' <"$HERE/../issue-claim-others.example.yml")
# yml_block <text> <key> — the lines under one two-space key (a trigger or a job),
# up to the next one.
yml_block() {
	printf '%s\n' "$1" | awk -v k="  $2:" '$0 == k { on = 1; print; next } on && /^  [a-z]/ { exit } on { print }'
}
# step_with <text> <line> — the step (from its "      - " line) holding <line>.
step_with() {
	printf '%s\n' "$1" | awk -v want="$2" '
		/^      - / { if (hit) { printf "%s", buf; exit } buf = ""; hit = 0 }
		{ buf = buf $0 "\n"; if ($0 == want) hit = 1 }
		END { if (hit) printf "%s", buf }'
}
has() {
	if grep -Fxq -- "$3" <<<"$2"; then ok "template: $1"; else bad "template: $1" "no line: $3"; fi
}
lacks() {
	if grep -Eq -- "$3" <<<"$2"; then bad "template: $1" "a line matches: $3"; else ok "template: $1"; fi
}
has "issue-claim.yml: pull_request covers opened, edited, synchronize, reopened, ready_for_review" \
	"$(yml_block "$TPL_CLAIM" pull_request)" '    types: [opened, edited, synchronize, reopened, ready_for_review]'
lacks "issue-claim.yml has no pull_request_target run, so no skipped 'issue claim' beside the real one" "$TPL_CLAIM" '^  pull_request_target:'
claim_job=$(yml_block "$TPL_CLAIM" claim)
has "the claim job is the one named 'issue claim'" "$claim_job" '    name: issue claim'
has "the claim job checks one pull request" "$claim_job" '        run: bash tools/merge-coordinator/scripts/claim-gate.sh "$PR"'
has "issue-claim-others.yml: pull_request_target covers the same and closed" \
	"$(yml_block "$TPL_OTHERS" pull_request_target)" '    types: [opened, edited, synchronize, reopened, ready_for_review, closed]'
lacks "issue-claim-others.yml runs on no other event" "$TPL_OTHERS" '^  (pull_request|merge_group|push):'
others_job=$(yml_block "$TPL_OTHERS" others)
lacks "the others job has no job named 'issue claim'" "$TPL_OTHERS" '^    name: issue claim$'
has "the others job queues closes apart from other changes" "$others_job" "      group: issue-claim-others-\${{ github.event.action == 'closed' && 'close' || 'change' }}"
has "the others job is never cancelled midway" "$others_job" '      cancel-in-progress: false'
has "the others job can re-run checks" "$others_job" '      actions: write # re-run the check'
lacks "the others job checks out no pull request code (no ref:)" "$others_job" '^ +ref:'
lacks "the others job checks out no pull request code (no head)" "$others_job" 'pull_request\.head'
step=$(step_with "$others_job" '        run: bash tools/merge-coordinator/scripts/claim-gate.sh --reconcile')
has "every change but a close reconciles every pull request, its own included" "$step" "        if: github.event.action != 'closed'"
lacks "no step leaves out the pull request whose event fired (it may have a merge conflict)" "$others_job" '--except'
step=$(step_with "$others_job" '        run: bash tools/merge-coordinator/scripts/claim-gate.sh --after-close')
has "a close re-checks after the close" "$step" "        if: github.event.action == 'closed'"

# --------------------------------------------------------------------------
# 4. The EnterWorktree hook.
# --------------------------------------------------------------------------
PROJ="$WORK/project"
mkdir -p "$PROJ/.github"
git -C "$PROJ" init -q
cp "$WORK/config.json" "$PROJ/.github/merge-coordinator.json"

# hook <payload> — guard-claim.sh with this payload, run from the scratch
# folder: with no repository in the payload or the project folder, the hook
# falls back to the folder it runs in, and from scripts/ that is this
# repository, which has adopted its own plugin.
hook() {
	set +e
	out=$(cd "$WORK" && printf '%s' "$1" | CLAUDE_PROJECT_DIR="${HOOK_PROJECT:-$PROJ}" MC_WORKTREE_LIST="$FIX/worktrees" \
		MC_PID_PROBE="$FIX/probe.sh" bash "$HERE/guard-claim.sh" 2>&1)
	status=$?
	set -e
}

reset_fixture
serve "$(page "$(node 10 A "$(block 'issue: 555')" b10 '')")"
printf 'worktree /w/b10\nHEAD aaa\nbranch refs/heads/b10\nlocked claude session b10 (pid 4242)\n\n' >"$FIX/worktrees"
hook '{"tool_name":"EnterWorktree","tool_input":{"name":"fix-555-nav"}}'
expect "the hook refuses a worktree for a claimed issue" 0 '"permissionDecision": "deny"' "issue #555 is already claimed" "#10"
expect "the refusal says whether the holder's session is live" 0 "session: live 4242"

reset_fixture
serve "$(page "$(node 11 'Names (#555)' '' b11 '')")"
hook '{"tool_name":"EnterWorktree","tool_input":{"name":"fix-555-nav"}}'
expect "the hook lets a worktree go ahead when the issue is only named" 0 "no open pull request claims issue #555"
expect_absent "a mention is not a refusal" "deny"

reset_fixture
hook '{"tool_name":"EnterWorktree","tool_input":{"name":"content-audit"}}'
expect "a name with no issue number goes ahead" 0
if [ ! -s "$FIX/calls.log" ]; then ok "a name with no issue number asks GitHub nothing"; else bad "a name with no issue number asks GitHub nothing" "$(cat "$FIX/calls.log")"; fi

reset_fixture
hook '{"tool_name":"EnterWorktree","tool_input":{"path":"/w/.claude/worktrees/fix-555-nav"}}'
expect "entering an existing worktree by path is not checked" 0
expect_absent "entering by path is not refused" "deny"

reset_fixture
route 'api graphql --paginate *' FAIL
hook '{"tool_name":"EnterWorktree","tool_input":{"name":"fix-555-nav"}}'
expect "the hook fails open when GitHub cannot be read" 0 "could not check whether issue #555 is claimed"
expect_absent "a failed read is not a refusal" "deny"

# The repository is where the session STANDS (the payload's cwd), not the folder
# it began in. [7 Oct 2026] A session that began above the checkout had no
# config at CLAUDE_PROJECT_DIR, and this hook waved every worktree through.
reset_fixture
serve "$(page "$(node 10 A "$(block 'issue: 555')" b10 '')")"
printf 'worktree /w/b10
HEAD aaa
branch refs/heads/b10
locked claude session b10 (pid 4242)

' >"$FIX/worktrees"
mkdir -p "$WORK/outer"
HOOK_PROJECT="$WORK/outer" hook "{\"tool_name\":\"EnterWorktree\",\"cwd\":\"$PROJ\",\"tool_input\":{\"name\":\"fix-555-nav\"}}"
expect "a session that began above the checkout still refuses a claimed issue" 0 '"permissionDecision": "deny"' "issue #555 is already claimed"

# --------------------------------------------------------------------------
# 5. ready.sh keeps a refused claim a draft, --force or not.
# --------------------------------------------------------------------------
reset_fixture
printf 'true\n' >"$FIX/draft"
printf 'merge:duplicate-claim\n' >"$FIX/labels"
# A real title, so the title gate passes and the label check is what refuses.
printf 'Fix the nav on narrow screens\tfix-555-nav\n' >"$FIX/title"
route 'pr view 12 --json isDraft *' draft
route 'pr view 12 --json title,headRefName *' title
route 'api repos/example/repo/issues/12/labels --jq *' labels
set +e
out=$(bash "$HERE/ready.sh" 12 --force 2>&1)
status=$?
set -e
expect "ready.sh refuses a PR whose claim was refused, even with --force" 1 "merge:duplicate-claim" "stays a draft"
if contains "$(cat "$FIX/calls.log")" "pr ready"; then
	bad "ready.sh does not mark a refused claim ready" "$(cat "$FIX/calls.log")"
else
	ok "ready.sh does not mark a refused claim ready"
fi

# --------------------------------------------------------------------------
# 6. SESSION.
# --------------------------------------------------------------------------
session_case() {
	local got
	got=$(MC_PID_PROBE="$FIX/probe.sh" mc_session_state "$1" "$(cat "$FIX/worktrees")")
	if [ "$got" = "$2" ]; then ok "$3"; else bad "$3" "got '$got', wanted '$2'"; fi
}
reset_fixture
cat >"$FIX/worktrees" <<'WT'
worktree /w/main
HEAD aaa
branch refs/heads/main

worktree /w/one
HEAD bbb
branch refs/heads/one
locked claude session one (pid 101)

worktree /w/two
HEAD ccc
branch refs/heads/two

worktree /w/three
HEAD ddd
branch refs/heads/three
locked

WT
session_case one "live 101" "a lock with a live pid reads live"
session_case two "unlocked" "a worktree with no lock reads unlocked, not the lock above it"
session_case three "locked" "a lock with no pid reads locked"
session_case four "-" "no worktree for a branch reads -"
printf 'echo dead\n' >"$FIX/probe.sh"
session_case one "dead 101" "a lock whose process is gone reads dead"
printf 'echo unknown\n' >"$FIX/probe.sh"
session_case one "? 101" "a pid this machine cannot check reads ?"

echo
echo "test-claims: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
