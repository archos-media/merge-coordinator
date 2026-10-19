#!/usr/bin/env bash
# Is the vendored copy of the merge coordinator exactly the release it claims?
#
#   bash tools/merge-coordinator/scripts/check-vendored.sh            # HEAD
#   bash tools/merge-coordinator/scripts/check-vendored.sh --ref <rev>
#   bash tools/merge-coordinator/scripts/check-vendored.sh --index    # what is staged
#
# Reads .github/merge-coordinator.vendor (written by vendor.sh) and compares
# every file under its "path" with the blob recorded there: same paths, same
# contents. Git's own blob ids are compared, so line endings in a working tree
# cannot make a clean copy look edited, and nothing needs the network.
#
# THREE ANSWERS: 0 the copy is the release; 1 it is not (and every changed,
# added and missing file is named); 2 it could not look. A run that could not
# look must never read as a clean one.
#
# MC_VENDOR_STAMP overrides the stamp path. It exists for the tests.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

mode=ref
rev=HEAD
while [ $# -gt 0 ]; do
	case "$1" in
	--index) mode=index; shift ;;
	--ref)
		[ $# -ge 2 ] || { echo "check-vendored: --ref needs a revision." >&2; exit 2; }
		rev="$2"; shift 2 ;;
	*) echo "check-vendored: unknown argument $1" >&2; exit 2 ;;
	esac
done

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "check-vendored: not inside a git repository, so there is nothing to compare." >&2; exit 2; }
cd "$top" || exit 2
stamp="${MC_VENDOR_STAMP:-$top/.github/merge-coordinator.vendor}"
[ -f "$stamp" ] || { echo "check-vendored: no stamp at $stamp. Run vendor.sh <tag> to create the copy and its stamp." >&2; exit 2; }

vpath=$(MC_STAMP="$stamp" mc_py -c '
import json, os, sys
try:
    p = json.load(open(os.environ["MC_STAMP"], encoding="utf-8"))["path"]
except Exception as exc:
    sys.exit("check-vendored: cannot read the path from %s: %s" % (os.environ["MC_STAMP"], exc))
sys.stdout.write(p)') || exit 2

listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
if [ "$mode" = index ]; then
	git ls-files -s -z -- "$vpath" >"$listing" || { echo "check-vendored: could not list the index." >&2; exit 2; }
else
	git rev-parse --verify -q "$rev^{commit}" >/dev/null || { echo "check-vendored: $rev is not a commit here." >&2; exit 2; }
	git ls-tree -r -z "$rev" -- "$vpath" >"$listing" || { echo "check-vendored: could not list $rev." >&2; exit 2; }
fi

MC_STAMP="$stamp" MC_LIST="$listing" MC_MODE="$mode" MC_PATH="$vpath" mc_py -c '
import json, os, sys

def main():
    stamp = json.load(open(os.environ["MC_STAMP"], encoding="utf-8"))
    want = stamp.get("files")
    if not isinstance(want, dict) or not want:
        print("check-vendored: the stamp lists no files, so there is nothing to hold the copy to.", file=sys.stderr)
        sys.exit(2)
    prefix = os.environ["MC_PATH"].rstrip("/") + "/"
    have = {}
    with open(os.environ["MC_LIST"], "rb") as fh:
        for entry in fh.read().split(b"\0"):
            if not entry:
                continue
            meta, path = entry.split(b"\t", 1)
            fields = meta.decode().split(" ")
            # ls-files -s: mode blob stage    ls-tree: mode type blob
            blob = fields[1] if os.environ["MC_MODE"] == "index" else fields[2]
            path = path.decode("utf-8")
            if path.startswith(prefix):
                have[path[len(prefix):]] = blob
    changed = sorted(p for p in want if p in have and have[p] != want[p])
    missing = sorted(p for p in want if p not in have)
    added = sorted(p for p in have if p not in want)
    label = "%s (%s)" % (stamp.get("tag", "?"), str(stamp.get("commit", "?"))[:12])
    if not (changed or missing or added):
        print("check-vendored: %s matches %s, %d files." % (os.environ["MC_PATH"], label, len(want)))
        sys.exit(0)
    print("check-vendored: %s is NOT %s." % (os.environ["MC_PATH"], label))
    for name, rows in (("changed", changed), ("added", added), ("missing", missing)):
        for r in rows:
            print("  %-8s %s/%s" % (name, os.environ["MC_PATH"], r))
    print("A change belongs in the merge coordinator repository, then a release, then vendor.sh <tag>.")
    print("To put this copy back: vendor.sh %s" % stamp.get("tag", "<tag>"))
    sys.exit(1)

try:
    main()
except SystemExit:
    raise
except Exception as exc:
    # A crash here is "could not look", never "drifted" and never "clean".
    print("check-vendored: could not compare: %s" % exc, file=sys.stderr)
    sys.exit(2)'
