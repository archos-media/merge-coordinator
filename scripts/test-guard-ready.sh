#!/usr/bin/env bash
# Tests guard-ready.sh — the PreToolUse hook that keeps a second session from
# starting CI behind the first.
#
# Same weighting as test-guard-merge.sh, for the same reason: denying too much
# is loud and gets fixed in a minute, allowing too much is silent. So most of
# these are about what must be REFUSED, and the allow cases are the doors that
# have to stay open — the sanctioned script, the override, going back TO draft,
# and every command that is not about readiness at all.
#
# overlap.sh is stubbed by copying the hook into a throwaway directory beside a
# fake one, because the hook finds it relative to itself. gh is stubbed on PATH.
# Nothing here touches the network.
set -euo pipefail

# contains <haystack> <needle> — substring test, done in the shell. Never
# `printf | grep -q`: grep exits at its match, printf dies of SIGPIPE, and under
# pipefail a found string arrives as status 141. In a "must NOT appear" helper
# that is an assertion that cannot fail.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

here=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Run from the scratch folder, never from scripts/. When neither the payload's
# folder nor the project folder is a repository, the guard falls back to the
# folder it runs in, and this repository has adopted its own plugin: from
# scripts/ a case meant to have no config would be judged by this repository's.
cd "$WORK"

pass=0
fail=0

mkdir -p "$WORK/plugin/scripts/lib" "$WORK/proj/.github" "$WORK/bin"
cp "$here/guard-ready.sh" "$WORK/plugin/scripts/guard-ready.sh"
cp "$here/lib/hook-repo.sh" "$WORK/plugin/scripts/lib/hook-repo.sh"
cp "$here/lib/cmd_target.py" "$WORK/plugin/scripts/lib/cmd_target.py"
SCRIPT="$WORK/plugin/scripts/guard-ready.sh"

cat >"$WORK/proj/.github/merge-coordinator.json" <<'JSON'
{
  "repo": "example/repo",
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" }
}
JSON

# The fake analysis. AHEAD_STATUS is the contract; AHEAD_LIST is the detail.
cat >"$WORK/plugin/scripts/overlap.sh" <<'SH'
#!/usr/bin/env bash
# The config it was handed, when it was handed one: OVERLAP_SAW records it.
if [ -n "${OVERLAP_SAW:-}" ] && [ -n "${MC_CONFIG:-}" ]; then cat "$MC_CONFIG" >"$OVERLAP_SAW"; fi
# Which checkout it ran in, by the marker file each test checkout holds.
if [ -n "${OVERLAP_WHERE:-}" ]; then cat .marker >"$OVERLAP_WHERE" 2>/dev/null || echo none >"$OVERLAP_WHERE"; fi
if [ -n "${OVERLAP_SLEEP:-}" ]; then sleep "$OVERLAP_SLEEP"; fi
if [ -n "${AHEAD_LIST:-}" ]; then printf '%s\n' "$AHEAD_LIST"; fi
exit "${AHEAD_STATUS:-0}"
SH
chmod +x "$WORK/plugin/scripts/overlap.sh"

# The fake Dependabot lister. DEPS_STATUS is the contract; DEPS_ROWS are
# rows in deps-open.sh's format. By default nothing is open.
cat >"$WORK/plugin/scripts/deps-open.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${DEPS_ARGS:-}" ]; then printf '%s\n' "$*" >"$DEPS_ARGS"; fi
if [ -n "${DEPS_SLEEP:-}" ]; then sleep "$DEPS_SLEEP"; fi
if [ -n "${DEPS_ROWS:-}" ]; then printf '%s\n' "$DEPS_ROWS"; fi
exit "${DEPS_STATUS:-0}"
SH

# A stub gh, for the `gh pr ready` with no number path. GH_LOG, when set,
# collects every call it gets. Another repository's config, read from GitHub,
# is $GH_REMOTES/OWNER__NAME.json, sent raw only when the raw Accept header asks
# for it, as GitHub does; no file answers 404, and GH_REMOTE_FAIL_FOR=OWNER/NAME
# answers a server error. The repository itself is visible to this account when
# it has a config there or an OWNER__NAME.visible file.
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ -n "${GH_LOG:-}" ]; then printf '%s\n' "$*" >>"$GH_LOG"; fi
case "$*" in
*contents/.github/merge-coordinator.json*)
	case "$*" in *"repos/${GH_REMOTE_FAIL_FOR:-none}/"*) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;; esac
	f="$GH_REMOTES/$(printf '%s' "$*" | sed -E 's#.*repos/([^/]+)/([^/]+)/contents.*#\1__\2#' | tr '[:upper:]' '[:lower:]').json"
	if [ -f "$f" ]; then
		case "$*" in
		*"Accept: application/vnd.github.raw+json"*) cat "$f" ;;
		*) printf '{"type":"file","encoding":"base64","content":"%s"}' "$(base64 <"$f" | tr -d '\n')" ;;
		esac
		exit 0
	fi
	echo "gh: Not Found (HTTP 404)" >&2
	exit 1
	;;
