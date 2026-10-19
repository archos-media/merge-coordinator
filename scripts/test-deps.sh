#!/usr/bin/env bash
# Tests deps-open.sh, the Dependabot lister, and deps.sh, /merge-deps.
#
# The lister is what every part of the Dependabot gate stands on, and a lister
# that matches nothing fails in silence: the gate never fires and every test of
# the gate still passes. So most of these are about WHICH pull requests it keeps.
# The bot has three names (see deps-open.sh), and a human account can be called
# dependabot too.
#
# Unlike most suites here, these hand the scripts whole GitHub responses, not
# what a --jq filter would have printed: both scripts read the JSON themselves,
# so the filter is under test as well. gh is lib/fixture-gh.sh; nothing here
# touches the network.
set -euo pipefail

# contains <haystack> <needle> — substring test, done in the shell. Never
# `printf | grep -q`: under pipefail a found string can arrive as status 141.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
HERE=$(pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; shift; printf '%s\n' "$*" | sed 's/^/    /'; fail=$((fail + 1)); }

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "dependabot": {
    "fixups": [{ "when": "go/go.mod", "run": "cd go && go mod vendor", "why": "vendored modules must match go.mod" }],
    "pairings": [{ "package": "next", "with": "eslint-config-next", "why": "keep the lint config on the same major as next" }]
  }
}
JSON
# A config with none of the new keys: an adopted repository on release day.
cat >"$WORK/config-plain.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" }
}
JSON

FIX="$WORK/fix"
export MC_CONFIG="$WORK/config.json"
export MC_GH="$HERE/lib/fixture-gh.sh"
export MC_FIXTURES="$FIX"
export MC_NOW="2026-10-12T12:00:00Z"

# mc_py, the plugin's own way to find a python that runs.
# shellcheck source=lib/gh.sh
. "$HERE/lib/gh.sh"

# page <file> <hasNext> <cursor> <pr>... — a GraphQL page of open pull requests.
# Each <pr> is number|typename|login|labels(+ joined)|inQueue|created|sha.
page() {
	local file="$1" next="$2" cursor="$3"
	shift 3
	mc_py - "$next" "$cursor" "$@" >"$file" <<'PY'
import json, sys
nxt, cursor, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
nodes = []
for spec in specs:
    number, typename, login, labels, queued, created, sha = spec.split("|")
    nodes.append({"number": int(number), "title": "Bump thing%s from 1.0.0 to 2.0.0" % number,
                  "createdAt": created, "isInMergeQueue": queued == "1", "headRefOid": sha,
                  "author": {"__typename": typename, "login": login},
                  "labels": {"nodes": [{"name": l} for l in labels.split("+") if l]}})
print(json.dumps({"data": {"repository": {"pullRequests": {
    "pageInfo": {"hasNextPage": nxt == "1", "endCursor": cursor or None}, "nodes": nodes}}}}))
PY
}

# Timestamps against MC_NOW, 12 Oct 12:00.
D3="2026-10-09T11:00:00Z"   # 3 days
H5="2026-10-12T07:00:00Z"   # 5 hours
M10="2026-10-12T11:50:00Z"  # under an hour

reset() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"
	printf '{"check_runs":[{"status":"completed","conclusion":"success"}]}' >"$FIX/runs-green.json"
	printf '{"check_runs":[{"status":"in_progress","conclusion":null}]}' >"$FIX/runs-running.json"
	printf '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}' >"$FIX/runs-red.json"
	printf '{"check_runs":[]}' >"$FIX/runs-none.json"
	printf '{"state":"success","statuses":[]}' >"$FIX/status-none.json"
	printf '{"state":"failure","statuses":[{"context":"ci/x","state":"failure"}]}' >"$FIX/status-red.json"
	: >"$FIX/routes"
}

route() { printf '%s\t%s\n' "$1" "$2" >>"$FIX/routes"; }

# Routes for the CI of one head: <sha> <runs file> [status file].
ci() {
	route "api --paginate repos/example/repo/commits/$1/check-runs*" "$2"
	route "api repos/example/repo/commits/$1/status" "${3:-status-none.json}"
}

list() {
	set +e
	out=$(bash "$HERE/deps-open.sh" 2>"$WORK/err")
	status=$?
	set -e
	err=$(cat "$WORK/err")
}

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Which pull requests are kept.
# ---------------------------------------------------------------------------
reset
page "$FIX/p1.json" 0 "" \
	"11|Bot|dependabot||0|$D3|sha11" \
	"12|User|dependabot||0|$D3|sha12" \
	"13|Bot|renovate||0|$D3|sha13" \
	"14|User|alice||0|$D3|sha14" \
	"15|Bot|dependabot|merge:blocked|0|$D3|sha15" \
	"16|Bot|dependabot||1|$H5|sha16" \
	"17|Bot|dependabot|merge:landing+size:S|0|$M10|sha17" \
	"18|Bot|dependabot|deps:safe|0|$D3|sha18"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha11 runs-green.json
