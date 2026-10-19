#!/usr/bin/env bash
# PreToolUse / Bash — do not start CI behind somebody who is already running it.
#
# WHAT THIS IS FOR. Marking a pull request ready for review is the moment CI
# starts: once CI is set to skip drafts, a draft runs nothing, so it is free
# and a ready pull request costs about fourteen runner-minutes. When two branches that
# touch the same files are both ready at once, the one that lands second cannot
# produce the tree it was tested on — main moved underneath it — so its merge
# group has to build something new and its green is earned twice. That is the
# one case a CI cache keyed on the tree cannot avoid, and it is avoidable by the
# second branch simply staying a draft until the first lands.
#
# So: whoever is already running CI keeps their turn. Everyone sharing ground
# with them waits as a draft, which costs nothing and goes stale never.
#
# It also refuses while a Dependabot pull request waits, or when it could not
# look for one; the way past is ready.sh --skip-deps.
#
# IT IS SCOPED TO SHARED GROUND, NOT TO EVERYTHING. Two pull requests with no
# file in common and no hotspot between them can both be ready, both run CI
# once, and both land with a cached merge group. Serializing those would buy
# nothing and cost a day of waiting. overlap.sh --ci-ahead draws the line.
#
# WHAT IT CANNOT DO. Same limit as guard-merge.sh: it reads the Bash command
# Claude asked to run, not subprocesses, so a `gh pr ready` from inside a script
# it cannot read still happens. It is a guard against the easy mistake, not a
# permission boundary.
#
# IT FAILS CLOSED. Only an outright "nothing is ahead" allows the call. Every
# other answer — something is ahead, the analysis broke, the pull request number
# could not be read — refuses, because "I could not look" and "the line is
# clear" must never produce the same result.
set -u

payload="$(cat)"

# This runs on EVERY Bash call, so rule out the vast majority on raw text before
# spawning anything. Match the bare words, not "pr ready": `gh pr -R X ready`
# and a doubled space both break the phrase but keep the word. The payload
# holds the session's folder too, so the command is tested again below.
case "$payload" in
*ready* | *create* | *new*) ;;
*) exit 0 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The candidate has to be RUN, not just found: Windows ships a python3.exe alias
# that resolves, prints "Python was not found" and exits non-zero.
py() {
	if [ -z "${MC_PYTHON:-}" ]; then
		for cand in python3 python py; do
			if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
				MC_PYTHON="$cand"
				break
			fi
		done
		# No python means this hook cannot read anything. Say nothing and let the
		# call through, for the reason guard-merge.sh gives: a guard that cannot
		# look must not pretend it did.
		[ -n "${MC_PYTHON:-}" ] || return 1
		export MC_PYTHON
	fi
	"$MC_PYTHON" "$@"
}

cmd="$(printf '%s' "$payload" | py -c "import json,sys
try:
    print(json.load(sys.stdin).get('tool_input',{}).get('command') or '', end='')
except Exception:
    pass" 2>/dev/null)"
# Where the command starts. With what the command itself says, that decides
# the repository: lib/hook-repo.sh says why this is not CLAUDE_PROJECT_DIR.
cwd="$(printf '%s' "$payload" | py -c "import json,sys
try:
    print(json.load(sys.stdin).get('cwd') or '', end='')
except Exception:
    pass" 2>/dev/null)"

[ -z "$cmd" ] && exit 0
case "$cmd" in
*ready* | *create* | *new*) ;;
*) exit 0 ;;
esac

# ready.sh, the sanctioned path, runs the same check itself and then does the
# flip. It makes no gh call the reader can see, so it is not guarded; a
# ready.sh mentioned in a --body does not excuse the call beside it.

deny() {
	py -c "import json,sys
print(json.dumps({'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'deny',
    'permissionDecisionReason': sys.argv[1]}}))" "$1"
	exit 0
}

