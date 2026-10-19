#!/usr/bin/env bash
# Fires registration, and hands the session the open Dependabot pull requests,
# when a session enters a new worktree.
#
# THIS SCRIPT ALWAYS EXITS 0. A hook that can halt a session because GitHub was
# slow, or because the branch is not pushed yet, gets deleted rather than
# respected - and then the layer it belongs to is dormant again. Everything
# here is best effort, and a failure is a printed line and nothing more.
#
# Measured before it was built, 26 August 2026, with a Bash matcher registered
# alongside as a control so that "the hook did not fire" could be told apart
# from "settings were not reloaded":
#
#   - A PostToolUse matcher DOES fire on a tool that is not Bash. The matcher
#     is compared against the tool name, so `EnterWorktree` matches the tool of
#     that name.
#   - A REFUSED tool call fires nothing. An EnterWorktree that was rejected
#     because the session was already in that directory produced no hook at
#     all. That is the right behaviour - no worktree was created, so there is
#     nothing to register - but it does mean this cannot be relied on to fire
#     once per attempt, only once per worktree that actually appeared.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The payload arrives on stdin and is not read. Registration needs the branch,
# which comes from the worktree the session is now in, and draining stdin keeps
# the writer from blocking on a full pipe.
cat >/dev/null 2>&1 || true

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	exit 0
fi

# A repository with no config of its own is not using this plugin, so there is
# nothing to register and nothing to say about it. Exit before register.sh, which
# now refuses to run without a config rather than querying an empty repo slug.
top=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$top" ] && [ -f "$top/.github/merge-coordinator.json" ] || exit 0

if ! MC_DEPS_NOTICE=off bash "$here/register.sh" >&2; then
	echo "merge-coordinator: could not register this branch. Nothing is broken —" >&2
	echo "  this session is simply not visible to the others yet. Run:" >&2
	echo "    bash $here/register.sh <paths you expect to touch>" >&2
fi

# The open Dependabot pull requests, handed to the session as context.
#
# Plain output from a hook that runs after a tool call goes to the debug log,
# never to the session, so this has to be JSON on stdout, as vendor-status.sh
# does it. Registration's report moved to stderr above so that stdout holds
# nothing else; it reached only the debug log before, and still does.
#
# A hook that runs past its timeout in hooks.json is killed and says nothing,
# so the look has a deadline of its own (MC_DEPS_TIMEOUT, 15 s) that ends in a
# "could not check" line instead. --no-ci makes it one query: the CI on each
# head costs seconds per pull request, and the stop and /merge-status say it.
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"
said=$(MC_DEPS_NOTICE_TIMEOUT="${MC_DEPS_TIMEOUT:-15}" mc_deps_notice --no-ci)
if [ -n "$said" ]; then
	printf '%s' "$said" | mc_py -c 'import json, sys
m = sys.stdin.read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                         "additionalContext": m}}))' 2>/dev/null || true
fi

exit 0
