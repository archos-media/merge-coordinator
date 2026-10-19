#!/usr/bin/env bash
# Which repository is a hook call about? Source this; do not run it.
#
# The hooks used to answer with CLAUDE_PROJECT_DIR, the directory the SESSION
# started in. That is only the repository when a session starts at its root.
# Sessions that start one level up, in a folder holding the checkout and its
# notes, have no config there, so every guard decided "this repository has not
# adopted the plugin" and let a bare `gh pr merge` through. Nothing said so: an
# allowed command looks exactly like a command the guard approved. Found
# 7 October 2026, when one project's sessions moved to a parent folder.
#
# Claude Code passes where the command starts as `cwd` in every hook payload,
# and it follows EnterWorktree, so mc_hook_repo asks it before
# CLAUDE_PROJECT_DIR and the hook's own working directory.
#
# Where a command starts is not always the repository it acts on. A
# `cd <dir> && ...` inside it, gh's -R, a pull request URL and GH_REPO all move
# the target, and a harness that resets the shell to the session folder after
# every call makes those the normal way to work in another repository. Reading
# the start folder alone, a guard applied the session repository's rules to a
# command aimed at another one: it refused a merge in an unadopted repository
# after checking the wrong pull request, and it waved through
# `gh pr merge -R <adopted> N` run from an unadopted folder without looking.
# Found 11 October 2026. mc_hook_target answers for the repository the command
# acts on, read by lib/cmd_target.py.

MC_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# mc_hook_repo <dir>... — print the directory whose .github/merge-coordinator.json
# applies, or return 1 when none does.
#
# The first candidate INSIDE A GIT REPOSITORY decides. If that repository has no
# config, the answer is "not adopted", and no later candidate is consulted:
# falling through would apply one repository's rules to a command running in
# another. A candidate outside any repository is skipped, unless the directory
# itself holds a config, which is how the offline test suites set things up.
mc_hook_repo() {
	local d top
	for d in "$@"; do
		[ -n "$d" ] || continue
		[ -d "$d" ] || continue
		if top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
			if [ -f "$top/.github/merge-coordinator.json" ]; then
				printf '%s' "$top"
				return 0
			fi
			return 1
		fi
		if [ -f "$d/.github/merge-coordinator.json" ]; then
			printf '%s' "$d"
			return 0
		fi
	done
	return 1
}

# The caller defines py(), as every guard does before sourcing this file.
mc_config_repo() {
	MC_FILE="$1" py -c "import json,os
try:
    print(json.load(open(os.environ['MC_FILE'], encoding='utf-8')).get('repo') or '', end='')
except Exception:
    pass" 2>/dev/null | tr -d '\r'
}

mc_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# mc_gh_timed <args...> — gh with a deadline of MC_GH_TIMEOUT seconds (10).
#
# A hook that runs past its timeout in hooks.json does not block the command:
# Claude Code lets the call through ("A timed-out command hook doesn't block
# the tool call", code.claude.com/docs/en/hooks). A GitHub that does not answer
# would turn every guard into an allow. With a deadline of its own, the hook
# finishes in time and refuses. timeout(1) exits 124 when it fires.
mc_gh_timed() {
	mc_timed "${MC_GH_TIMEOUT:-10}" gh "$@"
}

# mc_timed <seconds> <command...> — the command with a deadline, through
# timeout(1), or gtimeout where coreutils carries the g prefix (macOS with
# Homebrew). With neither, the command runs with none, and only the hook's own
# timeout in hooks.json bounds it.
mc_timed() {
	local secs="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" "$@"
	else
		"$@"
	fi
}

