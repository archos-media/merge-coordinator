#!/usr/bin/env bash
# Tests register.sh — the Register layer.
#
# Registration is the one part of this plugin that WRITES before anything is
# decided: it opens a pull request. So the cases here are mostly about what it
# must not do twice, and about the body it puts there being readable again by
# the thing that consumes it. The round trip matters more than either half:
# a block register.sh writes and mc_pr_footprint cannot read is two correct
# halves and a broken feature.
#
# gh is stubbed through MC_GH and git runs against a throwaway repository, so
# nothing here touches the network or the real checkout.
set -euo pipefail

# contains <haystack> <needle> — substring test, done in the shell.
#
# NOT `printf '%s' "$h" | grep -qF -- "$n"`. These files set `pipefail`, and
# grep -q exits at its first match while printf is still writing; printf dies of
# SIGPIPE and 141 becomes the pipeline's status, so a string that WAS found
# reads as not found — and in a "must not appear" assertion that is a test which
# cannot fail.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
HERE=$(pwd)
SCRIPT="$HERE/register.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; shift; printf '%s\n' "$*" | sed 's/^/    /'; fail=$((fail + 1)); }

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "backbone": "github-merge-queue",
  "requireApproval": true,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": []
}
JSON

FIX="$WORK/fix"
mkdir -p "$FIX"

# A throwaway repository. register.sh reads the branch from it and writes
# nothing, because every case below runs --dry-run.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
# The default branch name comes from the machine, so it is set here instead of
# assumed. A repo on `master` makes the refusal case below pass for the wrong
# reason: it would refuse "main" as a branch that does not exist.
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
: >"$REPO/file"
git -C "$REPO" add file
git -C "$REPO" commit -qm "first"
git -C "$REPO" checkout -qb feature/thing

reset_fixture() {
	rm -f "$FIX/calls.log" "$FIX"/.seq.*
	: >"$FIX/calls.log"
	: >"$FIX/none"
	cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	none
ROUTES
}

# register <args...> — runs the script in the throwaway repo, prints its output.
register() {
	set +e
	out=$(cd "$REPO" && MC_CONFIG="$WORK/config.json" MC_GH="$HERE/lib/fixture-gh.sh" \
		MC_FIXTURES="$FIX" bash "$SCRIPT" --dry-run "$@" 2>&1)
	status=$?
	set -e
}

# expect_ok <name> <substring>...
expect_ok() {
	local name="$1" want
	shift
	if [ "$status" -ne 0 ]; then
		bad "$name — exited $status" "$out"
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
	local name="$1" unwanted="$2"
	if contains "$out" "$unwanted"; then
		bad "$name — output contained what it must not: $unwanted" "$out"
		return
	fi
	ok "$name"
}

# --------------------------------------------------------------------------
# 1. Nothing open for this branch: it opens one.
# --------------------------------------------------------------------------
reset_fixture
register
expect_ok "a branch with no pull request gets one" \
	"would run:" "pr create" "--draft" "feature/thing"

# 2. The empty commit. GitHub refuses a pull request with no commits between
#    base and head, and a branch created seconds ago has none. Without this the
#    whole layer fails at the first session that uses it.
expect_ok "it makes an empty commit first" "commit --allow-empty"

# 3. It pushes before asking GitHub about a branch GitHub cannot see yet.
expect_ok "it pushes the branch" "git push -u origin feature/thing"

# --------------------------------------------------------------------------
# 4. Already registered: it edits, and it must not open a second one.
# --------------------------------------------------------------------------
reset_fixture
printf '%s\n' "77" >"$FIX/number"
cat >"$FIX/body" <<'BODY'
Some words a person wrote.

