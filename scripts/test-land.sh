#!/usr/bin/env bash
# Tests land.sh — the landing sequence.
#
# Almost every case below is a REFUSAL. That is the point of the script: the
# happy path is one `gh pr merge`, and everything else is the seven ways it
# should not have run. A version of land.sh that merged unconditionally would
# pass a test suite built the other way round.
#
# The three that map to real incidents:
#   - "a cancelled run is not a pass"      gh run watch --exit-status returns 0
#                                          for a run a later push superseded.
#   - "a missing check is not a pass"      a billing wall fails every job in
#                                          seconds with no steps and no reason
#                                          outside the annotations.
#   - "a merge that reverted the release heading is caught"
#                                          a squash merge that reverted a
#                                          release heading while CI was green.
#
# The fixture does not implement --jq, so these prove the logic around each API
# call and not the filter inside it. See lib/fixture-gh.sh.
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
SCRIPT=./land.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# The Dependabot fixtures are dated 9 Oct 11:00 and expected "3 days old":
# against the real clock that turned into 4 days on 13 Oct and failed.
export MC_NOW="2026-10-12T12:00:00Z"

pass=0
fail=0

REPO=example/repo
SHA=abc123def456
FIX="$WORK/fix"

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed", "gitleaks"],
  "backbone": "serialized-claim",
  "requireApproval": true,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": [
    { "path": "CHANGELOG.md", "rule": "serialize", "action": "rebase by hand", "why": "clean merges lose entries" },
    { "path": "*/migrations/**", "rule": "serialize", "action": "renumber", "why": "numbers are assigned at merge time" }
  ]
}
JSON

# The same repository, read under the other backbone. Three steps behave
# differently on a merge queue — the claim, the freshness/conflict check and the
# notify — and the only way to prove a branch is read at all is to run the same
# inputs through both.
sed 's/"serialized-claim"/"github-merge-queue"/' "$WORK/config.json" >"$WORK/config-queue.json"
grep -q 'github-merge-queue' "$WORK/config-queue.json" ||
	{ echo "FAIL: the queue fixture config was not written"; exit 1; }

# ---------------------------------------------------------------------------
# Fixture scaffolding. reset_fixture writes the responses for a PR that is in
# perfect shape; each case then overrides one of them by prepending a route.
# ---------------------------------------------------------------------------
reset_fixture() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"

	cat >"$FIX/pr.json" <<JSON
{"state":"open","draft":false,"title":"Change the auth handler","head":{"ref":"work","sha":"$SHA"}}
JSON
	printf 'size:S\n' >"$FIX/labels.txt"
	# The same PR's labels once the claim is taken. On a queue, land.sh reads
	# its own claim back from here.
	printf 'size:S,merge:landing\n' >"$FIX/labels-claimed.txt"
	printf '1\n' >"$FIX/reviews.txt"
	printf '7\n' >"$FIX/holders.txt"
	printf '' >"$FIX/nobody.txt"
	printf '0\n' >"$FIX/behind0.txt"
	printf '3\n' >"$FIX/behind3.txt"
	printf 'CI passed\tsuccess\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
	printf 'auth/handler.go\n' >"$FIX/files7.txt"
	printf 'auth/handler.go\n' >"$FIX/files9.txt"
	printf 'v1.2.3\n' >"$FIX/tag.txt"
	printf '## [v1.2.3] - the release\n\nnotes\n' >"$WORK/changelog-good.md"
	cp "$WORK/changelog-good.md" "$FIX/changelog-ok.txt"
	printf '## [Unreleased]\n\nnotes\n' >"$WORK/changelog-bad.md"
	cp "$WORK/changelog-bad.md" "$FIX/changelog-bad.txt"
	printf '9\tAnother change\tfalse\tother\t\n' >"$FIX/openprs.txt"
	printf '' >"$FIX/noprs.txt"
	# `mergeable` as gh --jq would print it: the JSON spelling, or null while
	# GitHub is still computing it. Only read on the merge-queue backbone.
	printf 'true\n' >"$FIX/mergeable-clean.txt"
	printf 'false\n' >"$FIX/mergeable-conflict.txt"
	printf 'null\n' >"$FIX/mergeable-unknown.txt"
	# No Dependabot pull request open, unless a case says otherwise. Whole
	# responses: deps-open.sh reads the JSON itself.
	deps_page
	printf '{"check_runs":[]}' >"$FIX/deps-runs.json"
	printf '{"statuses":[]}' >"$FIX/deps-status.json"

	cat >"$FIX/routes" <<ROUTES
