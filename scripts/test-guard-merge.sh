#!/usr/bin/env bash
# Tests guard-merge.sh — the PreToolUse hook that closes the shortcut.
#
# A hook has two ways to be wrong and only one of them is visible. Denying too
# much is loud and gets fixed in a minute. Allowing too much is silent, and the
# thing it lets through is the merge that skipped every check. So the cases here
# are mostly about what must be DENIED, and the allow cases are all about the
# doors that have to stay open: the sanctioned script, the override, and every
# command that is not a merge at all.
#
# gh is stubbed on PATH, so nothing here touches the network.
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

here=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$here/guard-merge.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Run from the scratch folder, never from scripts/. When neither the payload's
# folder nor the project folder is a repository, the guard falls back to the
# folder it runs in, and this repository has adopted its own plugin: from
# scripts/ a case meant to have no config would be judged by this repository's.
cd "$WORK"

pass=0
fail=0

mkdir -p "$WORK/proj/.github" "$WORK/bin"
cat >"$WORK/proj/.github/merge-coordinator.json" <<'JSON'
{
  "repo": "example/repo",
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" }
}
JSON

# A stub gh. GH_LABELS decides what it reports; GH_FAIL makes the lookup fail.
# GH_LOG, when set, collects every call it gets.
# Another repository's config, read from GitHub, is $GH_REMOTES/OWNER__NAME.json,
# sent raw only when the raw Accept header asks for it, as GitHub does; no file
# answers 404, and GH_REMOTE_FAIL_FOR=OWNER/NAME answers a server error;
# GH_SLEEP=N makes it take N seconds first. The repository itself is visible to
# this account when it has a config there or an OWNER__NAME.visible file, and
# GH_VIS_FAIL makes that lookup fail outright. Names are looked up in lower
# case, as GitHub does: the filesystem ignores case on Windows and not on
# Linux, and the same test must mean the same thing on both.
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ -n "${GH_LOG:-}" ]; then printf '%s\n' "$*" >>"$GH_LOG"; fi
case "$*" in
*contents/.github/merge-coordinator.json*)
	if [ -n "${GH_SLEEP:-}" ]; then sleep "$GH_SLEEP"; fi
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
	if [ -n "${GH_VIS_FAIL:-}" ]; then echo "gh: connection reset by peer" >&2; exit 1; fi
	f="$GH_REMOTES/$(printf '%s' "$*" | sed -E 's#.*repos/([^/ ]+)/([^/ ]+).*#\1__\2#' | tr '[:upper:]' '[:lower:]')"
	if [ -f "$f.json" ] || [ -f "$f.visible" ]; then echo "repo"; exit 0; fi
	echo "gh: Not Found (HTTP 404)" >&2
	exit 1
	;;
