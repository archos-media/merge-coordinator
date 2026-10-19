#!/usr/bin/env bash
# Live probe: run every helper in lib/gh.sh against the REAL GitHub API.
#
# WHY THIS EXISTS. The test-*.sh suites are offline and fixture-driven, and
# lib/fixture-gh.sh does not implement `--jq`. Every assertion in those suites is
# therefore handed a value that no jq filter ever selected. The filters are the
# one part of this plugin the fixtures structurally cannot prove, and a filter
# that selects the wrong field fails in the exact shape this plugin exists to
# refuse: a confident answer produced from a value nobody read.
#
# So this script sets no MC_GH. Real gh evaluates every filter against a real
# response, and each result is checked against something known independently.
#
# IT IS READ-ONLY. Every call is a GET. It labels nothing, comments on nothing,
# merges nothing and creates nothing. It is safe to run at any time against a
# repository with work in flight.
#
# It is NOT part of CI: it needs the network, an authenticated gh, and it reads
# live state that moves. Run it by hand before relying on the plugin in anger,
# and after any change to a --jq string. Run it from inside the repository it
# should probe:
#
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/probe-live.sh"
#
# FIXTURES LIVE IN THE PROBED REPOSITORY, not here. Every expectation about one
# repository's history — a merged pull request and its file count, a commit with
# no checks, a pull request that declares a footprint — is read from
# .github/merge-coordinator-probe.json (or the file MC_PROBE names). Start from
# probe.example.json in the plugin. A fixture left out is reported N/M, never
# PASS: an assertion with nothing to read is not one that held.
#
# THREE OUTCOMES, NOT TWO: an assertion PASSES, FAILS, or is NOT MEASURABLE.
#
# Expectations that name a specific pull request, commit or tag are pinned to
# history that has already happened. Main moving on cannot disturb them. But
# pinning does not make a fixture permanent. GitHub collects a commit that no
# branch reaches, and check-run data has a retention of its own, so a pin can
# stop being readable with nothing having regressed. A few assertions need live
# state instead — an open pull request carrying a label — which is absent on a
# quiet day for the same non-reason.
#
# Called FAIL, either of those teaches the reader to skip a red line. The next
# failure in that list is then the one this script was built to catch. So they
# are reported as N/M, with the reason and with what to repoint. They are
# counted apart from the failures and they do not set the exit status.
#
# N/M is not a pass. Nothing was measured, and the summary says so. Where the
# difference is visible, this file keeps "I could not look" apart from "I
# looked and it was not there" — a read that comes back empty when the data is
# known to exist is a broken read, and it is still a failure.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# The repository is the one the caller is standing in. The plugin no longer lives
# inside it, so its own location says nothing about which repository to probe.
root=$(git rev-parse --show-toplevel 2>/dev/null) || mc_die "run this from inside the repository to probe."
: "${MC_CONFIG:=$root/.github/merge-coordinator.json}"
: "${MC_PROBE:=$root/.github/merge-coordinator-probe.json}"
export MC_CONFIG MC_PROBE
[ -f "$MC_CONFIG" ] || mc_die "no config at $MC_CONFIG"
[ -f "$MC_PROBE" ] || mc_die "no probe fixtures at $MC_PROBE — copy probe.example.json from the plugin there and point it at this repository's own history."
[ -z "${MC_GH:-}" ] || mc_die "MC_GH is set. This probe is pointless against a fixture; unset it."

# pf <dotted.key> — one probe fixture: a scalar, or a list one item per line.
# Exits 3 when the key is absent, and 1 when the file cannot be read, so a caller
# can say N/M for "not set" and still FAIL on "could not look".
pf() {
	MC_KEY="$1" MC_FILE="$MC_PROBE" mc_py -c '
import json, os, sys
path = os.environ["MC_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        node = json.load(fh)
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (path, exc))
for part in os.environ["MC_KEY"].split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit(3)
    node = node[part]
if isinstance(node, bool):
    node = "true" if node else "false"
if isinstance(node, list):
    sys.stdout.write("\n".join(str(x) for x in node))
else:
    sys.stdout.write("" if node is None else str(node))
'
}
# fixture <var> <dotted.key> — sets var to the fixture and returns 0, or returns
# 1 when the key is absent. An unreadable file stops the probe outright.
fixture() {
	local _v _rc
	_v=$(pf "$2")
	_rc=$?
	case "$_rc" in
	0) printf -v "$1" '%s' "$_v" ;;
	3) return 1 ;;
	*) mc_die "could not read fixture $2 from $MC_PROBE" ;;
	esac
}

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "  PASS  $1"
}
no() {
	fail=$((fail + 1))
	echo "  FAIL  $1"
	[ $# -gt 1 ] && echo "        $2"
	return 0
}
nm_count=0
nm_list=()
# nm <label> <why> — NOT MEASURABLE. The pinned fixture has aged out of the API,
# or the live state this assertion needs is not there today. It is not a pass:
# nothing was checked. It is not a failure: nothing was found wrong. It is
# counted and listed on its own so that neither reading can be taken.
nm() {
	nm_count=$((nm_count + 1))
	nm_list+=("$1${2:+ — $2}")
	echo "  N/M   $1"
	[ $# -gt 1 ] && echo "        $2"
	return 0
}
# want <label> <expected> <actual>
want() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }
# has <label> <needle> <haystack>
has() {
	case "$3" in
	*"$2"*) ok "$1" ;;
	*) no "$1" "[$2] not in: $(printf '%s' "$3" | head -c 200)" ;;
	esac
}