api graphql -f owner=example -f name=repo -f query=*	deps-page.json
api --paginate repos/$REPO/commits/depsha*	deps-runs.json
api repos/$REPO/commits/depsha*	deps-status.json
api repos/$REPO/pulls/7	pr.json
api repos/$REPO/issues/7/labels*	SEQ:labels.txt,labels-claimed.txt
api repos/$REPO/pulls/7/reviews*	reviews.txt
pr list --repo $REPO --state open --label merge:landing*	holders.txt
pr edit 7 --repo $REPO --add-label*	EMPTY
pr edit 7 --repo $REPO --remove-label*	EMPTY
api repos/$REPO/compare/main...$SHA*	behind0.txt
api --paginate repos/$REPO/commits/$SHA/check-runs*	checks-ok.txt
api repos/$REPO/commits/$SHA/status*	EMPTY
api --paginate repos/$REPO/pulls/7/files*	files7.txt
api --paginate repos/$REPO/pulls/9/files*	files9.txt
pr merge 7*	EMPTY
api repos/$REPO/tags*	tag.txt
api repos/$REPO/contents/CHANGELOG.md*	changelog-ok.txt
api --paginate repos/$REPO/pulls?state=open*	openprs.txt
pr edit 9 --repo $REPO --add-label*	EMPTY
pr comment 9*	EMPTY
api repos/$REPO/pulls/7 --jq .mergeable	mergeable-clean.txt
api repos/$REPO/pulls/9 --jq .mergeable	mergeable-clean.txt
ROUTES
}

# deps_page [<number>:<author bot|human>:<in queue 0|1>:<label>]... — the
# GraphQL page of open pull requests that deps-open.sh reads.
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
	printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}' "$nodes" >"$FIX/deps-page.json"
}

# override <glob> <response> — prepended, so it wins over the default route.
override() {
	printf '%s\t%s\n' "$1" "$2" >"$FIX/routes.new"
	cat "$FIX/routes" >>"$FIX/routes.new"
	mv "$FIX/routes.new" "$FIX/routes"
}

land() {
	# MC_CLAIM_SLEEP=0 so the claim read-back's retry loop does not put real
	# seconds into the suite. The retry COUNT is left alone, so the refusal
	# below still happens after the same number of reads it would take live.
	# MC_MERGEABLE_SLEEP=0 is the same bargain for the conflict read on a queue
	# backbone, which waits out GitHub's lazily-computed `mergeable`.
	MC_CONFIG="${MC_TEST_CONFIG:-$WORK/config.json}" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		MC_CLAIM_SLEEP=0 MC_MERGEABLE_SLEEP=0 \
		bash "$SCRIPT" "$@" 2>&1
}

# expect_fail <name> <substring>... — land.sh must exit non-zero and say why.
expect_fail() {
	local name="$1"
	shift
	local out status want
	set +e
	out=$(land 7 ${LAND_ARGS[@]+"${LAND_ARGS[@]}"})
	status=$?
	set -e
	if [ "$status" -eq 0 ]; then
		echo "FAIL: $name — it landed. It should have refused."
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			echo "FAIL: $name — refusal did not say: $want"
			printf '%s\n' "$out" | sed 's/^/    /'
			fail=$((fail + 1))
			return
		fi
	done
	echo "ok: $name"
	pass=$((pass + 1))
}

