#!/usr/bin/env bash
# PreToolUse / Bash — refuse to merge a pull request outside the landing sequence.
#
# Every step land.sh performs can be skipped by typing `gh pr merge` instead, and
# the skipped steps are exactly the ones that stop a landing from silently
# invalidating another session. So the shortcut is closed here.
#
# WHAT IT ALLOWS, on purpose:
#   - a command that runs land.sh, the sanctioned path, which makes no gh
#     merge call of its own that the guard can see;
#   - a merge of a PR that already holds the landing label, because that PR is
#     inside the sequence already and step 5 is this exact command;
#   - a command with MERGE_COORDINATOR_OVERRIDE=1 as an assignment word (a
#     prefix, or exported before the call), which is break glass.
#     --admin is not blocked outright: it is the recovery path when the
#     coordinator itself is what is broken, and a control that cannot be
#     stepped over in an emergency gets removed instead of respected.
#
# WHAT IT CANNOT DO. It reads the Bash command that Claude asked to run. It does
# not see subprocesses, so a merge from inside a script it cannot read still
# happens. It is a guard against the easy mistake, not a permission boundary.
#
# It also fails CLOSED: if the label cannot be read, the merge is refused rather
# than allowed, because "I could not look" and "there is nothing there" must
# never produce the same answer.
set -u

payload="$(cat)"

# This runs on EVERY Bash call. Rule out the vast majority on raw text before
# spawning anything. Match the bare word, not "pr merge": `gh pr -R X merge`
# and a doubled space both break the phrase but keep the word. The payload
# holds the session's folder too, so the command is tested again below.
case "$payload" in
*merge*) ;;
*) exit 0 ;;
esac

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
		# call through: a guard that cannot look must not pretend it did, and
		# blocking every Bash command on a machine without python is worse than
		# the shortcut it is guarding.
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
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hook-repo.sh
. "$here/lib/hook-repo.sh"

[ -z "$cmd" ] && exit 0
case "$cmd" in
*merge*) ;;
*) exit 0 ;;
esac

# Whether this command merges a pull request, and which one in which
# repository, is read by lib/cmd_target.py through mc_hook_target: a `gh pr
# merge` or a PUT to the REST merge path, the shell's way, so a merge named
# inside a commit message is text and a -R inside a --body is not a flag.
# land.sh, the sanctioned path, makes no gh call the reader can see, so it is
# not guarded; a land.sh mentioned in a --body does not excuse the merge beside it.

deny() {
	py -c "import json,sys
print(json.dumps({'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'deny',
    'permissionDecisionReason': sys.argv[1]}}))" "$1"
	exit 0
}

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
# The repository the merge acts on: where it runs, or where a leading `cd`,
# -R, a pull request URL, GH_REPO or the REST path's OWNER/NAME points it. A
# repository with no config is not using this plugin, so it is not blocked; a
# command that makes no merge is not either. One the guard cannot place, or
# whose config it could not read, is refused.
mc_hook_target merge "$cmd" "$cwd" "${CLAUDE_PROJECT_DIR:-}" "$(pwd)"
rc=$?

# Break glass: MERGE_COORDINATOR_OVERRIDE=1 as an assignment word, read by the
# reader, so the same text inside a --body breaks nothing. A reader that failed
# cannot read it, and then the raw text decides, for the reason above.
glass=0
if [ "$MC_TARGET_OVERRIDE" = 1 ]; then
	glass=1
elif [ "$MC_TARGET_BROKEN" = 1 ]; then
	case "$cmd" in
	*MERGE_COORDINATOR_OVERRIDE=1*) glass=1 ;;
	esac
