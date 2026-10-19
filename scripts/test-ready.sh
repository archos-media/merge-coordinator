#!/usr/bin/env bash
# Tests ready.sh — the title gate it runs before it marks a pull request ready.
#
# The squash commit on main takes the pull request title, and main cannot be
# changed after the merge. So a title that is only the branch name must stop
# ready.sh. Most cases here are titles that must be REFUSED, in each form that
# register.sh and EnterWorktree produce. The allow cases prove that a real title
# still gets through, including one that repeats words from the branch.
#
# The proof of a refusal is the call log: no `pr ready` call was made. An exit
# status alone is not enough, because the script also exits 1 for other reasons.
#
# ready.sh finds overlap.sh and lib/ relative to itself, so it is copied into a
# throwaway directory beside a fake overlap.sh. gh is the routed fixture from
# lib/fixture-gh.sh. Nothing here touches the network.
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
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# The Dependabot fixtures are dated 9 Oct 11:00 and expected "3 days old":
# against the real clock that turned into 4 days on 13 Oct and failed.
export MC_NOW="2026-10-12T12:00:00Z"

pass=0
fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; shift; printf '%s\n' "$*" | sed 's/^/    /'; fail=$((fail + 1)); }

mkdir -p "$WORK/scripts/lib" "$WORK/fix"
cp ./ready.sh "$WORK/scripts/ready.sh"
cp ./lib/gh.sh ./lib/fixture-gh.sh "$WORK/scripts/lib/"
[ -f ./lib/claims.py ] && cp ./lib/claims.py "$WORK/scripts/lib/"
# The real Dependabot lister, fed whole GraphQL pages below.
cp ./deps-open.sh "$WORK/scripts/deps-open.sh"
SCRIPT="$WORK/scripts/ready.sh"

# The fake analysis. By default nothing is ahead, so a title that passes goes
# straight to `pr ready`. FAKE_AHEAD lists pull requests ahead, the way
# --ci-ahead prints them, with one of overlap.sh's warnings mixed in.
cat >"$WORK/scripts/overlap.sh" <<'SH'
#!/usr/bin/env bash
# The arguments it was given, so a test can see what --skip-deps passed on.
printf '%s\n' "$*" >"$MC_FIXTURES/overlap-args"
[ -n "${FAKE_AHEAD:-}" ] || exit 0
echo "merge-coordinator: could not read the body of #99" >&2
printf '%s\n' $FAKE_AHEAD
exit 1
SH

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "ciWorkflow": "ci.yml",
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" }
}
JSON

FIX="$WORK/fix"
export MC_CONFIG="$WORK/config.json"
export MC_GH="$WORK/scripts/lib/fixture-gh.sh"
export MC_FIXTURES="$FIX"