repo=$(mc_repo)
echo "merge-coordinator: live probe against $repo"

# --------------------------------------------------------------------------
echo
echo "== 1. config reads =="
# --------------------------------------------------------------------------
# Each reader is checked against a value written down by hand in the probe file,
# not against a second parse of the config: a second parse would share whatever
# the first one got wrong.
if fixture v expectConfig.repo; then want "repo" "$v" "$repo"; else nm "repo" "set expectConfig.repo"; fi
for key in defaultBranch backbone requireApproval labels.landing; do
	if fixture v "expectConfig.$key"; then
		want "$key" "$v" "$(mc_cfg_get "$key")"
	else
		nm "$key" "set expectConfig.$key"
	fi
done
if fixture checks expectConfig.requiredChecks; then
	want "requiredChecks" "$checks" "$(mc_cfg_list requiredChecks)"
	first_check=$(printf '%s\n' "$checks" | head -1)
	# The CRLF trap, checked as an exact equality rather than a substring: python on
	# Windows writes text mode, and "CI passed\r" never equals "CI passed".
	want "no trailing CR on a config value" "$first_check" "$(mc_cfg_list requiredChecks | head -1)"
else
	nm "requiredChecks" "set expectConfig.requiredChecks"
	first_check=$(mc_cfg_list requiredChecks | head -1)
fi
if fixture v expectConfig.hotspotCount; then
	want "hotspot count" "$v" "$(mc_hotspots | grep -c .)"
else
	nm "hotspot count" "set expectConfig.hotspotCount"
fi

# --------------------------------------------------------------------------
echo
echo "== 2. mc_pr_files — .[].filename =="
# --------------------------------------------------------------------------
# mergedPr is a pull request that is merged, so its file list can no longer
# change and the count is a fixed number. Its head should also be green on every
# required check: section 5 uses it as the known-good head.
merged_pr=
merged_sha=
if fixture merged_pr mergedPr.number; then
	files=$(mc_pr_files "$merged_pr")
	if fixture v mergedPr.fileCount; then
		want "#$merged_pr file count" "$v" "$(printf '%s\n' "$files" | grep -c .)"
	else
		nm "#$merged_pr file count" "set mergedPr.fileCount"
	fi
	if fixture named mergedPr.files; then
		while IFS= read -r f; do
			[ -n "$f" ] && has "#$merged_pr names $f" "$f" "$files"
		done <<EOF
$named
EOF
	fi
	# `case`, for the same reason the assertion at the bottom of this file enforces
	# everywhere else. A short file list is far too small to trip the trap, which is
	# exactly how this construction survives review and then fails on the one input
	# that matters.
	case "$files" in
	*MERGE-COORDINATOR-TRUNCATED*) no "no false truncation sentinel on a small PR" ;;
	*) ok "no false truncation sentinel on a small PR" ;;
	esac
else
	nm "mc_pr_files reads a merged pull request" "set mergedPr.number"
fi

# --------------------------------------------------------------------------
echo
echo "== 3. mc_pr_head_sha — .head.sha =="
# --------------------------------------------------------------------------
if [ -n "$merged_pr" ]; then
	merged_sha=$(mc_pr_head_sha "$merged_pr")
	case "$merged_sha" in
	????????????????????????????????????????) ok "returns a 40-character sha ($merged_sha)" ;;
	*) no "returns a 40-character sha" "got [$merged_sha]" ;;
	esac
else
	nm "mc_pr_head_sha returns a sha" "set mergedPr.number"
fi

# --------------------------------------------------------------------------
echo
echo "== 3b. mc_mergeable — .mergeable =="
# --------------------------------------------------------------------------
# The filter this whole probe exists for. On the queue backbone `mergeable` is
# what stops a landing, so a `--jq` that silently returns nothing would refuse
# every pull request or wave every one through, and no offline fixture can tell.
#
# GitHub computes the field lazily and answers null until a background merge
# attempt finishes, so ALL THREE of CLEAN, CONFLICTING and UNKNOWN are correct
# answers here. What is asserted is that the filter returns one of them and
# never an empty string.
for probe_pr in $(mc_gh pr list --repo "$repo" --state open --limit 3 --json number --jq '.[].number'); do
	state=$(mc_mergeable "$probe_pr")
	case "$state" in
	CLEAN | CONFLICTING | UNKNOWN) ok "mc_mergeable #$probe_pr reads $state" ;;
	*) no "mc_mergeable #$probe_pr returns a known state" "got [$state]" ;;
	esac