expect_ok() {
	local name="$1"
	shift
	local out status want
	set +e
	out=$(land 7 ${LAND_ARGS[@]+"${LAND_ARGS[@]}"})
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

# called <name> <substring> — assert a call was made.
called() {
	local name="$1" want="$2"
	if grep -qF -- "$want" "$FIX/calls.log"; then
		echo "ok: $name"
		pass=$((pass + 1))
	else
		echo "FAIL: $name — no call matching: $want"
		sed 's/^/    /' "$FIX/calls.log"
		fail=$((fail + 1))
	fi
}

not_called() {
	local name="$1" want="$2"
	if grep -qF -- "$want" "$FIX/calls.log"; then
		echo "FAIL: $name — it made this call and should not have: $want"
		sed 's/^/    /' "$FIX/calls.log"
		fail=$((fail + 1))
	else
		echo "ok: $name"
		pass=$((pass + 1))
	fi
}

LAND_ARGS=()

# --------------------------------------------------------------------------
# 1. Preflight
# --------------------------------------------------------------------------
reset_fixture
printf '{"state":"open","draft":true,"title":"WIP","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
expect_fail "a draft is a registration, not a candidate" "is a draft"

reset_fixture
printf '{"state":"closed","draft":false,"title":"Gone","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
expect_fail "a closed PR is refused" "is closed, not open"

reset_fixture
printf 'size:S,merge:blocked\n' >"$FIX/labels.txt"
expect_fail "a blocked PR is refused, and says someone meant it" \
	"merge:blocked" "on purpose"

# A pull request the issue claim check refused does not land. The config
# here has no labels.duplicateClaim, so this also proves the default name.
reset_fixture
printf 'size:S,merge:duplicate-claim\n' >"$FIX/labels.txt"
expect_fail "a PR whose issue claim was refused does not land" \
	"merge:duplicate-claim" "issue claim comment"

reset_fixture
printf '0\n' >"$FIX/reviews.txt"
expect_fail "no approval is refused, and the break-glass door is named" \
	"no approving review" "--admin"

reset_fixture
printf '0\n' >"$FIX/reviews.txt"
LAND_ARGS=(--admin)
expect_ok "--admin passes the review gate and still runs the rest" \
	"break-glass" "3/7 freshness" "4/7 verify" "7/7 notify"
LAND_ARGS=()

# --------------------------------------------------------------------------
# 2. Claim
# --------------------------------------------------------------------------
reset_fixture
printf '3\n' >"$FIX/holders.txt"
expect_fail "another PR holding the claim is refused, by number" \
	"#3 already holds" "--release-claim"

# The read-back is the interesting half: both sessions added the label, and the
# tie has to resolve the same way from either side.
reset_fixture
override "pr list --repo $REPO --state open --label merge:landing*" "SEQ:nobody.txt,tie.txt"
printf '5\n7\n' >"$FIX/tie.txt"
expect_fail "a simultaneous claim resolves to the lowest number" \
	"#5 took" "lowest number"
called "the loser gives its own claim back" "remove-label"

# A listing that does not yet show the label we just wrote is STALE, and stale
# reads here exactly like "nobody else is claiming". Live, `issues?labels=`
# answered from an index that lagged the write by about five seconds — measured
# 25 August 2026: invisible at t=0, correct at t=5 — so the read-back saw an
# empty list every single time. The tie-break was dead code, and the empty list
# made the grep behind it exit 1 under pipefail, killing land.sh with NO MESSAGE
# immediately after it had taken a claim.
reset_fixture
override "pr list --repo $REPO --state open --label merge:landing*" "SEQ:nobody.txt,nobody.txt,holders.txt"
expect_ok "a claim that is not visible yet is re-read rather than believed" \
	"claim not visible yet" "#7 landed."

reset_fixture
override "pr list --repo $REPO --state open --label merge:landing*" nobody.txt
expect_fail "a claim that never becomes visible refuses, and says why" \
	"never showed it" "cannot be trusted" "wave through"
called "and it gives the claim back" "remove-label"

# --------------------------------------------------------------------------
# 3. Freshness — the reported bug
# --------------------------------------------------------------------------
reset_fixture
override "api repos/$REPO/compare/main...$SHA*" behind3.txt
expect_fail "a stale head is refused even though GitHub calls it mergeable" \
	"3 commit(s) ahead" "says" "nothing about the tree it would produce" \
	"git rebase origin/main"
called "a refused landing releases the claim" "remove-label"
not_called "a refused landing does not merge" "pr merge"

# A hotspot PR must not be fixed by the update-branch API: that resolves by
# merging, and a clean merge is the dangerous case there.
reset_fixture
override "api repos/$REPO/compare/main...$SHA*" behind3.txt
printf 'CHANGELOG.md\n' >"$FIX/files7.txt"
LAND_ARGS=(--update-branch)
expect_fail "--update-branch is refused on a hotspot" \
	"refusing --update-branch" "Rebase it by hand instead."
LAND_ARGS=()

reset_fixture
override "api repos/$REPO/compare/main...$SHA*" behind3.txt
override "api --method PUT repos/$REPO/pulls/7/update-branch" EMPTY
LAND_ARGS=(--update-branch)
expect_fail "--update-branch is allowed when no hotspot is involved" \
	"asked GitHub to bring the branch up to date" "Not an error"
called "update-branch was actually requested" "update-branch"
LAND_ARGS=()

# --------------------------------------------------------------------------
# 4. Verify — the three false greens
# --------------------------------------------------------------------------
reset_fixture
printf 'CI passed\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "a required check with no run at all is a failure" \
	"MISSING  gitleaks" "not an absence of news" "annotations"

reset_fixture
printf 'CI passed\tcancelled\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "a cancelled run is not a pass" \
	"CANCELLED CI passed" "gh run watch --exit-status"

reset_fixture
printf 'CI passed\trunning\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "an unfinished check is not a pass" "RUNNING  CI passed"

reset_fixture
printf 'CI passed\tfailure\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "a failed check is a failure" "FAILED   CI passed"

# A job that did not run proved nothing, so landing still refuses. Only the
# WORD changed for a skipped job, never the verdict — queue-state.sh forgives this for a
# draft, and a draft is not landable in the first place. If this test ever goes
# green, an all-skipped run can land having compiled nothing.
reset_fixture
printf 'CI passed\tskipped\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "a skipped check is not a pass" "SKIPPED  CI passed"

# A check name must match exactly. "CI" must not be satisfied by "CI passed".
reset_fixture
printf 'CI passed extra\tsuccess\ngitleaks\tsuccess\n' >"$FIX/checks-ok.txt"
expect_fail "a check name is matched whole, not as a substring" "MISSING  CI passed"

# The older commit-status API is the other place a required context can live.
reset_fixture
printf 'CI passed\tsuccess\n' >"$FIX/checks-ok.txt"
printf 'gitleaks\tsuccess\n' >"$FIX/status.txt"
override "api repos/$REPO/commits/$SHA/status*" status.txt
expect_ok "a required context posted as a commit status counts" "ok       gitleaks"

# --------------------------------------------------------------------------
# 5-7. The full sequence
# --------------------------------------------------------------------------
reset_fixture
expect_ok "a clean PR lands" "merged." "release guard ok" "#7 landed."
called "it merged with a squash" "pr merge 7 --squash"
called "it released the claim" "remove-label merge:landing"
called "it labelled the PR it invalidated" "pr edit 9 --repo example/repo --add-label merge:needs-rebase"
called "it told that PR why" "pr comment 9"

# The overlap that a merge queue cannot see: no shared file, same hotspot.
reset_fixture
printf 'auth/migrations/000041_x.up.sql\n' >"$FIX/files7.txt"
printf 'content/migrations/000112_y.up.sql\n' >"$FIX/files9.txt"
expect_ok "a hotspot-only overlap is still notified" "both touch */migrations/**"

reset_fixture
printf 'web/app/page.tsx\n' >"$FIX/files9.txt"
expect_ok "an unrelated PR is left alone" "nothing else open needed telling"
not_called "an unrelated PR is not labelled" "pr edit 9"

# A truncated file list is the one case where finding no overlap proves nothing.
# Both directions have to notify, or a huge merge tells nobody at all — which
# looks exactly like a merge that overlapped nothing.
reset_fixture
printf 'auth/handler.go\nMERGE-COORDINATOR-TRUNCATED\n' >"$FIX/files7.txt"
printf 'web/app/page.tsx\n' >"$FIX/files9.txt"
expect_ok "a truncated merge tells every open PR" \
	"more files than the API will list" "#9"
called "a truncated merge labels them too" "pr edit 9 --repo example/repo --add-label"

reset_fixture
printf 'auth/handler.go\n' >"$FIX/files7.txt"
printf 'web/app/page.tsx\nMERGE-COORDINATOR-TRUNCATED\n' >"$FIX/files9.txt"
expect_ok "a PR with a truncated list of its own is told as well" "cannot be read"

# The sentinel is bookkeeping, not a path. It must never be reported as a file
# the two pull requests have in common.
reset_fixture
printf 'MERGE-COORDINATOR-TRUNCATED\n' >"$FIX/files7.txt"
printf 'MERGE-COORDINATOR-TRUNCATED\n' >"$FIX/files9.txt"
expect_ok "the truncation marker is never reported as a shared file" "cannot be read"

# --------------------------------------------------------------------------
# 6. The release guard
# --------------------------------------------------------------------------
reset_fixture
override "api repos/$REPO/contents/CHANGELOG.md*" changelog-bad.txt
expect_fail "a merge that reverted the release heading is caught" \
	"NO LONGER CONTAINS" "## [v1.2.3]" "reverted a release heading"

# CRLF must not be what decides it.
reset_fixture
printf '## [v1.2.3] - the release\r\n\r\nnotes\r\n' >"$WORK/crlf.md"
cp "$WORK/crlf.md" "$FIX/changelog-crlf.txt"
override "api repos/$REPO/contents/CHANGELOG.md*" changelog-crlf.txt
expect_ok "a CRLF changelog still passes the release guard" "release guard ok"

# Size must not be what decides it either, and this is the case every fixture
# above misses. Each of them is about thirty bytes, so they fit in the pipe
# buffer whole. A real CHANGELOG.md of over a megabyte broke it, and the guard
# failed on it every single time: `grep -q` matched the heading, stopped, and
# closed the pipe under a `printf` that was still writing. printf died of
# SIGPIPE and pipefail made that the pipeline's status, so a heading that was
# found was reported missing — after the merge, and before step 7 ran.
#
# The heading goes FIRST, ahead of the filler, so a matcher that stops early
# stops while there is still plenty left to write. That is what makes this test
# go red against the old code rather than passing by luck.
reset_fixture
{
	printf '## [v1.2.3] - the release\n\n'
	i=0
	while [ "$i" -lt 8000 ]; do
		printf 'an entry line, long enough that eight thousand of them clear any pipe buffer\n'
		i=$((i + 1))
	done
} >"$WORK/changelog-big.md"
cp "$WORK/changelog-big.md" "$FIX/changelog-big.txt"
override "api repos/$REPO/contents/CHANGELOG.md*" changelog-big.txt
expect_ok "a changelog larger than the pipe buffer still passes the release guard" \
	"release guard ok" "#7 landed."

# An unreadable changelog is not a reverted heading, and must not print the
# reverted-heading alarm. The contents API stops embedding content above 1 MiB:
# it answers 200 with "encoding": "none" and an empty "content". A real
# CHANGELOG.md crossed that line at 1,049,858 bytes on 25 August 2026, and the guard read
# the empty body, announced that a release heading had been reverted, and
# exited before step 7 — so a merge that reverted nothing raised the alarm and
# nobody was told they had gone stale. The guard now asks for raw, and an
# empty body is reported as a failed read.
reset_fixture
: >"$FIX/changelog-empty.txt"
override "api repos/$REPO/contents/CHANGELOG.md*" changelog-empty.txt
expect_fail "an empty changelog response is a failed read, not the reverted-heading alarm" \
	"could not read" "NOT the reverted-heading alarm"

# --------------------------------------------------------------------------
# 7. --dry-run changes nothing
# --------------------------------------------------------------------------
reset_fixture
LAND_ARGS=(--dry-run)
expect_ok "--dry-run walks the whole sequence" "DRY RUN" "would run" "#7 landed."
not_called "--dry-run merges nothing" "pr merge 7 --squash --repo"
not_called "--dry-run labels nothing" "pr edit 9 --repo"
LAND_ARGS=()

# --------------------------------------------------------------------------
# 8. The merge-queue backbone hands over instead of merging.
# --------------------------------------------------------------------------
reset_fixture
set +e
out=$(MC_CONFIG="$WORK/config-queue.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
	bash "$SCRIPT" 7 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ] && contains "$out" "handing to the merge queue" &&
	grep -qF -- "--auto" "$FIX/calls.log"; then
	echo "ok: the merge-queue backbone enqueues rather than merging"
	pass=$((pass + 1))
else
	echo "FAIL: the merge-queue backbone enqueues rather than merging"
	printf '%s\n' "$out" | sed 's/^/    /'
	fail=$((fail + 1))
fi

# --------------------------------------------------------------------------
# 8b. --post-merge runs the two steps the queue hand-off leaves behind.
#
# On the merge-queue backbone step 5 enqueues and returns, so the release guard
# and the notify cannot have run yet. Preflight used to refuse the merged pull
# request outright, which left no way of ever running them: the queue would
# merge, and nobody would be told they had gone stale.
# --------------------------------------------------------------------------
reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed by the queue","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
LAND_ARGS=(--post-merge)
expect_ok "--post-merge runs the release guard and the notify on a merged PR" \
	"already merged" "release guard ok" "#7 landed."
not_called "--post-merge merges nothing" "pr merge 7"
not_called "--post-merge takes no claim" "pr edit 7 --repo"
# Assert the notify actually reached someone, not merely that the run ended
# well. Step 7 decides who to tell from the merged file list, and an empty
# list tells nobody, prints "nothing else open needed telling" and still
# exits 0 — indistinguishable from a working run. Emptying that list survived
# a mutation against the two lines above, which is what these two catch.
called "--post-merge labels the PR the merge invalidated"  "pr edit 9 --repo example/repo --add-label merge:needs-rebase"
called "--post-merge tells that PR why" "pr comment 9"
LAND_ARGS=()

# Closed unmerged is not the same as merged, and must not be treated as it.
# That pull request produced no commit, so there is no release heading to check
# and nobody it could have invalidated — telling other sessions to rebase onto
# a merge that never happened is the confident wrong answer this tool exists to
# prevent.
reset_fixture
printf '{"state":"closed","draft":false,"merged":false,"title":"Abandoned","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
LAND_ARGS=(--post-merge)
expect_fail "--post-merge refuses a PR closed without merging" "not merged"
not_called "--post-merge notifies nobody about an unmerged PR" "pr comment"
LAND_ARGS=()

# The refusal has to name the way forward, or the queue hand-off dead-ends.
reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
expect_fail "a merged PR without the flag is told which flag would work" \
	"is closed, not open" "--post-merge"

# --------------------------------------------------------------------------
# 9. An API that cannot be read must refuse, never assume.
# --------------------------------------------------------------------------
reset_fixture
override "api --paginate repos/$REPO/commits/$SHA/check-runs*" FAIL
override "api repos/$REPO/commits/$SHA/status*" FAIL
expect_fail "unreadable check state refuses rather than assuming" "MISSING"

# --------------------------------------------------------------------------
# 10. The truncation sentinel itself.
#
# Every case above HANDS the sentinel to the script. None of them proves it is
# ever produced, and a detector that never fires is indistinguishable from one
# that works — the API stops at 3000 files and says nothing about it, so the
# short list arrives looking complete. These two drive mc_pr_files directly.
# --------------------------------------------------------------------------
pr_files_of() {
	MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" \
		bash -c '. ./lib/gh.sh; mc_pr_files 7' 2>/dev/null
}

gen_files() {
	MC_N="$1" python -c '
import os
print("\n".join("path/to/f%d.go" % i for i in range(int(os.environ["MC_N"]))))
' 2>/dev/null || MC_N="$1" python3 -c '
import os
print("\n".join("path/to/f%d.go" % i for i in range(int(os.environ["MC_N"]))))
'
}

reset_fixture
gen_files 3000 >"$FIX/big.txt"
override "api --paginate repos/$REPO/pulls/7/files*" big.txt
out=$(pr_files_of | grep -cFx 'MERGE-COORDINATOR-TRUNCATED' || true)
if [ "$out" = "1" ]; then
	echo "ok: a file list at the API ceiling is marked truncated"
	pass=$((pass + 1))
else
	echo "FAIL: a file list at the API ceiling is marked truncated — sentinel count $out"
	fail=$((fail + 1))
fi

reset_fixture
gen_files 2999 >"$FIX/big.txt"
override "api --paginate repos/$REPO/pulls/7/files*" big.txt
out=$(pr_files_of | grep -cFx 'MERGE-COORDINATOR-TRUNCATED' || true)
if [ "$out" = "0" ]; then
	echo "ok: a file list under the ceiling is not marked truncated"
	pass=$((pass + 1))
else
	echo "FAIL: a file list under the ceiling was marked truncated"
	fail=$((fail + 1))
fi

# --------------------------------------------------------------------------
# 11. THE MERGE-QUEUE BACKBONE, step by step.
#
# Everything above runs on serialized-claim and stays that way — the plugin is
# portable and the old backbone has to keep working. These are the same inputs
# under `github-merge-queue`, which is the only way to prove the setting is read
# rather than ignored.
#
# The pairs matter more than the individual cases. "behind 3 refuses" and
# "behind 3 lands" are the same fixture and opposite verdicts, so a land.sh that
# stopped reading `backbone` cannot satisfy both.
# --------------------------------------------------------------------------
MC_TEST_CONFIG="$WORK/config-queue.json"

# 11a. Freshness. A head the base has moved past is refused on serialized-claim
#      and is FINE on a queue: the queue builds base+PR and tests that.
reset_fixture
override "api repos/$REPO/compare/main...$SHA*" behind3.txt
MC_TEST_CONFIG="" expect_fail "behind 3 is refused on serialized-claim" "tested against an older main"
reset_fixture
override "api repos/$REPO/compare/main...$SHA*" behind3.txt
expect_ok "behind 3 is fine on a queue" \
	"3/7 conflicts" "no conflict with main" "handing to the merge queue"
not_called "a queue landing tells nobody to rebase for staleness" "pr edit 9 --repo example/repo --add-label"

# 11b. What DOES stop a landing on a queue: a conflict. The queue cannot merge
#      a tree git will not produce.
reset_fixture
override "api repos/$REPO/pulls/7 --jq .mergeable" mergeable-conflict.txt
expect_fail "a conflicting PR is refused on a queue" "conflicts with main" "git rebase origin/main"
not_called "a refused conflict is never handed to the queue" "pr merge 7"

# 11c. Fails closed. `mergeable` is null while GitHub computes it, and null is
#      not "no conflict" — this is the whole "could not look" family.
reset_fixture
override "api repos/$REPO/pulls/7 --jq .mergeable" mergeable-unknown.txt
expect_fail "an unsettled mergeable refuses rather than assuming" \
	"could not find out" "Nothing was checked"
not_called "an unsettled mergeable is never handed to the queue" "pr merge 7"

# 11d. And it must actually retry before giving up, or the refusal fires on the
#      normal few-second lag after every push.
reset_fixture
override "api repos/$REPO/pulls/7 --jq .mergeable" "SEQ:mergeable-unknown.txt,mergeable-unknown.txt,mergeable-clean.txt"
expect_ok "a mergeable that settles late is waited for" "no conflict with main"

# 11e. The claim. Another PR holding it stops a landing on serialized-claim and
#      must NOT on a queue — that global lock is what kept every merge group to
#      a single entry.
reset_fixture
printf '5\n7\n' >"$FIX/holders.txt"
MC_TEST_CONFIG="" expect_fail "another holder blocks on serialized-claim" "already holds merge:landing"
reset_fixture
printf '5\n7\n' >"$FIX/holders.txt"
expect_ok "another holder does not block on a queue" "#5 is landing too" "handing to the merge queue"

# 11f. But the claim still has to stick. Losing our own label is a read we
#      cannot trust, on either backbone. On a queue the read-back is the PR's
#      own label list, so that is the one that never shows it here.
reset_fixture
override "api repos/$REPO/issues/7/labels*" labels.txt
expect_fail "a claim that never reads back still refuses on a queue" "never showed it"

# 11f2. The listing lag. The label LISTING cannot see the claim yet, and the PR's
#       own labels can. On a queue that is enough, with no re-read. The listing
#       is the surface that lagged on nearly every land.
reset_fixture
printf '' >"$FIX/holders.txt"
expect_ok "a queue reads its own claim from the PR, not the lagging listing" \
	"claim taken" "handing to the merge queue"
reset_fixture
printf '' >"$FIX/holders.txt"
set +e
out=$(land 7)
set -e
if contains "$out" "claim not visible yet"; then
	echo "FAIL: a queue land does not wait on the label listing"
	printf '%s\n' "$out" | sed 's/^/    /'
	fail=$((fail + 1))
else
	echo "ok: a queue land does not wait on the label listing"
	pass=$((pass + 1))
fi

# 11f3. serialized-claim still reads the listing, because its tie-break needs
#       every holder. The PR's own labels showing the claim is not enough there.
reset_fixture
printf '' >"$FIX/holders.txt"
MC_TEST_CONFIG="" expect_fail "serialized-claim still needs the listing to show the claim" "never showed it"

# 11g. --update-branch is refused outright: it exists to fix staleness, and it
#      would buy a full CI run to reach the state the queue produces free.
reset_fixture
LAND_ARGS=(--update-branch)
expect_fail "--update-branch is refused on a queue" "refusing --update-branch on a merge queue"
LAND_ARGS=()

# 11h. The notify. #9 shares auth/handler.go with #7. On serialized-claim that
#      is enough to label and comment. On a queue, if #9 still merges cleanly
#      there is nothing to tell it — this is the six-comments-in-a-day case.
reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
LAND_ARGS=(--post-merge)
expect_ok "a clean overlap is left alone on a queue" "still merges cleanly" "left alone"
not_called "a clean overlap gets no rebase label" "pr edit 9 --repo example/repo --add-label"
not_called "a clean overlap gets no comment" "pr comment 9"

# 11i. And when it genuinely conflicts, it is labelled and told — the one case
#      still worth sending.
reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
override "api repos/$REPO/pulls/9 --jq .mergeable" mergeable-conflict.txt
expect_ok "a conflicting overlap is still told on a queue" "CONFLICTS now"
called "a conflicting overlap is labelled" "pr edit 9 --repo example/repo --add-label merge:needs-rebase"
called "a conflicting overlap is told why" "pr comment 9"
LAND_ARGS=()

# 11j. A hotspot with no shared file: nothing conflicts and nothing will, but a
#      CLEAN merge is the hazard there. Told, and deliberately NOT labelled.
reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
printf 'auth/migrations/000041_a.up.sql\n' >"$FIX/files7.txt"
printf 'auth/migrations/000042_b.up.sql\n' >"$FIX/files9.txt"
LAND_ARGS=(--post-merge)
expect_ok "a hotspot with no shared file is still reported on a queue" "hotspot:" "renumber"
called "a hotspot overlap is told" "pr comment 9"
not_called "a hotspot overlap is not labelled needs-rebase" "pr edit 9 --repo example/repo --add-label"
LAND_ARGS=()

# ---------------------------------------------------------------------------
# 12. outOfQueueCi — CI for a commit that reached the default branch without a
#     queue testing it.
#
#     ci.yml and secret-scan.yml stopped answering a push to main, because the
#     merge queue already tests the exact tree a merge produces. That leaves one
#     real gap: a merge land.sh performs ITSELF, with no queue in front of it.
#     These four cases are the whole contract - it fires there, it stays silent
#     on a queue, an absent key means off, and a config it cannot read says so
#     instead of looking like off.
# ---------------------------------------------------------------------------

# A config that names workflows to fire. Written out rather than sed-patched
# into the base one: inserting a line with sed needs a literal newline in the
# replacement, which is not portable, and a sed that fails here would leave the
# fixture looking like a config with the key absent - which is case 12c, so the
# suite would still pass while testing the wrong thing.
write_ooqci_config() {
	# $1 backbone, $2 the outOfQueueCi value as JSON, $3 destination
	cat >"$3" <<JSON
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed", "gitleaks"],
  "backbone": "$1",
  "outOfQueueCi": $2,
  "requireApproval": true,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": []
}
JSON
	contains "$(cat "$3")" '"outOfQueueCi"' ||
		{ echo "FAIL: the outOfQueueCi fixture config was not written to $3"; exit 1; }
}

