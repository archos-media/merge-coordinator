#!/usr/bin/env bash
# Shared helpers for the merge coordinator. Source this; do not run it.
#
# Everything that talks to GitHub goes through mc_gh, and everything that reads
# repository settings goes through mc_cfg_*. That is what makes the three entry
# scripts testable: a test points MC_GH at a fixture script and MC_CONFIG at a
# fixture file, and every rule then runs exactly as it runs for real.
#
# THE ONE FUNCTION THAT MATTERS is mc_require_checks. Three separate traps in
# this repository are all the same mistake — reading a result that was never
# produced and calling it a pass:
#
#   - `gh run watch --exit-status` returns 0 for a CANCELLED run, so a run that
#     a later push superseded reports success with nothing behind it.
#   - A GitHub billing wall refuses every job in 2-4 seconds with no steps run.
#     The reason exists only in the check-run annotations, so a red that fast
#     means nothing ran at all.
#   - `<search> || echo "all clear"` reports "not found" and "could not look"
#     in the same words.
#
# So mc_require_checks reads the conclusion of a NAMED check on a NAMED commit,
# and a name it cannot find is a failure. Never a pass, never a warning.
#
# Bash 3.2 compatible on purpose: it has to run on the maintainer's Git Bash for
# Windows as well as on ubuntu-latest, and Windows ships bash 3.2 semantics for
# anything Apple-adjacent. No associative arrays, no `readarray`.

# --------------------------------------------------------------------------
# Basics
# --------------------------------------------------------------------------

# Where the plugin itself is installed, for messages that name a file shipped
# with it. Not the repository: that is wherever the caller is standing.
MC_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

mc_die() {
	echo "merge-coordinator: $*" >&2
	exit 1
}

mc_warn() {
	echo "merge-coordinator: $*" >&2
}

# The config is JSON, matching .github/labels.json, and jq is not installed on
# every machine that runs this (the maintainer's Windows box has python and gh
# but no jq). gh's own --jq only filters API responses, never a local file, so
# python does the local reads.
#
# It is not enough that the name is on PATH. Windows installs an App Execution
# Alias called python3.exe that exists, resolves, prints "Python was not found"
# and exits non-zero — so the candidate has to be RUN before it is believed.
# That is the same shape as every other trap in this file: presence is not proof.
mc_py() {
	if [ -z "${MC_PYTHON:-}" ]; then
		local cand
		for cand in python3 python py; do
			if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
				MC_PYTHON="$cand"
				break
			fi
		done
		[ -n "${MC_PYTHON:-}" ] || mc_die "needs a working python3 (or python) on PATH to read the config file."
		export MC_PYTHON
	fi
	# UTF-8 out and LF out, always, on every platform.
	#
	# Two Windows behaviours would otherwise reach the comparisons below. Python
	# writes stdout in the console codepage, so an em dash is a different byte
	# there than on a CI runner; and python writes text mode line endings, so
	# every line it prints arrives with a trailing carriage return. A required
	# check named "CI passed" then never equals the "CI passed\r" read out of the
	# config, and the script reports it missing — a wrong answer produced with
	# complete confidence, about a file that was perfectly correct.
	#
	# Callers therefore get LF-only text. Nothing in this plugin wants a CR.
	#
	# The status returned is PYTHON's, not the one the pipeline would give.
	# Ending a function in a pipe hands the caller the status of `tr`, which is
	# 0 whatever python did, unless that caller happens to have set pipefail.
	# Every script in this plugin does set it - and a helper whose failures are
	# only visible to callers configured a particular way is the same shape as
	# every trap this file is written against: "I could not look" arriving as
	# "there was nothing there". Found 26 August by a test that deliberately
	# does not set pipefail.
	local rc
	PYTHONIOENCODING=utf-8 "$MC_PYTHON" "$@" | tr -d '\r'
	rc=${PIPESTATUS[0]}
	return "$rc"
}

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

# MC_CONFIG overrides the path: the test scripts feed fixtures through it, and
# guard-ready.sh passes a config read from GitHub for a repository with no
# checkout here. There is
# deliberately NO fallback to the bundled config.example.json: a repository with
# no config of its own must stop, not quietly coordinate against someone else's
# hotspot table.
mc_config_path() {
	if [ -n "${MC_CONFIG:-}" ]; then
		printf '%s' "$MC_CONFIG"
		return 0
	fi
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null) || mc_die "not inside a git repository, and MC_CONFIG is unset."
	printf '%s/.github/merge-coordinator.json' "$root"
}