done
# And the fail-closed half, which matters more than the happy path: a pull
# request that does not exist must read UNKNOWN, never CLEAN. If a failed call
# fell through to CLEAN, step 3 would wave through everything it could not read.
missing=$(mc_mergeable 99999999)
want "a pull request that cannot be read is UNKNOWN" "UNKNOWN" "$missing"

# --------------------------------------------------------------------------
echo
echo "== 4. mc_behind_by — .behind_by =="
# --------------------------------------------------------------------------
main_sha=$(mc_gh api "repos/$repo/commits/main" --jq '.sha')
want "main compared with itself is 0" "0" "$(mc_behind_by "$main_sha")"
# The oldest OPEN pull request, found rather than hardcoded. This named one
# fixed number until 26 August, when that pull request landed and the
# assertion started failing for the
# one reason that is not a fault: the pull request it watched had gone. A probe
# that has to be edited every time an old branch lands gets edited without being
# read. The point of the assertion is that the field is read at all and comes
# back as a number, so any stale branch will do.
oldest=$(mc_gh pr list --repo "$repo" --state open --limit 1 \
	--json number --jq '.[0].number' 2>/dev/null || true)
if [ -z "$oldest" ]; then
	# Nothing open is a legitimate state. It is not a pass, and it is not a
	# failure either: there is no branch that could be stale. This was the first
	# not-measurable case in the file. It was written as a bare echo that no
	# total counted, so it is now reported like every other one.
	nm "oldest open PR reads as behind" \
		"nothing is open today, so there is no stale branch to measure"
else
	behind=$(mc_behind_by "$(mc_pr_head_sha "$oldest")")
	case "$behind" in
	'' | *[!0-9]*) no "oldest open PR #$oldest reads as behind" "got [$behind]" ;;
	*) ok "oldest open PR #$oldest is $behind commit(s) behind main" ;;
	esac
fi

# --------------------------------------------------------------------------
echo
echo "== 5. mc_require_checks — the three false-green traps =="
# --------------------------------------------------------------------------
echo "-- a head that really is green"
states=
if [ -n "$merged_sha" ]; then
	states=$(mc_checks_state "$merged_sha")
	while IFS= read -r c; do
		[ -n "$c" ] && has "check-runs filter yields '$c'" "$c" "$states"
	done <<EOF
$(mc_cfg_list requiredChecks)
EOF
	out=$(mc_require_checks "$merged_sha")
	rc=$?
	want "green head passes" "0" "$rc"
	has "reports ok for $first_check" "ok       $first_check" "$out"
else
	nm "a green head passes" "set mergedPr.number to a merged pull request whose head is green"
fi

echo "-- a run that was CANCELLED: gh run watch --exit-status returns 0 for these"
# One job is cancelled, and the aggregate gate reports the whole thing as a
# FAILURE rather than as cancelled — so in this repository the protection comes
# from the failure branch, and the cancelled branch is defensive. Both are
# checked, separately, because assuming either one covers the other is how a
# false green gets in.
#
# THIS FIXTURE CANNOT BE PINNED. It used to name
# a274fb79, the head of a pull request branch. That commit now returns 422:
# GitHub collects a commit that no branch reaches. Check-run data expires on its
# own schedule besides, so even a commit that stays can stop carrying the
# cancelled run this needs.
#
# The old guard asked whether the COMMIT still existed and fell back only then.
# That is the wrong question twice. It stays answerable long after the fixture
# is useless, and it was unanswerable here, so the fallback did all the work in
# silence while the header claimed a pin. The question asked now is the one that
# matters: does a commit still carry a cancelled CHECK.
#
# Candidates come from the runs API, which is a surface independent of the
# check-state filter under test. A cancelled run does not guarantee a cancelled
# check run — a re-run supersedes it under filter=latest — so several are tried.
tried=0
saw_any_state=0
cancel_sha=
states_c=
cancelled_name=
for cand in $(mc_gh run list --limit 300 --json headSha,conclusion \
	--jq '.[] | select(.conclusion == "cancelled") | .headSha' 2>/dev/null | sort -u | sed -n '1,8p'); do
	tried=$((tried + 1))
	cand_states=$(mc_checks_state "$cand")
	[ -n "$cand_states" ] && saw_any_state=1
	# A name counts only when EVERY row it has is cancelled. A workflow that runs
	# on several events leaves several rows under one name on one commit, and a
	# cancelled row with a later success beside it is a superseded run, not a
	# cancelled check: mc_require_checks is right to call that one ok. Picking it
	# made this section report three failures in a healthy repository.
	cand_name=$(printf '%s\n' "$cand_states" | awk -F'\t' '
		NF >= 2 { if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } if ($2 != "cancelled") other[$1] = 1; else c[$1] = 1 }
		END { for (i = 1; i <= n; i++) if ((order[i] in c) && !(order[i] in other)) { print order[i]; exit } }')
	if [ -n "$cand_name" ]; then
		cancel_sha=$cand
		states_c=$cand_states
		cancelled_name=$cand_name
		break
	fi
