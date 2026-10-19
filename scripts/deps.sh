#!/usr/bin/env bash
# /merge-deps: the facts about one Dependabot pull request, and the verdict on
# it once a session has judged them.
#
# This script gathers; the session judges. Whether a bump is safe turns on its
# release notes, and reading those for a breaking change is reading, not
# matching. So the facts come out here in one place, the session decides safe,
# unsafe or needs a fix-up, and --record writes that down where the next session
# will see it: one comment and one label on the pull request.
#
# A verdict does NOT stop the pull request from waiting. ready.sh and land.sh
# keep stopping on it until it lands or closes, so a "safe" nobody acted on is
# still in the way, which is the point: it was in the way for a week before.
#
# Usage:
#   deps.sh 90                                     the facts
#   deps.sh 90 --record safe "patch, notes clean, CI green" <head sha>
#   deps.sh 90 --record unsafe "drops Node 18, which web still runs" <head sha>
#   deps.sh 90 --record fixup "next moved to 16; eslint-config-next did not" <head sha>
#
# The head sha is the one the facts printed. --record refuses when the pull
# request has moved since, because Dependabot rebases and regroups its own
# branches, and a verdict on a head nobody read is not one. Left out, the
# comment names the head at the time of recording and says so.
#
# The facts, in order: what moves (each package, from and to, major / minor /
# patch; a grouped pull request lists several), the files it changes and the
# diff of each manifest, the fix-ups and pairings this repository's config names
# for them, whether the branch is behind the default branch, the required checks
# on the exact head, and Dependabot's own description, which carries the release
# notes.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

mc_require_config

pr="${1:-}"
case "$pr" in
'' | *[!0-9]*) mc_die "usage: deps.sh <pr-number> [--record safe|unsafe|fixup \"<one line why>\" [<head sha>]]" ;;
esac
shift
record=""
why=""
reviewed=""
if [ $# -gt 0 ]; then
	[ "$1" = "--record" ] || mc_die "unknown option $1"
	[ $# -eq 3 ] || [ $# -eq 4 ] ||
		mc_die "--record takes a verdict, one line saying why, and the head sha the facts printed: --record safe|unsafe|fixup \"<why>\" <sha>"
	record="$2"
	why="$3"
	reviewed="${4:-}"
	case "$record" in
	safe | unsafe | fixup) ;;
	*) mc_die "the verdict is safe, unsafe or fixup, not '$record'." ;;
	esac
	[ -n "$(printf '%s' "$why" | tr -d '[:space:]')" ] || mc_die "--record needs a reason. The next session reads it instead of redoing the review."
fi

repo=$(mc_repo)
cfg=$(mc_config_path)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The pull request, raw, read once. Read as JSON in python rather than through
# --jq, so the tests prove what is read out of it.
mc_gh api "repos/$repo/pulls/$pr" >"$work/pr.json" || mc_die "could not read #$pr."
meta=$(MC_PR="$work/pr.json" MC_BODY="$work/body.md" mc_py -c '
import io, json, os, sys
with io.open(os.environ["MC_PR"], encoding="utf-8") as fh:
    pr = json.load(fh)
user = pr.get("user") or {}
if user.get("type") != "Bot" or user.get("login") != "dependabot[bot]":
    sys.exit("merge-coordinator: #%s was opened by %s, not by Dependabot. /merge-deps is for Dependabot pull requests."
             % (pr.get("number"), user.get("login") or "nobody"))
with io.open(os.environ["MC_BODY"], "w", encoding="utf-8", newline="\n") as fh:
    fh.write(pr.get("body") or "")
print("\t".join([pr.get("state") or "", (pr.get("head") or {}).get("sha") or "",
                 " ".join((pr.get("title") or "").split())]))
')
IFS=$'\t' read -r state sha title <<<"$meta"
[ "$state" = "open" ] || mc_die "#$pr is $state, not open."
[ -n "$sha" ] || mc_die "could not read the head commit of #$pr."

# --------------------------------------------------------------------------
# --record
# --------------------------------------------------------------------------
if [ -n "$record" ]; then
	if [ -n "$reviewed" ] && [ "$reviewed" != "$sha" ]; then
		mc_die "#$pr has moved since the facts were read: its head is $sha, not $reviewed.
  Read the facts again (deps.sh $pr) and judge the new head. Nothing was recorded."
	fi
	if [ -n "$reviewed" ]; then
		head_line="Head reviewed: $sha"
	else
		head_line="Head when recorded: $sha"
	fi
	case "$record" in
	safe) label="deps:safe" color="0e8a16" said="safe to land" ;;
	unsafe) label="deps:unsafe" color="b60205" said="unsafe: close it and tell Dependabot to ignore it" ;;
	fixup) label="deps:needs-fixup" color="fbca04" said="needs a fix-up before it can land" ;;
	esac
	# Created on first use. --force updates it in place when it exists (its
	# colour and description are reset to these), so a second use does not fail.
	mc_gh label create "$label" --repo "$repo" --color "$color" \
		--description "/merge-deps verdict on a Dependabot pull request" --force >/dev/null ||
		mc_die "could not create the label $label."
	labels=$(mc_gh api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")') ||
		mc_die "could not read the labels of #$pr."
	# One verdict at a time: a newer one replaces the old.
	for old in deps:safe deps:unsafe deps:needs-fixup; do
		[ "$old" = "$label" ] && continue
		case ",$labels," in
		*",$old,"*) mc_gh pr edit "$pr" --repo "$repo" --remove-label "$old" >/dev/null ||
			mc_die "could not remove $old from #$pr." ;;
		esac
	done
	mc_gh pr edit "$pr" --repo "$repo" --add-label "$label" >/dev/null || mc_die "could not label #$pr $label."
	mc_gh pr comment "$pr" --repo "$repo" --body "**/merge-deps verdict: $said.**

