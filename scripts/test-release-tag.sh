#!/usr/bin/env bash
# Tests release-tag.sh against a fixture repository and a local bare "origin".
#
# The cases are mostly about what must be CAUGHT or put in the right place: a
# tag on the wrong commit, a plugin change hidden behind a later merge, a
# later merge's run tagging an earlier merge's version. A release step that
# passes too much leaves a version no copy can reach, and says nothing.
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
release() {
	out=$(cd "$R" && bash "$HERE/release-tag.sh" "$@" 2>&1)
	status=$?
}
# origin_tag <tag>: the commit origin's tag names, or nothing.
origin_tag() { git -C "$O" rev-parse -q --verify "refs/tags/$1^{commit}"; }

# --------------------------------------------------------------------------
# Fixture: origin (bare) and a clone of it, the plugin at 0.1.0, tagged.
# --------------------------------------------------------------------------
O="$WORK/origin.git"
R="$WORK/plugin"
git init -q --bare -b main "$O"
git init -q -b main "$R"
git -C "$R" remote add origin "$O"
mkdir -p "$R/.claude-plugin" "$R/scripts"
version() { printf '{\n  "name": "merge-coordinator",\n  "description": "names no version",\n  "version": "%s"\n}\n' "$1" >"$R/.claude-plugin/plugin.json"; }
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD; }
version 0.1.0
printf 'one\n' >"$R/scripts/a.sh"
printf 'readme\n' >"$R/README.md"
V010=$(commit base)
git -C "$R" tag v0.1.0
git -C "$R" push -q origin main v0.1.0

# --------------------------------------------------------------------------
# Tagging
# --------------------------------------------------------------------------
printf 'two\n' >"$R/scripts/a.sh"
version 0.1.1
V011=$(commit bump)
release "$V011"
expect "a merge that raised the version is tagged on itself" 0 "tagged v0.1.1 on $V011"
[ "$(origin_tag v0.1.1)" = "$V011" ] || bad "origin's v0.1.1 names the bump commit" "origin has: $(origin_tag v0.1.1)"

release "$V011"
expect "a re-run finds its tag in place" 0 "already names $V011"

# A README-only merge right after the bump, its run finishing first: the tag
# still goes on the commit that set the version, not on this one.
printf 'two\n' >"$R/scripts/c.sh"
version 0.1.2
V012=$(commit bump-again)
printf 'readme two\n' >"$R/README.md"
DOCS=$(commit docs)
release "$DOCS"
expect "a later merge's run tags the commit that set the version" 0 "tagged v0.1.2 on $V012"
[ "$(origin_tag v0.1.2)" = "$V012" ] || bad "origin's v0.1.2 names the bump commit, not the later merge" "origin has: $(origin_tag v0.1.2)"
release "$V012"
expect "the earlier merge's run, finishing last, agrees" 0 "already names $V012"

# A description edit that leaves the version line alone is not a release.
edit_description() { sed -i 's/names no version/names no version, still/' "$R/.claude-plugin/plugin.json"; }
edit_description
DESC=$(commit description)
release "$DESC"
expect "an edit beside the version line does not move the release" 1 "v0.1.2 was set at $V012" ".claude-plugin/plugin.json"
git -C "$R" reset -q --hard "$DOCS"

# --------------------------------------------------------------------------
# What must be caught
# --------------------------------------------------------------------------
printf 'unbumped\n' >"$R/scripts/a.sh"
commit unbumped >/dev/null
printf 'readme three\n' >"$R/README.md"
HIDDEN=$(commit docs-after-unbumped)
release "$HIDDEN"
expect "a plugin change with no bump, behind a later merge, is caught" 1 "scripts/a.sh" "v0.1.2 was set at $V012"
git -C "$R" reset -q --hard "$DOCS"

printf 'three\n' >"$R/scripts/a.sh"
version 0.1.3
V013=$(commit bump-three)
printf 'side\n' >"$R/side.txt"
SIDE=$(commit side)
git -C "$R" tag v0.1.3 "$SIDE"
git -C "$R" push -q origin v0.1.3
git -C "$R" tag -d v0.1.3 >/dev/null
release "$V013"
expect "a tag on another commit is caught, naming both" 1 "v0.1.3 names $SIDE" "is $V013"
git -C "$R" tag -d v0.1.3 >/dev/null 2>&1
git -C "$O" tag -d v0.1.3 >/dev/null

# A lightweight tag (some real releases are tagged that way) is read the same way.
git -C "$R" tag v0.1.3 "$V013"
git -C "$R" push -q origin v0.1.3
git -C "$R" tag -d v0.1.3 >/dev/null
release "$V013"
expect "a lightweight tag on the release commit passes" 0 "already names $V013"

# --------------------------------------------------------------------------
# The push is refused
# --------------------------------------------------------------------------
# Another run wins the race: origin's hook makes the tag on the release
# commit, then refuses this push. A hook may not update refs inside the push's
# quarantine unless it leaves it.
printf 'five\n' >"$R/scripts/a.sh"
version 0.1.5
V015=$(commit bump-five)
git -C "$R" push -q origin HEAD:main
HOOK="$O/hooks/pre-receive"
printf '#!/bin/sh\nunset GIT_QUARANTINE_PATH\ngit update-ref refs/tags/v0.1.5 %s\nexit 1\n' "$V015" >"$HOOK"
chmod +x "$HOOK"
release "$V015"
expect "a tag another run pushed meanwhile, on the same commit, passes" 0 "pushed meanwhile, on $V015"

# The tag that appears meanwhile names another commit.
printf 'five more\n' >"$R/scripts/a.sh"
version 0.1.7
V017=$(commit bump-seven)
printf '#!/bin/sh\nunset GIT_QUARANTINE_PATH\ngit update-ref refs/tags/v0.1.7 %s\nexit 1\n' "$V015" >"$HOOK"
release "$V017"
expect "a tag pushed meanwhile on another commit is not a pass" 2 "could not push v0.1.7"

# Origin refuses, and no tag appears.
printf 'six\n' >"$R/scripts/a.sh"
version 0.1.6
V016=$(commit bump-six)
printf '#!/bin/sh\nexit 1\n' >"$HOOK"
release "$V016"
expect "a refused push is not a pass" 2 "could not push v0.1.6"
rm -f "$HOOK"

# --------------------------------------------------------------------------
# Could not look: never a pass
# --------------------------------------------------------------------------
git -C "$R" remote set-url origin "$WORK/no-such-origin.git"
printf 'four\n' >"$R/scripts/a.sh"
version 0.1.4
V014=$(commit bump-four)
release "$V014"
expect "an origin that cannot be read is not a pass" 2 "could not fetch the tags of origin"
git -C "$R" remote set-url origin "$O"

release 0000000000000000000000000000000000000000
expect "a head that is not here cannot be released" 2 "is not a commit here"

release
expect "no argument is a usage error" 2 "usage:"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