write_ooqci_config serialized-claim   '["ci.yml", "secret-scan.yml"]' "$WORK/config-ooqci.json"
write_ooqci_config github-merge-queue '["ci.yml", "secret-scan.yml"]' "$WORK/config-ooqci-queue.json"
write_ooqci_config serialized-claim   '"ci.yml"'                      "$WORK/config-ooqci-bad.json"

# 12a. No queue, key set: both workflows are fired against the default branch.
reset_fixture
override "workflow run*" EMPTY
MC_TEST_CONFIG="$WORK/config-ooqci.json"
expect_ok "a merge with no queue fires CI on the default branch" "fired ci.yml on main"
called "it fires ci.yml" "workflow run ci.yml --ref main"
called "it fires secret-scan.yml" "workflow run secret-scan.yml --ref main"

# 12b. On a queue it must NEVER fire - the merge group tested that tree, and
#      firing here puts back the duplicate run that dropping CI on push removed. This is the
#      assertion that would catch someone "simplifying" the condition away.
reset_fixture
override "workflow run*" EMPTY
MC_TEST_CONFIG="$WORK/config-ooqci-queue.json"
expect_ok "a queue land fires no extra CI" "queued"
not_called "the queue path fires no workflow" "workflow run"

# 12c. Key absent: the feature is off, and it says so rather than going quiet.
reset_fixture
override "workflow run*" EMPTY
MC_TEST_CONFIG="$WORK/config.json"
expect_ok "an absent outOfQueueCi is off, and says so" "outOfQueueCi is not set"
not_called "an absent key fires nothing" "workflow run"