ci sha16 runs-running.json
ci sha17 runs-none.json
ci sha18 runs-red.json
list
if [ "$status" -ne 0 ]; then
	bad "the lister answers" "status $status" "$err"
else
	ok "the lister answers"
fi
contains "$out" "11${TAB}waiting${TAB}3 days${TAB}passed${TAB}-${TAB}Bump thing11" && ok "a Bot called dependabot is kept, with its age and CI" || bad "a Bot called dependabot is kept, with its age and CI" "$out"
contains "$out" "12${TAB}" && bad "a human account called dependabot is not kept" "$out" || ok "a human account called dependabot is not kept"
contains "$out" "13${TAB}" && bad "another bot is not kept" "$out" || ok "another bot is not kept"
contains "$out" "14${TAB}" && bad "a person's pull request is not kept" "$out" || ok "a person's pull request is not kept"
contains "$out" "15${TAB}" && bad "a pull request carrying the blocked label is dropped" "$out" || ok "a pull request carrying the blocked label is dropped"
contains "$out" "16${TAB}landing${TAB}5 hours${TAB}running" && ok "one in the merge queue is marked landing, not dropped" || bad "one in the merge queue is marked landing, not dropped" "$out"
contains "$out" "17${TAB}landing${TAB}under an hour${TAB}none" && ok "one holding the landing label is marked landing" || bad "one holding the landing label is marked landing" "$out"
contains "$out" "18${TAB}waiting${TAB}3 days${TAB}failed${TAB}safe${TAB}" && ok "a /merge-deps verdict is read from its label, and does not stop it waiting" || bad "a /merge-deps verdict is read from its label, and does not stop it waiting" "$out"
rows=$(printf '%s\n' "$out" | grep -c . || true)
[ "$rows" -eq 4 ] && ok "exactly the four Dependabot pull requests" || bad "exactly the four Dependabot pull requests" "$rows rows:" "$out"

# The REST spelling of the bot is kept too, in case GitHub ever returns it here.
reset
page "$FIX/p1.json" 0 "" "21|Bot|dependabot[bot]||0|$D3|sha21"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha21 runs-green.json
list
contains "$out" "21${TAB}waiting" && ok "the REST spelling dependabot[bot] is kept" || bad "the REST spelling dependabot[bot] is kept" "$out" "$err"

# ---------------------------------------------------------------------------
# CI states. A read that failed is not a red.
# ---------------------------------------------------------------------------
reset
page "$FIX/p1.json" 0 "" "31|Bot|dependabot||0|$D3|sha31" "32|Bot|dependabot||0|$D3|sha32" "33|Bot|dependabot||0|$D3|sha33"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
route "api --paginate repos/example/repo/commits/sha31/check-runs*" FAIL
ci sha32 runs-green.json status-red.json
route "api --paginate repos/example/repo/commits/sha33/check-runs*" runs-green.json
route "api repos/example/repo/commits/sha33/status" FAIL
list
[ "$status" -eq 0 ] && ok "a failed CI read does not fail the list" || bad "a failed CI read does not fail the list" "status $status" "$err"
contains "$out" "31${TAB}waiting${TAB}3 days${TAB}could not read" && ok "a failed check-run read reads 'could not read', and the pull request is still listed" || bad "a failed check-run read reads 'could not read', and the pull request is still listed" "$out"
contains "$out" "33${TAB}waiting${TAB}3 days${TAB}could not read" && ok "a failed status read reads 'could not read' too" || bad "a failed status read reads 'could not read' too" "$out"
contains "$out" "32${TAB}waiting${TAB}3 days${TAB}failed" && ok "a red commit status counts as failed" || bad "a red commit status counts as failed" "$out"

# ---------------------------------------------------------------------------
# Pages, and order.
# ---------------------------------------------------------------------------
reset
page "$FIX/p1.json" 1 "CUR1" "45|Bot|dependabot||0|$D3|sha45" "41|User|bob||0|$D3|sha41"
page "$FIX/p2.json" 0 "" "42|Bot|dependabot||0|$H5|sha42"
route "api graphql -f owner=example -f name=repo -f cursor=CUR1 -f query=*" p2.json
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha45 runs-green.json
ci sha42 runs-green.json
list
contains "$out" "42${TAB}waiting${TAB}5 hours" && ok "a Dependabot pull request on the second page is listed" || bad "a Dependabot pull request on the second page is listed" "$out" "$err"
first=$(printf '%s\n' "$out" | sed -n '1p' | cut -f1)
[ "$first" = "42" ] && ok "oldest number first" || bad "oldest number first" "$out"