$why

$head_line" >/dev/null || mc_die "#$pr is labelled $label, but the comment saying why could not be posted."
	echo "merge-coordinator: #$pr recorded as $label, with the reason as a comment."
	case "$record" in
	safe) echo "  Next: /merge-land $pr." ;;
	unsafe) echo "  Next: comment '@dependabot ignore this major version' (or 'ignore this dependency'; for a grouped pull request '@dependabot ignore <package> major version'). Dependabot closes it." ;;
	fixup) echo "  Next: bring the user the options. Push nothing to the Dependabot branch." ;;
	esac
	exit 0
fi

# --------------------------------------------------------------------------
# The facts
# --------------------------------------------------------------------------
# The files, raw, with their patches: the manifest diffs are the other place the
# versions are written, and the only one left when the description is in no form
# this reads.
mc_gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" >"$work/files.json" ||
	mc_die "could not list the files of #$pr."

echo "merge-coordinator: Dependabot pull request #$pr"
echo "  $title"
echo "  https://github.com/$repo/pull/$pr"
echo

# What moves, and what the config says about it. One python pass, because the
# pairings need the package list and the fix-ups need the file list.
MC_BODY="$work/body.md" MC_TITLE="$title" MC_FILES="$work/files.json" MC_FILE="$cfg" mc_py -c '
import fnmatch, io, json, os, re, sys

body = io.open(os.environ["MC_BODY"], encoding="utf-8").read()
title = os.environ["MC_TITLE"]

# gh --paginate writes one JSON array per page, back to back.
text = io.open(os.environ["MC_FILES"], encoding="utf-8").read()
dec, i, entries = json.JSONDecoder(), 0, []
try:
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        page, i = dec.raw_decode(text, i)
        entries.extend(page)
    files = [e["filename"] for e in entries]
except Exception as exc:
    sys.exit("merge-coordinator: the file list could not be read (%s)" % exc.__class__.__name__)
patches = {e["filename"]: e.get("patch") for e in entries}

def v(text):
    return text.rstrip(".,;:")

moves = []
def add(pkg, frm, to):
    item = (pkg.strip(), v(frm), v(to))
    if item not in moves:
        moves.append(item)

# A grouped pull request lists every package in a table, one per directory,
#   | [x](link) | `a` | `b` |
# and then "Updates `x` from a to b" above the notes of each package, for as
# many as fit. Read both: the table is the whole list, and an "Updates" line is the only
# form some older bodies have. Seen live, 13 Oct 2026, on a group of 7 updates
# whose body had "Updates" lines for 5.
for m in re.finditer(r"^\|\s*\[([^\]]+)\]\([^)]*\)\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|", body, re.M):
    add(*m.groups())