# mc_require_config — read the config once, HERE, in the caller's own shell.
#
# Every other read of it happens inside a command substitution, and that is what
# made a missing config produce a confident wrong answer instead of a stop. An
# assignment like `repo=$(mc_repo)` at least hands `set -e` a status it can act
# on. A here-document does not:
#
#     while IFS=$'	' read -r number title draft head labels; do
#             ...
#     done <<EOF
#     $(mc_open_prs)
#     EOF
#
# The status of mc_open_prs is discarded by the heredoc expansion, so mc_die's
# `exit 1` ends the subshell and nothing else notices. With no config the repo
# slug resolved EMPTY, every call went to https://api.github.com/repos//pulls/...,
# and overlap.sh read the 404 error body back as a list of pull request numbers —
# phantom entries called `#Found",` and `#"documentation_url":`, and then a
# refusal reading "#12 shares ground with pull request(s) already running CI".
# Every part of that verdict was false and none of it looked like a failure.
# Found 29 August 2026 in a repository that had not adopted the plugin.
#
# Being inside a git repository is not the test. The test is whether THIS
# repository has a config of its own. A tool whose own lookup failed must not
# emit a verdict.
#
# It checks the repo slug too, because a config present with an empty or
# malformed "repo" builds the exact same https://api.github.com/repos//... URL,
# and the phantom numbers come back the same way.
mc_require_config() {
	local cfg repo
	cfg=$(mc_config_path) || exit 1
	if [ ! -f "$cfg" ]; then
		echo "merge-coordinator: no config at $cfg" >&2
		echo "  This repository does not have merge-coordination settings, so there is" >&2
		echo "  nothing to coordinate against and no answer this script could give." >&2
		echo "  Stopping rather than guessing: the last time it carried on, it queried" >&2
		echo "  an empty repository slug and read the 404 body back as pull requests." >&2
		echo >&2
		echo "  Copy $MC_PLUGIN_ROOT/config.example.json to $cfg" >&2
		echo "  and edit it." >&2
		exit 1
	fi
	repo=$(MC_FILE="$cfg" mc_py -c '
import json, os, re, sys
path = os.environ["MC_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (path, exc))
slug = cfg.get("repo")
if not isinstance(slug, str) or not re.match(r"^[^/\s]+/[^/\s]+$", slug):
    sys.exit("merge-coordinator: config %s has repo %r; expected \"owner/name\"." % (path, slug))
sys.stdout.write(slug)
') || exit 1
	[ -n "$repo" ] || mc_die "config $cfg produced an empty repo slug."
}

# mc_cfg_get <dotted.key> — prints the value, or fails if the key is absent.
# An absent key is an error rather than an empty string: a landing sequence that
# read an empty label name would happily "hold" a claim nobody can see.
mc_cfg_get() {
	local key="$1" cfg
	cfg=$(mc_config_path)
	[ -f "$cfg" ] || mc_die "no config at $cfg — copy $MC_PLUGIN_ROOT/config.example.json there and edit it."
	MC_KEY="$key" MC_FILE="$cfg" mc_py -c '
import json, os, sys
key, path = os.environ["MC_KEY"], os.environ["MC_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        node = json.load(fh)
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (path, exc))
for part in key.split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit("merge-coordinator: config %s has no key %r" % (path, key))
    node = node[part]
if isinstance(node, (dict, list)):
    sys.exit("merge-coordinator: config key %r is not a scalar" % key)
if isinstance(node, bool):
    # Spelled the way JSON spells it, so a bash comparison reads the same as
    # the config file a human is looking at.
    node = "true" if node else "false"
sys.stdout.write("" if node is None else str(node))
' || exit 1
}

# mc_cfg_list_opt <key> — like mc_cfg_list, but a key that is absent is an
# answer, not an error: the feature it configures is simply off, and the caller
# gets nothing on stdout and a 0 exit.
#
# An UNREADABLE config is still a failure. "the key is not there" and "I could
# not look" are different answers and this must never print them the same way -
# a caller that cannot tell them apart silently does nothing when the config is
# broken. Only the missing key is quiet.
mc_cfg_list_opt() {
	local key="$1" cfg
	cfg=$(mc_config_path)
	[ -f "$cfg" ] || mc_die "no config at $cfg — copy $MC_PLUGIN_ROOT/config.example.json there and edit it."
	MC_KEY="$key" MC_FILE="$cfg" mc_py -c '
import json, os, sys
key, path = os.environ["MC_KEY"], os.environ["MC_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        node = json.load(fh)
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (path, exc))
for part in key.split("."):
    if not isinstance(node, dict) or part not in node:
        raise SystemExit(0)          # absent: the feature is off
    node = node[part]
if node is None:
    raise SystemExit(0)
if not isinstance(node, list):
    sys.exit("merge-coordinator: config key %r is not a list" % key)
for item in node:
    print(item)
' || exit 1
}

# mc_cfg_list <key> — one array element per line.
mc_cfg_list() {
	local key="$1" cfg
	cfg=$(mc_config_path)
	[ -f "$cfg" ] || mc_die "no config at $cfg — copy $MC_PLUGIN_ROOT/config.example.json there and edit it."
	MC_KEY="$key" MC_FILE="$cfg" mc_py -c '
import json, os, sys
key, path = os.environ["MC_KEY"], os.environ["MC_FILE"]
with open(path, encoding="utf-8") as fh:
    node = json.load(fh)
for part in key.split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit("merge-coordinator: config %s has no key %r" % (path, key))
    node = node[part]
if not isinstance(node, list):
    sys.exit("merge-coordinator: config key %r is not a list" % key)
for item in node:
    print(item)
' || exit 1
}

# mc_hotspots — one hotspot per line as path<TAB>rule<TAB>action<TAB>why.
# Callers read this ONCE into a variable and match against it in bash; calling it
# per file would spawn a python process per changed path.
mc_hotspots() {
	local cfg
	cfg=$(mc_config_path)
	[ -f "$cfg" ] || mc_die "no config at $cfg — copy $MC_PLUGIN_ROOT/config.example.json there and edit it."
	MC_FILE="$cfg" mc_py -c '
import json, os, sys
path = os.environ["MC_FILE"]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
spots = cfg.get("hotspots")
if not isinstance(spots, list):
    sys.exit("merge-coordinator: config %s has no hotspots list" % path)
for spot in spots:
    for field in ("path", "rule", "action", "why"):
        if field not in spot:
            sys.exit("merge-coordinator: hotspot %r is missing %r" % (spot, field))
    if spot["rule"] not in ("serialize", "alone"):
        sys.exit("merge-coordinator: hotspot %s has rule %r; expected serialize or alone"
                 % (spot["path"], spot["rule"]))
    print("\t".join(str(spot[f]).replace("\t", " ").replace("\n", " ")
                    for f in ("path", "rule", "action", "why")))
' || exit 1
}

# mc_hotspot_match <pattern> <path> — does this changed path fall in this hotspot?
#
# The patterns are ordinary shell case globs, in which `*` crosses directory
# separators. That is deliberate and it is why "vendor/**" and "vendor/*" mean
# the same thing here. `**` is folded to `*` so the config can be written the way
# a reader expects gitignore to work.
mc_hotspot_match() {
	local pattern="$1" path="$2"
	# shellcheck disable=SC2295 # the fold is a literal, not a pattern
	while [ "${pattern}" != "${pattern//\*\*/\*}" ]; do
		pattern="${pattern//\*\*/\*}"
	done
	case "$path" in
	$pattern) return 0 ;;
	esac
	return 1
}

# --------------------------------------------------------------------------
# GitHub
# --------------------------------------------------------------------------

# Every GitHub call in this plugin goes through here. MC_GH is a path to a bash
# script that replays canned responses; the test scripts use lib/fixture-gh.sh.
# It is invoked through bash rather than executed directly, because a checkout on
# Windows does not reliably carry the executable bit.
mc_gh() {
	if [ -n "${MC_GH:-}" ]; then
		bash "$MC_GH" "$@"
	else
		gh "$@"
	fi
}

mc_repo() {
	mc_cfg_get repo
}

# mc_pr_files <number> — the paths a PR touches, one per line.
#
# Read from the API rather than from `git diff base...head` so this works without
# fetching every branch, and so it agrees with what GitHub itself computed.
#
# The endpoint stops at 3000 files. Hitting that ceiling is reported and the PR
# is then treated as touching EVERYTHING, because a truncated file list that
# looks complete is exactly the failure this plugin exists to prevent.
mc_pr_files() {
	local pr="$1" repo out count
	repo=$(mc_repo)
	out=$(mc_gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[].filename') || {
		mc_warn "could not list files for #$pr"
		return 1
	}
	printf '%s\n' "$out"
	count=$(printf '%s\n' "$out" | grep -c . || true)
	if [ "$count" -ge 3000 ]; then
		mc_warn "#$pr reports $count files — the API caps at 3000, so this list may be short."
		mc_warn "  Treating #$pr as touching every path. Split the PR."
		printf '%s\n' "MERGE-COORDINATOR-TRUNCATED"
	fi
	return 0
}

mc_pr_head_sha() {
	local pr="$1" repo
	repo=$(mc_repo)
	mc_gh api "repos/$repo/pulls/$pr" --jq '.head.sha'
}

# mc_behind_by <head-sha> — how many commits the default branch is ahead of this
# head. 0 means the PR was tested against the tree it will produce.
mc_behind_by() {
	local sha="$1" repo base
	repo=$(mc_repo)
	base=$(mc_cfg_get defaultBranch)
	mc_gh api "repos/$repo/compare/$base...$sha" --jq '.behind_by'
}

# mc_mergeable <number> — can git merge this PR into the base at all?
#
# Prints exactly one of: CLEAN, CONFLICTING, UNKNOWN.
#
# This is the question a merge queue leaves behind. The queue owns freshness —
# it builds the base plus everything ahead of the PR and tests THAT — but it
# cannot merge a pull request git refuses to merge. So under a queue backbone
# "does it conflict" replaces "is it behind" as the thing that stops a landing.
#
# THE FIELD IS COMPUTED LAZILY AND STARTS AS null. GitHub kicks off a background
# merge attempt the first time anything asks, and answers null until it
# finishes — which is normal for a few seconds after any push. null is reported
# as UNKNOWN, never as CLEAN, and the caller retries. A background job that has
# not answered yet and a merge that is genuinely clean are different states, and
# a plugin whose whole purpose is refusing to confuse "could not look" with
# "nothing wrong" must not confuse them here either.
#
# mergeable, not mergeStateStatus: the latter also goes BLOCKED for a missing
# review or a pending check, both of which are steps 1 and 4's business, not
# this one's.
mc_mergeable() {
	local pr="$1" repo value
	repo=$(mc_repo)
	value=$(mc_gh api "repos/$repo/pulls/$pr" --jq '.mergeable' 2>/dev/null) || {
		printf 'UNKNOWN\n'
		return 0
	}
	case "$value" in
	true) printf 'CLEAN\n' ;;
	false) printf 'CONFLICTING\n' ;;
	*) printf 'UNKNOWN\n' ;;
	esac
}