# A page that says there is another and gives no cursor is not the end.
reset
page "$FIX/p1.json" 1 "" "51|Bot|dependabot||0|$D3|sha51"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha51 runs-green.json
list
[ "$status" -eq 3 ] && [ -z "$out" ] && ok "a next page with no cursor is 'could not look'" || bad "a next page with no cursor is 'could not look'" "status $status" "$out"

# ---------------------------------------------------------------------------
# Could not look, and nothing there. These must never read the same.
# ---------------------------------------------------------------------------
reset
route "api graphql -f owner=example -f name=repo -f query=*" FAIL
list
[ "$status" -eq 3 ] && ok "a failed query exits 3" || bad "a failed query exits 3" "status $status" "$out"
[ -z "$out" ] && ok "and prints no rows" || bad "and prints no rows" "$out"

reset
printf '{"data":{"repository":null},"errors":[{"message":"Could not resolve to a Repository"}]}' >"$FIX/err.json"
route "api graphql -f owner=example -f name=repo -f query=*" err.json
list
[ "$status" -eq 3 ] && ok "a GraphQL error answered with 200 exits 3" || bad "a GraphQL error answered with 200 exits 3" "status $status" "$out"

reset
page "$FIX/p1.json" 1 "CUR1" "61|Bot|dependabot||0|$D3|sha61"
route "api graphql -f owner=example -f name=repo -f cursor=CUR1 -f query=*" FAIL
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha61 runs-green.json
list
[ "$status" -eq 3 ] && [ -z "$out" ] && ok "a failed second page exits 3 and prints none of the first" || bad "a failed second page exits 3 and prints none of the first" "status $status" "$out"

reset
page "$FIX/p1.json" 0 "" "71|User|alice||0|$D3|sha71"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
list
[ "$status" -eq 0 ] && [ -z "$out" ] && ok "none open: exit 0 and nothing printed" || bad "none open: exit 0 and nothing printed" "status $status" "$out" "$err"

# No config is "could not look", not "none open".
reset
MC_CONFIG="$WORK/nope.json" list
[ "$status" -eq 3 ] && ok "no config exits 3" || bad "no config exits 3" "status $status"

# ---------------------------------------------------------------------------
# More CI states, and the shapes gh really hands back.
# ---------------------------------------------------------------------------
reset
printf '{"check_runs":[{"status":"in_progress","conclusion":null},{"status":"completed","conclusion":"failure"}]}' >"$FIX/runs-mixed.json"
printf '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}' >"$FIX/runs-someskip.json"
printf '{"check_runs":[{"status":"completed","conclusion":"skipped"},{"status":"completed","conclusion":"skipped"}]}' >"$FIX/runs-allskip.json"
# gh --paginate writes one document per page, back to back.
printf '{"check_runs":[{"status":"completed","conclusion":"success"}]}\n{"check_runs":[{"status":"completed","conclusion":"failure"}]}' >"$FIX/runs-pages.json"
printf '{"message":"Not Found"}' >"$FIX/runs-wrong.json"
printf '{"state":"pending","statuses":[{"context":"ci/x","state":"pending"}]}' >"$FIX/status-pending.json"
page "$FIX/p1.json" 0 "" \
	"81|Bot|dependabot||0|$D3|sha81" "82|Bot|dependabot||0|$D3|sha82" "83|Bot|dependabot||0|$D3|sha83" \
	"84|Bot|dependabot||0|$D3|sha84" "85|Bot|dependabot||0|$D3|sha85" "86|Bot|dependabot||0|$D3|sha86" \
	"87|Bot|dependabot|deps:needs-fixup|0|$D3|sha87"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha81 runs-mixed.json