done

if [ -z "$cancelled_name" ]; then
	# Why it could not be measured decides whether this is news. A check-state
	# read that comes back EMPTY for commits the runs API says ran something is
	# a broken read, not an expired fixture, and it stays a failure.
	if [ "$tried" -eq 0 ]; then
		why="no run in the last 300 was cancelled, so no commit here carries one"
	elif [ "$saw_any_state" -eq 0 ]; then
		no "mc_checks_state reads a state back for a commit that ran" \
			"$tried commit(s) the runs API says were cancelled, and not one check row between them"
		why="the check-state read above returned nothing, so the cancelled branch cannot be reached"
	else
		why="$tried commit(s) had a cancelled run, but none still reports a cancelled CHECK — superseded by a re-run, or expired"
	fi
	nm "a cancelled job is visible in the check state" "$why"
	nm "the commit behind a cancelled run does not pass" "same fixture"
	nm "requiring a cancelled check name does not pass" "same fixture"
else
	# The discriminator above IS this assertion, so it is reported here rather
	# than re-tested. Re-testing it against the value that selected it would be
	# an assertion that cannot fail.
	ok "a cancelled job is visible in the check state ('$cancelled_name' on $cancel_sha)"
	# With the configured required checks, the commit must fail only if the
	# cancelled name is one of them. A cancelled job that nothing requires is not
	# a reason to refuse a landing.
	if mc_cfg_list requiredChecks | awk -v n="$cancelled_name" '$0 == n { f = 1 } END { exit f ? 0 : 1 }'; then
		out=$(mc_require_checks "$cancel_sha")
		rc=$?
		if [ "$rc" -ne 0 ]; then ok "the commit behind a cancelled run does not pass (rc=$rc)"; else no "the commit behind a cancelled run does not pass" "$out"; fi
		has "and it says so rather than reporting ok" "$cancelled_name" "$out"
	else
		echo "       '$cancelled_name' is not a required check, so the configured list is not expected to fail here;"
		echo "       the scratch list below makes it required and tests the cancelled branch directly."
	fi

	echo "-- and the cancelled branch itself, by requiring a name that IS cancelled"
	# Same real API, same real --jq. Only the list of required names is scratch,
	# which is a configured value rather than a fixture: whichever check is
	# cancelled on that commit is made the required one, so the branch that
	# prints CANCELLED is reached with data GitHub actually returned.
	scratch=$(mktemp)
	MC_SRC="$MC_CONFIG" MC_NAME="$cancelled_name" mc_py -c '
import json, os, sys
cfg = json.load(open(os.environ["MC_SRC"], encoding="utf-8"))
cfg["requiredChecks"] = [os.environ["MC_NAME"]]
sys.stdout.write(json.dumps(cfg))
' >"$scratch"
	out=$(MC_CONFIG="$scratch" mc_require_checks "$cancel_sha")
	rc=$?
	rm -f "$scratch"
	if [ "$rc" -ne 0 ]; then ok "requiring '$cancelled_name' does not pass (rc=$rc)"; else no "requiring '$cancelled_name' does not pass" "$out"; fi
	has "and it is named CANCELLED, not success" "CANCELLED" "$out"
fi

echo "-- a commit with no checks at all: absence is a failure, not silence"
# noCheckCommit is a commit from before any workflow existed — a repository's
# first week is the usual place. Both surfaces are genuinely empty on it: 0
# check-runs and 0 commit statuses, and the first two assertions prove that
# before the third leans on it.
if fixture nocheck noCheckCommit; then
	want "the fixture commit really has no check-runs" "0" \
		"$(mc_gh api "repos/$repo/commits/$nocheck/check-runs?filter=latest" --jq '.total_count')"
	want "and no commit statuses either" "0" \
		"$(mc_gh api "repos/$repo/commits/$nocheck/status" --jq '.statuses | length')"
	out=$(mc_require_checks "$nocheck")
	rc=$?
	if [ "$rc" -ne 0 ]; then ok "a commit with no checks fails (rc=$rc)"; else no "a commit with no checks fails" "$out"; fi
	has "and it names them MISSING" "MISSING" "$out"
else
	nm "a commit with no checks fails" "set noCheckCommit to a commit made before any workflow existed"
fi