# 12d. A key of the wrong shape is NOT read as off. "not set" and "could not
#      read" are different answers; a caller that prints them the same way does
#      nothing at all when the config is broken and reports that as normal.
reset_fixture
override "workflow run*" EMPTY
MC_TEST_CONFIG="$WORK/config-ooqci-bad.json"
expect_ok "a malformed outOfQueueCi warns, and does not read as off" "could not read outOfQueueCi"
not_called "a malformed key fires nothing" "workflow run"
MC_TEST_CONFIG=""

MC_TEST_CONFIG=""

# --------------------------------------------------------------------------
# 13. The Dependabot gate.
#
# A Dependabot pull request waiting stops a landing before step 1, and the
# session asks the user: land it first (/merge-deps), or later (--skip-deps).
# --admin is the break-glass for a missing review, not for this.
# --------------------------------------------------------------------------
reset_fixture
deps_page "90:bot:0:" "91:human:0:"
expect_fail "a waiting Dependabot pull request stops the landing" \
	"#90 Bump x from 1.0.0 to 1.0.1 (3 days old, no CI on it yet)" "Ask the user whether to land these first" "--skip-deps"
not_called "it stops before the claim" "pr edit 7 --repo"
not_called "and merges nothing" "pr merge 7"
not_called "a person's pull request is not read as Dependabot's" "commits/depsha91"