# mc_mergeable_settled <number> — mc_mergeable, but waits for the background
# merge attempt instead of reporting the null it starts with.
#
# Still prints UNKNOWN if it never settles. The caller decides what to do about
# that; this function will not guess CLEAN on its behalf.
mc_mergeable_settled() {
	local pr="$1" tries="${2:-6}" state i=0
	while [ "$i" -lt "$tries" ]; do
		state=$(mc_mergeable "$pr")
		if [ "$state" != "UNKNOWN" ]; then
			printf '%s\n' "$state"
			return 0
		fi
		i=$((i + 1))
		[ "$i" -lt "$tries" ] || break
		echo "       mergeable is not computed yet; asking again ($i/$tries)." >&2
		sleep "${MC_MERGEABLE_SLEEP:-3}"
	done
	printf 'UNKNOWN\n'
}

# mc_checks_state <sha> — every check GitHub knows about on this exact commit,
# as name<TAB>state. States are lower-cased: success, failure, cancelled,
# timed_out, skipped, action_required, neutral, or "running" for anything not
# completed yet.
#
# Both surfaces are read. Check runs come from Actions; the older commit-status
# API is where some Apps still post. A required name could live on either, and
# looking at only one of them would produce the "no result found, so nothing is
# wrong" answer this file exists to refuse.
mc_checks_state() {
	local sha="$1" repo
	repo=$(mc_repo)
	mc_gh api --paginate "repos/$repo/commits/$sha/check-runs?filter=latest" \
		--jq '.check_runs[] | [.name, (if .status == "completed" then (.conclusion // "unknown") else "running" end)] | @tsv' 2>/dev/null || true
	mc_gh api "repos/$repo/commits/$sha/status" \
		--jq '.statuses[] | [.context, (if .state == "pending" then "running" else .state end)] | @tsv' 2>/dev/null || true
}

