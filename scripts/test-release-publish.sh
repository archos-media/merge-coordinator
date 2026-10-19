#!/usr/bin/env bash
# Tests release-publish.sh against a fixture repository and a fake gh.
#
# What must be caught: a failed read taken for "no Release yet", a refused
# create taken for a pass, and a tag with no notes published anyway.
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

# The fake gh. VIEW is what reading the Release does: "found", "missing", or
# "error". CREATE is what creating it does: "ok", "refused", or "race" (refused,
# and the Release is found from then on). Every call is logged, and every
# create with its notes.
GH="$WORK/gh.sh"
cat >"$GH" <<'EOF'
echo "$*" >>"$WORK/calls"
state="$WORK/state"
if [ "$1" = api ]; then
	case "$(cat "$state" 2>/dev/null || echo "$VIEW")" in
	found) echo 7; exit 0 ;;
	missing) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
	*) echo "error connecting to api.github.com" >&2; exit 1 ;;
	esac
fi
if [ "$1 $2" = "release create" ]; then
	while [ $# -gt 0 ]; do
		[ "$1" = --notes-file ] && { echo "created with:" >>"$WORK/created"; cat "$2" >>"$WORK/created"; }
		shift
	done
	case "$CREATE" in
	ok) exit 0 ;;
	race) echo found >"$state"; echo "HTTP 422: already_exists" >&2; exit 1 ;;
	*) echo "HTTP 422: refused" >&2; exit 1 ;;
	esac
fi
echo "fake gh: unexpected call: $*" >&2
exit 3
EOF
export WORK MC_GH="$GH"

# publish <view> <create> <tag>
publish() {
	rm -f "$WORK/state" "$WORK/created" "$WORK/calls"
	out=$(cd "$R" && VIEW="$1" CREATE="$2" bash "$HERE/release-publish.sh" acme/plugin "$3" 2>&1)
	status=$?
	created=$(cat "$WORK/created" 2>/dev/null)
	calls=$(cat "$WORK/calls" 2>/dev/null)
}

R="$WORK/plugin"
git init -q -b main "$R"
mkdir -p "$R/.claude-plugin"
printf '{\n  "name": "merge-coordinator",\n  "version": "0.2.0"\n}\n' >"$R/.claude-plugin/plugin.json"
printf '# Changelog\n\n## [v0.2.0]\n\n- The second thing.\n\n## [v0.1.0]\n\n- The first thing.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A && git -C "$R" commit -qm two
git -C "$R" tag v0.2.0
printf '{\n  "name": "merge-coordinator",\n  "version": "0.3.0"\n}\n' >"$R/.claude-plugin/plugin.json"
git -C "$R" add -A && git -C "$R" commit -qm three
git -C "$R" tag v0.3.0

# --------------------------------------------------------------------------
# Publishing
# --------------------------------------------------------------------------
publish missing ok v0.2.0
expect "a tag with no Release gets one" 0 "published the Release for v0.2.0"
contains "$created" "- The second thing." || bad "its notes are the tag's section" "$created"
contains "$created" "The first thing" && bad "its notes leave out the older section" "$created"
# Any path that answers would pass the cases above: read some other Release,
# and every version after the first is skipped as already published.
if contains "$calls" "api repos/acme/plugin/releases/tags/v0.2.0 " &&
	contains "$calls" "release create v0.2.0 -R acme/plugin --verify-tag --title v0.2.0 --notes-file "; then
	ok "the Release is read by its tag, and made for that tag"
else
	bad "the Release is read by its tag, and made for that tag" "$calls"
fi

publish found ok v0.2.0
expect "a Release already there is left alone" 0 "already published"
[ -z "$created" ] || bad "nothing is created when the Release exists" "$created"

publish missing race v0.2.0
expect "a Release another run published meanwhile passes" 0 "published meanwhile"

# --------------------------------------------------------------------------
# What must be caught
# --------------------------------------------------------------------------
publish missing ok v0.3.0
expect "a tag with no notes is not published" 1 "no ## [v0.3.0] heading"
[ -z "$created" ] || bad "nothing is created for a tag with no notes" "$created"

publish missing refused v0.2.0
expect "a refused create is not a pass" 2 "could not publish the Release for v0.2.0"

publish error ok v0.2.0
expect "a failed read is not taken for no Release" 2 "could not read the Release for v0.2.0"
[ -z "$created" ] || bad "nothing is created when the read failed" "$created"

out=$(cd "$R" && VIEW=missing CREATE=ok bash "$HERE/release-publish.sh" acme/plugin 2>&1)
status=$?
expect "a missing argument is a usage error" 2 "usage:"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
