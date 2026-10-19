#!/usr/bin/env bash
# Copy a tagged release of the merge coordinator into the repository you are
# standing in, and record exactly what was copied.
#
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/vendor.sh" <tag> [--dest <path>]
#
# WHY A COPY AT ALL. Claude Code sessions get the coordinator from the installed
# plugin. A GitHub Actions runner and an agent from another vendor do not: the
# issue-claim workflow and AGENTS.md need the scripts inside the repository.
#
# WHY IT CANNOT DRIFT. The copy is taken from a TAG, never a branch, and the
# blob of every file is written to .github/merge-coordinator.vendor.
# check-vendored.sh compares the copy against that list in CI, so a local edit
# fails the build; guard-vendored-edit.sh refuses the edit before it is made;
# vendor-status.sh says at session start when a newer release exists. A change
# belongs in archos-media/merge-coordinator, then a release, then this script.
#
# The default destination is tools/merge-coordinator. Never .claude/skills/:
# Claude Code loads a plugin it finds there, and the copy would run beside the
# installed plugin, every hook twice.
#
# MC_VENDOR_SOURCE overrides where releases come from. It exists for the tests.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

tag=""
dest="tools/merge-coordinator"
while [ $# -gt 0 ]; do
	case "$1" in
	--dest)
		[ $# -ge 2 ] || mc_die "--dest needs a path."
		dest="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,22p' "$0"
		exit 0
		;;
	-*) mc_die "unknown option $1" ;;
	*)
		[ -z "$tag" ] || mc_die "one tag only (got $tag and $1)."
		tag="$1"
		shift
		;;
	esac
done
[ -n "$tag" ] || mc_die "usage: vendor.sh <tag> [--dest <path>]   (a release tag such as v0.3.0, never a branch)"

source="${MC_VENDOR_SOURCE:-https://github.com/archos-media/merge-coordinator.git}"
dest="${dest%/}"
case "$dest" in
/* | [A-Za-z]:*) mc_die "--dest is a path inside the repository, not an absolute path." ;;
*..*) mc_die "--dest may not climb out of the repository." ;;
.claude/skills/* | */.claude/skills/*)
	mc_die "not under .claude/skills/: Claude Code would load the copy as a second plugin beside the installed one, and every hook would run twice."
	;;
esac

top=$(git rev-parse --show-toplevel 2>/dev/null) || mc_die "run this from inside the repository that should carry the copy."
cd "$top"

if [ -f .claude-plugin/plugin.json ] &&
	[ "$(mc_py -c 'import json; print(json.load(open(".claude-plugin/plugin.json", encoding="utf-8")).get("name", ""))')" = "merge-coordinator" ]; then
	mc_die "this is the merge coordinator's own repository. It is the source of a copy, never the destination."
fi

# Never the copy's own vendor.sh: the rm -rf below deletes this script while
# bash is still reading it, and the run dies half done.
# Compared by identity (-ef), not by spelling: on Windows the same folder can be
# reached in another letter case, and a text match would miss it.
if [ -d "$dest" ]; then
	d=$here
	while :; do
		[ "$d" -ef "$dest" ] &&
			mc_die "this is the vendor.sh inside the copy it would replace. Run the installed plugin's vendor.sh $tag instead, from inside the repository: the session-start notice prints its path (Claude Code keeps it under ~/.claude/plugins/cache/merge-coordinator/)."
		up=$(dirname "$d")
		[ "$up" != "$d" ] || break
		d=$up
	done
fi

# A tag, checked as a tag. `git clone --branch` takes a branch name just as
# happily, and a copy of a branch is a copy of something that will move.
remote_tag=$(git ls-remote --tags --refs "$source" "refs/tags/$tag" 2>/dev/null) ||
	mc_die "could not read the tags of $source. Not looking and finding nothing are different answers: check access and retry."
[ -n "$remote_tag" ] || mc_die "$source has no tag named $tag. Copies are taken from release tags only."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
depth=(--depth 1)
[ -d "$source" ] && depth=() # a local source is the test fixture; git ignores --depth there and says so
# ${a[@]+...}: bash 3.2 calls an empty array unbound under set -u.
git -c advice.detachedHead=false clone -q ${depth[@]+"${depth[@]}"} --branch "$tag" "$source" "$work/src" ||
	mc_die "could not clone $tag from $source."
commit=$(git -C "$work/src" rev-parse HEAD)

# The list of what was copied: path and blob, from git itself, so the check
# compares like with like whatever the line endings in the working tree.
git -C "$work/src" ls-tree -r -z HEAD >"$work/tree"

rm -rf "$dest"
mkdir -p "$dest"
git -C "$work/src" archive HEAD | tar -x -C "$dest"

mkdir -p .github
MC_TREE="$work/tree" MC_SRC="$source" MC_TAG="$tag" MC_COMMIT="$commit" MC_DEST="$dest" mc_py -c '
import json, os
files = {}
with open(os.environ["MC_TREE"], "rb") as fh:
    for entry in fh.read().split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, kind, blob = meta.decode().split(" ")
        if kind == "blob":
            files[path.decode("utf-8")] = blob
stamp = {
    "$comment": "Written by the merge coordinator vendor.sh. Do not edit by hand: check-vendored.sh compares the copy against this list, and a change belongs in the coordinator repository, then a release, then vendor.sh.",
    "source": os.environ["MC_SRC"],
    "tag": os.environ["MC_TAG"],
    "commit": os.environ["MC_COMMIT"],
    "path": os.environ["MC_DEST"],
    "files": dict(sorted(files.items())),
}
with open(".github/merge-coordinator.vendor", "wb") as fh:
    fh.write((json.dumps(stamp, indent=2) + "\n").encode("utf-8"))
'

git add -A -- "$dest" .github/merge-coordinator.vendor

# Prove it before saying it. If line-ending rules or attributes in THIS
# repository change what git stores, the copy is not what was fetched, and the
# CI check would fail on the first push. Better to find out here.
if ! bash "$here/check-vendored.sh" --index; then
	mc_die "the staged copy does not match $tag. Something in this repository changes what git stores for these files (check .gitattributes). Nothing is committed; inspect with git status."
fi

echo "merge-coordinator: copied $tag (${commit:0:12}) into $dest and staged it with .github/merge-coordinator.vendor."
echo "  Commit it on a branch and open a pull request. CI will hold the copy to that list from now on."