fi
if [ "$glass" = 1 ]; then
	# Break glass is allowed to work, but it puts a commit on the default branch
	# that no merge group tested, and a repository that stopped running CI on
	# a push to the default branch tests nothing there. land.sh fires the
	# workflows itself when IT merges outside a queue - it cannot help here,
	# because this path does not run
	# land.sh at all. So say what to run. Printed, never blocking: a control that
	# can halt a session gets removed rather than respected.
	#
	# The workflows are the repository's own outOfQueueCi list. A repository
	# that still runs CI on a push to its default branch leaves the key out,
	# and then there is nothing to fire and nothing is printed. The list is the
	# one of the repository the merge acts on, not the session's, and each line
	# names that repository: the shell starts in the session's folder, where a
	# bare `gh workflow run` would fire the session repository's workflow.
	if [ "$rc" = 2 ]; then
		echo "merge-coordinator: break glass - $MC_TARGET_WHY. Whether CI must be fired by hand after this merge is unknown: check the target's outOfQueueCi." >&2
	fi
	if [ -n "${MC_TARGET_CONFIG:-}" ]; then
		fire=$(MC_FILE="$MC_TARGET_CONFIG" py -c "import json,os
try:
    cfg = json.load(open(os.environ['MC_FILE'], encoding='utf-8'))
    branch = cfg.get('defaultBranch') or 'main'
    where = (' --repo %s' % cfg['repo']) if cfg.get('repo') else ''
    for wf in cfg.get('outOfQueueCi') or []:
        print('    gh workflow run %s --ref %s%s' % (wf, branch, where))
except Exception:
    print('    (could not read outOfQueueCi from the config: check it by hand)')" 2>/dev/null | tr -d '\r')
		if [ -n "$fire" ]; then
			echo "merge-coordinator: break glass - this merge skips the queue, and CI does" >&2
			echo "  not run on a push to the default branch there. Once it lands, fire:" >&2
			printf '%s\n' "$fire" >&2
		fi
	fi
	exit 0
fi

case $rc in
0) config="$MC_TARGET_CONFIG" ;;
1) exit 0 ;;
*) deny "Refused: $MC_TARGET_WHY. Not looking and finding nothing are different answers, and this one is 'could not look'. Rewrite the command in a form it reads, or prefix it with MERGE_COORDINATOR_OVERRIDE=1 to break glass." ;;
esac

read_cfg() {
	MC_FILE="$config" MC_KEY="$1" py -c "import json,os,sys
try:
    with open(os.environ['MC_FILE'], encoding='utf-8') as fh:
        node = json.load(fh)
    for part in os.environ['MC_KEY'].split('.'):
        node = node[part]
    print(node, end='')
except Exception:
    pass" 2>/dev/null
}

landing_label="$(read_cfg labels.landing)"
# The repository comes from the config, not from the working directory: this
# hook runs wherever Claude happened to be, which may be another checkout.
repo="$(read_cfg repo)"

if [ -z "$landing_label" ] || [ -z "$repo" ]; then
	deny "Refused: $config does not name both 'repo' and 'labels.landing', so the merge coordinator cannot tell whether this pull request holds the landing claim. Fix the config, or prefix the command with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

# From the same gh call the repository came from. A branch name in its place is
# not read: which pull request it means depends on what is open right now.
pr="$MC_TARGET_PR"

if [ -z "$pr" ]; then
	deny "Refused: this merges a pull request, but the merge coordinator could not read which one from the command, so it cannot check whether that pull request holds the '$landing_label' claim. Use /merge-land <number>, or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

labels="$(mc_gh_timed api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")' 2>/dev/null)"
status=$?

if [ "$status" -ne 0 ]; then
	deny "Refused: could not read the labels on #$pr, so the merge coordinator cannot tell whether it holds the '$landing_label' claim. Not looking and finding nothing are different answers, and this one is 'could not look'. Use /merge-land $pr, or prefix with MERGE_COORDINATOR_OVERRIDE=1 to break glass."
fi

case ",$labels," in
*",$landing_label,"*) exit 0 ;;
esac

deny "Refused: #$pr does not hold the '$landing_label' claim, so merging it here skips the landing sequence.

That sequence is not ceremony. It checks that this head was tested against the current default branch (GitHub calls a stale PR mergeable unless branch protection requires branches to be up to date), it reads the named check conclusions on this exact commit rather than trusting a run that may have been cancelled, it asserts afterwards that the merge did not revert a release heading, and it tells every overlapping pull request that it just went stale.

Run /merge-land $pr instead. To break glass — including for --admin — prefix the command with MERGE_COORDINATOR_OVERRIDE=1."