reset_fixture
printf '0\n' >"$FIX/reviews.txt"
deps_page "90:bot:0:"
LAND_ARGS=(--admin)
expect_fail "--admin alone does not step over it" "Ask the user whether to land these first"
not_called "and merges nothing under --admin" "pr merge 7"
LAND_ARGS=()

reset_fixture
deps_page "90:bot:0:"
LAND_ARGS=(--skip-deps)
expect_ok "--skip-deps lands" "the user said later" "#7 landed."
called "and merges" "pr merge 7"
LAND_ARGS=()

reset_fixture
deps_page "90:bot:1:" "93:bot:0:merge:landing"
expect_ok "a Dependabot pull request that is landing does not stop it" "#7 landed."

reset_fixture
deps_page "7:bot:0:" "90:bot:0:"
expect_ok "a Dependabot pull request lands past the other Dependabot pull requests" \
	"is a Dependabot pull request, so the other open ones do not stop it" "#7 landed."

reset_fixture
override "api graphql *" FAIL
expect_fail "a lookup that fails stops the landing" "could not check the open Dependabot pull requests" "could not look"
not_called "and takes no claim" "pr edit 7 --repo"

# Landing a bump is never stopped, and that must not depend on a listing that
# just failed: the pull request is read directly.
reset_fixture
cat >"$FIX/pr.json" <<JSON
{"state":"open","draft":false,"title":"Bump x","user":{"login":"dependabot[bot]","type":"Bot"},"head":{"ref":"dependabot/x","sha":"$SHA"}}
JSON
override "api graphql *" FAIL
expect_ok "a Dependabot pull request lands when the lookup fails" "but #7 is a Dependabot pull request" "#7 landed."