# mc_require_checks <sha> — 0 only if every required check completed successfully
# on THIS commit. Prints a line per required check either way.
mc_require_checks() {
	local sha="$1" states name state missing=0 bad=0 seen_any=0
	states=$(mc_checks_state "$sha")

	while IFS= read -r name; do
		[ -z "$name" ] && continue
		seen_any=1
		# Exact match on the whole first field. A required check called "CI"
		# must not be satisfied by one called "CI passed", and a substring
		# search would let it be.
		# No `exit` in the awk program. Leaving early closes the pipe under the
		# printf that is still writing, and a caller running with `set -o
		# pipefail` then reads SIGPIPE as the pipeline's status — the same
		# mistake that made the release guard in land.sh report a heading it
		# had actually found. `!seen` keeps it to the first match instead.
		state=$(printf '%s\n' "$states" | awk -F'\t' -v want="$name" '$1 == want && !seen { print $2; seen = 1 }')
		if [ -z "$state" ]; then
			echo "  MISSING  $name — no check with this name exists on $sha."
			echo "           That is a failure, not an absence of news. If the run"
			echo "           finished in seconds with no steps, read the annotations:"
			echo "           gh api repos/\$REPO/check-runs/<job_id>/annotations"
			missing=1
			continue
		fi
		case "$state" in
		success)
			echo "  ok       $name"
			;;
		running)
			echo "  RUNNING  $name — not finished on $sha. Wait; do not land."
			bad=1
			;;
		cancelled)
			echo "  CANCELLED $name — a cancelled run is not a pass. Something superseded it."
			bad=1
			;;
		skipped)
			# Still a refusal: a job that did not run proved nothing, and
			# an all-skipped set on a ready pull request is the
			# skip-propagation trap this file exists to catch — a run that
			# reports green having compiled nothing.
			#
			# But it is not the same fact as a failure, and it needs its
			# own word. A draft runs no CI here by design, so every one of
			# its checks concludes "skipped". Calling that FAILED told
			# three sessions in one day that a healthy branch was broken.
			# The caller knows whether this is a draft; this function only
			# reports what GitHub said, in the right words.
			echo "  SKIPPED  $name — conclusion: skipped. No job ran on $sha."
			bad=1
			;;
		*)
			echo "  FAILED   $name — conclusion: $state"
			bad=1
			;;
		esac
	done <<EOF