echo "-- a required name must match whole, not as a prefix"
# The prefix is the first word of the first required check: "CI" for "CI passed".
# A single-word name has no shorter prefix to confuse it with.
prefix=${first_check%% *}
if [ -z "$states" ]; then
	nm "a required name is not satisfied by its prefix" "needs the green head from mergedPr"
elif [ "$prefix" = "$first_check" ]; then
	nm "a required name is not satisfied by its prefix" "'$first_check' is one word, so there is no prefix to test"
elif printf '%s\n' "$states" | awk -F'\t' -v p="$prefix" '$1 == p { found = 1 } END { exit found ? 0 : 1 }'; then
	no "no real check is literally named $prefix (the prefix test needs that to hold)"
else
	ok "'$first_check' is not satisfiable by a check named '$prefix'"
fi

# --------------------------------------------------------------------------
echo
echo "== 6. mc_open_prs — the ordering tie-break =="
# --------------------------------------------------------------------------
prs=$(mc_open_prs)
n=$(printf '%s\n' "$prs" | grep -c .)
if [ "$n" -ge 1 ]; then ok "lists $n open pull request(s)"; else no "lists the open pull requests" "got none"; fi
want "five tab-separated fields" "5" "$(printf '%s\n' "$prs" | head -1 | awk -F'\t' '{print NF}')"
oldest=$(printf '%s\n' "$prs" | head -1 | cut -f1)
lowest=$(printf '%s\n' "$prs" | cut -f1 | sort -n | head -1)
want "oldest-first: the first row is the lowest number" "$lowest" "$oldest"
if printf '%s\n' "$prs" | awk -F'\t' '$3 != "true" && $3 != "false" { bad = 1 } END { exit bad ? 1 : 0 }'; then
	ok "the draft field is a JSON boolean, spelled true/false"
else
	no "the draft field is a JSON boolean" "$(printf '%s\n' "$prs" | cut -f3 | sort -u | tr '\n' ' ')"
fi

# --------------------------------------------------------------------------
echo
echo "== 7. the filters land.sh runs inline, outside lib/gh.sh =="
# --------------------------------------------------------------------------
if [ -n "$merged_pr" ]; then
	labels=$(mc_gh api "repos/$repo/issues/$merged_pr/labels" --jq '[.[].name] | join(",")')
	case "$labels" in
	*'['*) no "the labels filter returns a joined string, not JSON" "$labels" ;;
	*) ok "the labels filter returns a joined string: [$labels]" ;;
	esac
	review=$(mc_gh api "repos/$repo/pulls/$merged_pr/reviews" --jq '[.[] | select(.state == "APPROVED")] | length')
	case "$review" in
	'' | *[!0-9]*) no "the approval count is an integer" "got [$review]" ;;
	*) ok "the approval count is an integer ($review)" ;;
	esac
else
	nm "the labels and approval filters" "set mergedPr.number"
fi
# The claim reader, checked against a label that is REALLY on an open pull
# request right now.
#
# The first version of this asserted only that the reader ran and found nothing
# holding merge:landing, and called that a pass. It cannot be one. Nothing was
# holding the claim, so "correctly empty" and "always empty, whatever you ask"
# produced identical output — the same shape as `<search> || echo "all clear"`,
# which reports "not found" and "could not look" in the same words. The reader
# WAS always empty, and this said PASS.
#
# So a label is picked out of the open pull requests as they are today, and the
# reader has to find the pull request it came from.
probe_label=$(mc_open_prs | awk -F'\t' '$5 != "" { split($5, a, ","); print $1 "\t" a[1]; exit }')
probe_pr=$(printf '%s' "$probe_label" | cut -f1)
probe_name=$(printf '%s' "$probe_label" | cut -f2)
if [ -z "$probe_name" ]; then
	# Not pinned history at all. This needs an open pull request carrying a
	# label, which is live state. On a day when nothing open has one there is
	# nothing to read the reader against, and FAIL would report the repository
	# being quiet as a defect in the claim reader.
	nm "found a labelled open pull request to test the claim reader against" \
		"no open pull request carries a label today; label any open one and re-run to check the claim reader"
else
	holders=$(mc_claim_holders "$probe_name" || true)
	case " $(printf '%s' "$holders" | tr '\n' ' ') " in
	*" $probe_pr "*) ok "the claim reader finds #$probe_pr by its label '$probe_name'" ;;
	*) no "the claim reader finds #$probe_pr by its label '$probe_name'" \
		"got [$(printf '%s' "$holders" | tr '\n' ' ')] — the claim read-back is blind" ;;
	esac