<!-- merge-coordinator:footprint
old/path/**
-->

More words, after the block.
BODY
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
ROUTES
register web/src/**
expect_ok "an existing registration is updated, not duplicated" \
	"#77 already registers" "declared paths updated"
expect_absent "it does not open a second pull request" "pr create"
expect_ok "it edits the existing one" "would run:" "pr edit 77"
expect_absent "no --title leaves the existing title alone" "--title"

# Only the BLOCK is rewritten. Everything a person wrote around it survives,
# and the paths declared before it do not. Rewriting the whole body would pass
# the three assertions above while deleting somebody else's words, which is the
# kind of loss nobody notices until they go looking for it.
expect_ok "words before and after the block survive the rewrite" \
	"Some words a person wrote." "More words, after the block."
expect_absent "the previous declaration is replaced, not appended to" "old/path/**"
expect_ok "the new declaration reaches the body" "web/src/**"

# 4b. --title on an existing registration. It used to be dropped here with exit
#     0, which is how branch names reached main as squash commit messages.
reset_fixture
printf '%s\n' "77" >"$FIX/number"
printf 'Words.\n' >"$FIX/body"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
ROUTES
register --title "Three defects and one heading" web/src/**
expect_ok "--title reaches the edit of an existing pull request" \
	"pr edit 77 --repo example/repo --title Three defects and one heading --body-file"

# The same, for real rather than dry-run, so the title read-back runs. The
# existing-PR path makes no git calls, so the fixture covers all of it.
register_live() {
	set +e
	out=$(cd "$REPO" && MC_CONFIG="$WORK/config.json" MC_GH="$HERE/lib/fixture-gh.sh" \
		MC_FIXTURES="$FIX" bash "$SCRIPT" "$@" 2>&1)
	status=$?
	set -e
}
reset_fixture
printf '%s\n' "77" >"$FIX/number"
printf 'Words.\n' >"$FIX/body"
printf 'Three defects and one heading\n' >"$FIX/title-good"
printf 'feature/thing\n' >"$FIX/title-stale"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
pr edit 77 --repo example/repo *	EMPTY
pr view 77 --repo example/repo --json title *	title-good
ROUTES
register_live --title "Three defects and one heading" web/src/**
expect_ok "a title that reads back is reported as set" "Title set: Three defects and one heading"

reset_fixture
printf '%s\n' "77" >"$FIX/number"
printf 'Words.\n' >"$FIX/body"
printf 'feature/thing\n' >"$FIX/title-stale"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
pr edit 77 --repo example/repo *	EMPTY
pr view 77 --repo example/repo --json title *	title-stale
ROUTES
register_live --title "Three defects and one heading" web/src/**
if [ "$status" -ne 0 ] && contains "$out" "its title reads 'feature/thing'"; then
	ok "a title that does not read back is a failure, not a success"
else
	bad "a title that does not read back is a failure, not a success" "status $status: $out"
fi

# --------------------------------------------------------------------------
# 5. Refusals.
# --------------------------------------------------------------------------
# 5a. On the default branch there is nothing to register.
reset_fixture
git -C "$REPO" checkout -q main
register
if [ "$status" -eq 0 ]; then
	bad "registering main is refused" "$out"
else
	if contains "$out" "refusing to register main"; then
		ok "registering main is refused"
	else
		bad "registering main is refused — wrong message" "$out"
	fi
fi
git -C "$REPO" checkout -q feature/thing

# 5b. An unknown option is refused rather than swallowed as a path. A flag read
#     as a glob would be declared, silently, and never match anything.
reset_fixture
register --nonsense
if [ "$status" -ne 0 ] && contains "$out" "unknown option"; then
	ok "an unknown option is refused, not declared as a path"
else
	bad "an unknown option is refused, not declared as a path" "$out"
fi

# --------------------------------------------------------------------------
# 6. THE ROUND TRIP — what register.sh writes, mc_pr_footprint reads.
#
#    This is the case worth the most. Both halves can be individually correct
#    and the feature still dead: a block written with a marker the reader does
#    not look for produces a registration that registers nothing, and every
#    other test in this file and in test-overlap.sh still passes. Nothing here
#    hand-writes a block - the input is whatever register.sh actually produced.
# --------------------------------------------------------------------------

# footprint <pr-number> — mc_pr_footprint against the fixture, one glob a line.
footprint() {
	MC_CONFIG="$WORK/config.json" MC_GH="$HERE/lib/fixture-gh.sh" MC_FIXTURES="$FIX" \
		bash -c '. "$0/lib/gh.sh"; mc_pr_footprint "$1"' "$HERE" "$1" 2>&1
}

# body_of <register-output> — the body between the dry-run fences.
body_of() {
	printf '%s\n' "$1" | sed -n '/^--- body it would write ---$/,/^--- end of body ---$/p' |
		sed '1d;$d'
}

reset_fixture
register web/src/** "go/feed/**"
body_of "$out" >"$FIX/written"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	none
api repos/example/repo/pulls/88 --jq *	written
ROUTES
read_back=$(footprint 88)
if [ "$read_back" = "web/src/**
go/feed/**" ]; then
	ok "a block register.sh wrote is read back with the same paths, in order"
else
	bad "a block register.sh wrote is read back with the same paths, in order" "$read_back"
fi

# 6b. Declaring nothing writes a block that reads back as nothing declared. The
#     comment lines inside it must not come back as paths - a glob of
#     "# No paths declared yet." would match nothing and look like a working
#     registration forever.
reset_fixture
register
body_of "$out" >"$FIX/written"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	none
api repos/example/repo/pulls/88 --jq *	written
ROUTES
read_back=$(footprint 88)
if [ -z "$read_back" ]; then
	ok "declaring nothing reads back as nothing, comments and all"
else
	bad "declaring nothing reads back as nothing, comments and all" "$read_back"
fi

# 6c. A body with no block at all is the normal case for a pull request nobody
#     registered, and is not an error.
reset_fixture
printf '%s\n' "Just a pull request. No block here." >"$FIX/plain"
cat >"$FIX/routes" <<'ROUTES'
api repos/example/repo/pulls/89 --jq *	plain
ROUTES
set +e
read_back=$(footprint 89)
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$read_back" ]; then
	ok "a body with no block declares nothing, and that is not an error"
else
	bad "a body with no block declares nothing, and that is not an error" "rc=$rc $read_back"
fi

# 6d. A block opened and never closed is a DIFFERENT answer from no block, and
#     must not be reported as "declared nothing". Same separation mc_cfg_list_opt
#     makes between an absent key and a config it could not read: a caller that
#     prints both the same way does nothing at all and calls it normal.
reset_fixture
cat >"$FIX/broken" <<'BODY'
<!-- merge-coordinator:footprint
web/src/**
BODY
cat >"$FIX/routes" <<'ROUTES'
api repos/example/repo/pulls/90 --jq *	broken
ROUTES
set +e
read_back=$(footprint 90)
rc=$?
set -e
if [ "$rc" -ne 0 ] && contains "$read_back" "opened and never closed"; then
	ok "an unterminated block is a failure, not an empty declaration"
else
	bad "an unterminated block is a failure, not an empty declaration" "rc=$rc $read_back"
fi

# --------------------------------------------------------------------------
# 7. The issue claim.
# --------------------------------------------------------------------------
# 7a. A branch with no number claims nothing, and says how to claim.
reset_fixture
register
expect_absent "a branch with no issue number writes no claim" "issue:"
expect_ok "a branch with no issue number says how to claim one" "No issue claimed" "--issue <number>"

# 7b. A branch with one number claims it, says it was read from the name, and
#     puts it first in the title.
git -C "$REPO" checkout -qb fix-1422-nav
reset_fixture
register
expect_ok "the branch name gives the claim, marked as a guess" \
	"issue: 1422 (from branch name)" "read from the branch name"
expect_ok "the title leads with the claimed issue" "--title #1422 fix-1422-nav"

# 7c. --issue wins over the branch name, and is not marked as a guess.
reset_fixture
register --issue 1500
expect_ok "--issue replaces the number in the branch name" "issue: 1500"
expect_absent "an explicit claim is not marked as a guess" "(from branch name)"
expect_absent "an explicit claim does not keep the branch number" "issue: 1422"
git -C "$REPO" checkout -q feature/thing

# 7d. --part-of declares planned work beside another pull request.
reset_fixture
register --issue 1444 --part-of 1450
expect_ok "--part-of is written on the claim line" "issue: 1444 part-of #1450"

# 7e. --part-of with no issue to attach it to is refused, not dropped.
reset_fixture
register --part-of 1450
if [ "$status" -ne 0 ] && contains "$out" "--part-of needs an issue"; then
	ok "--part-of with no issue is refused"
else
	bad "--part-of with no issue is refused" "$out"
fi

# 7f. A claim that is not a number is refused.
reset_fixture
register --issue abc
if [ "$status" -ne 0 ] && contains "$out" "needs a number"; then
	ok "--issue that is not a number is refused"
else
	bad "--issue that is not a number is refused" "$out"
fi

# 7g. An existing registration KEEPS its claim when --issue is not given. This
#     is a case seen live: a branch named for one issue, a pull request that
#     does another, and a session that corrected the claim. Re-declaring paths must not
#     put the guess back.
git -C "$REPO" checkout -qb fix-1441-drift
reset_fixture
printf '%s\n' "77" >"$FIX/number"
cat >"$FIX/body" <<'BODY'
Words.

<!-- merge-coordinator:footprint
issue: 1443
old/path/**
-->
BODY
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
ROUTES
register web/src/**
expect_ok "an update keeps the claim already in the block" "issue: 1443" "web/src/**"
expect_absent "an update does not bring back the guess from the branch name" "issue: 1441"
body_of "$out" >"$FIX/updated"
issue_lines=$(grep -c '^issue:' "$FIX/updated" || true)
if [ "$issue_lines" = "1" ]; then
	ok "an update leaves exactly one claim line"
else
	bad "an update leaves exactly one claim line" "found $issue_lines"
fi

# 7h. An explicit --issue on an update replaces the old claim.
register --issue 1500 web/src/**
expect_ok "an explicit --issue on an update replaces the claim" "issue: 1500"
expect_absent "an explicit --issue on an update drops the old claim" "issue: 1443"
git -C "$REPO" checkout -q feature/thing

# 7i. THE ROUND TRIP, claim half. The claim line shares the block with the
#     paths, so the path reader must skip it. Otherwise overlap.sh would
#     declare a glob named "issue: 42" that matches nothing and looks declared.
reset_fixture
register --issue 42 web/src/**
body_of "$out" >"$FIX/written"
cat >"$FIX/routes" <<'ROUTES'
api repos/example/repo/pulls/88 --jq *	written
ROUTES
read_back=$(footprint 88)
if [ "$read_back" = "web/src/**" ]; then
	ok "the claim line is not read back as a declared path"
else
	bad "the claim line is not read back as a declared path" "$read_back"
fi

# And claims.sh reads the claim out of the same body register.sh wrote.
MC_BODY_FILE="$FIX/written" bash -c '. "$0/lib/gh.sh"; mc_py -c "
import io, json, os
body = io.open(os.environ[\"MC_BODY_FILE\"], encoding=\"utf-8\").read()
node = {\"number\": 88, \"title\": \"t\", \"body\": body, \"isDraft\": True, \"headRefName\": \"b\",
        \"updatedAt\": \"x\", \"closingIssuesReferences\": {\"nodes\": []}}
print(json.dumps({\"data\": {\"repository\": {\"pullRequests\": {\"nodes\": [node]}}}}))
"' "$HERE" >"$FIX/page.json"
cat >"$FIX/routes" <<'ROUTES'
api graphql --paginate *	page.json
ROUTES
set +e
claimed=$(MC_CONFIG="$WORK/config.json" MC_GH="$HERE/lib/fixture-gh.sh" MC_FIXTURES="$FIX" \
	bash "$HERE/claims.sh" --pr 88 2>&1)
set -e
if contains "$claimed" "#88 claims #42"; then
	ok "claims.sh reads the claim register.sh wrote"
else
	bad "claims.sh reads the claim register.sh wrote" "$claimed"
fi

# --------------------------------------------------------------------------
# The open Dependabot pull requests, after the claim report. Best effort:
# a failed look is one line and registration still succeeds.
# --------------------------------------------------------------------------
# deps_routes <page json> — the lister's page, and green CI on every head.
deps_routes() {
	printf '%s' "$1" >"$FIX/deps.json"
	printf '{"check_runs":[{"status":"completed","conclusion":"success"}]}' >"$FIX/deps-runs.json"
	printf '{"statuses":[]}' >"$FIX/deps-status.json"
	{
		printf 'api graphql -f owner=example -f name=repo -f query=*\tdeps.json\n'
		printf 'api --paginate repos/example/repo/commits/depsha*\tdeps-runs.json\n'
		printf 'api repos/example/repo/commits/depsha*\tdeps-status.json\n'
	} >>"$FIX/routes"
}
ONE_DEP='{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":90,"title":"Bump x from 1.0.0 to 1.0.1","createdAt":"2020-01-01T00:00:00Z","isInMergeQueue":false,"headRefOid":"depsha90","author":{"__typename":"Bot","login":"dependabot"},"labels":{"nodes":[]}}]}}}}'
NO_DEP='{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'

reset_fixture
deps_routes "$ONE_DEP"
register
expect_ok "a new registration shows the open Dependabot pull requests" \
	"feature/thing is registered." "Dependabot pull request(s) open:" "#90 Bump x from 1.0.0 to 1.0.1 (" "CI passed)" "While one waits"

reset_fixture
printf '%s\n' "77" >"$FIX/number"
printf 'Body.\n' >"$FIX/body"
cat >"$FIX/routes" <<'ROUTES'
pr list --repo example/repo --head * --state open --json number --jq *	number
api repos/example/repo/pulls/77 --jq *	body
ROUTES
deps_routes "$ONE_DEP"
register
expect_ok "an existing registration shows them too" "#77 already registers" "#90 Bump x"

reset_fixture
deps_routes "$NO_DEP"
register
expect_absent "none open: nothing about Dependabot" "Dependabot"

reset_fixture
printf 'api graphql -f owner=*\tFAIL\n' >>"$FIX/routes"
register
expect_ok "a failed look is one line, and registration still succeeds" "is registered." "could not check Dependabot pull requests"

# register-hook.sh hands them to the session as JSON context. Plain output from
# a hook after a tool call goes to the debug log, never to the session.
# hook_json <page json> — runs the hook in the throwaway repository; sets $hook.
hook_json() {
	reset_fixture
	if [ "$1" = FAIL ]; then
		printf 'api graphql -f owner=*\tFAIL\n' >>"$FIX/routes"
	else
		deps_routes "$1"
	fi
	mkdir -p "$WORK/hookrepo"
	if [ ! -d "$WORK/hookrepo/.git" ]; then
		git -C "$WORK/hookrepo" init -q
		git -C "$WORK/hookrepo" symbolic-ref HEAD refs/heads/main
		mkdir -p "$WORK/hookrepo/.github"
		cp "$WORK/config.json" "$WORK/hookrepo/.github/merge-coordinator.json"
	fi
	set +e
	# HEAD on an unborn main: register.sh refuses it, which is the "could not
	# register" path. The hook must still exit 0 and still hand over the list.
	hook=$(cd "$WORK/hookrepo" && printf '{}' | MC_GH="$HERE/lib/fixture-gh.sh" MC_FIXTURES="$FIX" \
		bash "$HERE/register-hook.sh" 2>/dev/null)
	hook_status=$?
	set -e
}
hook_context() {
	printf '%s' "$hook" | bash -c '. "$0/lib/gh.sh"; mc_py -c "
import json, sys
d = json.load(sys.stdin)
assert d[\"hookSpecificOutput\"][\"hookEventName\"] == \"PostToolUse\"
sys.stdout.write(d[\"hookSpecificOutput\"][\"additionalContext\"])
"' "$HERE" 2>/dev/null || echo "NOT-JSON"
}

hook_json "$ONE_DEP"
ctx=$(hook_context)
if [ "$hook_status" -eq 0 ] && contains "$ctx" "#90 Bump x from 1.0.0 to 1.0.1 (" && contains "$ctx" "While one waits"; then
	ok "register-hook hands the open Dependabot pull requests to the session as JSON"
else
	bad "register-hook hands the open Dependabot pull requests to the session as JSON" "status $hook_status" "$hook"
fi
contains "$hook" "could not register" && bad "registration's own report stays off stdout" "$hook" || ok "registration's own report stays off stdout"

hook_json "$NO_DEP"
[ "$hook_status" -eq 0 ] && [ -z "$hook" ] && ok "register-hook says nothing when none is open" || bad "register-hook says nothing when none is open" "status $hook_status" "$hook"

hook_json FAIL
ctx=$(hook_context)
[ "$hook_status" -eq 0 ] && contains "$ctx" "could not check Dependabot pull requests" && ok "register-hook says so when it could not look, and exits 0" ||
	bad "register-hook says so when it could not look, and exits 0" "status $hook_status" "$hook"

# A registration that SUCCEEDS writes its report to stdout. The hook must keep
# that off its own stdout, or the JSON is not JSON and the notice is lost on
# every worktree. So register.sh is a stub here that succeeds out loud.
STUBPLUGIN="$WORK/stubplugin"
mkdir -p "$STUBPLUGIN/scripts/lib"
cp "$HERE/register-hook.sh" "$HERE/deps-open.sh" "$STUBPLUGIN/scripts/"
cp "$HERE/lib/gh.sh" "$HERE/lib/fixture-gh.sh" "$STUBPLUGIN/scripts/lib/"
cat >"$STUBPLUGIN/scripts/register.sh" <<'SH'
#!/usr/bin/env bash
echo "merge-coordinator: feature/x is registered."
echo "NOTICE=${MC_DEPS_NOTICE:-}" >&2
exit 0
SH
# stub_hook — runs the stub plugin's hook in the throwaway repository; sets
# $hook, $hook_err and $hook_status.
stub_hook() {
	set +e
	hook=$(cd "$WORK/hookrepo" && printf '{}' | MC_FIXTURES="$FIX" bash "$STUBPLUGIN/scripts/register-hook.sh" 2>"$WORK/hook-err")
	hook_status=$?
	set -e
	hook_err=$(cat "$WORK/hook-err")
}
reset_fixture
deps_routes "$ONE_DEP"
MC_GH="$HERE/lib/fixture-gh.sh" stub_hook
ctx=$(hook_context)
if [ "$hook_status" -eq 0 ] && contains "$ctx" "#90 Bump x from 1.0.0 to 1.0.1 (" && ! contains "$hook" "is registered"; then
	ok "a registration that succeeds keeps its report off the hook's JSON"
else
	bad "a registration that succeeds keeps its report off the hook's JSON" "status $hook_status" "$hook"
fi
contains "$hook_err" "NOTICE=off" && ok "and register.sh is told not to look a second time" || bad "and register.sh is told not to look a second time" "$hook_err"
contains "$(cat "$FIX/calls.log")" "check-runs" && bad "the hook reads no CI: one query, inside its deadline" "$(cat "$FIX/calls.log")" || ok "the hook reads no CI: one query, inside its deadline"

# A look that does not finish in time ends in a line, not in a hook killed
# with nothing said.
reset_fixture
deps_routes "$ONE_DEP"
cat >"$WORK/slow-gh.sh" <<SH
sleep 3
exec bash "$HERE/lib/fixture-gh.sh" "\$@"
SH
MC_GH="$WORK/slow-gh.sh" MC_DEPS_TIMEOUT=1 stub_hook
ctx=$(hook_context)
[ "$hook_status" -eq 0 ] && contains "$ctx" "could not check Dependabot pull requests (no answer within 1 seconds)" &&
	ok "a look past its deadline says so, and the hook exits 0" || bad "a look past its deadline says so, and the hook exits 0" "status $hook_status" "$hook"

echo
echo "test-register: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