for m in re.finditer(r"Updates `([^`]+)` from (\S+) to (\S+)", body):
    add(*m.groups())
# A single bump says "Bumps [x](link) from a to b."
for m in re.finditer(r"Bumps \[([^\]]+)\]\([^)]*\) from (\S+) to (\S+)", body):
    add(*m.groups())
# And the title says it too, when the body is not in either form.
if not moves:
    m = re.search(r"[Bb]ump (\S+) from (\S+) to (\S+)", title)
    if m:
        add(*m.groups())

def parts(version):
    nums = []
    for piece in version.lstrip("vV").split("."):
        m = re.match(r"\d+", piece)
        if not m:
            break
        nums.append(int(m.group()))
    return nums

def kind(frm, to):
    a, b = parts(frm), parts(to)
    if not a or not b:
        return "unknown (not a version this reads)"
    a, b = (a + [0, 0, 0])[:3], (b + [0, 0, 0])[:3]
    for i, name in enumerate(("MAJOR", "minor", "patch")):
        if a[i] != b[i]:
            if name == "minor" and a[0] == 0:
                return "minor, on 0.x, where a minor can break"
            return name
    # The numbers agree and the strings do not: a Go pseudo-version
    # (v0.0.0-20240101-abc) or a pre-release. That can be any change at all.
    return "unknown (a pseudo or pre-release version; read the commits)"

print("What moves:")
if not moves:
    print("  could not read the packages from the title or the description. Read the description below.")
for pkg, frm, to in moves:
    print("  %s  %s -> %s  (%s)" % (pkg, frm, to, kind(frm, to)))
print()

print("Files it changes:")
for f in files:
    print("  " + f)
if not files:
    print("  none listed")
print()

# The manifest diffs, where the versions are written down. Lock files are left
# out: they run to thousands of lines and repeat what the manifest says.
LOCKS = ("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "go.sum",
         "Gemfile.lock", "poetry.lock", "Pipfile.lock", "uv.lock", "Cargo.lock", "composer.lock")
LIMIT = 60
print("Manifest diffs (lock files left out):")
shown = False
for f in files:
    if f.rsplit("/", 1)[-1] in LOCKS:
        continue
    shown = True
    patch = patches.get(f)
    if not patch:
        print("  %s: GitHub gives no diff for it (too large, or binary)" % f)
        continue
    lines = patch.splitlines()
    print("  %s:" % f)
    for line in lines[:LIMIT]:
        print("    " + line)
    if len(lines) > LIMIT:
        print("    [%d more lines]" % (len(lines) - LIMIT))
if not shown:
    print("  none: every file it changes is a lock file")
print()

try:
    cfg = json.load(io.open(os.environ["MC_FILE"], encoding="utf-8"))
except Exception as exc:
    sys.exit("merge-coordinator: cannot read %s: %s" % (os.environ["MC_FILE"], exc))
block = cfg.get("dependabot") or {}
if not isinstance(block, dict):
    sys.exit("merge-coordinator: the dependabot key in %s is not an object." % os.environ["MC_FILE"])
fixups = block.get("fixups") or []
pairings = block.get("pairings") or []
for name, items, keys in (("fixups", fixups, ("when", "run", "why")),
                          ("pairings", pairings, ("package", "with", "why"))):
    if not isinstance(items, list) or not all(isinstance(i, dict) and all(k in i for k in keys) for i in items):
        sys.exit("merge-coordinator: dependabot.%s in %s must be a list of {%s}."
                 % (name, os.environ["MC_FILE"], ", ".join(keys)))
for fx in fixups:
    pr_ = fx.get("produces")
    if "produces" in fx and not (isinstance(pr_, str) and pr_.strip() and pr_ == pr_.strip()
                                 and not pr_.startswith("/")):
        sys.exit("merge-coordinator: dependabot.fixups in %s: produces, when given, is a glob naming the files the fix-up writes,"
                 " read from the folder of the file that matched when (vendor/**), with no spaces around it."
                 % os.environ["MC_FILE"])

def fold(p):
    while "**" in p:
        p = p.replace("**", "*")
    return p