fi
# And the endpoint it used to use, on the same label, for contrast. This one is
# a report rather than an assertion: it is correct for labels written a while
# ago and wrong only for one written seconds earlier, which is exactly when the
# claim reads it. See mc_claim_holders in lib/gh.sh.
if [ -n "${probe_name:-}" ]; then
	legacy=$(mc_gh api --paginate "repos/$repo/issues?labels=$probe_name&state=open" \
		--jq '.[] | select(.pull_request != null) | .number' 2>/dev/null | tr '\n' ' ' || true)
	echo "       for contrast, issues?labels=$probe_name returns: [${legacy}]"
fi
claimed=$(mc_claim_holders "$(mc_cfg_get labels.landing)" || true)
echo "       merge:landing is currently held by: [$(printf '%s' "$claimed" | tr '\n' ' ')]"
# The label has to exist, or the claim step takes a claim nobody can see.
for want_label in landing blocked needsRebase; do
	name=$(mc_cfg_get "labels.$want_label")
	if mc_gh api "repos/$repo/labels/$(printf '%s' "$name" | sed 's/:/%3A/')" --jq '.name' >/dev/null 2>&1; then
		ok "label $name exists in the repository"
	else
		no "label $name exists in the repository" "the claim would be invisible"
	fi
done

# --------------------------------------------------------------------------
echo
echo "== 8. the release guard: base64 out of the contents API, then CRLF =="
# --------------------------------------------------------------------------
tag=$(mc_gh api "repos/$repo/tags?per_page=1" --jq '.[0].name // ""')
changelog=$(mc_cfg_get releaseGuard.changelog)
if [ -z "$changelog" ]; then
	nm "the release guard" "releaseGuard.changelog is \"\", so the guard is off in this repository"
elif [ -z "$tag" ]; then
	nm "the release guard" "the repository has no tags yet, so there is no heading to look for"
else
fmt=$(mc_cfg_get releaseGuard.headingFormat)
heading=${fmt//\{tag\}/$tag}
base=$(mc_cfg_get defaultBranch)
echo "       newest tag $tag, looking for '$heading' in $changelog on $base"
body=$(mc_gh api "repos/$repo/contents/$changelog?ref=$base" --jq '.content' |
	tr -d '\n' | mc_py -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode("utf-8","replace"))' |
	tr -d '\r')
bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
# changelogMinBytes is a floor the file is known to be above. It stops a decode
# that returned a fragment from passing as one that returned the file.
fixture min_bytes changelogMinBytes || min_bytes=1
if [ "$bytes" -ge "$min_bytes" ]; then ok "decoded $changelog from the API ($bytes bytes)"; else no "decoded $changelog" "only $bytes bytes, expected at least $min_bytes"; fi
case "$body" in
*$'\r'*) no "the decoded body carries no carriage returns" ;;
*) ok "the decoded body carries no carriage returns" ;;
esac
# Matched with `case`, exactly as land.sh does it. Writing this probe with
# `printf | grep -qF` is what found the bug in the first place: grep matched,
# closed the pipe, printf died of SIGPIPE, and pipefail reported the heading
# missing from a file that plainly contains it.
case "$body" in
*"$heading"*) ok "the guard finds '$heading' on $base" ;;
*) no "the guard finds '$heading' on $base" "this is the reverted-heading shape — check $base" ;;
esac
# The guard is only worth anything if it can say no.
case "$body" in
*"## [v0.0.0-absent]"*) no "the guard would reject a heading that is not there" ;;
*) ok "the guard would reject a heading that is not there" ;;
esac
# And the shape itself, asserted rather than assumed: a piped grep -q reports the
# wrong answer under pipefail, which is why neither land.sh nor this file uses
# one.
#
# Tested against a SYNTHETIC body, not against CHANGELOG.md. The trap needs more
# text than the pipe buffer holds — about 64 KiB — and the changelog it was
# written against used to have a megabyte of it. Its archives were split out
# on 26 August, leaving roughly
# 60 KB, just under the line, so the assertion stopped reproducing and reported
# the trap as platform-specific. It is neither: it is size-dependent, and the
# file will cross back over as releases accumulate. Generating the body pins the
# platform behaviour whatever the file happens to weigh today.
printf '       %s on %s is %s bytes (the trap needs ~65536)\n' "$changelog" "$base" "${#body}"
# WHETHER THE TRAP FIRES IS NOT DETERMINISTIC, so it is reported and not
# asserted. It needs grep to exit while the writer still has text to push, and
# that depends on the body size, on the pipe buffer, and on which of the two
# processes the scheduler runs first. Bash's printf is a builtin, and on Git Bash
# for Windows a 300 KB body with the match at the front still returns 0.
#
# This used to be a hard assertion against CHANGELOG.md, and it passed only
# because that file was a megabyte. When its archives were split out on
# 26 August, the file fell to ~60 KB, and the assertion began failing on a
# perfectly healthy repository — reporting a real trap as "platform-specific" and training the
# reader to skip a red line. An assertion that flips with an unrelated file's
# size is measuring the file, not the code.
#
# What IS deterministic is whether the code uses the unsafe construction, so that
# is what gets asserted, below.
big="$heading$(printf 'x%.0s' $(seq 1 200000))"
sigpipe=$(
	set -o pipefail
	printf '%s' "$big" | grep -qF -- "$heading" # UNSAFE-ON-PURPOSE
	echo $?
)
if [ "$sigpipe" = "0" ]; then
	echo "       FYI: a piped grep -q returned 0 over ${#big} bytes here, so the trap did"
	echo "            not reproduce on this platform. That is not evidence it is safe."
