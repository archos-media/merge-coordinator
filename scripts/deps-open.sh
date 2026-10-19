#!/usr/bin/env bash
# The open Dependabot pull requests, one per line.
#
# One lister, read by every part of the Dependabot gate: ready.sh and land.sh
# stop on what it prints, guard-ready.sh refuses on it, and register.sh,
# register-hook.sh and queue-state.sh show it. A script rather than a function so
# the guard can run it under a time limit; timeout(1) cannot run a function.
#
# WHY THERE IS A GATE AT ALL. Sessions ran `ready.sh --force` past open
# Dependabot pull requests again and again, a dozen times in one repository's
# land log, and the bumps sat until Dependabot closed them itself at 168 hours,
# replaced by its next weekly run because nobody had landed them. Nothing was
# deciding about them; they were simply in the way. Now a session that goes to
# ready or land its own work while one waits is stopped and asks its human:
# land it first (/merge-deps), or later (--skip-deps).
#
# Usage:  deps-open.sh            the rows, with the CI on each head
#         deps-open.sh --no-ci    the rows, without reading CI ("-" in that
#                                 column). One query in all, for the callers
#                                 that run against a deadline: the raw
#                                 gh pr ready guard and the new-worktree hook.
#
# Prints, tab separated, lowest number (so oldest) first:
#
#   number  status  age  ci  verdict  title
#
#   status   waiting, or landing (in the merge queue, or holding the landing
#            label). A landing one is shown and never stops anything.
#   age      "3 days", "5 hours", "under an hour", from when it was opened.
#   ci       passed, running, failed, skipped (every check skipped, so nothing
#            ran), none (no check on the head yet), "could not read", or "-"
#            under --no-ci. A failed read is NOT shown as failed: a red that
#            nobody measured would send a session to fix a bump that is fine.
#            And skipped is NOT shown as passed: a job that did not run proved
#            nothing, which is mc_require_checks's rule too.
#   verdict  safe, unsafe or needs-fixup, from the deps:* label /merge-deps
#            sets; "-" when it has none. A verdict does not stop a pull request
#            from waiting. Only landing or closing it does.
#
# A pull request carrying the blocked label is left out: somebody stopped it on
# purpose, so it is not waiting on anybody.
#
# EXIT 0 with rows or with nothing; EXIT 3 on any failure. Nothing is printed on
# a failure, so a caller can never act on half a list: "could not look" and
# "nothing open" must not read the same.
#
# A DEPENDABOT PULL REQUEST IS ONE WHOSE AUTHOR IS A Bot CALLED dependabot. The
# bot has three names. GraphQL says `dependabot` with __typename Bot; REST says
# `dependabot[bot]`; `gh pr list --json author` says `app/dependabot`. A filter
# written against the wrong one matches nothing, and the gate never fires while
# every test of it passes. This reads GraphQL, and keeps the REST spelling
# too in case GraphQL ever returns it. A human account that happens to be called
# dependabot is a User, and is not kept.
#
# The responses are read RAW and filtered in python, not with --jq. The test
# fixture does not run --jq, so a jq filter here could only be proved live; read
# raw, the offline tests hand it real response shapes and prove the filter too.
# scripts/probe-live.sh still runs it against a real repository.
#
# Cost: one GraphQL query per hundred open pull requests, plus at least two
# reads per open Dependabot pull request, landing or waiting, for its CI. About
# two seconds each, one after another, so ten open bumps is twenty seconds:
# --no-ci skips them.
set -euo pipefail

with_ci=1
for arg in "$@"; do
	case "$arg" in
	--no-ci) with_ci=0 ;;
	*)
		echo "merge-coordinator: unknown option $arg" >&2
		exit 3
		;;
	esac
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

work=$(mktemp -d)
# Every way out that is not a clean exit 0 becomes 3, mc_die's exit 1 included.
# 1 means something else to the callers' other checks, and "could not look" has
# one number here.
finish() {
	local rc=$?
	rm -rf "$work"
	[ "$rc" -eq 0 ] || exit 3
}
trap finish EXIT

mc_require_config
repo=$(mc_repo)
blocked_label=$(mc_cfg_get labels.blocked)
landing_label=$(mc_cfg_get labels.landing)
owner=${repo%%/*}
name=${repo#*/}

query='query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{number title createdAt isInMergeQueue headRefOid author{__typename login}labels(first:100){nodes{name}}}}}}'

found="$work/found.tsv"
: >"$found"

