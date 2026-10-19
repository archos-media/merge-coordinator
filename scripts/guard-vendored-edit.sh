#!/usr/bin/env bash
# PreToolUse / Edit|Write|MultiEdit|NotebookEdit — refuse an edit inside a
# vendored copy of the merge coordinator.
#
# A copy (vendor.sh) is a release, held to a list of blobs by check-vendored.sh.
# An edit made here is either thrown away by the next vendor.sh or fails CI,
# and either way the coordinator repository never hears about it, which is how
# copies drift apart. So the edit is refused at the moment it is attempted, and
# the refusal says where the change belongs.
#
# It decides from the repository that holds the FILE: a copy is recognised by
# that repository's .github/merge-coordinator.vendor naming the folder the file
# is in. No stamp, no copy, no opinion.
#
# This runs on every edit in every project, so it rules out almost everything
# on raw text before starting anything. It fails OPEN: if it cannot read the
# payload or the stamp it says nothing. CI's check-vendored.sh is the gate;
# this only moves the refusal earlier.
set -u

payload="$(cat)"
case "$payload" in
*merge-coordinator*) ;;
*) exit 0 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

file=$(printf '%s' "$payload" | mc_py -c 'import json, sys
try:
    t = json.load(sys.stdin).get("tool_input") or {}
    sys.stdout.write(t.get("file_path") or t.get("notebook_path") or "")
except Exception:
    pass' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

# Paths arrive as D:\x\y on Windows. Compare them in one spelling.
posix() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}
f=$(posix "$file")

# The file may not exist yet (a Write that creates it), so look from the
# nearest directory that does.
d=$(dirname "$f")
while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d=$(dirname "$d"); done
top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || exit 0
stamp="$top/.github/merge-coordinator.vendor"
[ -f "$stamp" ] || exit 0

info=$(MC_STAMP="$stamp" mc_py -c 'import json, os, sys
try:
    s = json.load(open(os.environ["MC_STAMP"], encoding="utf-8"))
    sys.stdout.write("%s\t%s" % (s["path"].rstrip("/"), s.get("tag", "?")))
except Exception:
    pass' 2>/dev/null) || exit 0
tab=$(printf '\t')
vpath=${info%%"$tab"*}
tag=${info#*"$tab"}
[ -n "$vpath" ] || exit 0

t=$(posix "$top")
rel=${f#"$t"/}
[ "$rel" != "$f" ] || exit 0
# Windows paths are case-insensitive, and the two spellings can differ in case.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	rel_cmp=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
	vpath_cmp=$(printf '%s' "$vpath" | tr '[:upper:]' '[:lower:]')
	;;
*) rel_cmp=$rel vpath_cmp=$vpath ;;
esac
case "$rel_cmp" in
"$vpath_cmp"/*) ;;
*) exit 0 ;;
esac

printf '%s' "Refused: $rel is inside the vendored copy of the merge coordinator ($vpath, release $tag). An edit here is overwritten by the next vendor.sh, fails check-vendored.sh in CI, and never reaches the coordinator itself.

Make the change in the merge coordinator repository (archos-media/merge-coordinator), release it as a new tag, then refresh this copy on a branch:
  bash $here/vendor.sh <new tag>" | mc_py -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.stdin.read()}}))' 2>/dev/null
exit 0
