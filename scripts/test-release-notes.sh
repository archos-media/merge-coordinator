#!/usr/bin/env bash
# Tests release-notes.sh against a fixture repository.
#
# What must be caught: a version with no heading, two headings for one
# version, and a heading with nothing under it. Each would publish a Release
# that says nothing, or the wrong thing.
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
# notes <ref>: stdout in $out, stderr in $err.
notes() {
	out=$(cd "$R" && bash "$HERE/release-notes.sh" "$@" 2>"$WORK/err")
	status=$?
	err=$(cat "$WORK/err")
}
# expect_err: as expect, against stderr.
expect_err() {
	local o="$out"
	out="$err"
	expect "$@"
	out="$o"
}

R="$WORK/plugin"
git init -q -b main "$R"
mkdir -p "$R/.claude-plugin"
version() { printf '{\n  "name": "merge-coordinator",\n  "version": "%s"\n}\n' "$1" >"$R/.claude-plugin/plugin.json"; }
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD; }

# --------------------------------------------------------------------------
# The notes
# --------------------------------------------------------------------------
version 0.2.0
cat >"$R/CHANGELOG.md" <<'EOF'
# Changelog

Intro text.

## [v0.2.0]

- **New:** the second thing.

- And a [link](https://example.invalid).

## [v0.1.0]

- The first thing.
EOF
TWO=$(commit two)
notes "$TWO"
expect "the section under the version's heading is printed" 0 "- **New:** the second thing." "- And a [link](https://example.invalid)."
contains "$out" "The first thing" && bad "the next version's section is left out" "$out"
contains "$out" "Intro text" && bad "the text above the heading is left out" "$out"
[ "${out:0:1}" = "-" ] || bad "leading blank lines are trimmed" "$out"

version 0.1.0
OLD=$(commit back-to-one)
notes "$OLD"
expect "the last section runs to the end of the file" 0 "- The first thing."

# Windows line endings in the stored file read the same.
version 0.2.0
sed -i 's/$/\r/' "$R/CHANGELOG.md"
CRLF=$(git -C "$R" -c core.autocrlf=false add -A && git -C "$R" -c core.autocrlf=false commit -qm crlf && git -C "$R" rev-parse HEAD)
contains "$(git -C "$R" cat-file blob "$CRLF:CHANGELOG.md")" $'\r' || bad "the fixture stores CRLF" "it does not: the case below would test nothing"
notes "$CRLF"
expect "a CRLF changelog is read the same" 0 "- **New:** the second thing."
contains "$out" $'\r' && bad "no carriage return reaches the notes" "$out"

# Larger than one environment variable may hold on Linux (128 KiB), where CI
# runs: the text must not travel that way. Git Bash on Windows passes it.
version 0.2.0
{
	printf '# Changelog\n\n## [v0.2.0]\n\n'
	for i in $(seq 1 3000); do printf -- '- Line %d of a long release, padded out with words to fill it.\n' "$i"; done
} >"$R/CHANGELOG.md"
LONG=$(commit long)
notes "$LONG"
expect "a changelog past an environment variable's size limit is read" 0 "- Line 3000 of a long release"
[ "${#out}" -gt 131072 ] || bad "the long fixture is past 128 KiB" "only ${#out} bytes: the case above would test nothing"

# --------------------------------------------------------------------------
# What must be caught
# --------------------------------------------------------------------------
version 0.3.0
printf '# Changelog\n\n## [v0.2.0]\n\n- The second thing.\n' >"$R/CHANGELOG.md"
MISSING=$(commit missing)
notes "$MISSING"
expect_err "a version with no heading is caught" 1 "no ## [v0.3.0] heading"
[ -z "$out" ] || bad "nothing is printed for a missing heading" "$out"

# The unreleased heading is not the version's.
printf '# Changelog\n\n## [Unreleased]\n\n- Something.\n' >"$R/CHANGELOG.md"
UNREL=$(commit unreleased)
notes "$UNREL"
expect_err "an Unreleased heading does not stand in for the version" 1 "no ## [v0.3.0] heading"

# The heading stands alone on its line: one with a date after it is not it.
printf '# Changelog\n\n## [v0.3.0] - 2026-11-01\n\n- Something.\n' >"$R/CHANGELOG.md"
PREFIX=$(commit prefix)
notes "$PREFIX"
expect_err "a heading that only begins with the version is not it" 1 "no ## [v0.3.0] heading" "alone on its line"

printf '# Changelog\n\n## [v0.3.0]\n\n- One side.\n\n## [v0.3.0]\n\n- Other side.\n' >"$R/CHANGELOG.md"
TWICE=$(commit twice)
notes "$TWICE"
expect_err "two headings for one version are caught" 1 "has 2 ## [v0.3.0] headings"

printf '# Changelog\n\n## [v0.3.0]\n\n  \n\n## [v0.2.0]\n\n- The second thing.\n' >"$R/CHANGELOG.md"
EMPTY=$(commit empty)
notes "$EMPTY"
expect_err "a heading with nothing under it is caught" 1 "nothing under it"

# --------------------------------------------------------------------------
# Could not look: never a pass
# --------------------------------------------------------------------------
git -C "$R" rm -q CHANGELOG.md
NOFILE=$(git -C "$R" commit -qm nofile && git -C "$R" rev-parse HEAD)
notes "$NOFILE"
expect_err "no CHANGELOG.md is not a pass" 2 "could not read CHANGELOG.md"

notes 0000000000000000000000000000000000000000
expect_err "a ref that is not here" 2 "is not a commit here"

notes
expect_err "no argument is a usage error" 2 "usage:"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