$(mc_cfg_list requiredChecks)
EOF

	# An empty requiredChecks list is a legitimate configuration — a repository
	# can genuinely have no pull-request CI (one that holds only documents, say).
	# It must not be a QUIET one. With nothing to iterate, the loop above sets
	# neither counter and this function returns success, which reads exactly like
	# "every required check passed" in the landing output. That is the same
	# shape as every trap this file is written against: a pass reported for a
	# question nobody asked. So say what actually happened.
	if [ "$seen_any" -eq 0 ]; then
		echo "  NONE     this repository declares no required checks."
		echo "           Nothing was verified on $sha. That is the config saying so,"
		echo "           not a green result — if this repository does run checks,"
		echo "           requiredChecks is empty when it should not be."
	fi

	[ "$missing" -eq 0 ] && [ "$bad" -eq 0 ]
}

# mc_claim_holders <label> — the open pull requests carrying this label, one
# number per line.
#
# NOT `issues?labels=`. That endpoint answers from a search index which lags the
# write, and the claim is read back milliseconds after it is written. Measured
# against the repository this was built for on 25 August 2026: the label was
# invisible to `issues?labels=` at t=0 and correct at t=5, while `gh pr list --label` had it
# immediately at t=0.
#
# The consequence was not a slow answer, it was a wrong one. The read-back saw
# an empty list every time, which made the lowest-number tie-break dead code —
# and because an empty list makes the `grep -v '^$'` behind it exit 1 under
# pipefail, it killed land.sh with no message at all, right after taking a claim.
mc_claim_holders() {
	local label="$1" repo
	repo=$(mc_repo)
	mc_gh pr list --repo "$repo" --state open --label "$label" --json number --jq '.[].number'
}

# mc_claim_runs <sha> [workflow] — the runs of one workflow (default
# issue-claim.yml) on one commit from the pull_request event, oldest first:
# id<TAB>status<TAB>head branch<TAB>head repository. claim-gate.sh picks a pull
# request's newest run from these by its branch and repository too, since two
# pull requests can share a head commit. probe-live.sh checks this filter
# against a live repository; the offline tests cannot run --jq.
mc_claim_runs() {
	local sha="$1" workflow="${2:-issue-claim.yml}" repo
	repo=$(mc_repo)
	mc_gh api "repos/$repo/actions/runs?event=pull_request&head_sha=$sha&per_page=100" \
		--jq "[.workflow_runs[] | select((.path // \"\") | endswith(\"/$workflow\"))] | sort_by(.created_at) | .[] | [(.id|tostring), .status, (.head_branch // \"\"), (.head_repository.full_name // \"\")] | @tsv"
}

# mc_open_prs — number<TAB>title<TAB>isDraft<TAB>headRefName<TAB>labels(comma) for
# every open PR, oldest first. Oldest first is the tie-break the ordering uses.
mc_open_prs() {
	local repo
	repo=$(mc_repo)
	mc_gh api --paginate "repos/$repo/pulls?state=open&sort=created&direction=asc&per_page=100" \
		--jq '.[] | [(.number|tostring), .title, (.draft|tostring), .head.ref, ([.labels[].name] | join(","))] | @tsv'
}

