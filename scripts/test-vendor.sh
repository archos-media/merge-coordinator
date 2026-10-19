#!/usr/bin/env bash
# Tests the vendored-copy tooling: vendor.sh, check-vendored.sh,
# guard-vendored-edit.sh and vendor-status.sh.
#
# Every release comes from a local fixture repository with real tags, so
# nothing here touches the network. The cases are mostly about what must be
# CAUGHT — an edited, added or missing file; a branch passed off as a release;
# a stamp that cannot be read — because a drift check that passes too much is
# silent, and silence is what it exists to end.
set -uo pipefail

contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok: $1"; }
bad() {
	fail=$((fail + 1))
	echo "FAIL: $1"
	[ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/    /'
	return 0
}
# expect <name> <status> [needle...] — against $status and $out.
expect() {
	local name="$1" want="$2"
	shift 2
	if [ "$status" != "$want" ]; then
		bad "$name" "exit $status, wanted $want
$out"
		return
	fi
	local n
	for n in "$@"; do
		contains "$out" "$n" || {
			bad "$name" "output did not contain: $n
$out"
			return
		}
	done
	ok "$name"
}
run() {
	out=$("$@" 2>&1)
	status=$?
}
# absent <name> <needle>... — none of the needles is in $out.
absent() {
	local name="$1" n
	shift
	for n in "$@"; do
		if contains "$out" "$n"; then
			bad "$name" "output contained what it must not: $n
$out"
			return
		fi
	done
	ok "$name"
}

# --------------------------------------------------------------------------
# Fixtures: an upstream with two releases and a branch, and a consumer.
# --------------------------------------------------------------------------
UP="$WORK/upstream"
mkdir -p "$UP/scripts"
git -C "$UP" init -q
printf 'one\n' >"$UP/scripts/a.sh"
printf 'readme\n' >"$UP/README.md"
git -C "$UP" add -A && git -C "$UP" commit -qm one && git -C "$UP" tag v0.1.0
printf 'two\n' >"$UP/scripts/a.sh"
printf 'helper\n' >"$UP/scripts/b.sh"
git -C "$UP" add -A && git -C "$UP" commit -qm two && git -C "$UP" tag v0.2.0
up_commit=$(git -C "$UP" rev-parse v0.2.0)
git -C "$UP" branch feature
export MC_VENDOR_SOURCE="$UP"

CONS="$WORK/consumer"
mkdir -p "$CONS"
git -C "$CONS" init -q
printf 'app\n' >"$CONS/app.txt"
git -C "$CONS" add -A && git -C "$CONS" commit -qm base

V="$CONS/tools/merge-coordinator"

# --------------------------------------------------------------------------
# 1. vendor.sh takes a release and records it.
# --------------------------------------------------------------------------
cd "$CONS" || exit 1
run bash "$HERE/vendor.sh" v0.2.0
expect "vendor.sh copies a release tag" 0 "copied v0.2.0" "staged"
if [ -f "$V/scripts/b.sh" ] && [ "$(cat "$V/scripts/a.sh")" = "two" ]; then ok "the copy holds the tagged contents"; else bad "the copy holds the tagged contents" "$(ls -R "$V" 2>&1)"; fi
stamp_commit=$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$CONS/.github/merge-coordinator.vendor" 2>/dev/null ||
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$CONS/.github/merge-coordinator.vendor")
stamp_commit=${stamp_commit%$'\r'}
if [ "$stamp_commit" = "$up_commit" ]; then ok "the stamp records the release commit"; else bad "the stamp records the release commit" "[$stamp_commit] vs [$up_commit]"; fi

run bash "$HERE/check-vendored.sh" --index
expect "the staged copy matches" 0 "matches v0.2.0" "3 files"
git -C "$CONS" commit -qm vendor
run bash "$HERE/check-vendored.sh"
expect "the committed copy matches" 0 "matches v0.2.0"

# --------------------------------------------------------------------------
# 2. Drift of every kind is caught, and named.
# --------------------------------------------------------------------------
printf 'edited\n' >"$V/scripts/a.sh"
git -C "$CONS" commit -qam edit
run bash "$HERE/check-vendored.sh"
expect "an edited file fails the check" 1 "is NOT v0.2.0" "changed  tools/merge-coordinator/scripts/a.sh" "vendor.sh v0.2.0"
git -C "$CONS" reset -q --hard HEAD~1

printf 'new\n' >"$V/scripts/c.sh"
git -C "$CONS" add -A && git -C "$CONS" commit -qm add
run bash "$HERE/check-vendored.sh"
expect "an added file fails the check" 1 "added    tools/merge-coordinator/scripts/c.sh"
git -C "$CONS" reset -q --hard HEAD~1

git -C "$CONS" rm -q "$V/scripts/b.sh" && git -C "$CONS" commit -qm rm
run bash "$HERE/check-vendored.sh"
expect "a missing file fails the check" 1 "missing  tools/merge-coordinator/scripts/b.sh"
git -C "$CONS" reset -q --hard HEAD~1

run bash "$HERE/check-vendored.sh" --ref HEAD~1
expect "--ref checks another commit (one before the copy existed: everything missing)" 1 "missing"

printf 'staged edit\n' >"$V/README.md"
git -C "$CONS" add -A
run bash "$HERE/check-vendored.sh" --index
expect "--index sees a staged edit before it is committed" 1 "changed  tools/merge-coordinator/README.md"
git -C "$CONS" reset -q --hard HEAD

# --------------------------------------------------------------------------
# 3. Could not look is its own answer, never a pass.
# --------------------------------------------------------------------------
run env MC_VENDOR_STAMP="$WORK/nothing-here" bash "$HERE/check-vendored.sh"
expect "no stamp is 'could not look' (2), not clean" 2 "no stamp"
printf '{"path": "tools/merge-coordinator", "files": {}}\n' >"$WORK/empty-stamp"
run env MC_VENDOR_STAMP="$WORK/empty-stamp" bash "$HERE/check-vendored.sh"
expect "a stamp listing no files is 2, not a vacuous pass" 2 "lists no files"
printf 'not json\n' >"$WORK/broken-stamp"
run env MC_VENDOR_STAMP="$WORK/broken-stamp" bash "$HERE/check-vendored.sh"
expect "an unreadable stamp is 2" 2
run bash "$HERE/check-vendored.sh" --ref no-such-rev
expect "a revision that does not exist is 2" 2 "not a commit"

# --------------------------------------------------------------------------
# 4. vendor.sh refuses what would make a copy that moves or double-loads.
# --------------------------------------------------------------------------
run bash "$HERE/vendor.sh" feature
expect "a branch is not a release" 1 "no tag named feature"
run bash "$HERE/vendor.sh" v0.2.0 --dest .claude/skills/merge-coordinator
expect "a copy under .claude/skills is refused" 1 "second plugin"
run bash "$HERE/vendor.sh" v0.2.0 --dest ../outside
expect "a destination outside the repository is refused" 1 "climb out"
run bash "$HERE/vendor.sh"
expect "no tag is a usage error" 1 "usage"
SELF="$WORK/self"
mkdir -p "$SELF/.claude-plugin"
git -C "$SELF" init -q
printf '{"name": "merge-coordinator"}\n' >"$SELF/.claude-plugin/plugin.json"
cd "$SELF" || exit 1
run bash "$HERE/vendor.sh" v0.2.0
expect "the coordinator never vendors itself" 1 "own repository"
cd "$CONS" || exit 1

# The copy's own vendor.sh would delete itself mid-run. The fixture releases
# carry no vendor.sh, so put one where a real copy has it.
cp "$HERE/vendor.sh" "$V/scripts/vendor.sh"
mkdir -p "$V/scripts/lib" && cp "$HERE/lib/gh.sh" "$V/scripts/lib/gh.sh"
run bash "$V/scripts/vendor.sh" v0.1.0
expect "the copy's own vendor.sh refuses to replace the copy" 1 "inside the copy it would replace"
if [ -f "$V/scripts/vendor.sh" ] && [ "$(cat "$V/scripts/a.sh")" = "two" ]; then ok "the refused run left the copy as it was"; else bad "the refused run left the copy as it was" "$(ls -R "$V" 2>&1)"; fi
# The same folder in another letter case is still the copy (Windows only:
# elsewhere the case-changed path is another folder, or none).
# On Linux CI this case does not run, so a text comparison there would pass.
if command -v cygpath >/dev/null 2>&1; then
	lower=$(printf '%s' "$V" | tr '[:upper:]' '[:lower:]')
	lower=$(printf '%s' "$lower" | sed 's#/tools/merge-coordinator$#/TOOLS/merge-coordinator#')
	if [ "$lower" = "$V" ]; then
		bad "the case-variant path differs from the real one" "$lower"
	else
		run bash "$lower/scripts/vendor.sh" v0.1.0
		expect "the copy's own vendor.sh, reached in another letter case, still refuses" 1 "inside the copy it would replace"
	fi
fi
# A folder above the copy is replaced along with it.
run bash "$V/scripts/vendor.sh" v0.1.0 --dest tools
expect "the copy's own vendor.sh refuses to replace a folder holding the copy" 1 "inside the copy it would replace"
if [ -f "$V/scripts/vendor.sh" ]; then ok "the refused run left the folder holding the copy as it was"; else bad "the refused run left the folder holding the copy as it was"; fi
rm -rf "$V/scripts/vendor.sh" "$V/scripts/lib"

# Run from the copy but writing somewhere else, or from a folder whose name
# only starts like the copy's: not the copy it would replace, so allowed. The
# other folder exists, so the guard's comparison really runs.
cp -r "$HERE/." "$V/scripts/"
mkdir -p "$CONS/tools/other"
run bash "$V/scripts/vendor.sh" v0.1.0 --dest tools/other
expect "the copy's vendor.sh may write a copy elsewhere" 0 "copied v0.1.0 (" "into tools/other"
git -C "$CONS" reset -q --hard HEAD && git -C "$CONS" clean -qfd tools
mkdir -p "$CONS/tools/merge-coordinator-old"
cp -r "$HERE" "$CONS/tools/merge-coordinator-old/scripts"
run bash "$CONS/tools/merge-coordinator-old/scripts/vendor.sh" v0.1.0
expect "a vendor.sh beside the copy, not inside it, is allowed" 0 "copied v0.1.0"
git -C "$CONS" reset -q --hard HEAD && git -C "$CONS" clean -qfd tools

# A re-run to an older tag replaces the copy wholesale: b.sh did not exist then.
run bash "$HERE/vendor.sh" v0.1.0
expect "vendor.sh moves a copy to another release" 0 "copied v0.1.0"
if [ ! -e "$V/scripts/b.sh" ]; then ok "a file the release does not have is gone"; else bad "a file the release does not have is gone"; fi
git -C "$CONS" reset -q --hard HEAD

# With no override, releases come from the default source, and the stamp names
# it: vendor-status.sh asks the stamp's source for newer releases. git rewrites
# exactly that URL to the fixture; any other GitHub URL, the old org's
# included, goes to a path that does not exist, so nothing touches the network.
up_url=$(cygpath -m "$UP" 2>/dev/null || printf '%s' "$UP")
nowhere=$(cygpath -m "$WORK/no-network" 2>/dev/null || printf '%s' "$WORK/no-network")
run env -u MC_VENDOR_SOURCE GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="url.$up_url.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/archos-media/merge-coordinator.git" GIT_CONFIG_KEY_1="url.$nowhere/.insteadOf" GIT_CONFIG_VALUE_1="https://github.com/" bash "$HERE/vendor.sh" v0.2.0
expect "with no override, releases come from archos-media" 0 "copied v0.2.0"
stamp_source=$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$CONS/.github/merge-coordinator.vendor" 2>/dev/null ||
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$CONS/.github/merge-coordinator.vendor")
stamp_source=${stamp_source%$'\r'}
if [ "$stamp_source" = "https://github.com/archos-media/merge-coordinator.git" ]; then ok "the stamp records the default source"; else bad "the stamp records the default source" "[$stamp_source]"; fi
git -C "$CONS" reset -q --hard HEAD

# --------------------------------------------------------------------------
# 5. guard-vendored-edit.sh refuses an edit inside the copy, and only there.
# --------------------------------------------------------------------------
edit() {
	local tool="$1" path="$2" payload
	payload=$(MC_TOOL="$tool" MC_PATH="$path" python -c 'import json, os
print(json.dumps({"tool_name": os.environ["MC_TOOL"], "tool_input": {"file_path": os.environ["MC_PATH"]}}))' 2>/dev/null ||
		MC_TOOL="$tool" MC_PATH="$path" python3 -c 'import json, os
print(json.dumps({"tool_name": os.environ["MC_TOOL"], "tool_input": {"file_path": os.environ["MC_PATH"]}}))')
	out=$(printf '%s' "$payload" | bash "$HERE/guard-vendored-edit.sh" 2>&1)
	status=$?
}
edit Edit "$V/scripts/a.sh"
expect "an edit inside the copy is refused" 0 '"permissionDecision": "deny"' "vendored copy" "vendor.sh <new tag>" "archos-media/merge-coordinator"
edit Write "$V/scripts/brand-new.sh"
expect "creating a file inside the copy is refused" 0 '"permissionDecision": "deny"'
edit Edit "$CONS/app.txt"
if [ -z "$out" ]; then ok "an edit elsewhere in the repository is untouched"; else bad "an edit elsewhere in the repository is untouched" "$out"; fi
mkdir -p "$WORK/other/tools/merge-coordinator"
git -C "$WORK/other" init -q
edit Edit "$WORK/other/tools/merge-coordinator/x.sh"
if [ -z "$out" ]; then ok "a folder with that name but no stamp is not a copy"; else bad "a folder with that name but no stamp is not a copy" "$out"; fi
WIN_V=$(cygpath -w "$V/scripts/a.sh" 2>/dev/null || true)
if [ -n "$WIN_V" ]; then
	edit Edit "$WIN_V"
	expect "a Windows-spelled path inside the copy is refused too" 0 '"permissionDecision": "deny"'
fi

# --------------------------------------------------------------------------
# 6. vendor-status.sh: silent when current, loud when behind or blind.
# --------------------------------------------------------------------------
PLUG="$WORK/plug"
mkdir -p "$PLUG/.claude-plugin"
cp -r "$HERE" "$PLUG/scripts"
printf '{"version": "0.1.0"}\n' >"$PLUG/.claude-plugin/plugin.json"
status_of() {
	local payload
	payload=$(MC_CWD="$1" python -c 'import json, os
print(json.dumps({"hook_event_name": "PostToolUse", "cwd": os.environ["MC_CWD"]}))' 2>/dev/null ||
		MC_CWD="$1" python3 -c 'import json, os
print(json.dumps({"hook_event_name": "PostToolUse", "cwd": os.environ["MC_CWD"]}))')
	out=$(printf '%s' "$payload" | bash "$PLUG/scripts/vendor-status.sh" 2>&1)
	status=$?
}
tags() { printf 'aaa\trefs/tags/%s\n' "$@"; }

# The consumer is at v0.1.0 again after section 4.
git -C "$CONS" reset -q --hard HEAD
run bash "$HERE/vendor.sh" v0.1.0
git -C "$CONS" commit -qm "pin v0.1.0" >/dev/null 2>&1

MC_VENDOR_REMOTE_TAGS=$(tags v0.0.9 v0.1.0) status_of "$CONS"
if [ "$status" = 0 ] && [ -z "$out" ]; then ok "current copy, current plugin: nothing said"; else bad "current copy, current plugin: nothing said" "$out"; fi

MC_VENDOR_REMOTE_TAGS=$(tags v0.1.0 v0.9.0 v0.10.0) status_of "$CONS"
expect "a newer release is named, compared as numbers (v0.10.0 beats v0.9.0)" 0 "is v0.1.0; the newest release is v0.10.0" "vendor.sh v0.10.0" "claude plugin update"
expect "the answer is addressed to the event that asked" 0 '"hookEventName": "PostToolUse"'
# Inside a repository the message is what it always was: the copy's own path,
# and vendor.sh run where the session stands.
expect "inside a repository the wording is unchanged" 0 \
	"the vendored copy in tools/merge-coordinator is v0.1.0" "Refresh it on a branch: bash $PLUG/scripts/vendor.sh v0.10.0"

MC_VENDOR_REMOTE_TAGS="" status_of "$CONS"
expect "unreachable releases say 'could not', not nothing" 0 "could not read the releases"
absent "unreachable releases name no plugin update" "claude plugin update" "the newest release is ."

MC_VENDOR_REMOTE_TAGS=$(printf 'aaa\trefs/tags/latest\n') status_of "$CONS"
expect "a source with no vN.N.N tags says so" 0 "lists no vN.N.N release tags"
absent "a source with no vN.N.N tags names no plugin update" "claude plugin update"

# A repository with no copy, holding one that has a copy: a session inside it
# does not look below.
OUTER="$WORK/outer"
mkdir -p "$OUTER" && git -C "$OUTER" init -q
mkdir -p "$OUTER/sub/.github" && git -C "$OUTER/sub" init -q
printf '{"source": "%s", "tag": "v0.0.1", "path": "tools/merge-coordinator", "files": {}}\n' "$UP" >"$OUTER/sub/.github/merge-coordinator.vendor"
MC_VENDOR_REMOTE_TAGS=$(tags v0.1.0) status_of "$OUTER"
if [ -z "$out" ]; then ok "inside a repository, repositories below it are not looked at"; else bad "inside a repository, repositories below it are not looked at" "$out"; fi

MC_VENDOR_REMOTE_TAGS=$(tags v0.1.0) status_of "$WORK/no-such-folder"
expect "a folder git cannot read is 'could not look', not a folder with nothing below" 0 "could not tell whether"

MC_VENDOR_REMOTE_TAGS=$(tags v0.1.0) status_of "$WORK/other"
if [ -z "$out" ]; then ok "a repository with no copy hears nothing"; else bad "a repository with no copy hears nothing" "$out"; fi

# --------------------------------------------------------------------------
# 7. A session in a folder that is not a repository: the repositories one
#    folder below it.
# --------------------------------------------------------------------------
PROJ="$WORK/project"
# pin <repo> <tag> — a repository whose stamp pins <tag> from the fixture.
pin() {
	mkdir -p "$1/.github"
	git -C "$1" init -q
	printf '{"source": "%s", "tag": "%s", "path": "tools/merge-coordinator", "files": {}}\n' "$up_url" "$2" >"$1/.github/merge-coordinator.vendor"
}
pin "$PROJ/alpha" v0.1.0
pin "$PROJ/beta" v0.1.0
mkdir -p "$PROJ/gamma" && git -C "$PROJ/gamma" init -q
pin "$PROJ/notes/deep" v0.0.1
mkdir -p "$PROJ/plain"

# The real source, asked through git, so the trace shows how often it was asked.
run_traced() {
	rm -f "$WORK/trace"
	GIT_TRACE="$WORK/trace" status_of "$1"
	asked=$(grep -c 'git ls-remote' "$WORK/trace" 2>/dev/null)
}
PROJM=$(cygpath -m "$PROJ" 2>/dev/null || printf '%s' "$PROJ")
run_traced "$PROJ"
expect "each repository one folder down is named, with where to run vendor.sh" 0 \
	"the vendored copy in alpha/tools/merge-coordinator is v0.1.0; the newest release is v0.2.0" \
	"the vendored copy in beta/tools/merge-coordinator is v0.1.0" \
	"cd \\\"$PROJM/alpha\\\" && bash $PLUG/scripts/vendor.sh v0.2.0" \
	"cd \\\"$PROJM/beta\\\" && bash $PLUG/scripts/vendor.sh v0.2.0"
if [ "$asked" = 1 ]; then ok "two copies from one source ask it once"; else bad "two copies from one source ask it once" "asked $asked times"; fi
# The hook prints the message twice (systemMessage and additionalContext); count one.
updates=$(printf '%s' "$out" | python -c 'import json, sys; print(json.load(sys.stdin)["systemMessage"].count("claude plugin update"))' 2>/dev/null ||
	printf '%s' "$out" | python3 -c 'import json, sys; print(json.load(sys.stdin)["systemMessage"].count("claude plugin update"))')
updates=${updates%$'\r'}
if [ "$updates" = 1 ]; then ok "the installed plugin is named once, not once per copy"; else bad "the installed plugin is named once, not once per copy" "$out"; fi
if contains "$out" "deep"; then bad "a repository two folders down is not looked at" "$out"; else ok "a repository two folders down is not looked at"; fi

WIN_PROJ=$(cygpath -w "$PROJ" 2>/dev/null || true)
if [ -n "$WIN_PROJ" ]; then
	MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$WIN_PROJ"
	expect "a Windows-spelled session folder is looked under too" 0 "alpha/tools/merge-coordinator is v0.1.0" \
		"cd \\\"$PROJM/alpha\\\" && bash"
fi

pin "$PROJ/alpha" v0.2.0
pin "$PROJ/beta" v0.2.0
MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$PROJ"
expect "copies one folder down that are current: only the plugin is named" 0 "the installed plugin is v0.1.0"
if contains "$out" "vendored copy"; then bad "current copies one folder down are not named" "$out"; else ok "current copies one folder down are not named"; fi
printf '{"version": "0.2.0"}\n' >"$PLUG/.claude-plugin/plugin.json"
MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$PROJ"
if [ "$status" = 0 ] && [ -z "$out" ]; then ok "everything current one folder down: nothing said"; else bad "everything current one folder down: nothing said" "$out"; fi

MC_VENDOR_REMOTE_TAGS="" status_of "$PROJ"
expect "unreachable releases one folder down say 'could not', for each copy" 0 "could not read the releases" \
	"alpha/tools/merge-coordinator (v0.2.0)" "beta/tools/merge-coordinator (v0.2.0)"
absent "unreachable releases one folder down name no plugin update" "claude plugin update"

MC_VENDOR_REMOTE_TAGS=$(printf 'aaa\trefs/tags/latest\n') status_of "$PROJ"
expect "a source with no vN.N.N tags, one folder down, says so" 0 "lists no vN.N.N release tags" "alpha/tools/merge-coordinator (v0.2.0)"

# One copy unreadable does not hide the others.
pin "$PROJ/alpha" v0.1.0
printf 'not json\n' >"$PROJ/beta/.github/merge-coordinator.vendor"
MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$PROJ"
expect "an unreadable stamp one folder down says so, beside the others" 0 \
	"could not read $PROJM/beta/.github/merge-coordinator.vendor" "alpha/tools/merge-coordinator is v0.1.0"

printf '{"source": "", "tag": "v0.1.0", "path": "tools/merge-coordinator"}\n' >"$PROJ/beta/.github/merge-coordinator.vendor"
MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$PROJ"
expect "a stamp with an empty field is unreadable, not shifted" 0 "could not read $PROJM/beta/.github/merge-coordinator.vendor"
absent "a stamp with an empty field does not name its tag as a source" "releases at v0.1.0"
pin "$PROJ/alpha" v0.2.0
pin "$PROJ/beta" v0.2.0

MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$PROJ/plain"
if [ -z "$out" ]; then ok "a folder with no repositories below it hears nothing"; else bad "a folder with no repositories below it hears nothing" "$out"; fi

# --------------------------------------------------------------------------
# 8. Several sources, a worktree, and a folder that only looks like a copy.
# --------------------------------------------------------------------------
UP2="$WORK/upstream2"
mkdir -p "$UP2" && git -C "$UP2" init -q
printf 'x\n' >"$UP2/x" && git -C "$UP2" add -A && git -C "$UP2" commit -qm x && git -C "$UP2" tag v0.3.0
up2_url=$(cygpath -m "$UP2" 2>/dev/null || printf '%s' "$UP2")
P2="$WORK/project2"
P2M=$(cygpath -m "$P2" 2>/dev/null || printf '%s' "$P2")
# stamp <folder> <source> <tag> — a stamp, without making a repository.
stamp() {
	mkdir -p "$1/.github"
	printf '{"source": "%s", "tag": "%s", "path": "tools/merge-coordinator", "files": {}}\n' "$2" "$3" >"$1/.github/merge-coordinator.vendor"
}
mkdir -p "$P2/alpha" && git -C "$P2/alpha" init -q && stamp "$P2/alpha" "$up_url" v0.1.0
mkdir -p "$P2/delta" && git -C "$P2/delta" init -q && stamp "$P2/delta" "$up2_url" v0.1.0
mkdir -p "$P2/epsilon" && git -C "$P2/epsilon" init -q && stamp "$P2/epsilon" "$WORK/missing-upstream" v0.1.0
# A worktree's .git is a file, not a folder.
mkdir -p "$WORK/main-repo" && git -C "$WORK/main-repo" init -q && git -C "$WORK/main-repo" commit -q --allow-empty -m base
git -C "$WORK/main-repo" worktree add -q "$P2/wt" 2>/dev/null
stamp "$P2/wt" "$up_url" v0.1.0
# A stamp in a folder that is not a repository is not a copy.
stamp "$P2/loose" "$up_url" v0.0.1

run_traced "$P2"
if [ "$asked" = 3 ]; then ok "three sources are asked once each"; else bad "three sources are asked once each" "asked $asked times"; fi
expect "each copy is held to its own source's releases" 0 \
	"alpha/tools/merge-coordinator is v0.1.0; the newest release is v0.2.0" \
	"delta/tools/merge-coordinator is v0.1.0; the newest release is v0.3.0" \
	"could not read the releases at $WORK/missing-upstream, so whether the vendored copy in epsilon/tools/merge-coordinator (v0.1.0)"
expect "a worktree one folder down is looked at" 0 "wt/tools/merge-coordinator is v0.1.0" "cd \\\"$P2M/wt\\\""
absent "a stamp in a folder that is not a repository is not a copy" "loose"

# The deadline each source is asked with: an even share of 18 seconds, 15 for
# one source. A stand-in timeout records it (mc_timed finds it by name).
timeout() {
	printf '%s\n' "$1" >>"$WORK/secs"
	shift
	"$@"
}
export -f timeout
export WORK
rm -f "$WORK/secs"
status_of "$P2"
secs=$(tr '\n' ' ' <"$WORK/secs" 2>/dev/null)
if [ "$secs" = "6 6 6 " ]; then ok "three sources get 6 seconds each"; else bad "three sources get 6 seconds each" "[$secs]"; fi
rm -f "$WORK/secs"
status_of "$PROJ"
secs=$(tr '\n' ' ' <"$WORK/secs" 2>/dev/null)
if [ "$secs" = "15 " ]; then ok "one source gets 15 seconds"; else bad "one source gets 15 seconds" "[$secs]"; fi

# The budget runs out: a source with no time left is named as not asked. The
# stand-in spends every second it is given and fails.
timeout() {
	printf '%s\n' "$1" >>"$WORK/secs"
	sleep "$1"
	return 124
}
export -f timeout
rm -f "$WORK/secs"
MC_VENDOR_BUDGET=3 status_of "$P2"
secs=$(tr '\n' ' ' <"$WORK/secs" 2>/dev/null)
if [ "$secs" = "3 " ]; then ok "once the budget is spent no other source is asked"; else bad "once the budget is spent no other source is asked" "[$secs]"; fi
expect "a source left with no time is named as not asked" 0 "was not asked, because the 3 seconds"
unset -f timeout

# A translated git still counts as "not a repository". Few machines here
# translate, so a stand-in git answers in German unless asked in the C locale.
git() {
	if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ] && [ "${LC_ALL:-}" != "C" ]; then
		echo "fatal: Kein Git-Repository (oder irgendeines der Elternverzeichnisse): .git" >&2
		return 128
	fi
	command git "$@"
}
export -f git
MC_VENDOR_REMOTE_TAGS=$(tags v0.2.0) status_of "$P2"
unset -f git
expect "a translated git still looks one folder down" 0 "alpha/tools/merge-coordinator is v0.1.0"
absent "a translated git is not taken for a git that failed" "could not tell whether"

echo
echo "test-vendor: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
