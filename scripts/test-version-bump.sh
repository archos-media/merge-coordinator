#!/usr/bin/env bash
# Tests check-version-bump.sh against a local fixture repository.
#
# The cases are mostly about what must be CAUGHT: a plugin change with no bump,
# a version that went down, two pull requests that bumped to the same version,
# a manifest that cannot be read. A bump check that passes too much is silent,
# and an installed copy that never updates says nothing either.
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
check() {
	out=$(cd "$R" && bash "$HERE/check-version-bump.sh" "$@" 2>&1)
	status=$?
}

# --------------------------------------------------------------------------
# Fixture: a plugin repository at 0.1.0, and helpers that commit on a branch.
# --------------------------------------------------------------------------
R="$WORK/plugin"
mkdir -p "$R/.claude-plugin" "$R/scripts" "$R/.github/workflows"
git -C "$R" init -q -b main
version() { printf '{\n  "name": "merge-coordinator",\n  "version": "%s"\n}\n' "$1" >"$R/.claude-plugin/plugin.json"; }
version 0.1.0
printf 'one\n' >"$R/scripts/a.sh"
printf 'readme\n' >"$R/README.md"
printf 'notes\n' >"$R/scripts/README.md"
printf 'on: push\n' >"$R/.github/workflows/test.yml"
git -C "$R" add -A && git -C "$R" commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# branch <name> [from]: a fresh branch, checked out, from BASE unless named.
branch() { git -C "$R" checkout -q -b "$1" "${2:-$BASE}"; }
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD; }

# --------------------------------------------------------------------------
# A plugin file changed
# --------------------------------------------------------------------------
branch bumped
printf 'two\n' >"$R/scripts/a.sh"
version 0.1.1
BUMPED=$(commit bumped)
check "$BASE" "$BUMPED"
expect "a plugin change with a bump passes" 0 "0.1.0 -> 0.1.1" "2 changed plugin file"

branch unbumped
printf 'two\n' >"$R/scripts/a.sh"
printf 'more notes\n' >"$R/scripts/README.md"
UNBUMPED=$(commit unbumped)
check "$BASE" "$UNBUMPED"
expect "a plugin change with no bump is refused, naming every file" 1 "scripts/a.sh" "scripts/README.md" "says 0.1.0" "above 0.1.0"

branch moved-out
git -C "$R" mv scripts/a.sh .github/a.sh
MOVED=$(commit moved-out)
check "$BASE" "$MOVED"
expect "moving a plugin file into .github/ is a plugin change" 1 "scripts/a.sh"

branch lowered
printf 'two\n' >"$R/scripts/a.sh"
version 0.0.9
LOWERED=$(commit lowered)
check "$BASE" "$LOWERED"
expect "a version that went down is refused" 1 "says 0.0.9"

branch nested-readme
printf 'more notes\n' >"$R/scripts/README.md"
NESTED=$(commit nested-readme)
check "$BASE" "$NESTED"
expect "only the top-level README is exempt" 1 "scripts/README.md"

branch manifest-only
version 0.2.0
MANIFEST_ONLY=$(commit manifest-only)
check "$BASE" "$MANIFEST_ONLY"
expect "a bump on its own passes" 0 "0.1.0 -> 0.2.0"

# --------------------------------------------------------------------------
# Nothing that ships changed
# --------------------------------------------------------------------------
branch docs-only
printf 'readme two\n' >"$R/README.md"
printf 'on: pull_request\n' >"$R/.github/workflows/test.yml"
DOCS=$(commit docs-only)
check "$BASE" "$DOCS"
expect "README.md and .github/** need no bump" 0 "2 file(s) changed, none of them ships"

# --------------------------------------------------------------------------
# Versions compare as numbers
# --------------------------------------------------------------------------
branch nine
version 0.9.0
NINE=$(commit nine)
branch ten "$NINE"
printf 'ten\n' >"$R/scripts/a.sh"
version 0.10.0
TEN=$(commit ten)
check "$NINE" "$TEN"
expect "0.10.0 is higher than 0.9.0" 0 "0.9.0 -> 0.10.0"

# --------------------------------------------------------------------------
# Two pull requests, both 0.1.0 -> 0.1.1, both merge cleanly
# --------------------------------------------------------------------------
branch first
printf 'first\n' >"$R/scripts/first.sh"
version 0.1.1
FIRST=$(commit first)
branch second
printf 'second\n' >"$R/scripts/second.sh"
version 0.1.1
SECOND=$(commit second)
# main after the first lands, then after the second merges on top of it.
git -C "$R" checkout -q -b main-after "$FIRST"
git -C "$R" merge -q --no-edit "$SECOND" >/dev/null 2>&1 || bad "fixture: the two bumps should merge cleanly"
MERGED=$(git -C "$R" rev-parse HEAD)

check "$FIRST" "$SECOND"
expect "the second pull request, checked against main after the first, is refused" 1 "scripts/second.sh" "already said 0.1.1"
check "$FIRST" "$MERGED"
expect "the push to main that carries the second is refused" 1 "scripts/second.sh"

# A pull request from the old base that ships nothing is not blamed for what
# main gained meanwhile.
branch late-docs
printf 'late readme\n' >"$R/README.md"
LATE=$(commit late-docs)
check "$FIRST" "$LATE"
expect "files main gained after the fork are not the pull request's" 0 "none of them ships"

# --------------------------------------------------------------------------
# Could not look: never a pass
# --------------------------------------------------------------------------
branch two-part
printf 'x\n' >"$R/scripts/a.sh"
version 0.2
TWO_PART=$(commit two-part)
check "$BASE" "$TWO_PART"
expect "a version that is not N.N.N cannot be compared" 2 "not N.N.N"

branch no-manifest
printf 'x\n' >"$R/scripts/a.sh"
git -C "$R" rm -q .claude-plugin/plugin.json
NO_MANIFEST=$(commit no-manifest)
check "$BASE" "$NO_MANIFEST"
expect "a missing manifest cannot be compared" 2 "has no .claude-plugin/plugin.json"

check "$BASE" 0000000000000000000000000000000000000000
expect "a head that is not here cannot be compared" 2 "is not a commit here"
check 0000000000000000000000000000000000000000 "$BASE"
expect "a base that is not here cannot be compared" 2 "is not a commit here"

mkdir -p "$WORK/not-a-repo"
out=$(cd "$WORK/not-a-repo" && GIT_CEILING_DIRECTORIES="$WORK" bash "$HERE/check-version-bump.sh" "$BASE" "$BASE" 2>&1)
status=$?
expect "outside a repository it cannot look" 2 "not inside a git repository"

check "$BASE"
expect "one argument is a usage error" 2 "usage:"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