# A repository with no config is not using this plugin. Do not block it.
#
# This used to read "no config AND not a git repository", which is both terms of
# an OR spelled as an AND: inside a git repository with no config — the one case
# that matters — the guard carried on and refused `gh pr create`, naming a
# ready.sh that had no config to work from either. The config file is the whole
# test, exactly as guard-merge.sh has it.
#
# The repository is the one the command acts on: where it runs, resolved to the
# top of its working tree, or where a leading `cd`, -R, a pull request URL or
# GH_REPO points it. lib/cmd_target.py reads the command the shell's way, so a
# --draft or a -R inside a quoted --body is text, not a flag. A draft and
# --undo come back as no guarded call at all: they start no CI wherever they
# act, so no form of them is ever refused.
# shellcheck source=lib/hook-repo.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hook-repo.sh"
# A missing helper is a broken plugin, not an unadopted repository. Treating it
# as "no config" would wave the command through in silence, which is the exact
# failure lib/hook-repo.sh exists to end. So it refuses, and says what is wrong.
# Break glass still goes through: it is the way past a broken coordinator.
if ! type mc_hook_target >/dev/null 2>&1; then
	case "$cmd" in
	*MERGE_COORDINATOR_OVERRIDE=1*) exit 0 ;;
	esac
	deny "Refused: the merge coordinator plugin is incomplete (scripts/lib/hook-repo.sh is missing), so it cannot tell which repository this command runs in. Reinstall the plugin, or prefix the command with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi
trap mc_hook_cleanup EXIT
mc_hook_target ready "$cmd" "$cwd" "${CLAUDE_PROJECT_DIR:-}" "$(pwd)"
rc=$?
# Break glass: MERGE_COORDINATOR_OVERRIDE=1 as an assignment word, read by the
# reader, so the same text inside a --body breaks nothing. A reader that failed
# cannot read it, and then the raw text decides.
[ "$MC_TARGET_OVERRIDE" = 1 ] && exit 0
if [ "$MC_TARGET_BROKEN" = 1 ]; then
	case "$cmd" in
	*MERGE_COORDINATOR_OVERRIDE=1*) exit 0 ;;
	esac
fi
case $rc in
0) ;;
1) exit 0 ;;
*) deny "Refused: $MC_TARGET_WHY. Not looking and finding nothing are different answers, and this one is 'could not look'. Rewrite the command in a form it reads, or prefix it with MERGE_COORDINATOR_OVERRIDE=1 to break glass." ;;
esac
# Everything below (gh pr view with no number, overlap.sh) reads the current
# directory, so stand in the checkout when there is one. A config read from
# GitHub has none: overlap.sh takes it through MC_CONFIG instead.
if [ -n "$MC_TARGET_LOCAL" ]; then
	cd "$MC_TARGET_LOCAL" ||
		deny "Refused: the merge coordinator could not enter $MC_TARGET_LOCAL to check the CI line there. Prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
else
	export MC_CONFIG="$MC_TARGET_CONFIG"
fi

# --------------------------------------------------------------------------
# `gh pr create` that is not a draft.
#
# There is no pull request to analyse yet, so there is nothing to measure. The
# rule here is therefore flat rather than scoped: open it as a draft. That is
# already how every worktree session starts (register.sh opens one on
# EnterWorktree), it costs no CI, and it makes the branch visible to the other
# sessions before any of them has written code.
# --------------------------------------------------------------------------
# A draft never gets here: the reader answers "no guarded call" for one.
case "$MC_TARGET_KIND" in
create)
	deny "Refused: this opens a pull request that is ready for review, which starts CI immediately.

Open it as a draft instead. A draft runs no CI at all, it registers the branch so other sessions can see what you are touching, and nothing about it goes stale while it waits:

    gh pr create --draft ...

Then, when the work is finished, mark it ready with:

    bash $here/ready.sh <number>

which checks first whether anybody sharing your files is already running CI. To break glass, prefix the command with MERGE_COORDINATOR_OVERRIDE=1."
	;;
esac

# --------------------------------------------------------------------------
# `gh pr ready`.
# --------------------------------------------------------------------------
[ "$MC_TARGET_KIND" = ready ] || exit 0

# --undo never gets here either: it puts a pull request BACK to draft, which is
# the thing this hook wants more of, and the reader answers "no guarded call".

# The number may be given, or a branch given in its place, or left out to mean
# the branch checked out here.
pr="$MC_TARGET_PR"

# The branches here say nothing about a pull request in another repository, so
# only a local target may name a branch or leave the number out.
if [ -z "$pr" ] && [ -n "$MC_TARGET_LOCAL" ]; then
	pr="$(mc_gh_timed pr view ${MC_TARGET_PRSEL:+"$MC_TARGET_PRSEL"} --json number --jq '.number' 2>/dev/null)"