# mc_hook_target <merge|ready> <command> <cwd> <dir>... — which config applies to
# the repository the command's guarded gh call acts on. <cwd> is the payload's;
# <dir>... are the fallbacks mc_hook_repo tries after it.
#
# Returns 0 when that repository uses the plugin: MC_TARGET_CONFIG is its config,
# and MC_TARGET_LOCAL its checkout, or empty when the config was read from GitHub.
# Returns 1 when it does not, or when the command makes no guarded call
# (MC_TARGET_FOUND=0). Returns 2 when the guard cannot say, and MC_TARGET_WHY
# says why: the command could not be read, or points somewhere in a form the
# guard does not read, or cds into a folder that is not here; or the target's
# config could not be fetched, or names a different repository. None of those
# may read as "not adopted".
#
# MC_TARGET_OVERRIDE is 1 when the command breaks glass: MERGE_COORDINATOR_OVERRIDE=1
# as an assignment word, never as text inside a --body. MC_TARGET_BROKEN is 1
# when the reader itself failed, and then the override cannot be read: the
# caller decides, from the raw text, whether break glass still goes through.
#
# Also set: MC_TARGET_SLUG, the OWNER/NAME the command named, if any;
# MC_TARGET_PR, the pull request number, if the command gave one;
# MC_TARGET_PRSEL, a branch given in its place; MC_TARGET_KIND (merge, ready or
# create); MC_TARGET_DRAFT and MC_TARGET_UNDO (1 or 0).
#
# A config read from GitHub is a temporary file. The caller removes it with
# mc_hook_cleanup, from its own EXIT trap.
mc_hook_target() {
	local mode="$1" cmd="$2" cwd="$3" out line status="" found="" top cd_dir local_repo
	shift 3
	MC_TARGET_FOUND=0 MC_TARGET_WHY="" MC_TARGET_SLUG="" MC_TARGET_PR="" MC_TARGET_PRSEL=""
	MC_TARGET_KIND="" MC_TARGET_DRAFT=0 MC_TARGET_UNDO=0 MC_TARGET_CONFIG="" MC_TARGET_LOCAL=""
	MC_TARGET_OVERRIDE=0 MC_TARGET_BROKEN=0
	# One python call, its status read directly: a parse that failed must refuse,
	# not come back as an empty answer that reads as "no guarded call". Its
	# stderr comes along, so the refusal can say what broke.
	if ! out=$(printf '%s\0%s\0%s' "$cwd" "${HOME:-}" "$cmd" | py "$MC_LIB_DIR/cmd_target.py" "$mode" 2>&1); then
		MC_TARGET_FOUND=1 MC_TARGET_BROKEN=1
		MC_TARGET_WHY="the merge coordinator could not read this command (scripts/lib/cmd_target.py failed or is missing: ${out##*$'\n'}), so it cannot tell which repository it acts on"
		return 2
	fi
	while IFS= read -r line; do
		case "$line" in
		found=*) found="${line#found=}" ;;
		status=*) status="${line#status=}" ;;
		why=*) MC_TARGET_WHY="${line#why=}" ;;
		kind=*) MC_TARGET_KIND="${line#kind=}" ;;
		slug=*) MC_TARGET_SLUG="${line#slug=}" ;;
		pr=*) MC_TARGET_PR="${line#pr=}" ;;
		prsel=*) MC_TARGET_PRSEL="${line#prsel=}" ;;
		draft=*) MC_TARGET_DRAFT="${line#draft=}" ;;
		undo=*) MC_TARGET_UNDO="${line#undo=}" ;;
		cd=*) cd_dir="${line#cd=}" ;;
		override=*) MC_TARGET_OVERRIDE="${line#override=}" ;;
		esac
	done <<<"$out"
	# Only an outright found=0 means "no guarded call". An answer without the
	# line is a reader out of step with this file.
	case "$found" in
	0) return 1 ;;
	1) MC_TARGET_FOUND=1 ;;
	*)
		MC_TARGET_FOUND=1 MC_TARGET_BROKEN=1
		MC_TARGET_WHY="the merge coordinator could not read this command (scripts/lib/cmd_target.py gave no answer), so it cannot tell which repository it acts on"
		return 2
		;;
	esac
	if [ "$status" != ok ]; then
		MC_TARGET_WHY="this command points the call somewhere the merge coordinator does not read: ${MC_TARGET_WHY:-no reason given}"
		return 2
	fi
	# gh also reads GH_REPO and GH_HOST from the environment the session gives
	# every command, which this hook shares. A repository the command names wins
	# over GH_REPO, as it does in gh.
	if [ -n "${GH_HOST:-}" ] && [ "$(mc_lower "$GH_HOST")" != github.com ]; then
		MC_TARGET_WHY="this session sets GH_HOST=$GH_HOST, and the merge coordinator reads only github.com"
		return 2
	fi
	if [ -z "$MC_TARGET_SLUG" ] && [ -n "${GH_REPO:-}" ]; then
		case "$GH_REPO" in
		*/*/* | *" "*)
			MC_TARGET_WHY="this session sets GH_REPO=$GH_REPO, which is not an OWNER/NAME the merge coordinator reads"
			return 2
			;;
		?*/?*) MC_TARGET_SLUG="$GH_REPO" ;;
		*)
			MC_TARGET_WHY="this session sets GH_REPO=$GH_REPO, which is not an OWNER/NAME the merge coordinator reads"
			return 2
			;;
		esac
	fi

	# Where it runs. After a leading cd, that folder alone decides: the folder
	# the command started in is somewhere it no longer is.
	if [ -n "${cd_dir:-}" ]; then
		if [ ! -d "$cd_dir" ]; then
			MC_TARGET_WHY="this command starts with a cd into $cd_dir, which is not a folder here, so the merge coordinator cannot tell which repository it acts on"
			return 2
		fi
		top=$(mc_hook_repo "$cd_dir") || top=""
	else
		top=$(mc_hook_repo "$cwd" "$@") || top=""
	fi

	if [ -n "$top" ]; then
		local_repo=$(mc_config_repo "$top/.github/merge-coordinator.json")
		if [ -z "$MC_TARGET_SLUG" ] || [ "$(mc_lower "$MC_TARGET_SLUG")" = "$(mc_lower "$local_repo")" ]; then
			MC_TARGET_CONFIG="$top/.github/merge-coordinator.json"
			MC_TARGET_LOCAL="$top"
			return 0
		fi
	elif [ -z "$MC_TARGET_SLUG" ]; then
		return 1
	fi
	mc_remote_config "$MC_TARGET_SLUG"
}