# Pages, not a search. The search index lags its writes (mc_claim_holders in
# lib/gh.sh says by how much), and a pull request opened a minute ago is exactly
# the one a session is about to step past.
cursor=""
page=0
while :; do
	page=$((page + 1))
	if [ "$page" -gt 50 ]; then
		mc_warn "more than 5000 open pull requests; stopped reading rather than list part of them."
		exit 3
	fi
	if [ -z "$cursor" ]; then
		mc_gh api graphql -f owner="$owner" -f name="$name" -f query="$query" >"$work/page.json" ||
			mc_die "could not list the open pull requests of $repo."
	else
		mc_gh api graphql -f owner="$owner" -f name="$name" -f cursor="$cursor" -f query="$query" >"$work/page.json" ||
			mc_die "could not list the open pull requests of $repo (page $page)."
	fi
	cursor=$(MC_PAGE="$work/page.json" MC_FOUND="$found" MC_BLOCKED="$blocked_label" MC_LANDING="$landing_label" mc_py -c '
import io, json, os, sys

try:
    with io.open(os.environ["MC_PAGE"], encoding="utf-8") as fh:
        doc = json.load(fh)
    conn = doc["data"]["repository"]["pullRequests"]
    nodes = conn["nodes"]
    info = conn["pageInfo"]
except Exception as exc:
    # GraphQL answers an error with HTTP 200 and an "errors" list, and a
    # repository it cannot see as "repository": null. Neither is "none open".
    errs = doc.get("errors") if isinstance(locals().get("doc"), dict) else None
    sys.exit("merge-coordinator: the pull request listing could not be read (%s)%s"
             % (exc.__class__.__name__, ": %s" % errs if errs else ""))

def clean(text):
    return " ".join(str(text or "").split())

with io.open(os.environ["MC_FOUND"], "a", encoding="utf-8", newline="\n") as out:
    for pr in nodes:
        author = pr.get("author") or {}
        if author.get("__typename") != "Bot" or author.get("login") not in ("dependabot", "dependabot[bot]"):
            continue
        labels = [l.get("name") for l in ((pr.get("labels") or {}).get("nodes") or [])]
        if os.environ["MC_BLOCKED"] in labels:
            continue
        landing = bool(pr.get("isInMergeQueue")) or os.environ["MC_LANDING"] in labels
        verdict = "-"
        for v in ("safe", "unsafe", "needs-fixup"):
            if "deps:" + v in labels:
                verdict = v
        out.write("\t".join([str(pr["number"]), pr["headRefOid"], pr["createdAt"],
                             "landing" if landing else "waiting", verdict,
                             clean(pr.get("title"))]) + "\n")

if info.get("hasNextPage"):
    if not info.get("endCursor"):
        sys.exit("merge-coordinator: the listing says there is another page and gives no cursor to it")
    sys.stdout.write(info["endCursor"])
')
	[ -n "$cursor" ] || break
done

# The CI on each head. Both surfaces, as mc_checks_state reads them: Actions
# posts check runs, and some Apps still post commit statuses.
rows="$work/rows.tsv"
: >"$rows"
while IFS=$'\t' read -r number sha created status verdict title; do
	[ -n "$number" ] || continue
	if [ "$with_ci" -eq 0 ]; then
		printf '%s\t%s\t%s\t-\t%s\t%s\n' "$number" "$status" "$created" "$verdict" "$title" >>"$rows"
		continue
	fi
	ci="could not read"
	# </dev/null: the loop reads its rows from stdin, and a gh that read it
	# would eat the rest of the list.
	if mc_gh api --paginate "repos/$repo/commits/$sha/check-runs?filter=latest&per_page=100" </dev/null >"$work/runs.json" 2>/dev/null &&
		mc_gh api "repos/$repo/commits/$sha/status" </dev/null >"$work/status.json" 2>/dev/null; then
		ci=$(MC_RUNS="$work/runs.json" MC_STATUS="$work/status.json" mc_py -c '
import io, json, os, sys

def docs(path):
    # gh --paginate writes one JSON document per page, back to back.
    with io.open(path, encoding="utf-8") as fh:
        text = fh.read()
    dec, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        doc, i = dec.raw_decode(text, i)
        out.append(doc)

try:
    runs = [r for d in docs(os.environ["MC_RUNS"]) for r in d["check_runs"]]
    statuses = [s for d in docs(os.environ["MC_STATUS"]) for s in d["statuses"]]
except Exception:
    print("could not read")
    raise SystemExit(0)

states = []
for r in runs:
    if r.get("status") != "completed":
        states.append("running")
    elif r.get("conclusion") in ("success", "neutral"):
        states.append("passed")
    elif r.get("conclusion") == "skipped":
        states.append("skipped")
    else:
        states.append("failed")
for s in statuses:
    st = s.get("state")
    states.append({"success": "passed", "pending": "running"}.get(st, "failed"))

# Passed needs something that ran and passed. Skipped jobs beside it are
# normal (path filters); a head where EVERY check skipped proved nothing.
if not states:
    print("none")
elif "failed" in states:
    print("failed")
elif "running" in states:
    print("running")
elif "passed" in states:
    print("passed")
else:
    print("skipped")
') || ci="could not read"
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$number" "$status" "$created" "$ci" "$verdict" "$title" >>"$rows"
done <"$found"

# Ages last, from one clock, lowest number first. MC_NOW pins the clock for the
# tests.
# Into a file and then out, so a failure part way prints nothing at all.
MC_ROWS="$rows" mc_py -c '
import io, os
from datetime import datetime, timezone

def when(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

now = when(os.environ["MC_NOW"]) if os.environ.get("MC_NOW") else datetime.now(timezone.utc)

def age(created):
    secs = (now - when(created)).total_seconds()
    days, hours = int(secs // 86400), int(secs // 3600)
    if days >= 1:
        return "%d day%s" % (days, "" if days == 1 else "s")
    if hours >= 1:
        return "%d hour%s" % (hours, "" if hours == 1 else "s")
    return "under an hour"

with io.open(os.environ["MC_ROWS"], encoding="utf-8") as fh:
    rows = [l.rstrip("\n").split("\t") for l in fh if l.strip()]
for number, status, created, ci, verdict, title in sorted(rows, key=lambda r: int(r[0])):
    print("\t".join([number, status, age(created), ci, verdict, title]))
' >"$work/out"
cat "$work/out"