# mc_pr_footprint <number> — the paths a pull request DECLARES it expects to
# touch, one glob per line. They come from a block in the pull request body:
#
#   <!-- merge-coordinator:footprint
#   web/src/**
#   go/signals/**
#   -->
#
# A declaration is a PREDICTION and is never a substitute for the real changed
# file list. It exists for the case the real list cannot cover: a draft opened
# at the start of a task has no commits, so its file list is empty and says
# nothing at all, and two sessions can plan the same files for hours without
# either being able to see the other.
#
# No block, an empty block, and a body of null all mean the same thing — this
# pull request declared nothing — and none of them is an error. Most will not
# have one.
#
# A block that cannot be READ is a different answer and returns 1, the same
# separation mc_cfg_list_opt makes. The caller reports it and carries on: a
# declaration is advisory, so failing to read one must never stop an ordering
# analysis.
mc_pr_footprint() {
	local pr="$1" repo work rc=0 out
	repo=$(mc_repo)
	work=$(mktemp)

	# The body goes to a FILE, and the matching happens in python. A pull
	# request body here runs to kilobytes, and `printf "$big" | grep` under
	# pipefail reports a match as a miss — grep matches, stops, closes the
	# pipe, printf dies of SIGPIPE and 141 becomes the pipeline's status. That
	# is the bug that made the release guard report every heading missing.
	mc_gh api "repos/$repo/pulls/$pr" --jq '.body // ""' >"$work" || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$work"
		mc_warn "could not read the body of #$pr, so its declared paths were not read."
		return 1
	fi

	out=$(MC_BODY="$work" mc_py -c '
import io, os, sys

OPEN = "<!-- merge-coordinator:footprint"
CLOSE = "-->"
LIMIT = 100

with io.open(os.environ["MC_BODY"], encoding="utf-8") as fh:
    body = fh.read()

start = body.find(OPEN)
if start < 0:
    raise SystemExit(0)              # declared nothing: not an error

end = body.find(CLOSE, start + len(OPEN))
if end < 0:
    sys.exit("merge-coordinator: the footprint block is opened and never closed")

globs = []
for line in body[start + len(OPEN):end].splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    # An issue claim shares the block with the paths. It is not a path, and a
    # glob of "issue: 12" would match nothing and look declared.
    if line.lower().startswith("issue:"):
        continue
    globs.append(line)

# Say what was dropped. A cap that truncates quietly reads as full coverage.
if len(globs) > LIMIT:
    sys.stderr.write(
        "merge-coordinator: the footprint declares %d paths; only the first %d are read.\n"
        % (len(globs), LIMIT))
    globs = globs[:LIMIT]

for g in globs:
    print(g)
') || rc=$?
	rm -f "$work"

	if [ "$rc" -ne 0 ]; then
		mc_warn "could not read the declared paths of #$pr."
		return 1
	fi
	[ -n "$out" ] && printf '%s\n' "$out"
	return 0
}

# --------------------------------------------------------------------------
# Issue claims and local sessions
# --------------------------------------------------------------------------

# mc_cfg_get_opt <dotted.key> <default> — like mc_cfg_get, but an absent key
# prints the default. An unreadable config is still a failure, for the reason
# given at mc_cfg_list_opt.
mc_cfg_get_opt() {
	local key="$1" default="$2" cfg
	cfg=$(mc_config_path)
	[ -f "$cfg" ] || mc_die "no config at $cfg — copy $MC_PLUGIN_ROOT/config.example.json there and edit it."
	MC_KEY="$key" MC_DEFAULT="$default" MC_FILE="$cfg" mc_py -c '
import json, os, sys
key, path = os.environ["MC_KEY"], os.environ["MC_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        node = json.load(fh)
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (path, exc))
for part in key.split("."):
    if not isinstance(node, dict) or part not in node:
        sys.stdout.write(os.environ["MC_DEFAULT"])
        raise SystemExit(0)
    node = node[part]
if isinstance(node, (dict, list)):
    sys.exit("merge-coordinator: config key %r is not a scalar" % key)
sys.stdout.write("" if node is None else str(node))
' || exit 1
}

# mc_dup_label — the label the issue-claim gate puts on a refused pull request.
mc_dup_label() {
	mc_cfg_get_opt labels.duplicateClaim "merge:duplicate-claim"
}

# mc_issue_from_name <name> — the issue number that a worktree or branch name
# carries, or nothing.
#
# The name is split at "-", "/" and "_". A segment of 3 to 5 digits is a
# number. Exactly one number is an answer. None, or more than one, is no answer,
# because a guess between two numbers is a claim on an issue nobody chose.
#
# Measured before this was built: in the 199 pull requests since registration
# began that cite an issue, this gave the right number for 176 and a wrong one
# for 1 (a branch named for one issue whose pull request did another).
mc_issue_from_name() {
	local seg found="" count=0
	local -a segs=()
	IFS='-/_' read -r -a segs <<<"$1"
	for seg in "${segs[@]+"${segs[@]}"}"; do
		case "$seg" in
		[0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9])
			found="$seg"
			count=$((count + 1))
			;;
		esac
	done
	if [ "$count" -eq 1 ]; then
		printf '%s\n' "$found"
	fi
	return 0
}

# mc_worktrees — `git worktree list --porcelain` for this repository.
# MC_WORKTREE_LIST names a file to read instead, for the tests.
mc_worktrees() {
	if [ -n "${MC_WORKTREE_LIST:-}" ]; then
		cat "$MC_WORKTREE_LIST"
		return 0
	fi
	git worktree list --porcelain 2>/dev/null || true
}

# mc_pid_state <pid> — "live" when a Claude process has this pid, "dead" when
# none does, "unknown" when this machine gives no way to look.
#
# A live pid is not enough. Windows reuses pids, so a lock can name a pid that
# now belongs to another program. The process name must also be Claude's.
# MC_PID_PROBE names a script that answers instead, for the tests.
mc_pid_state() {
	local pid="$1" out
	if [ -n "${MC_PID_PROBE:-}" ]; then
		bash "$MC_PID_PROBE" "$pid"
		return 0
	fi
	if command -v tasklist >/dev/null 2>&1; then
		# The doubled slashes stop Git Bash from reading /FI as a path.
		out=$(tasklist //FI "PID eq $pid" //NH //FO CSV 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z') || {
			echo unknown
			return 0
		}
		case "$out" in
		*'"claude'*) echo live ;;
		*) echo dead ;;
		esac
		return 0
	fi
	if command -v ps >/dev/null 2>&1; then
		out=$(ps -p "$pid" -o comm= 2>/dev/null | tr 'A-Z' 'a-z' || true)
		case "$out" in
		*claude*) echo live ;;
		*) echo dead ;;
		esac
		return 0
	fi
	echo unknown
}