reset_fixture
override "api graphql *" FAIL
LAND_ARGS=(--dry-run)
expect_ok "--dry-run with a failed lookup reports it, and walks on" "could not check the open Dependabot pull requests" "it would stop here" "would run"
not_called "and merges nothing" "pr merge 7 --squash --repo"
LAND_ARGS=()

reset_fixture
deps_page "90:bot:0:"
LAND_ARGS=(--dry-run)
expect_ok "--dry-run reports what it would stop on, and walks on" "Ask the user whether to land these first" "it would stop here" "would run"
not_called "--dry-run with a Dependabot pull request waiting merges nothing" "pr merge 7 --squash --repo"
LAND_ARGS=()

reset_fixture
printf '{"state":"closed","draft":false,"merged":true,"title":"Landed by the queue","head":{"ref":"work","sha":"%s"}}\n' "$SHA" >"$FIX/pr.json"
override "api graphql *" FAIL
LAND_ARGS=(--post-merge)
expect_ok "--post-merge is not gated" "#7 landed."
not_called "--post-merge does not look for Dependabot pull requests" "api graphql"
LAND_ARGS=()

reset_fixture
override "api graphql *" FAIL
LAND_ARGS=(--release-claim)
expect_ok "--release-claim is not gated" "claim released"
not_called "--release-claim does not look for Dependabot pull requests" "api graphql"
LAND_ARGS=()

reset_fixture
deps_page "90:bot:0:"
set +e
out=$(MERGE_COORDINATOR_OVERRIDE=1 land 7)
status=$?
set -e
if [ "$status" -eq 0 ] && contains "$out" "were not checked"; then
	echo "ok: break glass gets past it, and says so"; pass=$((pass + 1))
else
	echo "FAIL: break glass gets past it, and says so (status $status)"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi

echo
echo "test-land: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