print("Fix-ups this repository names for these files:")
for fx in fixups:
    hit = [f for f in files if fnmatch.fnmatchcase(f, fold(fx["when"]))]
    if not hit:
        # Said, not skipped: a "when" that matches no path in the repository
        # would otherwise read exactly like "no fix-up needed".
        print("  none for %s: no file it changes matches" % fx["when"])
        continue
    # Each file that matched is judged on its own, so a grouped bump across
    # several modules names every one that still needs the fix-up.
    for t in hit:
        if "produces" not in fx:
            print("  %s changes, so run: %s" % (t, fx["run"]))
            print("    why: %s" % fx["why"])
            continue
        # What the fix-up writes, read from the folder of the file that
        # matched: vendor/** beside go/go.mod is go/vendor/**, so one module
        # cannot vouch for another. Dependabot regenerates some outputs itself
        # (a committed vendor/ comes in the same commit as go.mod), and naming
        # a fix-up the pull request already carries leads the session to record
        # needs-fixup for nothing. The files that matched "when" and lock files
        # never count as output: Dependabot changes them on every bump, so a
        # produces broad enough to take them in would vouch for anything.
        beside = t.rsplit("/", 1)[0] + "/" if "/" in t else ""
        pattern = beside + fx["produces"]
        made = [f for f in files if f not in hit and f.rsplit("/", 1)[-1] not in LOCKS
                and fnmatch.fnmatchcase(f, fold(pattern))]
        if made:
            print("  %s changes, and so do %d file(s) matching %s (%s): the pull request already carries %s."
                  % (t, len(made), pattern, made[0], fx["run"]))
            print("    Nothing to run, unless the required checks say what it carries is incomplete.")
        else:
            print("  %s changes, so run: %s" % (t, fx["run"]))
            print("    why: %s" % fx["why"])
            print("    no file matching %s changes: the pull request does not carry it" % pattern)
if not fixups:
    print("  none configured (dependabot.fixups)")
print()

print("Pairings:")
said = False
moved = {pkg: to for pkg, frm, to in moves}
for pa in pairings:
    a, b = pa["package"], pa["with"]
    if a not in moved and b not in moved:
        continue
    said = True
    if a in moved and b in moved:
        ma, mb = parts(moved[a])[:1], parts(moved[b])[:1]
        if ma and ma == mb:
            print("  %s and %s move together, both to major %s." % (a, b, ma[0]))
        else:
            print("  MISMATCH: %s goes to %s and %s to %s." % (a, moved[a], b, moved[b]))
    else:
        lone, other = (a, b) if a in moved else (b, a)
        print("  MISMATCH: %s moves to %s and %s does not move with it." % (lone, moved[lone], other))
    print("    why they go together: %s" % pa["why"])
if not said:
    print("  none" if pairings else "  none configured (dependabot.pairings)")
'
echo

behind=$(mc_behind_by "$sha" 2>/dev/null) || behind=""
case "$behind" in
'') echo "Behind $(mc_cfg_get defaultBranch): could not read." ;;
0) echo "Behind $(mc_cfg_get defaultBranch): no, it is current." ;;
*) echo "Behind $(mc_cfg_get defaultBranch): $behind commit(s). Comment '@dependabot rebase' to bring it up to date,
  not land.sh --update-branch: a merge commit pushed to its branch stops Dependabot rebasing it." ;;
esac
echo

echo "Required checks on $sha:"
mc_require_checks "$sha" || true
echo

# Dependabot puts the release notes, the changelog and the commits in its
# description. Capped, and the cap is said: a cut that is not said reads as the
# whole thing.
echo "Dependabot's description (release notes, changelog, commits):"
MC_BODY="$work/body.md" MC_PR_NUMBER="$pr" mc_py -c '
import io, os
lines = io.open(os.environ["MC_BODY"], encoding="utf-8").read().splitlines()
LIMIT = 400
for line in lines[:LIMIT]:
    print("  " + line)
if len(lines) > LIMIT:
    print("  [%d more lines: gh pr view %s]" % (len(lines) - LIMIT, os.environ.get("MC_PR_NUMBER", "")))
' 2>/dev/null || echo "  could not print it: gh pr view $pr"
echo
echo "Judge it, then record the verdict on this head:"
echo "  bash $here/deps.sh $pr --record safe|unsafe|fixup \"<one line why>\" $sha"
