#!/usr/bin/env bash
# Publish the GitHub Release for a tag, its notes the tag's CHANGELOG.md section.
#
#   bash scripts/release-publish.sh <owner/repo> <tag>
#
# Run by main's release job after release-tag.sh, on every push to main: a
# push that sets no new version finds its Release already there. The notes
# come from release-notes.sh at the tag, so a version with no CHANGELOG
# section fails here rather than publishing an empty Release.
#
# THREE ANSWERS: 0 the Release exists (published now, or already); 1 the tag
# has no notes; 2 it could not look, or could not publish.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh" || { echo "release-publish: could not load $here/lib/gh.sh." >&2; exit 2; }

[ $# -eq 2 ] || { echo "usage: release-publish.sh <owner/repo> <tag>" >&2; exit 2; }
repo="$1"
tag="$2"

# published: 0 the Release exists, 1 it does not, 2 could not tell. Only a
# 404 is "does not": any other failure is not knowing.
published() {
	local err
	err=$(mc_gh api "repos/$repo/releases/tags/$tag" --jq .id 2>&1 >/dev/null) && return 0
	case "$err" in
	*"HTTP 404"*) return 1 ;;
	esac
	echo "release-publish: could not read the Release for $tag: $err" >&2
	return 2
}

published
case $? in
0)
	echo "release-publish: the Release for $tag is already published; nothing to do."
	exit 0 ;;
1) ;;
*) exit 2 ;;
esac

notes=$(bash "$here/release-notes.sh" "$tag")
case $? in
0) ;;
1) exit 1 ;;
*) exit 2 ;;
esac

file=$(mktemp) || { echo "release-publish: could not make a temporary file." >&2; exit 2; }
trap 'rm -f "$file"' EXIT
printf '%s\n' "$notes" >"$file"
if mc_gh release create "$tag" -R "$repo" --verify-tag --title "$tag" --notes-file "$file"; then
	echo "release-publish: published the Release for $tag."
	exit 0
fi
# Refused: another run may have published it since the look. That is a pass
# only if it is there now.
if published; then
	echo "release-publish: the Release for $tag was published meanwhile; nothing to do."
	exit 0
fi
echo "release-publish: could not publish the Release for $tag." >&2
exit 2