# setup <title-response> — routes for pull request #7. <title-response> is the
# text `gh pr view --jq '[.title, .headRefName] | @tsv'` prints, or FAIL.
setup() {
	rm -f "$FIX"/*
	: >"$FIX/calls.log"
	printf 'true\n' >"$FIX/draft"
	: >"$FIX/labels"
	if [ "$1" = "FAIL" ]; then
		title_route="FAIL"
	else
		printf '%s\n' "$1" >"$FIX/title"
		title_route="title"
	fi
	# No Dependabot pull request open, unless a case says otherwise.
	deps_page
	{
		printf 'pr view 7 --json isDraft *\tdraft\n'
		printf 'pr view 7 --json title,headRefName *\t%s\n' "$title_route"
		printf 'api repos/example/repo/issues/7/labels *\tlabels\n'
		printf 'pr ready 7\tEMPTY\n'
		printf 'api graphql -f owner=example -f name=repo -f query=*\tdeps-page\n'
		printf 'api --paginate repos/example/repo/commits/depsha*\truns\n'
		printf 'api repos/example/repo/commits/depsha*\tstatus\n'
	} >"$FIX/routes"
	printf '{"check_runs":[]}' >"$FIX/runs"
	printf '{"statuses":[]}' >"$FIX/status"
}

# deps_page [<number>:<author>:<in queue 0|1>:<label>]... — the GraphQL page of
# open pull requests that deps-open.sh reads. Author is "bot" for Dependabot.
deps_page() {
	local spec number author queued label nodes="" sep=""
	for spec in "$@"; do
		IFS=: read -r number author queued label <<<"$spec"
		if [ "$author" = bot ]; then
			author='{"__typename":"Bot","login":"dependabot"}'
		else
			author='{"__typename":"User","login":"alice"}'
		fi
		[ "$queued" = 1 ] && queued=true || queued=false
		[ -n "$label" ] && label="{\"name\":\"$label\"}"
		nodes="$nodes$sep{\"number\":$number,\"title\":\"Bump x from 1.0.0 to 1.0.1\",\"createdAt\":\"2026-10-09T11:00:00Z\",\"isInMergeQueue\":$queued,\"headRefOid\":\"depsha$number\",\"author\":$author,\"labels\":{\"nodes\":[$label]}}"
		sep=","
	done
	printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}' "$nodes" >"$FIX/deps-page"
}

# run <args...> — runs ready.sh; sets $out and $status.
run() {
	set +e
	out=$(bash "$SCRIPT" "$@" 2>&1)
	status=$?
	set -e
}

readied() { contains "$(cat "$FIX/calls.log")" "pr ready 7"; }

TAB=$(printf '\t')

# must_refuse <name> <title-response> [extra args] — no `pr ready`, exit 1, and
# the message names the title problem.
must_refuse() {
	local name="$1" resp="$2"
	shift 2
	setup "$resp"
	run 7 "$@"
	if [ "$status" -ne 1 ]; then
		bad "$name: expected exit 1, got $status" "$out"
	elif readied; then
		bad "$name: marked the pull request ready" "$(cat "$FIX/calls.log")"
	elif ! contains "$out" "no real title"; then
		bad "$name: refused, but not for the title" "$out"
	else
		ok "$name"
	fi
}

must_allow() {
	local name="$1" resp="$2"
	setup "$resp"
	run 7
	if [ "$status" -ne 0 ]; then
		bad "$name: expected exit 0, got $status" "$out"
	elif ! readied; then
		bad "$name: did not mark the pull request ready" "$(cat "$FIX/calls.log")"
	else
		ok "$name"
	fi
}

BR="worktree-fix-1422-friends-defects"

must_refuse "title is the branch name"            "$BR${TAB}$BR"
must_refuse "title is #issue + branch (register)" "#1422 $BR${TAB}$BR"
must_refuse "title is the branch without worktree-" "fix-1422-friends-defects${TAB}$BR"
must_refuse "title is the branch in words"        "Worktree fix 1422 friends defects${TAB}$BR"
must_refuse "title is the branch, other case"     "WORKTREE-FIX-1422-FRIENDS-DEFECTS${TAB}$BR"
must_refuse "slash branch, title in words"        "feature thing${TAB}feature/thing"
must_refuse "empty title"                         "${TAB}$BR"
must_refuse "--force does not step over it"       "$BR${TAB}$BR" --force

must_allow "a real title"                         "Three Friends defects and one page heading${TAB}$BR"
must_allow "a real title that repeats branch words" "Fix 1422 friends defects in the page heading${TAB}$BR"

# A title that could not be read is not a title that passed.
setup FAIL
run 7
if [ "$status" -eq 1 ] && ! readied && contains "$out" "could not read the title"; then
	ok "unreadable title stays a draft"
else
	bad "unreadable title stays a draft: status $status" "$out"
fi

# ---------------------------------------------------------------------------
# The refusal says where each pull request ahead stands.
#
# overlap.sh counts every pull request out of draft: a live one, a green one
# nobody is landing, one that merged a second ago. The refusal used to print
# bare numbers under "already running CI", and each session looked every one up
# by hand before it could decide.
# ---------------------------------------------------------------------------
# setup_ahead — a good title, plus one routed pull request per state.
#   12 merged   13 in the queue   14 CI running   15 green, idle
#   16 only the draft's skipped run   17 red   18 unreadable
setup_ahead() {
	setup "A real title${TAB}$BR"
	local n
	printf 'MERGED,false,2026-09-29T10:00:00Z,alice,sha12\n' >"$FIX/pr12"
	printf 'OPEN,true,2026-09-29T10:00:00Z,alice,sha13\n' >"$FIX/pr13"
	printf 'OPEN,false,2026-09-29T10:00:00Z,alice,sha14\n' >"$FIX/pr14"
	printf 'OPEN,false,2026-09-20T10:00:00Z,dependabot,sha15\n' >"$FIX/pr15"
	printf 'OPEN,false,2026-09-29T10:00:00Z,alice,sha16\n' >"$FIX/pr16"
	printf 'OPEN,false,2026-09-29T10:00:00Z,alice,sha17\n' >"$FIX/pr17"
	printf 'in_progress,\n' >"$FIX/run14"
	printf 'completed,success\n' >"$FIX/run15"
	printf 'completed,skipped\n' >"$FIX/run16"
	printf 'completed,failure\n' >"$FIX/run17"
	{
		for n in 12 13 14 15 16 17; do
			printf 'api graphql -F n=%s *\tpr%s\n' "$n" "$n"
		done
		printf 'api graphql -F n=18 *\tFAIL\n'
		for n in 14 15 16 17; do
			printf 'api repos/example/repo/actions/workflows/ci.yml/runs -X GET -f head_sha=sha%s *\trun%s\n' "$n" "$n"
		done
	} >>"$FIX/routes"
}

# says_ahead <name> <line>... — ready.sh refused, made no `pr ready` call, and
# printed every line given.
says_ahead() {
	local name="$1" want
	shift
	if [ "$status" -ne 1 ]; then
		bad "$name: expected exit 1, got $status" "$out"
		return
	fi
	if readied; then
		bad "$name: marked the pull request ready" "$(cat "$FIX/calls.log")"
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			bad "$name: output did not contain: $want" "$out"
			return
		fi
	done
	ok "$name"
}

setup_ahead
FAKE_AHEAD="12 13 14 15 16 17 18" run 7
says_ahead "the refusal names the pull requests out of draft" \
	"shares ground with pull request(s) that are out of draft: 12 13 14 15 16 17 18"
if contains "$out" "already running CI"; then
	bad "the refusal no longer claims they are all running CI" "$out"
else
	ok "the refusal no longer claims they are all running CI"
fi
if contains "$out" "draft: 12 13 14 15 16 17 18 " || contains "$out" "#99"; then
	bad "a warning from overlap.sh is not read as a pull request" "$out"
else
	ok "a warning from overlap.sh is not read as a pull request"
fi
says_ahead "a merged one says to run it again"   "#12 merged after the list was read"
says_ahead "a queued one says to wait"           "#13 is in the merge queue"
says_ahead "a running one says CI is running"    "#14 has CI running"
says_ahead "a green idle one names its author and age" \
	"#15 is green and not in the queue. Author dependabot, last updated 2026-09-20T10:00:00Z."
says_ahead "a draft's skipped twin is not green" "#16 has not started its CI yet"
says_ahead "a red one names its result"          "#17 finished its CI as 'failure'"
says_ahead "an unreadable one says so"           "#18: could not read its state."

# --force still describes them. The forced flip is the one somebody reads later.
setup_ahead
FAKE_AHEAD="15" run 7 --force
if [ "$status" -eq 0 ] && readied && contains "$out" "#15 is green and not in the queue"; then
	ok "--force marks it ready and still says where the others stand"
else
	bad "--force marks it ready and still says where the others stand: status $status" "$out"
fi

# ---------------------------------------------------------------------------
# The Dependabot gate.
#
# Sessions ran ready.sh --force past open Dependabot pull requests a dozen times
# in one repository's land log, and the bumps sat until Dependabot closed them.
# Now a waiting one stops ready.sh and the session asks the user: land it first
# (/merge-deps), or later (--skip-deps). --force does not step over it.
# ---------------------------------------------------------------------------
GOOD="A real title${TAB}$BR"
args_seen() { cat "$FIX/overlap-args" 2>/dev/null || true; }

setup "$GOOD"
deps_page "90:bot:0:" "91:human:0:"
run 7
if [ "$status" -eq 1 ] && ! readied && contains "$out" "#90 Bump x from 1.0.0 to 1.0.1 (3 days old, no CI on it yet)" &&
	contains "$out" "Ask the user whether to land these first" && contains "$out" "re-run with --skip-deps"; then
	ok "a waiting Dependabot pull request stops it, named, with both answers"
else
	bad "a waiting Dependabot pull request stops it, named, with both answers: status $status" "$out"
fi
contains "$out" "#91" && bad "a person's pull request is not named as Dependabot's" "$out" || ok "a person's pull request is not named as Dependabot's"
[ -z "$(args_seen)" ] && ok "it stops before the overlap check" || bad "it stops before the overlap check" "$(args_seen)"

setup "$GOOD"
deps_page "90:bot:0:"
run 7 --force
[ "$status" -eq 1 ] && ! readied && ok "--force alone does not step over it" || bad "--force alone does not step over it: status $status" "$out"

setup "$GOOD"
deps_page "90:bot:0:" "92:bot:0:"
run 7 --skip-deps
if [ "$status" -eq 0 ] && readied; then
	ok "--skip-deps goes on"
else
	bad "--skip-deps goes on: status $status" "$out"
fi
contains "$(args_seen)" "--except=90,92" && ok "and takes the ones put off out of the overlap check" || bad "and takes the ones put off out of the overlap check" "$(args_seen)"

setup "$GOOD"
deps_page "90:bot:1:" "93:bot:0:merge:landing"
run 7
[ "$status" -eq 0 ] && readied && ok "a Dependabot pull request that is landing does not stop it" || bad "a Dependabot pull request that is landing does not stop it: status $status" "$out"
contains "$(args_seen)" "--except" && bad "and nothing is left out of the overlap check" "$(args_seen)" || ok "and nothing is left out of the overlap check"

setup "$GOOD"
deps_page "7:bot:0:" "90:bot:0:"
run 7
[ "$status" -eq 0 ] && readied && ok "a Dependabot pull request is not stopped by the others" || bad "a Dependabot pull request is not stopped by the others: status $status" "$out"

setup "$GOOD"
printf 'api graphql *\tFAIL\n' >"$FIX/routes.new"
cat "$FIX/routes" >>"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run 7
if [ "$status" -eq 1 ] && ! readied && contains "$out" "could not check the open Dependabot pull requests"; then
	ok "a lookup that fails stops it: could not look"
else
	bad "a lookup that fails stops it: could not look: status $status" "$out"
fi
run 7 --skip-deps
[ "$status" -eq 0 ] && readied && contains "$out" "--skip-deps was given, so carrying on" &&
	ok "under --skip-deps a failed lookup is only reported" || bad "under --skip-deps a failed lookup is only reported: status $status" "$out"

# The words the session repeats to the user. A read that failed is not a red,
# and a verdict already recorded is said, so nobody redoes the review.
setup "$GOOD"
deps_page "90:bot:0:deps:safe" "92:bot:0:"
printf '{"check_runs":[{"status":"completed","conclusion":"failure"}]}' >"$FIX/runs-red"
{
	printf 'api --paginate repos/example/repo/commits/depsha90/check-runs*\tFAIL\n'
	printf 'api --paginate repos/example/repo/commits/depsha92/check-runs*\truns-red\n'
	cat "$FIX/routes"
} >"$FIX/routes.new"
mv "$FIX/routes.new" "$FIX/routes"
run 7
contains "$out" "#90 Bump x from 1.0.0 to 1.0.1 (3 days old, its CI could not be read, /merge-deps said safe)" &&
	ok "a failed CI read is said as one, with the verdict already recorded" || bad "a failed CI read is said as one, with the verdict already recorded" "$out"
contains "$out" "#92 Bump x from 1.0.0 to 1.0.1 (3 days old, CI failed)" && ok "a red CI is said as failed" || bad "a red CI is said as failed" "$out"

setup "$GOOD"
deps_page "90:bot:0:"
MERGE_COORDINATOR_OVERRIDE=1 run 7
[ "$status" -eq 0 ] && readied && ok "break glass gets past it" || bad "break glass gets past it: status $status" "$out"

# The title is still checked first: a gate that ran before it would send a
# session to /merge-deps on a pull request that cannot go ready anyway.
setup "$BR${TAB}$BR"
deps_page "90:bot:0:"
run 7 --skip-deps
[ "$status" -eq 1 ] && contains "$out" "no real title" && ok "--skip-deps does not step over the title check" || bad "--skip-deps does not step over the title check: status $status" "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