esac
if [ -n "${GH_LABELS_SLEEP:-}" ]; then sleep "$GH_LABELS_SLEEP"; fi
if [ -n "${GH_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "${GH_LABELS:-}"
SH
chmod +x "$WORK/bin/gh"
export GH_REMOTES="$WORK/remotes"
mkdir -p "$GH_REMOTES"
# Its own landing label, unlike the session repository's: a guard that judged
# this repository's pull request by the session's config would read the wrong one.
cat >"$GH_REMOTES/other__adopted.json" <<'JSON'
{
  "repo": "other/adopted",
  "labels": { "landing": "mc:landing", "blocked": "mc:blocked", "needsRebase": "mc:needs-rebase" }
}
JSON
touch "$GH_REMOTES/other__plain.visible" "$GH_REMOTES/other__app2.visible"
# A fork carrying its parent's config, and a config that came back empty.
cp "$GH_REMOTES/other__adopted.json" "$GH_REMOTES/fork__adopted.json"
: >"$GH_REMOTES/other__empty.json"

# decide <command> — prints ALLOW or the deny reason.
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
# 1. Commands that are not a merge must pass straight through. This hook runs
#    on every Bash call in the session; a false deny here is unusable.
# --------------------------------------------------------------------------
export GH_LABELS=""
allows "an unrelated command is untouched" "ls -la"
allows "a git command is untouched" "git status"
allows "reading a PR is untouched" "gh pr view 7 --json title"
allows "listing PRs is untouched" "gh pr list --state open"
allows "the word merge in prose is untouched" "grep -rn 'merge queue' docs/"

# --------------------------------------------------------------------------
# 2. A bare merge of a PR that holds no claim is the case this exists for.
# --------------------------------------------------------------------------
export GH_LABELS="size:S,area:infra"
denies "a bare merge is refused" "gh pr merge 7 --squash" "does not hold"
denies "the refusal points at the command that does work" "gh pr merge 7 --squash" "/merge-land 7"
denies "an --admin merge is refused too" "gh pr merge 7 --squash --admin" "MERGE_COORDINATOR_OVERRIDE=1"
denies "the REST merge endpoint is refused" "gh api --method PUT repos/example/repo/pulls/7/merge" "does not hold"

# --------------------------------------------------------------------------
# 3. The doors that stay open.
# --------------------------------------------------------------------------
export GH_LABELS="merge:landing"
allows "a PR holding the claim may merge" "gh pr merge 7 --squash"

export GH_LABELS="size:S"
allows "the landing script itself is never blocked" "bash .claude/skills/merge-coordinator/scripts/land.sh 7"
allows "the override prefix breaks the glass" "MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 --squash --admin"
allows "and exported before the call" "export MERGE_COORDINATOR_OVERRIDE=1; gh pr merge 7 --squash"
# Text that names the sanctioned path or the override excuses nothing.
denies "the override inside a --body is text" "gh pr merge 7 --squash --body \"MERGE_COORDINATOR_OVERRIDE=1\"" "does not hold"
denies "land.sh inside a --body is text" "gh pr merge 7 --squash --body \"skipped land.sh\"" "does not hold"

# --------------------------------------------------------------------------
# 4. Fail closed. A guard that cannot look must not answer as though it looked.
# --------------------------------------------------------------------------
export GH_FAIL=1
denies "an unreadable label list refuses" "gh pr merge 7 --squash" "could not look"
unset GH_FAIL
GH_LABELS_SLEEP=3 MC_GH_TIMEOUT=1 denies "a label list that does not arrive in time refuses" "gh pr merge 7 --squash" "could not look"

export GH_LABELS="size:S"
denies "a merge with no readable PR number refuses" "gh pr merge --squash" "could not read which one"

# --------------------------------------------------------------------------
# 5. A repository that does not use this plugin must not be policed by it.
# --------------------------------------------------------------------------
mv "$WORK/proj/.github/merge-coordinator.json" "$WORK/config-away.json"
allows "a repo with no config is left alone" "gh pr merge 7 --squash"
mv "$WORK/config-away.json" "$WORK/proj/.github/merge-coordinator.json"

# A config missing the keys it needs is NOT the same as no config: something is
# half-set-up, and guessing which half is the dangerous move.
cat >"$WORK/proj/.github/merge-coordinator.json" <<'JSON'
{ "defaultBranch": "main" }
JSON
denies "a config missing its keys refuses rather than guessing" "gh pr merge 7 --squash" "labels.landing"

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
export GH_LABELS="size:S"
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/repo"
denies "a session that began above the checkout still guards a command inside it" "gh pr merge 7 --squash" "does not hold"
# The first git repository decides. A command running in a repository with no
# config is not judged by a config sitting in the session folder: one
# repository's rules never apply to another's work.
export DECIDE_PROJECT="$WORK/adopted" DECIDE_CWD="$WORK/plain"
allows "a command in an unadopted repository is not judged by another folder's config" "gh pr merge 7 --squash"
# A plugin missing its helper is broken, and broken must not read as allowed.
cp "$here/guard-merge.sh" "$WORK/broken/scripts/guard-merge.sh"
export DECIDE_PROJECT="$WORK/outer" DECIDE_CWD="$WORK/repo" DECIDE_SCRIPT="$WORK/broken/scripts/guard-merge.sh"
denies "a plugin missing lib/hook-repo.sh refuses instead of waving the command through" "gh pr merge 7 --squash" "hook-repo.sh"
allows "and break glass still goes through it" "MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 --squash"
unset DECIDE_PROJECT DECIDE_CWD DECIDE_SCRIPT

# --------------------------------------------------------------------------
# Which repository, part two: the one the command ACTS on. A `cd` inside the
# command, gh's -R, a pull request URL and GH_REPO all point it away from
# where it starts. [11 Oct 2026] Reading only the starting folder, the guard
# judged a merge in another repository by the session's rules, and let
# `-R <adopted>` from an unadopted folder through without looking.
# lib/cmd_target.py's own suite covers the reading; these cover what the guard
# does with it.
# --------------------------------------------------------------------------
export GH_LABELS="size:S" DECIDE_PROJECT="$WORK/repo" DECIDE_CWD="$WORK/repo"
allows "-R into a repository that has not adopted it is not judged by the session's config" "gh pr merge 5 --squash --admin -R other/plain"
allows "--repo= is read the same way" "gh pr merge 5 --squash --repo=other/plain"
allows "a name with a digit in it is read whole" "gh pr merge 15 -R other/app2"
allows "a REST merge in an unadopted repository is not judged by the session's config" "gh api --method PUT repos/other/plain/pulls/5/merge"
denies "-R into an adopted repository is judged by that repository's config" "gh pr merge -R other/adopted 5 --squash" "does not hold the 'mc:landing' claim"
# The session repository's landing label means nothing over there.
export GH_LABELS="merge:landing"
denies "the session's landing label does not let another repository's PR merge" "gh pr merge 5 -R other/adopted" "does not hold the 'mc:landing' claim"
export GH_LABELS="mc:landing" GH_LOG="$WORK/gh-calls"
: >"$GH_LOG"
allows "and a PR there holding that repository's claim may merge" "gh pr merge 5 -R other/adopted"
calls=$(cat "$GH_LOG")
if contains "$calls" "repos/other/adopted/issues/5/labels" && ! contains "$calls" "repos/example/repo/issues"; then
	echo "ok: the labels read are that repository's pull request's"; pass=$((pass + 1))
else
	echo "FAIL: the labels read are that repository's pull request's"; printf '%s\n' "$calls" | sed 's/^/    /'; fail=$((fail + 1))
fi
unset GH_LOG
export GH_LABELS="size:S" GH_REMOTE_FAIL_FOR="other/adopted"
denies "a target whose config could not be read refuses" "gh pr merge 5 -R other/adopted" "could not read whether other/adopted uses it"
export GH_REMOTE_FAIL_FOR="example/repo"
denies "-R naming the session's own repository uses the local config, without asking GitHub" "gh pr merge 7 -R example/repo" "does not hold"
denies "and in another case" "gh pr merge 7 -R Example/Repo" "does not hold"
# 0.3.2's first draft let these two through inside an adopted repository:
# -R github.com/OWNER/NAME, and a REST read of another repository earlier in
# the line.
denies "-R github.com/OWNER/NAME names the repository, not github.com/OWNER" "gh pr merge 7 -R github.com/example/repo" "does not hold"
unset GH_REMOTE_FAIL_FOR
denies "a REST read of another repository earlier in the line does not move the merge" "gh api repos/other/plain/pulls/3 --jq .title && gh pr merge 7 --squash" "does not hold"
# A quoted value before gh is still an assignment, not the command's name.
denies "a quoted variable before gh does not hide the merge" "FOO=\"a b\" gh pr merge 7" "does not hold"
denies "another repository's name in another case reads that repository's config" "gh pr merge 5 -R Other/Adopted" "does not hold the 'mc:landing' claim"
# A GitHub that does not answer: the hook's own deadline refuses before Claude
# Code's would let the command through.
GH_SLEEP=3 MC_GH_TIMEOUT=1 denies "a config that does not arrive in time refuses" "gh pr merge 5 -R other/adopted" "did not answer within 1 seconds"
GH_VIS_FAIL=1 denies "a failed visibility check says what failed" "gh pr merge 5 -R other/nope" "connection reset"
# gh reads GH_REPO and GH_HOST from the session's environment, which the hook shares.
GH_REPO=other/adopted denies "GH_REPO set for the session points a bare merge there" "gh pr merge 5" "does not hold the 'mc:landing' claim"
GH_HOST=ghe.example.com denies "GH_HOST set for the session refuses" "gh pr merge 5" "GH_HOST=ghe.example.com"
denies "a -R on another command in the line is not taken for the merge's" "gh pr view -R other/plain 3 && gh pr merge 7 --squash" "does not hold"
denies "a -R inside the body is text" "gh pr merge 7 --squash --body \"tested with -R other/plain\"" "does not hold"
# 404 is "not adopted" only for a repository GitHub shows this account.
denies "a 404 for a repository this account cannot see refuses" "gh pr merge 5 -R other/nope" "no repository by that name"
denies "a config naming another repository is not this one's" "gh pr merge 5 -R fork/adopted" "names other/adopted"
denies "a config that comes back empty refuses" "gh pr merge 5 -R other/empty" "came back empty"
# The forms the guard does not read refuse, and say what it does read.
denies "a cd the guard does not follow refuses" "pushd $WORK/plain && gh pr merge 5" "It reads -R OWNER/NAME"
denies "gh run through another command refuses" "sudo gh pr merge 5 -R other/plain" "through sudo"
denies "a merge in a string a shell runs refuses" "bash -c 'gh pr merge 5 -R other/plain'" "string"
allows "a merge named in a commit message is text" "git commit -m 'gh pr merge 5 is refused here'"
allows "a leading cd into an unadopted repository moves the command there" "cd $WORK/plain && gh pr merge 5 --squash"
allows "a relative cd is read against where the command starts" "cd ../plain && gh pr merge 5"
allows "and a single-quoted one" "cd '$WORK/plain' && gh pr merge 5"
HOME="$WORK" allows "and one from the home folder" "cd ~/plain && gh pr merge 5"
# After a cd, the start folder is somewhere the command no longer is.
allows "a cd out of the repository leaves its config behind" "cd $WORK/outer && gh pr merge 5"
denies "a cd into a folder that is not here refuses" "cd $WORK/missing && gh pr merge 5" "not a folder here"
export DECIDE_PROJECT="$WORK/plain" DECIDE_CWD="$WORK/plain"
denies "-R into an adopted repository from an unadopted folder is still guarded" "gh pr merge 5 -R other/adopted --squash" "does not hold"
denies "a pull request URL into an adopted repository is guarded" "gh pr merge https://github.com/other/adopted/pull/5" "does not hold"
denies "GH_REPO into an adopted repository is guarded" "GH_REPO=other/adopted gh pr merge 5" "does not hold"
denies "-R between pr and merge is read" "gh pr -R other/adopted merge 5" "does not hold"
denies "-R before pr is read" "gh -R other/adopted pr merge 5" "does not hold the 'mc:landing' claim"
denies "a quoted GH_REPO into an adopted repository is guarded" 'GH_REPO="other/adopted" gh pr merge 5' "does not hold"
denies "gh behind a wrapper nobody listed refuses" "winpty gh pr merge 5 -R other/adopted" "through winpty"
denies "a merge piped into a shell refuses" "echo 'gh pr merge 5 -R other/adopted' | bash" "string"
denies "a leading cd into an adopted repository is guarded" "cd \"$WORK/repo\" && gh pr merge 5 --squash" "does not hold"
HOME="$WORK" denies "and from the home folder" "cd ~/repo && gh pr merge 5" "does not hold"
unset DECIDE_PROJECT DECIDE_CWD

# A plugin missing the command reader cannot tell which repository: refused.
mkdir -p "$WORK/noreader/scripts/lib"
cp "$here/guard-merge.sh" "$WORK/noreader/scripts/guard-merge.sh"
cp "$here/lib/hook-repo.sh" "$WORK/noreader/scripts/lib/hook-repo.sh"
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-merge.sh" denies "a plugin missing lib/cmd_target.py refuses" "gh pr merge 7 --squash" "cmd_target.py"
# A reader that crashes refuses, and says what broke.
printf 'raise RuntimeError("reader broke here")\n' >"$WORK/noreader/scripts/lib/cmd_target.py"
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-merge.sh" denies "a reader that crashes refuses and names the error" "gh pr merge 7 --squash" "reader broke here"
# Break glass is the way past a broken coordinator, so the raw text decides it.
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-merge.sh" allows "break glass still works when the reader crashes" "MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 --squash"
# A reader that answers without found= is out of step: refused, not "no call".
printf 'print("status=ok")\n' >"$WORK/noreader/scripts/lib/cmd_target.py"
DECIDE_SCRIPT="$WORK/noreader/scripts/guard-merge.sh" denies "a reader answer with no found= line refuses" "gh pr merge 7 --squash" "gave no answer"

# A config fetched from GitHub is a temporary file, and it is removed.
mkdir -p "$WORK/tmpd"
TMPDIR="$WORK/tmpd" GH_LABELS="mc:landing" allows "a fetched config is used" "gh pr merge 5 -R other/adopted"
left=$(ls -A "$WORK/tmpd")
if [ -z "$left" ]; then
	echo "ok: the fetched config's temporary file is removed"; pass=$((pass + 1))
else
	echo "FAIL: the fetched config's temporary file is removed (left: $left)"; fail=$((fail + 1))
fi

# --------------------------------------------------------------------------
# Break glass names THIS repository's out-of-queue workflows, from its config.
# It used to print two workflow names that exist in one repository only.
# --------------------------------------------------------------------------
glass() {
	printf '{"tool_name":"Bash","tool_input":{"command":"MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 --squash"}}' |
		PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$1" bash "$SCRIPT" 2>&1 >/dev/null
}
mkdir -p "$WORK/glass/.github" "$WORK/noqueue/.github"
printf '{"repo":"example/repo","defaultBranch":"trunk","outOfQueueCi":["build.yml","scan.yml"]}' >"$WORK/glass/.github/merge-coordinator.json"
printf '{"repo":"example/repo","defaultBranch":"main"}' >"$WORK/noqueue/.github/merge-coordinator.json"
said=$(glass "$WORK/glass")
if contains "$said" "gh workflow run build.yml --ref trunk" && contains "$said" "gh workflow run scan.yml --ref trunk"; then
	echo "ok: break glass names the repository's own out-of-queue workflows"; pass=$((pass + 1))
else
	echo "FAIL: break glass names the repository's own out-of-queue workflows"; printf '%s
' "$said" | sed 's/^/    /'; fail=$((fail + 1))
fi
said=$(glass "$WORK/noqueue")
if contains "$said" "workflow run"; then
	echo "FAIL: with no outOfQueueCi, break glass asks for no workflow"; printf '%s
' "$said" | sed 's/^/    /'; fail=$((fail + 1))
else
	echo "ok: with no outOfQueueCi, break glass asks for no workflow"; pass=$((pass + 1))
fi

# The list is the one of the repository the merge acts on: a -R merge into an
# unadopted repository asks for none of the session repository's workflows.
said=$(printf '{"tool_name":"Bash","tool_input":{"command":"MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 -R other/plain"}}' |
	PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$WORK/glass" bash "$SCRIPT" 2>&1 >/dev/null)
if [ -z "$said" ]; then
	echo "ok: break glass into an unadopted repository says nothing"; pass=$((pass + 1))
else
	echo "FAIL: break glass into an unadopted repository says nothing"; printf '%s\n' "$said" | sed 's/^/    /'; fail=$((fail + 1))
fi

# And it names that repository's own, read from GitHub.
printf '{"repo":"other/glassy","defaultBranch":"dev","outOfQueueCi":["remote.yml"],"labels":{"landing":"mc:landing"}}' >"$GH_REMOTES/other__glassy.json"
glass_at() {
	printf '{"tool_name":"Bash","tool_input":{"command":"MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7 -R %s"}}' "$1" |
		PATH="$WORK/bin:$PATH" CLAUDE_PROJECT_DIR="$WORK/glass" bash "$SCRIPT" 2>&1 >/dev/null
}
said=$(glass_at other/glassy)
if contains "$said" "gh workflow run remote.yml --ref dev --repo other/glassy" && ! contains "$said" "build.yml"; then
	echo "ok: break glass into another repository names that repository's workflows"; pass=$((pass + 1))
else
	echo "FAIL: break glass into another repository names that repository's workflows"; printf '%s\n' "$said" | sed 's/^/    /'; fail=$((fail + 1))
fi
said=$(GH_REMOTE_FAIL_FOR=other/glassy glass_at other/glassy)
if contains "$said" "could not read whether other/glassy uses it" && contains "$said" "outOfQueueCi" && ! contains "$said" "workflow run"; then
	echo "ok: break glass says when it could not read the target's config"; pass=$((pass + 1))
else
	echo "FAIL: break glass says when it could not read the target's config"; printf '%s\n' "$said" | sed 's/^/    /'; fail=$((fail + 1))
fi

echo
echo "test-guard-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