# mc_session_state <branch> <porcelain> — whether a live session on THIS
# machine holds the worktree for a branch. <porcelain> is mc_worktrees output,
# read once by the caller.
#
# Prints one of:
#   live <pid>    a lock names a Claude process that is running
#   dead <pid>    a lock names a process that is gone. A crash leaves this.
#   ? <pid>       a lock names a pid that this machine cannot check
#   locked        a lock with no pid in its reason
#   unlocked      a worktree here with no lock
#   -             no worktree for this branch on this machine
#
# "-" is not "nobody". The session can be on another machine, in the cloud, or
# be another vendor's agent.
mc_session_state() {
	local want="refs/heads/$1" line found=0 has_lock=0 reason="" pid
	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			[ "$found" -eq 1 ] && break
			has_lock=0
			reason=""
			;;
		"branch $want") found=1 ;;
		locked) has_lock=1 ;;
		"locked "*)
			has_lock=1
			reason="${line#locked }"
			;;
		esac
	done <<EOF
$2
EOF
	if [ "$found" -ne 1 ]; then
		echo "-"
		return 0
	fi
	if [ "$has_lock" -ne 1 ]; then
		echo "unlocked"
		return 0
	fi
	pid=$(printf '%s\n' "$reason" | sed -n 's/.*(pid \([0-9][0-9]*\)).*/\1/p')
	if [ -z "$pid" ]; then
		echo "locked"
		return 0
	fi
	case "$(mc_pid_state "$pid")" in
	live) echo "live $pid" ;;
	dead) echo "dead $pid" ;;
	*) echo "? $pid" ;;
	esac
}

# --------------------------------------------------------------------------
# Dependabot
# --------------------------------------------------------------------------

# The scripts folder, where deps-open.sh lives beside the entry scripts.
MC_SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# mc_deps_line <row> — one row of deps-open.sh, in words.
mc_deps_line() {
	local number status age ci verdict title words
	IFS=$'\t' read -r number status age ci verdict title <<<"$1"
	case "$ci" in
	passed) words=", CI passed" ;;
	running) words=", CI running" ;;
	failed) words=", CI failed" ;;
	skipped) words=", every check skipped, so nothing ran" ;;
	none) words=", no CI on it yet" ;;
	-) words="" ;; # deps-open.sh --no-ci: not read, so not said
	*) words=", its CI could not be read" ;;
	esac
	[ "$verdict" = "-" ] || words="$words, /merge-deps said $verdict"
	[ "$status" = "landing" ] && words="$words, landing now"
	printf '  #%s %s (%s old%s)\n' "$number" "$title" "$age" "$words"
}

# mc_is_dependabot_pr <number> — 0 when Dependabot opened this pull request,
# read straight from it, as deps.sh reads it. For when the lister could not
# look: landing a bump is never stopped, and that must not depend on a listing
# that just failed.
mc_is_dependabot_pr() {
	local repo json
	repo=$(mc_repo) || return 1
	json=$(mc_gh api "repos/$repo/pulls/$1" 2>/dev/null) || return 1
	printf '%s' "$json" | mc_py -c 'import json, sys
user = json.load(sys.stdin).get("user") or {}
sys.exit(0 if user.get("type") == "Bot" and user.get("login") == "dependabot[bot]" else 1)' 2>/dev/null
}

