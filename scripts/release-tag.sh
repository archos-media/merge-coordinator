#!/usr/bin/env bash
# Tag the release main's head belongs to, after checking nothing has shipped
# since it without a bump.
#
#   bash scripts/release-tag.sh <head>
#
# The release for version V is the commit that set V: the newest first-parent
# commit, at or before <head>, that changed the version line of
# .claude-plugin/plugin.json. Every run computes the same commit, so runs for
# merges close together, finishing in any order, put v<V> in one place.
#
# Before tagging, check-version-bump.sh compares that commit with <head>. The
# versions are equal, so any plugin file changed since fails: an unbumped
# change merged earlier, or a second pull request that bumped to the same
# version, cannot sit behind a later merge's green run.
#
# THREE ANSWERS: 0 v<V> names the release commit (tagged now, or already), and
# nothing has shipped since it; 1 a plugin file changed since the release with
# no bump, or v<V> names another commit (both named); 2 it could not look, or
# could not push the tag.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh" || { echo "release-tag: could not load $here/lib/gh.sh." >&2; exit 2; }
# mc_py stops with exit 1 when it finds no Python; probed in a subshell here,
# so that case reads as "could not look".
(mc_py -c "") >/dev/null 2>&1 || { echo "release-tag: no working python3 (or python) on PATH." >&2; exit 2; }

[ $# -eq 1 ] || { echo "usage: release-tag.sh <head>" >&2; exit 2; }
head="$1"
manifest=.claude-plugin/plugin.json

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "release-tag: not inside a git repository." >&2; exit 2; }
cd "$top" || exit 2
git rev-parse --verify -q "$head^{commit}" >/dev/null || { echo "release-tag: $head is not a commit here." >&2; exit 2; }

version=$(git show "$head:$manifest" | mc_py -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["version"])') ||
	{ echo "release-tag: could not read the version from $manifest at $head." >&2; exit 2; }
tag="v$version"
release=$(git log --first-parent -n 1 --format=%H -G'^[[:space:]]*"version"[[:space:]]*:' "$head" -- "$manifest") ||
	{ echo "release-tag: could not read the history of $manifest." >&2; exit 2; }
[ -n "$release" ] || { echo "release-tag: no commit before $head set a version in $manifest." >&2; exit 2; }

bash "$here/check-version-bump.sh" "$release" "$head"
case $? in
0) ;;
1)
	echo "release-tag: $tag was set at $release; the files above changed after it at the same version, so no installed copy has them."
	exit 1 ;;
*) exit 2 ;;
esac

# Every tag on origin, fresh: one made by a run that finished after this
# checkout is then seen here. A failed fetch is "could not look".
git fetch -q origin "refs/tags/*:refs/tags/*" || { echo "release-tag: could not fetch the tags of origin." >&2; exit 2; }
if tagged=$(git rev-parse -q --verify "refs/tags/$tag^{commit}"); then
	if [ "$tagged" = "$release" ]; then
		echo "release-tag: $tag already names $release, the commit that set it; nothing to tag."
		exit 0
	fi
	echo "release-tag: $tag names $tagged, but the commit that set version $version is $release. Whoever vendors $tag gets other code: move the tag to $release."
	exit 1
fi

git tag -a "$tag" -m "$tag" "$release" || { echo "release-tag: could not create $tag." >&2; exit 2; }
if git push -q origin "refs/tags/$tag"; then
	echo "release-tag: tagged $tag on $release."
	exit 0
fi
# Refused: another run may have pushed the same tag since the fetch. That is
# a pass only if it names the same commit.
git tag -d "$tag" >/dev/null
if git fetch -q origin "refs/tags/$tag:refs/tags/$tag" && [ "$(git rev-parse -q --verify "refs/tags/$tag^{commit}")" = "$release" ]; then
	echo "release-tag: $tag was pushed meanwhile, on $release; nothing to tag."
	exit 0
fi
echo "release-tag: could not push $tag to origin." >&2
exit 2