else
	echo "       FYI: a piped grep -q returned $sigpipe over ${#big} bytes here — the trap,"
	echo "            reproduced. This is why the guard matches with 'case'."
fi
fi # release guard configured and a tag to look for

# The real guarantee, and it does not depend on the weather: no script in this
# plugin may read a body through `| grep -q`. That is the construction that
# reported a release heading missing from a file that plainly contained it.
# Two exclusions, both deliberate.
#
# Comment lines: several scripts here explain this trap in prose, so a scan that
# did not skip comments would fail on the documentation that exists because of
# it.
#
# `# UNSAFE-ON-PURPOSE`: the demonstration a few lines above, which has to use
# the bad construction to find out whether it still reproduces. A marker rather
# than a line number, so it survives an edit, and a marker rather than silence,
# so the exception is visible to anyone grepping for it.
#
# Written this way this scan found FOUR live instances when it was added —
# guard-merge.sh's merge detector, both truncation-sentinel tests in land.sh
# step 7, and one in this file. Every one of them was safe only by accident:
# either the script happened not to set pipefail, or the match happened to sit
# at the end of the input where grep reads everything before exiting.
unsafe=$(grep -rn '| *grep -q' "$here"/*.sh "$here"/lib/*.sh 2>/dev/null |
	grep -v ':[0-9]*:[[:space:]]*#' |
	grep -v 'UNSAFE-ON-PURPOSE' || true)
if [ -n "$unsafe" ]; then
	no "no plugin script pipes into grep -q" "$(printf '%s' "$unsafe" | sed -n '1p')"
else
	ok "no plugin script pipes into grep -q"
fi

# --------------------------------------------------------------------------
echo
echo "== 8b. mc_pr_footprint - .body // \"\" =="
# --------------------------------------------------------------------------
# The filter here has two jobs the fixtures cannot check. It has to select the
# body and not the title, and `// ""` has to turn a null body into an empty
# string rather than the four characters "null" - a body of null is what GitHub
# returns for a pull request opened with no description at all, and "null" would
# be searched for a block and reported as "declared nothing", which is the same
# wrong answer arrived at a different way.
#
# footprintPr is pinned history: a pull request whose body declares a footprint
# block of two or more lines, listed in footprintPr.declares. noFootprintPr is
# one whose body carries no block.
if fixture fp_pr footprintPr.number && fixture fp_paths footprintPr.declares; then
	declared=$(mc_pr_footprint "$fp_pr" || echo "READ-FAILED")
	first_path=$(printf '%s\n' "$fp_paths" | head -1)
	last_path=$(printf '%s\n' "$fp_paths" | tail -1)
	has "a real declaration is read back" "$first_path" "$declared"
	if [ "$first_path" = "$last_path" ]; then
		nm "every line of the block is read, not only the first" "footprintPr.declares names one path; give it two"
	else
		has "every line of the block is read, not only the first" "$last_path" "$declared"
	fi
	case "$declared" in
	*"<!--"* | *"-->"*) no "the markers themselves are not returned as paths" "$declared" ;;
	*) ok "the markers themselves are not returned as paths" ;;
	esac
else
	nm "mc_pr_footprint reads a declaration back" "set footprintPr.number and footprintPr.declares"
fi

if fixture nofp_pr noFootprintPr; then
	undeclared=$(mc_pr_footprint "$nofp_pr")
	rc=$?
	want "a pull request with no block declares nothing" "" "$undeclared"
	want "and that is not an error" "0" "$rc"

	# A body of null must not arrive as the string "null". Asked of the endpoint
	# directly, because no open pull request is guaranteed to have an empty body.
	nulled=$(mc_gh api "repos/$repo/pulls/$nofp_pr" --jq '.nosuchfield // ""')
	want "// \"\" turns an absent field into an empty string, not \"null\"" "" "$nulled"
else
	nm "a pull request with no block declares nothing" "set noFootprintPr"
fi

# --------------------------------------------------------------------------
echo
echo "== 9. mc_hotspot_match against typical paths =="
# --------------------------------------------------------------------------
t() {
	if mc_hotspot_match "$1" "$2"; then r=match; else r=no; fi
	want "$1  vs  $2" "$3" "$r"
}
t "CHANGELOG.md" "CHANGELOG.md" match
t "CHANGELOG.md" "docs/CHANGELOG.md" no
t "*/migrations/**" "db/migrations/0142_add_thing.sql" match
t "*/migrations/**" "docs/plans/EXAMPLE-PLAN.md" no
t "vendor/**" "vendor/github.com/lib/pq/conn.go" match
t "vendor/**" "web/src/vendor.ts" no
t ".github/workflows/**" ".github/workflows/ci.yml" match
t ".github/workflows/**" ".github/merge-coordinator.json" no

# --------------------------------------------------------------------------
echo
echo "== 9b. mc_claim_runs — the claim check's runs on one commit =="
# --------------------------------------------------------------------------
# claim-gate.sh re-runs the newest issue-claim.yml run on a pull request's head,
# picked from these rows by branch and repository. The offline tests hand it
# rows and never run the --jq. Checked against gh's own run list: the newest
# pull_request run of the workflow must come back as the newest row for its
# commit and branch.
cr_latest=$(mc_gh run list --repo "$repo" --workflow issue-claim.yml --event pull_request --limit 1 \
	--json databaseId,headSha,headBranch --jq '.[0] | select(.) | "\(.databaseId)\t\(.headSha)\t\(.headBranch)"' 2>/dev/null || true)
if [ -z "$cr_latest" ]; then
	nm "mc_claim_runs finds the newest claim run on its commit" \
		"no pull_request run of issue-claim.yml in this repository (no claim check, or none yet)"
else
	cr_id=$(printf '%s' "$cr_latest" | cut -f1)
	cr_sha=$(printf '%s' "$cr_latest" | cut -f2)
	cr_branch=$(printf '%s' "$cr_latest" | cut -f3)
	cr_rows=$(mc_claim_runs "$cr_sha" issue-claim.yml || echo "READ FAILED")
	cr_got=$(printf '%s\n' "$cr_rows" | awk -F'\t' -v b="$cr_branch" '$3 == b { last = $1 } END { print last }')
	want "mc_claim_runs finds the newest claim run on its commit ($cr_sha, $cr_branch)" "$cr_id" "$cr_got"
	cr_bad=$(printf '%s\n' "$cr_rows" | awk -F'\t' 'NF != 4' | grep -c . || true)
	want "every row has four fields" "0" "$cr_bad"
fi

# --------------------------------------------------------------------------
echo
echo "== 10. deps-open.sh — the open Dependabot pull requests =="
# --------------------------------------------------------------------------
# The lister reads GraphQL, where the bot is a Bot called `dependabot`. It is
# checked against gh's own author filter, which names the same bot a different
# way (`app/dependabot`): two spellings agreeing is the evidence that neither
# filter matches nothing. Pull requests carrying the blocked label are left out
# of both, as the lister leaves them out.
deps_rows=$(bash "$here/deps-open.sh")
deps_rc=$?
want "deps-open.sh could look" "0" "$deps_rc"
deps_listed=$(printf '%s\n' "$deps_rows" | cut -f1 | grep . | sort -n | tr '\n' ' ')
blocked=$(mc_cfg_get labels.blocked)
deps_gh=$(mc_gh pr list --repo "$repo" --author app/dependabot --state open --limit 500 --json number,labels \
	--jq "[.[] | select([.labels[].name] | index(\"$blocked\") | not) | .number] | sort | .[]" | tr '\n' ' ')
deps_gh_rc=$?
if [ "$deps_gh_rc" -ne 0 ]; then
	no "gh pr list --author app/dependabot could be read" "exit $deps_gh_rc"
elif [ -z "$deps_gh" ] && [ -z "$deps_listed" ]; then
	nm "the lister finds the same Dependabot pull requests as gh's author filter" "no Dependabot pull request is open in $repo today"
else
	want "the lister finds the same Dependabot pull requests as gh's author filter" "$deps_gh" "$deps_listed"
fi
if [ -n "$deps_rows" ]; then
	bad_rows=$(printf '%s\n' "$deps_rows" | awk -F'\t' 'NF != 6 || ($2 != "waiting" && $2 != "landing")' | grep -c . || true)
	want "every row has six fields and a status" "0" "$bad_rows"
	unread=$(printf '%s\n' "$deps_rows" | awk -F'\t' '$4 == "could not read"' | grep -c . || true)
	want "the CI of every head could be read" "0" "$unread"
fi

echo
echo "-------------------------------------"
echo "  passed $pass, failed $fail, not measurable $nm_count"
if [ "$nm_count" -gt 0 ]; then
	echo
	echo "  NOT MEASURABLE — the fixture or the live state these need was not there."
	echo "  Nothing regressed, and nothing was proved. Repoint or re-run:"
	for nm_line in "${nm_list[@]}"; do echo "    - $nm_line"; done
fi
# Only a real failure sets the exit status. A probe that exits 1 because a
# commit aged out is a probe people stop running.
[ "$fail" -eq 0 ] || exit 1