*"--jq .full_name"*)
	f="$GH_REMOTES/$(printf '%s' "$*" | sed -E 's#.*repos/([^/ ]+)/([^/ ]+).*#\1__\2#' | tr '[:upper:]' '[:lower:]')"
	if [ -f "$f.json" ] || [ -f "$f.visible" ]; then echo "repo"; exit 0; fi
	echo "gh: Not Found (HTTP 404)" >&2
	exit 1
	;;
esac
if [ -n "${GH_VIEW_SLEEP:-}" ]; then sleep "$GH_VIEW_SLEEP"; fi
if [ -n "${GH_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "${GH_PR_NUMBER:-}"
SH
chmod +x "$WORK/bin/gh"
export GH_REMOTES="$WORK/remotes"
mkdir -p "$GH_REMOTES"
cat >"$GH_REMOTES/other__adopted.json" <<'JSON'
{
  "repo": "other/adopted",
  "labels": { "landing": "mc:landing", "blocked": "mc:blocked", "needsRebase": "mc:needs-rebase" }
}
JSON
touch "$GH_REMOTES/other__plain.visible"

decide() {
	local cmd="$1" payload out
	payload=$(MC_CMD="$cmd" python -c '
import json, os, sys
sys.stdout.write(json.dumps({"tool_name": "Bash",
                             "cwd": os.environ.get("DECIDE_CWD", "/x"),
                             "tool_input": {"command": os.environ["MC_CMD"]}}))
' 2>/dev/null || MC_CMD="$cmd" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"tool_name": "Bash",
                             "cwd": os.environ.get("DECIDE_CWD", "/x"),
                             "tool_input": {"command": os.environ["MC_CMD"]}}))
')
	out=$(printf '%s' "$payload" |
		PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="${DECIDE_PROJECT:-$WORK/proj}" bash "${DECIDE_SCRIPT:-$SCRIPT}" 2>/dev/null)
	if [ -z "$out" ]; then
		echo "ALLOW"
	else
		printf '%s' "$out"
	fi
}

allows() {
	local name="$1" cmd="$2" got
	got=$(decide "$cmd")
	if [ "$got" = "ALLOW" ]; then
		echo "ok: $name"
		pass=$((pass + 1))
	else
		echo "FAIL: $name — it was denied and should not have been"
		printf '%s\n' "$got" | sed 's/^/    /'
		fail=$((fail + 1))
	fi
}