ci sha82 runs-someskip.json
ci sha83 runs-allskip.json
ci sha84 runs-pages.json
ci sha85 runs-wrong.json
ci sha86 runs-green.json status-pending.json
ci sha87 runs-green.json
list
contains "$out" "81${TAB}waiting${TAB}3 days${TAB}failed" && ok "a failure beside a running check reads failed" || bad "a failure beside a running check reads failed" "$out" "$err"
contains "$out" "82${TAB}waiting${TAB}3 days${TAB}passed" && ok "a skipped job beside a passing one reads passed" || bad "a skipped job beside a passing one reads passed" "$out"
contains "$out" "83${TAB}waiting${TAB}3 days${TAB}skipped" && ok "every check skipped reads skipped, never passed" || bad "every check skipped reads skipped, never passed" "$out"
contains "$out" "84${TAB}waiting${TAB}3 days${TAB}failed" && ok "a failure on the second page of check runs is read" || bad "a failure on the second page of check runs is read" "$out"
contains "$out" "85${TAB}waiting${TAB}3 days${TAB}could not read" && ok "a response of the wrong shape reads 'could not read', not failed" || bad "a response of the wrong shape reads 'could not read', not failed" "$out"
contains "$out" "86${TAB}waiting${TAB}3 days${TAB}running" && ok "a pending commit status reads running" || bad "a pending commit status reads running" "$out"
contains "$out" "87${TAB}waiting${TAB}3 days${TAB}passed${TAB}needs-fixup${TAB}" && ok "a needs-fixup verdict is read from its label" || bad "a needs-fixup verdict is read from its label" "$out"
calls=$(cat "$FIX/calls.log")
contains "$calls" "isInMergeQueue" && ok "the query asks for isInMergeQueue" || bad "the query asks for isInMergeQueue" "$calls"
contains "$calls" "check-runs?filter=latest&per_page=100" && ok "the check runs are the latest per name, paged" || bad "the check runs are the latest per name, paged" "$calls"

# Numbers, not text: 9 before 10.
reset
page "$FIX/p1.json" 0 "" "10|Bot|dependabot||0|$D3|sha10" "9|Bot|dependabot||0|$D3|sha9"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
ci sha10 runs-green.json
ci sha9 runs-green.json
list
first=$(printf '%s\n' "$out" | sed -n '1p' | cut -f1)
[ "$first" = "9" ] && ok "rows are in number order, not text order" || bad "rows are in number order, not text order" "$out"

# --no-ci: one query, and the CI column says it was not read.
reset
page "$FIX/p1.json" 0 "" "91|Bot|dependabot||0|$D3|sha91"
route "api graphql -f owner=example -f name=repo -f query=*" p1.json
set +e
out=$(bash "$HERE/deps-open.sh" --no-ci 2>"$WORK/err")
status=$?
set -e
calls=$(cat "$FIX/calls.log")
[ "$status" -eq 0 ] && contains "$out" "91${TAB}waiting${TAB}3 days${TAB}-${TAB}-${TAB}Bump thing91" && ok "--no-ci lists the rows with '-' for CI" || bad "--no-ci lists the rows with '-' for CI" "status $status" "$out" "$(cat "$WORK/err")"
contains "$calls" "check-runs" && bad "--no-ci reads no CI" "$calls" || ok "--no-ci reads no CI"

# ===========================================================================
# deps.sh — the facts for /merge-deps.
# ===========================================================================
# pr_json <file> <login> <type> <title> <body-file> [state] — a REST pull request.
pr_json() {
	MC_LOGIN="$2" MC_TYPE="$3" MC_TITLE="$4" MC_BODYF="$5" MC_STATE="${6:-open}" mc_py -c '
import json, os
print(json.dumps({"number": 90, "state": os.environ["MC_STATE"], "title": os.environ["MC_TITLE"],
                  "user": {"login": os.environ["MC_LOGIN"], "type": os.environ["MC_TYPE"]},
                  "head": {"sha": "depsha90", "ref": "dependabot/x"},
                  "body": open(os.environ["MC_BODYF"], encoding="utf-8").read()}))' >"$1"
}

# files_json <name>... — the pull request's files as the REST API gives them,
# raw. Each file gets a small patch naming it, so a test can see whose diff is
# printed.
files_json() {
	mc_py -c '
import json, sys
print(json.dumps([{"filename": f, "patch": "@@ -1 +1 @@\n-old " + f + "\n+new " + f} for f in sys.argv[1:]]))' "$@" >"$FIX/files90.json"
}

reset_deps() {
	reset
	printf 'CI passed\tsuccess\n' >"$FIX/checks.txt"
	printf '0\n' >"$FIX/behind.txt"
	{
		printf 'api repos/example/repo/pulls/90\tpr90.json\n'
		printf 'api --paginate repos/example/repo/pulls/90/files*\tfiles90.json\n'
		printf 'api repos/example/repo/compare/main...depsha90*\tbehind.txt\n'
		printf 'api --paginate repos/example/repo/commits/depsha90/check-runs*\tchecks.txt\n'
		printf 'api repos/example/repo/commits/depsha90/status*\tEMPTY\n'
	} >"$FIX/routes"
}

# record_routes — the writes --record makes, all routed, so a refusal can only
# come from the check under test and never from an unrouted call.
record_routes() {
	printf '%s\n' "${1:-size:S}" >"$FIX/labels90.txt"
	{
		printf 'label create *\tEMPTY\n'
		printf 'api repos/example/repo/issues/90/labels*\tlabels90.txt\n'
		printf 'pr edit 90 *\tEMPTY\n'
		printf 'pr comment 90 *\tEMPTY\n'
	} >>"$FIX/routes"
}