# mc_remote_config <OWNER/NAME> — read that repository's config from its default
# branch on GitHub, for a command aimed at a repository with no checkout here.
#
# A 404 is "not adopted" only when GitHub shows this account the repository
# itself. A name the guard misread, or one this account cannot see, also
# answers 404, and reading that as "not adopted" would let the command through
# on a misreading. A config that names another repository is not this one's:
# a fork carries its parent's config, and judging the fork's pull request by it
# would check the parent's pull request of the same number.
mc_remote_config() {
	local slug="$1" err rc named
	MC_TARGET_TMP=$(mktemp 2>/dev/null) || {
		MC_TARGET_WHY="the merge coordinator could not make a temporary file to read whether $slug uses it"
		return 2
	}
	err=$(mc_gh_timed api -H "Accept: application/vnd.github.raw+json" "repos/$slug/contents/.github/merge-coordinator.json" 2>&1 >"$MC_TARGET_TMP")
	rc=$?
	if [ "$rc" -eq 0 ]; then
		if [ ! -s "$MC_TARGET_TMP" ]; then
			MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it: its .github/merge-coordinator.json on GitHub came back empty"
			return 2
		fi
		named=$(mc_config_repo "$MC_TARGET_TMP")
		if [ "$(mc_lower "$named")" != "$(mc_lower "$slug")" ]; then
			MC_TARGET_WHY="$slug's .github/merge-coordinator.json names ${named:-no repository}, not $slug (a fork carrying its parent's config, or a repository renamed since?), so the merge coordinator will not judge $slug by it"
			return 2
		fi
		MC_TARGET_CONFIG="$MC_TARGET_TMP"
		return 0
	fi
	if [ "$rc" -eq 124 ]; then
		MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it: GitHub did not answer within ${MC_GH_TIMEOUT:-10} seconds"
		return 2
	fi
	case "$err" in
	*"HTTP 404"*)
		err=$(mc_gh_timed api "repos/$slug" --jq .full_name 2>&1 >/dev/null)
		rc=$?
		[ "$rc" -eq 0 ] && return 1
		case "$rc:$err" in
		124:*) MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it: GitHub did not answer within ${MC_GH_TIMEOUT:-10} seconds" ;;
		*"HTTP 404"*) MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it: GitHub shows this account no repository by that name" ;;
		*) MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it (whether GitHub shows the repository): ${err%%$'\n'*}" ;;
		esac
		return 2
		;;
	esac
	MC_TARGET_WHY="the merge coordinator could not read whether $slug uses it (its .github/merge-coordinator.json on GitHub): ${err%%$'\n'*}"
	return 2
}

# mc_hook_cleanup — remove the config mc_remote_config fetched, if it fetched
# one. The caller runs it from its EXIT trap; this file sets no trap of its own.
mc_hook_cleanup() {
	if [ -n "${MC_TARGET_TMP:-}" ]; then
		rm -f "$MC_TARGET_TMP"
	fi
}