denies() {
	local name="$1" cmd="$2" want="${3:-}" got
	got=$(decide "$cmd")
	if [ "$got" = "ALLOW" ]; then
		echo "FAIL: $name — it was allowed through"
		fail=$((fail + 1))
		return
	fi
	if ! contains "$got" '"permissionDecision": "deny"'; then
		echo "FAIL: $name — output is not a deny decision"
		printf '%s\n' "$got" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	if [ -n "$want" ] && ! contains "$got" "$want"; then
		echo "FAIL: $name — the reason did not mention: $want"
		printf '%s\n' "$got" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# --------------------------------------------------------------------------
# Commands this hook has no business touching.
# --------------------------------------------------------------------------
export AHEAD_STATUS=1 AHEAD_LIST="90"
allows "an ordinary command is untouched" "go test ./..."
allows "a merge is guard-merge.sh's business, not this one" "gh pr merge 1071 --squash"
allows "reading a pull request is not readying it" "gh pr view 1071 --json isDraft"
allows "the word ready in prose is not a command" "echo 'the branch is ready to land'"

# --------------------------------------------------------------------------
# The line is clear.
# --------------------------------------------------------------------------
export AHEAD_STATUS=0 AHEAD_LIST=""
allows "nothing ahead lets it through" "gh pr ready 1071"
GH_PR_NUMBER=1071 allows "and with no number, resolved from the branch" "gh pr ready"

# --------------------------------------------------------------------------
# Somebody is ahead.
# --------------------------------------------------------------------------
export AHEAD_STATUS=1 AHEAD_LIST="90"
denies "one pull request ahead is refused" "gh pr ready 1071" "#90"
denies "and the refusal names the pull request being held" "gh pr ready 1071" "#1071"

export AHEAD_LIST="90
91"
denies "several ahead are all named" "gh pr ready 1071" "#90 #91"

# --------------------------------------------------------------------------
# Could not tell. This is the case that must never read as "clear".
# --------------------------------------------------------------------------
export AHEAD_STATUS=3 AHEAD_LIST=""
denies "an analysis that could not answer is refused" "gh pr ready 1071" "could not look"

export AHEAD_STATUS=2 AHEAD_LIST=""
denies "an exit code nobody predicted is refused" "gh pr ready 1071" "could not look"

# Exit 1 is the "somebody is ahead" code, so an empty list alongside it means
# the two halves disagree. Refuse rather than name nobody.
export AHEAD_STATUS=1 AHEAD_LIST=""
denies "ahead-with-nobody-named is refused, not waved through" "gh pr ready 1071" "could not look"

export AHEAD_STATUS=0 AHEAD_LIST=""
GH_FAIL=1 denies "a pull request number that cannot be resolved is refused" "gh pr ready" "could not read which"
GH_VIEW_SLEEP=3 MC_GH_TIMEOUT=1 GH_PR_NUMBER=1071 denies "and one that does not arrive in time" "gh pr ready" "could not read which"

# --------------------------------------------------------------------------
# The doors that stay open.
# --------------------------------------------------------------------------
export AHEAD_STATUS=1 AHEAD_LIST="90"
allows "break glass" "MERGE_COORDINATOR_OVERRIDE=1 gh pr ready 1071"
allows "the sanctioned script" "bash .claude/skills/merge-coordinator/scripts/ready.sh 1071"
allows "going back TO draft is never in the way" "gh pr ready 1071 --undo"
denies "--undo=false is not going back" "gh pr ready 1071 --undo=false" "#90"
denies "nor is --undo=0" "gh pr ready 1071 --undo=0" "#90"
denies "-R before pr is read" "gh -R example/repo pr ready 1071" "#90"
# Text that names the sanctioned path or the override excuses nothing.
denies "the override inside a --body is text" "gh pr create --title x --body \"MERGE_COORDINATOR_OVERRIDE=1\"" "--draft"
denies "ready.sh inside a --body is text" "gh pr create --title x --body \"Then run ready.sh\"" "--draft"
# An overlap.sh that does not answer in time refuses, before the hook's own
# timeout would let the call through.
AHEAD_STATUS=0 OVERLAP_SLEEP=3 MC_OVERLAP_TIMEOUT=1 denies "an analysis that does not finish in time is refused" "gh pr ready 1071" "could not look"
# Nor in a form the guard does not read: a draft and --undo start no CI
# wherever they act, so there is nothing to refuse.
allows "an --undo after a cd the guard does not follow" "cd /x; gh pr ready 1071 --undo"
allows "a draft behind a wrapper" "timeout 60 gh pr create --draft --title x"
allows "a draft after a cd the guard does not follow" "cd /x; gh pr create --draft --title x"

# --------------------------------------------------------------------------
# gh pr create. No pull request exists yet, so the rule is flat: draft it.
# --------------------------------------------------------------------------
export AHEAD_STATUS=0 AHEAD_LIST=""
denies "creating a ready pull request is refused" "gh pr create --title x --body y" "--draft"
denies "and through its alias, gh pr new" "gh pr new --title x --body y" "--draft"
denies "a --draft=0 is not a draft" "gh pr create --title x --draft=0" "--draft"
allows "creating a draft is the encouraged path" "gh pr create --draft --title x --body y"
allows "a trailing --draft still counts" "gh pr create --title x --body y --draft"
allows "and the short form" "gh pr create --title x -d"
denies "a quoted variable before gh does not hide a ready create" "FOO=\"x\" gh pr create --title t" "--draft"
# A --draft inside the body is text: this opens a ready pull request.
denies "a --draft inside the body is not the flag" "gh pr create --title x --body \"open it with --draft next time\"" "--draft"
denies "nor is a title that reads --draft" "gh pr create --title --draft --body y" "--draft"

# --------------------------------------------------------------------------
# Which repository: the one the command RUNS in, not the folder the session
# began in. [7 Oct 2026] Sessions that start in a folder above the checkout
# have no config at CLAUDE_PROJECT_DIR, and this guard read that as "not
# adopted" and let the command through in silence. lib/hook-repo.sh.
# --------------------------------------------------------------------------
mkdir -p "$WORK/outer" "$WORK/repo/.github" "$WORK/plain" "$WORK/adopted/.github" "$WORK/broken/scripts"
git -C "$WORK/repo" init -q
git -C "$WORK/plain" init -q
cat >"$WORK/repo/.github/merge-coordinator.json" <<'JSON'
{
  "repo": "example/repo",
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" }
}
JSON
cp "$WORK/repo/.github/merge-coordinator.json" "$WORK/adopted/.github/merge-coordinator.json"
echo repo >"$WORK/repo/.marker"
export AHEAD_STATUS=1 AHEAD_LIST="90"
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/repo"
OVERLAP_WHERE="$WORK/overlap-where"
export OVERLAP_WHERE
denies "a session that began above the checkout still guards a command inside it" "gh pr ready 1071" "#90"
where=$(cat "$OVERLAP_WHERE" 2>/dev/null || true)
if [ "$where" = repo ]; then
	echo "ok: overlap.sh runs inside the checkout the command acts on"; pass=$((pass + 1))
else
	echo "FAIL: overlap.sh runs inside the checkout the command acts on (it ran in: ${where:-nothing recorded})"; fail=$((fail + 1))
fi
rm -f "$OVERLAP_WHERE"
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/outer"
denies "a leading cd into the checkout is followed there" "cd $WORK/repo && gh pr ready 1071" "#90"
where=$(cat "$OVERLAP_WHERE" 2>/dev/null || true)
if [ "$where" = repo ]; then
	echo "ok: and overlap.sh runs inside it"; pass=$((pass + 1))
else
	echo "FAIL: and overlap.sh runs inside it (it ran in: ${where:-nothing recorded})"; fail=$((fail + 1))
fi
unset OVERLAP_WHERE
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/repo"
# The first git repository decides. A command running in a repository with no
# config is not judged by a config sitting in the session folder: one
# repository's rules never apply to another's work.
export DECIDE_PROJECT="$WORK/adopted" DECIDE_CWD="$WORK/plain"
allows "a command in an unadopted repository is not judged by another folder's config" "gh pr ready 1071"
# A plugin missing its helper is broken, and broken must not read as allowed.
cp "$here/guard-ready.sh" "$WORK/broken/scripts/guard-ready.sh"
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/repo" DECIDE_SCRIPT="$WORK/broken/scripts/guard-ready.sh"
denies "a plugin missing lib/hook-repo.sh refuses instead of waving the command through" "gh pr ready 1071" "hook-repo.sh"
unset DECIDE_PROJECT DECIDE_CWD DECIDE_SCRIPT

# --------------------------------------------------------------------------
# Which repository, part two: the one the command ACTS on. A `cd` inside the
# command, gh's -R and a pull request URL all point it away from where it
# starts. [11 Oct 2026]
# Reading only the starting folder, the guard asked about the session
# repository's pull request of the same number, could not find it, and refused.
# --------------------------------------------------------------------------
export AHEAD_STATUS=1 AHEAD_LIST="90" DECIDE_PROJECT="$WORK/repo" DECIDE_CWD="$WORK/repo"
allows "-R into a repository that has not adopted it is not judged by the session's config" "gh pr ready 5 -R other/plain"
allows "a ready pull request created in an unadopted repository is not refused" "gh pr create -R other/plain --title x --body y"
allows "a leading cd into an unadopted repository moves the command there" "cd $WORK/plain && gh pr ready 5"
OVERLAP_SAW="$WORK/overlap-saw"
export OVERLAP_SAW
denies "-R into an adopted repository is judged by that repository's line" "gh pr ready -R other/adopted 5" "#90"
saw=$(cat "$OVERLAP_SAW" 2>/dev/null || true)
if contains "$saw" '"repo": "other/adopted"'; then
	echo "ok: overlap.sh is handed the target repository's config"; pass=$((pass + 1))
else
	echo "FAIL: overlap.sh is handed the target repository's config"; printf '%s\n' "$saw" | sed 's/^/    /'; fail=$((fail + 1))
fi
unset OVERLAP_SAW
GH_PR_NUMBER=1071 denies "a pull request in another repository is never resolved from the branch here" "gh pr ready --repo other/adopted" "could not read which"
GH_PR_NUMBER=1071 denies "nor from a branch named here" "gh pr ready my-branch --repo other/adopted" "could not read which"
export GH_REMOTE_FAIL_FOR="other/adopted"
denies "a target whose config could not be read refuses" "gh pr ready 5 -R other/adopted" "could not read whether other/adopted uses it"
unset GH_REMOTE_FAIL_FOR
denies "a 404 for a repository this account cannot see refuses" "gh pr ready 5 -R other/nope" "no repository by that name"
denies "a form the guard does not read refuses" "pushd $WORK/plain && gh pr ready 5" "It reads -R OWNER/NAME"
# A branch named in place of the number is resolved here, by that name.
export AHEAD_STATUS=0 AHEAD_LIST="" GH_PR_NUMBER=1071 GH_LOG="$WORK/gh-calls"
: >"$GH_LOG"
allows "a branch given in place of the number is resolved by name" "gh pr ready my-branch"
calls=$(cat "$GH_LOG")
if contains "$calls" "pr view my-branch --json number"; then
	echo "ok: the branch named is the one looked up"; pass=$((pass + 1))
else
	echo "FAIL: the branch named is the one looked up"; printf '%s\n' "$calls" | sed 's/^/    /'; fail=$((fail + 1))
fi
unset GH_LOG GH_PR_NUMBER
export AHEAD_STATUS=1 AHEAD_LIST="90"
export DECIDE_PROJECT="$WORK/plain" DECIDE_CWD="$WORK/plain"
denies "-R into an adopted repository from an unadopted folder is still guarded" "gh pr ready 5 -R other/adopted" "#90"
denies "-R between pr and ready is read" "gh pr -R other/adopted ready 5" "#90"
denies "a pull request URL into an adopted repository is guarded" "gh pr ready https://github.com/other/adopted/pull/5" "#90"
denies "a ready pull request created in an adopted repository is refused" "gh pr create -R other/adopted --title x --body y" "--draft"
unset DECIDE_PROJECT DECIDE_CWD

# A plugin missing the command reader cannot tell which repository: refused.
mkdir -p "$WORK/noreader/scripts/lib"
cp "$SCRIPT" "$WORK/noreader/scripts/guard-ready.sh"
cp "$here/lib/hook-repo.sh" "$WORK/noreader/scripts/lib/hook-repo.sh"
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-ready.sh" denies "a plugin missing lib/cmd_target.py refuses" "gh pr ready 1071" "cmd_target.py"
# Break glass is the way past a broken coordinator, so the raw text decides it.
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-ready.sh" allows "break glass still works when the reader is missing" "MERGE_COORDINATOR_OVERRIDE=1 gh pr ready 1071"

# --------------------------------------------------------------------------
# The Dependabot gate, for a raw `gh pr ready`. A raw command has no
# --skip-deps, so the refusal points at ready.sh, which has.
# --------------------------------------------------------------------------
T=$(printf '\t')
export AHEAD_STATUS=0 AHEAD_LIST=""
export DEPS_ROWS="90${T}waiting${T}3 days${T}passed${T}-${T}Bump x from 1.0.0 to 1.0.1"
export DEPS_ARGS="$WORK/deps-args"
denies "a waiting Dependabot pull request refuses it" "gh pr ready 1071" "Dependabot pull request(s) waiting: #90"
if [ "$(cat "$DEPS_ARGS" 2>/dev/null)" = "--no-ci" ]; then
	echo "ok: the guard asks the lister for no CI, which it does not use and cannot wait for"; pass=$((pass + 1))
else
	echo "FAIL: the guard asks the lister for no CI (it passed: $(cat "$DEPS_ARGS" 2>/dev/null))"; fail=$((fail + 1))
fi
unset DEPS_ARGS
denies "and the refusal points at ready.sh --skip-deps for later" "gh pr ready 1071" "ready.sh 1071 --skip-deps"
denies "and at /merge-deps for yes" "gh pr ready 1071" "/merge-deps <number>"
allows "break glass gets past it" "MERGE_COORDINATOR_OVERRIDE=1 gh pr ready 1071"
allows "the Dependabot pull request itself is not refused" "gh pr ready 90"
export DEPS_ROWS="90${T}landing${T}3 days${T}passed${T}-${T}Bump x from 1.0.0 to 1.0.1"
allows "a Dependabot pull request that is landing does not refuse it" "gh pr ready 1071"
export DEPS_ROWS="" DEPS_STATUS=3
denies "a lookup that fails refuses it" "gh pr ready 1071" "could not check the open Dependabot pull requests"
export DEPS_STATUS=0
DEPS_SLEEP=3 MC_DEPS_TIMEOUT=1 denies "a lookup that does not finish in time refuses it" "gh pr ready 1071" "did not finish within 1 seconds"
unset DEPS_ROWS DEPS_STATUS

echo
echo "test-guard-ready: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