# mc_deps_gate <pr> <skip-deps 0|1> <dry-run 0|1> — the stop before ready.sh or
# land.sh goes on with <pr> while a Dependabot pull request waits.
#
# Returns 1 to stop, having said why. A Dependabot pull request that is landing
# does not stop anything, and nor does <pr> itself when it is one: landing a bump
# is the answer to the question this asks. --force and --admin are not read
# here, so they cannot step over it; only --skip-deps (the user said "later")
# and MERGE_COORDINATOR_OVERRIDE=1 do.
#
# A lister that could not look stops it too: "could not look" and "nothing
# waiting" must never read the same. Unless <pr> is itself Dependabot's, read
# from the pull request directly. Under --skip-deps there is no question to
# ask, so a failed look is only reported.
#
# Called as a plain command, never inside $( ): it sets MC_DEPS_WAITING to the
# waiting numbers that --skip-deps let past, so the overlap check can leave them
# out too. Otherwise that check refuses next, naming the same pull request, and
# "later" turns back into --force.
mc_deps_gate() {
	local pr="$1" skip="$2" dry="$3" rows rc=0 row number rest status waiting="" lines="" self=0
	MC_DEPS_WAITING=""
	if [ "${MERGE_COORDINATOR_OVERRIDE:-}" = 1 ]; then
		echo "merge-coordinator: MERGE_COORDINATOR_OVERRIDE=1, so the open Dependabot pull requests were not checked."
		return 0
	fi
	rows=$(bash "$MC_SCRIPTS_DIR/deps-open.sh") || rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$skip" -eq 1 ]; then
			mc_warn "could not check the open Dependabot pull requests. --skip-deps was given, so carrying on."
			return 0
		fi
		if mc_is_dependabot_pr "$pr"; then
			echo "merge-coordinator: could not check the open Dependabot pull requests, but #$pr is a Dependabot pull request, so they do not stop it."
			return 0
		fi
		{
			echo "merge-coordinator: could not check the open Dependabot pull requests, so #$pr goes no further."
			echo "  Not looking and finding nothing are different answers. This one is 'could not look'."
			echo "  Try again. If it still cannot look, ask the user; if they say go on, re-run with --skip-deps."
		} >&2
		if [ "$dry" -eq 1 ]; then
			echo "  Dry run: it would stop here. Carrying on to show the rest." >&2
			return 0
		fi
		return 1
	fi
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		number=${row%%$'\t'*}
		rest=${row#*$'\t'}
		status=${rest%%$'\t'*}
		if [ "$number" = "$pr" ]; then
			self=1
			continue
		fi
		[ "$status" = "waiting" ] || continue
		waiting="$waiting $number"
		lines="$lines$(mc_deps_line "$row")
"
	done <<ROWS
$rows
ROWS
	if [ "$self" -eq 1 ]; then
		echo "merge-coordinator: #$pr is a Dependabot pull request, so the other open ones do not stop it."
		return 0
	fi
	[ -n "$waiting" ] || return 0
	if [ "$skip" -eq 1 ]; then
		MC_DEPS_WAITING="${waiting# }"
		echo "merge-coordinator: --skip-deps: the user said later for these Dependabot pull request(s)."
		printf '%s' "$lines"
		return 0
	fi
	{
		echo "merge-coordinator: Dependabot pull request(s) waiting, so #$pr stops here:"
		printf '%s' "$lines"
		echo "  Ask the user whether to land these first."
		echo "    Yes:    /merge-deps <number> reviews the bump, then lands it or closes it."
		echo "    Later:  re-run with --skip-deps."
		echo "  --force and --admin do not step over this."
	} >&2
	if [ "$dry" -eq 1 ]; then
		echo "  Dry run: it would stop here. Carrying on to show the rest." >&2
		return 0
	fi
	return 1
}

# mc_deps_notice [deps-open.sh options] — the open Dependabot pull requests, for
# a session that is starting work with GitHub: registering, entering a
# worktree, /merge-status.
#
# Best effort and always returns 0: a failed look prints one line, with the
# reason, and the command it sits in still succeeds. Prints nothing when none is
# open. MC_DEPS_NOTICE_TIMEOUT, when set, is a deadline in seconds: a hook that
# runs past its own timeout is killed and says nothing at all, so the hook
# gives the look a deadline that ends in a line instead.
mc_deps_notice() {
	local rows row lines="" waiting=0 rc=0 err why=""
	err=$(mktemp 2>/dev/null) || err=""
	if [ -n "${MC_DEPS_NOTICE_TIMEOUT:-}" ] && command -v timeout >/dev/null 2>&1; then
		rows=$(timeout "$MC_DEPS_NOTICE_TIMEOUT" bash "$MC_SCRIPTS_DIR/deps-open.sh" "$@" 2>"${err:-/dev/null}") || rc=$?
	else
		rows=$(bash "$MC_SCRIPTS_DIR/deps-open.sh" "$@" 2>"${err:-/dev/null}") || rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 124 ]; then
			why="no answer within $MC_DEPS_NOTICE_TIMEOUT seconds"
		elif [ -n "$err" ]; then
			why=$(sed -n '$p' "$err" | sed 's/^merge-coordinator: //; s/\.$//')
		fi
		[ -z "$err" ] || rm -f "$err"
		echo "merge-coordinator: could not check Dependabot pull requests${why:+ ($why)}."
		return 0
	fi
	[ -z "$err" ] || rm -f "$err"
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		case "$row" in
		*$'\t'waiting$'\t'*) waiting=1 ;;
		esac
		lines="$lines$(mc_deps_line "$row")
"
	done <<ROWS
$rows
ROWS
	[ -n "$lines" ] || return 0
	echo "merge-coordinator: Dependabot pull request(s) open:"
	printf '%s' "$lines"
	if [ "$waiting" -eq 1 ]; then
		echo "  While one waits, readying or landing other work stops and asks whether to land it first (/merge-deps <number>)."
	fi
	return 0
}
