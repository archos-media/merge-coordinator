#!/usr/bin/env bash
# PreToolUse / EnterWorktree — do not start a worktree for an issue that another
# open pull request already claims.
#
# The issue claim check on GitHub enforces the rule for every agent. This hook
# only moves the refusal earlier, for Claude sessions on this machine: before
# the worktree exists, before registration opens a second draft, and before any
# work is done twice. On 8 Sep 2026 a session planned an issue while a peer had
# already built it in another pull request. This is the check that would have
# stopped it.
#
# The issue number comes from the worktree name, the same way register.sh reads
# it from the branch. A name with no single number is not checked.
#
# IT FAILS OPEN. If it cannot read GitHub or cannot parse the payload, the
# worktree goes ahead. The check on GitHub is the gate. A hook that stops a
# session because GitHub was slow gets deleted, not respected.
set -u

payload="$(cat)"

# This runs on every EnterWorktree. A payload with no digit cannot carry an
# issue number, so it is ruled out before python starts.
case "$payload" in
*[0-9]*) ;;
*) exit 0 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# json_out <python expression> <message> — print a hook answer as JSON.
json_out() {
	printf '%s' "$2" | mc_py -c "import json, sys
message = sys.stdin.read()
print(json.dumps($1))" 2>/dev/null
}

# Entering an existing worktree by path is not a new claim. Only a name is.
name=$(printf '%s' "$payload" | mc_py -c 'import json, sys
try:
    tool_input = json.load(sys.stdin).get("tool_input") or {}
    sys.stdout.write(tool_input.get("name") or "")
except Exception:
    pass' 2>/dev/null) || exit 0
[ -n "$name" ] || exit 0

issue=$(mc_issue_from_name "$name")
[ -n "$issue" ] || exit 0

# The worktree is made from the repository the session is standing in, which is
# the payload's cwd, not CLAUDE_PROJECT_DIR (lib/hook-repo.sh says why).
cwd=$(printf '%s' "$payload" | mc_py -c 'import json, sys
try:
    sys.stdout.write(json.load(sys.stdin).get("cwd") or "")
except Exception:
    pass' 2>/dev/null)
# shellcheck source=lib/hook-repo.sh
. "$here/lib/hook-repo.sh"
top=$(mc_hook_repo "$cwd" "${CLAUDE_PROJECT_DIR:-}" "$(pwd)") || exit 0

found=$(cd "$top" && bash "$here/claims.sh" --issue "$issue" 2>/dev/null)
status=$?

if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
	json_out '{"systemMessage": message}' \
		"merge-coordinator: could not check whether issue #$issue is claimed, so the worktree goes ahead. The issue claim check on the pull request still applies." ||
		true
	exit 0
fi

worktrees=$(cd "$top" && mc_worktrees)
claims=""
mentions=""
while IFS=$'\t' read -r kind number branch state updated part_of; do
	[ -n "$kind" ] || continue
	session=$(mc_session_state "$branch" "$worktrees")
	line="  #$number  $state  branch $branch  updated $updated  session: $session"
	[ "$part_of" = "-" ] || line="$line  ($part_of)"
	case "$kind" in
	claim) claims="$claims$line
" ;;
	mention) mentions="$mentions$line
" ;;
	esac
done <<EOF
$found
EOF

if [ "$status" -eq 0 ]; then
	if [ -n "$mentions" ]; then
		json_out '{"systemMessage": message}' \
			"merge-coordinator: no open pull request claims issue #$issue. These name it in their title:
$mentions" || true
	fi
	exit 0
fi

json_out '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": message}}' \
	"Refused: issue #$issue is already claimed by an open pull request:
$claims
Another session may be working on it now. Before you start:
- Read that pull request. If its session is live, ask it (ListAgents, then SendMessage), or ask the user.
- To take over its work on this machine, enter its worktree: EnterWorktree with path set to that worktree.
- If your work is planned beside it (a plan, a later phase), name the worktree without the issue number. Then run: bash $here/register.sh --issue $issue --part-of <that number>

The issue claim check on GitHub enforces the same rule for every agent." || exit 0
exit 0