# called_line <line> — calls.log holds exactly this line. A substring would
# let deps:unsafe-x pass for deps:unsafe.
called_line() {
	grep -qFx -- "$1" "$FIX/calls.log"
}

facts() {
	set +e
	out=$(bash "$HERE/deps.sh" "$@" 2>&1)
	status=$?
	set -e
}

# A single bump. The title names no versions, so the "Bumps" line in the body
# is the only place they can come from: the title fallback cannot cover for it.
reset_deps
printf 'Bumps [golang.org/x/net](https://github.com/golang/net) from 0.30.0 to 1.0.0.\n<details><summary>Release notes</summary>NOTES-TEXT</details>\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Update golang.org/x/net in /go" "$WORK/body"
files_json go/go.mod go/go.sum
facts 90
[ "$status" -eq 0 ] && ok "deps.sh reads a single bump" || bad "deps.sh reads a single bump" "status $status" "$out"
contains "$out" "golang.org/x/net  0.30.0 -> 1.0.0  (MAJOR)" && ok "a single bump: package, versions and MAJOR" || bad "a single bump: package, versions and MAJOR" "$out"
contains "$out" "go/go.mod changes, so run: cd go && go mod vendor" && ok "a fix-up whose file changes is named" || bad "a fix-up whose file changes is named" "$out"
contains "$out" "NOTES-TEXT" && ok "Dependabot's description, with the release notes, is printed" || bad "Dependabot's description, with the release notes, is printed" "$out"
contains "$out" "  ok       CI passed" && ok "the required checks on the head are read" || bad "the required checks on the head are read" "$out"
contains "$out" "Behind main: no, it is current." && ok "a current branch says so" || bad "a current branch says so" "$out"
contains "$out" "+new go/go.mod" && ok "the manifest diff is printed" || bad "the manifest diff is printed" "$out"
contains "$out" "+new go/go.sum" && bad "a lock file's diff is left out" "$out" || ok "a lock file's diff is left out"
contains "$out" "--record safe|unsafe|fixup \"<one line why>\" depsha90" && ok "the record line carries the head the facts were read on" || bad "the record line carries the head the facts were read on" "$out"

# A grouped bump, in the table form and the Updates form.
reset_deps
cat >"$WORK/body" <<'BODY'
Bumps the web group with 3 updates in the /web directory:

| Package | From | To |
| --- | --- | --- |
| [next](https://github.com/vercel/next.js) | `15.1.0` | `16.0.1` |
| [zod](https://github.com/colinhacks/zod) | `0.4.0` | `0.5.0` |
| [left-pad](https://example.com) | `1.3.0` | `1.3.1` |

Updates `next` from 15.1.0 to 16.0.1
Updates `zod` from 0.4.0 to 0.5.0
BODY
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump the web group with 3 updates" "$WORK/body"
files_json web/package.json web/package-lock.json
printf '4\n' >"$FIX/behind.txt"
facts 90
contains "$out" "next  15.1.0 -> 16.0.1  (MAJOR)" && ok "a grouped bump lists each package" || bad "a grouped bump lists each package" "$out"
contains "$out" "zod  0.4.0 -> 0.5.0  (minor, on 0.x, where a minor can break)" && ok "a minor on 0.x says it can break" || bad "a minor on 0.x says it can break" "$out"
contains "$out" "left-pad  1.3.0 -> 1.3.1  (patch)" && ok "a package only in the table is listed" || bad "a package only in the table is listed" "$out"
n=$(printf '%s\n' "$out" | grep -c -- ' -> ' || true)
[ "$n" -eq 3 ] && ok "a package in both forms is listed once" || bad "a package in both forms is listed once" "$n lines" "$out"
contains "$out" "MISMATCH: next moves to 16.0.1 and eslint-config-next does not move with it." && ok "a pairing that does not move together is a MISMATCH" || bad "a pairing that does not move together is a MISMATCH" "$out"
contains "$out" "none for go/go.mod: no file it changes matches" && ok "a fix-up whose file does not change says so by name" || bad "a fix-up whose file does not change says so by name" "$out"
contains "$out" "Behind main: 4 commit(s)" && contains "$out" "not land.sh --update-branch" && ok "a branch behind says by how much, and how to bring it up to date" || bad "a branch behind says by how much, and how to bring it up to date" "$out"

# A pairing that moves together, and one that moves to different majors.
reset_deps
printf 'Updates `next` from 15.1.0 to 16.0.1\nUpdates `eslint-config-next` from 15.1.0 to 16.0.1\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump the web group" "$WORK/body"
files_json web/package.json
facts 90
contains "$out" "next and eslint-config-next move together, both to major 16." && ok "a pairing that moves together says so" || bad "a pairing that moves together says so" "$out"
printf 'Updates `next` from 15.1.0 to 16.0.1\nUpdates `eslint-config-next` from 15.1.0 to 15.2.0\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump the web group" "$WORK/body"
facts 90
contains "$out" "MISMATCH: next goes to 16.0.1 and eslint-config-next to 15.2.0." && ok "a pairing that moves to different majors is a MISMATCH" || bad "a pairing that moves to different majors is a MISMATCH" "$out"

# A fix-up glob that crosses directories.
reset_deps
cat >"$WORK/config-glob.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "dependabot": { "fixups": [{ "when": "**/go.mod", "run": "go mod vendor", "why": "vendored" }] }
}
JSON
printf 'Bumps [x](https://e.com) from 1.0.0 to 1.1.0.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
files_json svc/go/go.mod
MC_CONFIG="$WORK/config-glob.json" facts 90
contains "$out" "svc/go/go.mod changes, so run: go mod vendor" && ok "a fix-up glob matches across directories" || bad "a fix-up glob matches across directories" "$out"

# A fix-up that names what it writes. Dependabot regenerates a committed vendor/
# in the same commit as go.mod, so a bump that carries it needs nothing run.
# produces is read from the folder of the file that matched "when".
NL=$'\n'
# fixups_config <fixups as a JSON array> — a config with those fix-ups.
fixups_config() {
	cat >"$WORK/config-produces.json" <<JSON
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "dependabot": { "fixups": $1 }
}
JSON
}
# produces_config <produces as JSON> — the go fix-up with that produces.
produces_config() {
	fixups_config "[{ \"when\": \"go/go.mod\", \"run\": \"cd go && go mod vendor\", \"produces\": $1, \"why\": \"vendored modules must match go.mod\" }]"
}
reset_deps
printf 'Bumps [x](https://e.com) from 1.0.0 to 1.1.0.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
produces_config '"vendor/**"'
files_json go/go.mod go/go.sum go/vendor/modules.txt go/vendor/golang.org/x/net/http.go
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "go/go.mod changes, and so do 2 file(s) matching go/vendor/** (go/vendor/modules.txt): the pull request already carries cd go && go mod vendor." &&
	ok "a fix-up whose output the pull request changes is called carried" || bad "a fix-up whose output the pull request changes is called carried" "$out"
contains "$out" "so run:" && bad "a carried fix-up is not named as one to run" "$out" || ok "a carried fix-up is not named as one to run"
contains "$out" "Nothing to run, unless the required checks say" && ok "a carried fix-up points at the checks" || bad "a carried fix-up points at the checks" "$out"

# Output that changes while the file that triggers the fix-up does not: no fix-up.
files_json go/vendor/modules.txt
MC_CONFIG="$WORK/config-produces.json" facts 90
[ "$status" -eq 0 ] && contains "$out" "none for go/go.mod: no file it changes matches" &&
	ok "output changing on its own triggers no fix-up" || bad "output changing on its own triggers no fix-up" "status $status" "$out"

files_json go/go.mod go/go.sum
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "go/go.mod changes, so run: cd go && go mod vendor" && contains "$out" "no file matching go/vendor/** changes: the pull request does not carry it" &&
	ok "a fix-up whose output does not change is named, and says its output is missing" ||
	bad "a fix-up whose output does not change is named, and says its output is missing" "$out"

# Output at the root, outside the folder of the file that matched, is not its output.
files_json go/go.mod vendor/modules.txt
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "go/go.mod changes, so run: cd go && go mod vendor" && ! contains "$out" "already carries" &&
	ok "produces is read from the folder of the file that matched" || bad "produces is read from the folder of the file that matched" "$out"

# A produces broad enough to take in the trigger and the lock file beside it
# vouches with neither: Dependabot changes both on every bump.
produces_config '"**"'
files_json go/go.mod go/go.sum
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "go/go.mod changes, so run: cd go && go mod vendor" && ! contains "$out" "already carries" &&
	ok "the trigger and a lock file are not counted as output" || bad "the trigger and a lock file are not counted as output" "$out"

# Several modules in one grouped bump: each is judged on its own, so the one
# whose vendor/ did not come along is named, and so is a root module that only
# a nested module's vendor/ changed beside.
fixups_config '[{ "when": "**/go.mod", "run": "go mod vendor", "produces": "vendor/**", "why": "vendored" },
                { "when": "go.mod", "run": "go mod vendor", "produces": "vendor/**", "why": "vendored at the root" }]'
