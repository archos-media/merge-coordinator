#!/usr/bin/env bash
# Does a change to the plugin come with a higher version in plugin.json?
#
#   bash scripts/check-version-bump.sh <base> <head>
#
# An installed plugin updates only when the version in .claude-plugin/plugin.json
# changes, so a change landed without a bump never reaches a session. The
# changed files are those between the merge base of <base> and <head>, and
# <head>; the version at <head> must be higher than the version at <base>. On a
# pull request <base> is the base branch's tip. On main, release-tag.sh passes
# the commit that set the current version, so anything shipped since it fails,
# including a second pull request that bumped to the same version.
#
# Every file ships in the plugin except the top-level README.md and
# .github/**: those change nothing an installed copy does. Renames are listed
# as a deletion plus an addition, so moving a plugin file into .github/ still
# counts as a plugin change.
#
# THREE ANSWERS: 0 nothing that ships changed, or the version went up; 1 a file
# that ships changed and the version did not go up (each such file is named);
# 2 it could not look. A run that could not look must never read as a pass.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh" || { echo "check-version-bump: could not load $here/lib/gh.sh." >&2; exit 2; }
# mc_py stops with exit 1 when it finds no Python; probed in a subshell here,
# so that case reads as "could not look" and not as "not bumped".
(mc_py -c "") >/dev/null 2>&1 || { echo "check-version-bump: no working python3 (or python) on PATH." >&2; exit 2; }

[ $# -eq 2 ] || { echo "usage: check-version-bump.sh <base> <head>" >&2; exit 2; }
base="$1"
head="$2"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "check-version-bump: not inside a git repository, so there is nothing to compare." >&2; exit 2; }
cd "$top" || exit 2
for rev in "$base" "$head"; do
	git rev-parse --verify -q "$rev^{commit}" >/dev/null || { echo "check-version-bump: $rev is not a commit here (a shallow clone needs fetch-depth: 0)." >&2; exit 2; }
done
fork=$(git merge-base "$base" "$head") || { echo "check-version-bump: $base and $head share no history." >&2; exit 2; }

changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
git diff --name-only --no-renames -z "$fork" "$head" >"$changed" || { echo "check-version-bump: could not list the files changed between $fork and $head." >&2; exit 2; }

MC_CHANGED="$changed" MC_BASE="$base" MC_HEAD="$head" mc_py -c '
import json, os, re, subprocess, sys

MANIFEST = ".claude-plugin/plugin.json"

def version_at(rev):
    blob = subprocess.run(["git", "show", "%s:%s" % (rev, MANIFEST)], capture_output=True)
    if blob.returncode != 0:
        raise ValueError("%s has no %s" % (rev, MANIFEST))
    declared = json.loads(blob.stdout.decode("utf-8")).get("version")
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(declared))
    if not m:
        raise ValueError("%s at %s declares version %r, not N.N.N" % (MANIFEST, rev, declared))
    return declared, tuple(int(g) for g in m.groups())

def ships(path):
    return path != "README.md" and not path.startswith(".github/")

def main():
    with open(os.environ["MC_CHANGED"], "rb") as fh:
        paths = [p.decode("utf-8") for p in fh.read().split(b"\0") if p]
    shipped = sorted(p for p in paths if ships(p))
    if not shipped:
        print("check-version-bump: %d file(s) changed, none of them ships in the plugin; no bump needed." % len(paths))
        sys.exit(0)
    base, head = os.environ["MC_BASE"], os.environ["MC_HEAD"]
    (was, was_n), (now, now_n) = version_at(base), version_at(head)
    if now_n > was_n:
        print("check-version-bump: version %s -> %s covers %d changed plugin file(s)." % (was, now, len(shipped)))
        sys.exit(0)
    print("check-version-bump: %d plugin file(s) changed but %s says %s, and %s already said %s." % (len(shipped), MANIFEST, now, base, was))
    for p in shipped:
        print("  " + p)
    print("Installed copies update only when the version changes, and here it must go up. Raise \"version\" in %s above %s." % (MANIFEST, was))
    sys.exit(1)

try:
    main()
except SystemExit:
    raise
except Exception as exc:
    # A crash here is "could not look", never "bumped" and never "not bumped".
    print("check-version-bump: could not compare: %s" % exc, file=sys.stderr)
    sys.exit(2)'
