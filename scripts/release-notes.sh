#!/usr/bin/env bash
# Print the CHANGELOG.md notes for the version a commit declares.
#
#   bash scripts/release-notes.sh <ref>
#
# The version is `version` in .claude-plugin/plugin.json at <ref>, and its
# notes are the lines under the `## [v<version>]` heading of CHANGELOG.md at
# <ref>, up to the next `## ` heading. Every pull request runs this, so a
# version with no notes is caught before it merges; the release job runs it
# again for the text of the GitHub Release.
#
# THREE ANSWERS: 0 the notes, on stdout; 1 the heading is missing, appears
# twice, or has nothing under it; 2 it could not look.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh" || { echo "release-notes: could not load $here/lib/gh.sh." >&2; exit 2; }
# mc_py stops with exit 1 when it finds no Python; probed in a subshell here,
# so that case reads as "could not look".
(mc_py -c "") >/dev/null 2>&1 || { echo "release-notes: no working python3 (or python) on PATH." >&2; exit 2; }

[ $# -eq 1 ] || { echo "usage: release-notes.sh <ref>" >&2; exit 2; }
ref="$1"
manifest=.claude-plugin/plugin.json
changelog=CHANGELOG.md

git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "release-notes: $ref is not a commit here." >&2; exit 2; }
version=$(git show "$ref:$manifest" | mc_py -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["version"])') ||
	{ echo "release-notes: could not read the version from $manifest at $ref." >&2; exit 2; }
text=$(git show "$ref:$changelog") || { echo "release-notes: could not read $changelog at $ref." >&2; exit 2; }

# The text goes in on stdin: an environment variable has a size limit a long
# changelog would exceed. The heading goes in the environment, so it never has
# to survive a shell pattern.
printf '%s\n' "$text" | MC_HEADING="## [v$version]" MC_FILE="$changelog" mc_py -c '
import os, sys
heading, name = os.environ["MC_HEADING"], os.environ["MC_FILE"]
lines = sys.stdin.read().replace("\r", "").split("\n")
at = [i for i, line in enumerate(lines) if line.rstrip() == heading]
if not at:
    sys.exit("release-notes: %s has no %s heading, alone on its line. Add one, with what this version changes under it." % (name, heading))
if len(at) > 1:
    sys.exit("release-notes: %s has %d %s headings; a clean merge can do that. Keep one." % (name, len(at), heading))
notes = []
for line in lines[at[0] + 1:]:
    if line.startswith("## "):
        break
    notes.append(line)
body = "\n".join(notes).strip("\n")
if not body.strip():
    sys.exit("release-notes: %s has a %s heading with nothing under it." % (name, heading))
print(body)
'