files_json go.mod a/go.mod a/vendor/modules.txt b/go.mod
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "a/go.mod changes, and so do 1 file(s) matching a/vendor/** (a/vendor/modules.txt): the pull request already carries go mod vendor." &&
	ok "a module whose vendor/ came along is carried" || bad "a module whose vendor/ came along is carried" "$out"
contains "$out" "b/go.mod changes, so run: go mod vendor" && contains "$out" "no file matching b/vendor/** changes" &&
	ok "another module in the same bump is named on its own" || bad "another module in the same bump is named on its own" "$out"
contains "$out" "go.mod changes, so run: go mod vendor${NL}    why: vendored at the root" && contains "$out" "no file matching vendor/** changes" &&
	ok "a nested vendor/ does not vouch for the root module" || bad "a nested vendor/ does not vouch for the root module" "$out"

# Two fix-ups, one carried and one not: each is judged on its own.
fixups_config '[{ "when": "go/go.mod", "run": "cd go && go mod vendor", "produces": "vendor/**", "why": "vendored" },
                { "when": "web/package.json", "run": "npm run gen", "produces": "gen/**", "why": "generated types" }]'
files_json go/go.mod go/vendor/modules.txt web/package.json
MC_CONFIG="$WORK/config-produces.json" facts 90
contains "$out" "the pull request already carries cd go && go mod vendor." && contains "$out" "web/package.json changes, so run: npm run gen" &&
	contains "$out" "no file matching web/gen/** changes" &&
	ok "of two fix-ups, the carried one and the one to run are each said" || bad "of two fix-ups, the carried one and the one to run are each said" "$out"

# No produces, the 0.4.0 shape: the fix-up is named and nothing is said about output.
reset_deps
printf 'Bumps [x](https://e.com) from 1.0.0 to 1.1.0.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
files_json go/go.mod go/vendor/modules.txt
facts 90
[ "$status" -eq 0 ] && contains "$out" "go/go.mod changes, so run: cd go && go mod vendor" && ! contains "$out" "no file matching" && ! contains "$out" "already carries" &&
	ok "a fix-up with no produces is named whatever else changes" || bad "a fix-up with no produces is named whatever else changes" "status $status" "$out"

for bad_produces in 3 '""' '"   "' '" vendor/**"' '"/vendor/**"' '["vendor/**"]'; do
	produces_config "$bad_produces"
	MC_CONFIG="$WORK/config-produces.json" facts 90
	[ "$status" -ne 0 ] && contains "$out" "produces, when given, is a glob" &&
		ok "a produces of $bad_produces is refused" || bad "a produces of $bad_produces is refused" "status $status" "$out"
done

# A pseudo-version: the numbers agree and the strings do not.
reset_deps
printf 'Bumps [golang.org/x/exp](https://e.com) from v0.0.0-20240101000000-abc to v0.0.0-20250101000000-def.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump golang.org/x/exp" "$WORK/body"
files_json go/go.mod
facts 90
contains "$out" "(unknown (a pseudo or pre-release version; read the commits))" && ok "a pseudo-version bump is not called the same version" || bad "a pseudo-version bump is not called the same version" "$out"

# Only the title, when the body is in neither form.
reset_deps
printf 'Something else entirely.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "chore(deps): bump lodash from 4.17.20 to 4.17.21" "$WORK/body"
files_json package.json
facts 90
contains "$out" "lodash  4.17.20 -> 4.17.21  (patch)" && ok "the title is read when the body says nothing" || bad "the title is read when the body says nothing" "$out"

# Not a Dependabot pull request: a person by the name, and another bot.
reset_deps
pr_json "$FIX/pr90.json" "dependabot" User "Bump x from 1 to 2" "$WORK/body"
facts 90
[ "$status" -ne 0 ] && contains "$out" "not by Dependabot" && ok "a person called dependabot is refused" || bad "a person called dependabot is refused" "status $status" "$out"
reset_deps
pr_json "$FIX/pr90.json" "renovate[bot]" Bot "Update x to v2" "$WORK/body"
record_routes
facts 90 --record safe "x"
calls=$(cat "$FIX/calls.log")
[ "$status" -ne 0 ] && contains "$out" "not by Dependabot" && ! contains "$calls" "pr edit" && ok "another bot's pull request is refused, and nothing is written" || bad "another bot's pull request is refused, and nothing is written" "status $status" "$out"

# A closed one.
reset_deps
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body" closed
record_routes
facts 90 --record safe "x"
calls=$(cat "$FIX/calls.log")
[ "$status" -ne 0 ] && contains "$out" "is closed, not open" && ! contains "$calls" "pr edit" && ok "a closed pull request is refused, and nothing is written" || bad "a closed pull request is refused, and nothing is written" "status $status" "$out"