fi

if [ -z "$pr" ]; then
	deny "Refused: this marks a pull request ready for review, which starts CI, but the merge coordinator could not read which pull request from the command or from the current branch.

Name it — 'bash $here/ready.sh <number>' — or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

# A Dependabot pull request waiting refuses it. The same stop as ready.sh's
# mc_deps_gate (lib/gh.sh), written again here because a hook answers with a
# deny, not by exiting 1: keep the two in step. The raw command has no
# --skip-deps of its own, so "later" goes through ready.sh. --no-ci: the stop
# needs only who is waiting, and the CI reads cost seconds per pull request.
# Its own deadline, inside the hook's 90 seconds, for the reason given at
# overlap.sh below; 124, the deadline, refuses like any other failure to look.
deps="$(mc_timed "${MC_DEPS_TIMEOUT:-20}" bash "$here/deps-open.sh" --no-ci 2>/dev/null)"
deps_status=$?
if [ "$deps_status" -ne 0 ]; then
	if [ "$deps_status" -eq 124 ]; then
		why="the lookup did not finish within ${MC_DEPS_TIMEOUT:-20} seconds"
	else
		why="the lookup failed"
	fi
	deny "Refused: could not check the open Dependabot pull requests ($why), so the merge coordinator will not mark #$pr ready.

Not looking and finding nothing are different answers, and this one is 'could not look'. Try again. If it still cannot look, ask the user; if they say go on: 'bash $here/ready.sh $pr --skip-deps'. Or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi
waiting=""
self=0
while IFS=$'\t' read -r n status age ci verdict title; do
	[ -n "$n" ] || continue
	if [ "$n" = "$pr" ]; then
		self=1
		break
	fi
	[ "$status" = waiting ] && waiting="$waiting #$n"
done <<DEPS
$deps
DEPS
if [ "$self" -eq 0 ] && [ -n "$waiting" ]; then
	deny "Refused: Dependabot pull request(s) waiting:$waiting. Marking #$pr ready goes on past them.

Ask the user whether to land these first.
  Yes:    /merge-deps <number> reviews the bump, then lands it or closes it.
  Later:  bash $here/ready.sh $pr --skip-deps

Or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

# overlap.sh asks GitHub about every open pull request. Its own deadline keeps
# a slow GitHub from running the hook past its timeout, which would let the
# call through (lib/hook-repo.sh, mc_gh_timed). 124, the deadline, refuses below.
ahead="$(mc_timed "${MC_OVERLAP_TIMEOUT:-25}" bash "$here/overlap.sh" "$pr" --ci-ahead 2>/dev/null)"
status=$?

# ONLY 0 ALLOWS. 1 means somebody is ahead, 3 means the analysis could not
# answer, and anything else is a failure nobody predicted. All of them refuse.
if [ "$status" -eq 0 ]; then
	exit 0
fi

if [ "$status" -ne 1 ] || [ -z "$ahead" ]; then
	deny "Refused: could not work out whether anything is ahead of #$pr in the CI line, so the merge coordinator will not say the line is clear.

Not looking and finding nothing are different answers, and this one is 'could not look'. Run 'bash $here/overlap.sh $pr' to see what it says, or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

# `tr` and not a loop: this is a short list of numbers.
list="$(printf '%s' "$ahead" | tr '\n' ' ' | sed 's/ *$//' | sed 's/\([0-9][0-9]*\)/#\1/g')"

deny "Refused: $list is already ready and running CI over ground #$pr shares.

Marking #$pr ready now starts a second CI pass on the same files. Whichever of you lands second cannot produce the tree it was tested on — main will have moved — so that one pays for CI twice: once on the pull request, and again on the merge group, which is the one case a CI cache keyed on the tree cannot avoid.

Leave #$pr as a draft until $list lands. A draft costs no CI and goes stale never. /merge-status shows where the line is, and 'bash $here/overlap.sh $pr' shows exactly what you share.

If these really are independent and overlap.sh is reading it wrong, say so in the pull request and prefix the command with MERGE_COORDINATOR_OVERRIDE=1."