# A config with none of the new keys still gives the facts.
reset_deps
printf 'Bumps [x](https://e.com) from 1.0.0 to 1.1.0.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
files_json go/go.mod
MC_CONFIG="$WORK/config-plain.json" facts 90
[ "$status" -eq 0 ] && contains "$out" "none configured (dependabot.fixups)" && contains "$out" "none configured (dependabot.pairings)" &&
	ok "a config with no dependabot block gives the facts and says none is configured" ||
	bad "a config with no dependabot block gives the facts and says none is configured" "status $status" "$out"

# ---------------------------------------------------------------------------
# --record
# ---------------------------------------------------------------------------
reset_deps
printf 'Bumps [x](https://e.com) from 1.0.0 to 1.1.0.\n' >"$WORK/body"
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
record_routes "size:S,deps:unsafe"
facts 90 --record safe "patch, notes clean, CI green" depsha90
calls=$(cat "$FIX/calls.log")
[ "$status" -eq 0 ] && ok "--record safe succeeds" || bad "--record safe succeeds" "status $status" "$out"
contains "$calls" "label create deps:safe --repo example/repo" && ok "the label is created on first use" || bad "the label is created on first use" "$calls"
called_line "pr edit 90 --repo example/repo --add-label deps:safe" && ok "deps:safe is set" || bad "deps:safe is set" "$calls"
contains "$calls" "pr edit 90 --repo example/repo --remove-label deps:unsafe" && ok "an older verdict is removed" || bad "an older verdict is removed" "$calls"
contains "$calls" "--remove-label deps:needs-fixup" && bad "a verdict it does not carry is not removed" "$calls" || ok "a verdict it does not carry is not removed"
contains "$calls" "pr comment 90 --repo example/repo --body **/merge-deps verdict: safe to land.**" && contains "$calls" "patch, notes clean, CI green" &&
	ok "one comment says the verdict and why" || bad "one comment says the verdict and why" "$calls"
contains "$calls" "Head reviewed: depsha90" && ok "the comment names the head that was reviewed" || bad "the comment names the head that was reviewed" "$calls"

reset_deps
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
record_routes "size:S,deps:unsafe"
facts 90 --record fixup "go mod vendor needed"
calls=$(cat "$FIX/calls.log")
called_line "pr edit 90 --repo example/repo --add-label deps:needs-fixup" && called_line "pr edit 90 --repo example/repo --remove-label deps:unsafe" && ok "--record fixup sets deps:needs-fixup in place of the old verdict" || bad "--record fixup sets deps:needs-fixup in place of the old verdict" "$calls"
contains "$calls" "Head when recorded: depsha90" && ok "with no head given, the comment says the head is the one at recording" || bad "with no head given, the comment says the head is the one at recording" "$calls"

reset_deps
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
record_routes
facts 90 --record unsafe "drops Node 18" depsha90
calls=$(cat "$FIX/calls.log")
called_line "pr edit 90 --repo example/repo --add-label deps:unsafe" && ok "--record unsafe sets deps:unsafe" || bad "--record unsafe sets deps:unsafe" "$calls"

# A head that moved since the facts were read.
reset_deps
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
record_routes
facts 90 --record safe "fine" oldsha
calls=$(cat "$FIX/calls.log")
[ "$status" -ne 0 ] && contains "$out" "has moved since the facts were read" && ! contains "$calls" "label create" && ! contains "$calls" "pr comment" &&
	ok "a head that moved since the facts refuses, and writes nothing" || bad "a head that moved since the facts refuses, and writes nothing" "status $status" "$out" "$calls"

reset_deps
pr_json "$FIX/pr90.json" "dependabot[bot]" Bot "Bump x" "$WORK/body"
record_routes
facts 90 --record fixup "   "
calls=$(cat "$FIX/calls.log")
[ "$status" -ne 0 ] && contains "$out" "needs a reason" && ! contains "$calls" "label create" && ! contains "$calls" "pr comment" &&
	ok "--record with no reason writes nothing" || bad "--record with no reason writes nothing" "status $status" "$out" "$calls"
facts 90 --record maybe "why"
[ "$status" -ne 0 ] && contains "$out" "safe, unsafe or fixup" && ok "an unknown verdict is refused" || bad "an unknown verdict is refused" "status $status" "$out"

reset_deps
pr_json "$FIX/pr90.json" "alice" User "Fix a thing" "$WORK/body"
record_routes
facts 90 --record safe "fine"
calls=$(cat "$FIX/calls.log")
[ "$status" -ne 0 ] && ! contains "$calls" "pr edit" && ok "--record on a pull request that is not Dependabot's writes nothing" || bad "--record on a pull request that is not Dependabot's writes nothing" "status $status" "$calls"

echo
echo "test-deps: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
