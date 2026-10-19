#!/usr/bin/env bash
# The ordering analysis: which open PRs may land in parallel, and which must
# queue behind which.
#
# It answers one question — if this PR lands now, what does that do to the
# others? Three ways two PRs can be entangled:
#
#   1. TEXTUAL   their changed-file sets intersect.
#   2. HOTSPOT   both touch a path listed in the config's hotspot table, even
#                with no file in common. This is the case a merge queue cannot
#                see: two edits under one CHANGELOG heading merge cleanly and
#                lose an entry, and git reports no conflict at any point.
#   3. DEPENDENCY one PR's head is an ancestor of the other's, so the second
#                already contains the first and has to follow it.
#
# And one thing that is reported and never ordered:
#
#   4. DECLARED   a pull request said in its body which paths it expects to
#                touch, and that declaration covers what another one is already
#                changing, or what another one also declared. This is the only
#                signal that exists BEFORE the code is written - a draft opened
#                at the start of a task has no commits, so rules 1 to 3 have
#                nothing to read. It is a prediction, so it never forces an
#                order and never joins a chain.
#
# `backbone` DECIDES WHAT A TEXTUAL OVERLAP MEANS.
#
# On serialized-claim, all three force an order: nothing re-tests between a
# green run and the merge, so anyone sharing a file with the merge went stale.
#
# On github-merge-queue, only 2 and 3 force an order. The queue builds the base
# plus everything ahead of a pull request and tests THAT, so two branches
# editing one file are both retested against the real result and neither has to
# go first. A textual overlap is still reported — it is where a conflict would
# come from — under its own heading, with no waiting attached.
#
# WHAT THIS DOES NOT DO. It does not read diffs, only file names. Two PRs
# editing opposite ends of one file are reported as overlapping even though git
# would merge them without complaint. That direction is chosen on purpose, and
# on a queue it is nearly free: the finding is a note rather than a queue to
# join. A false "go ahead" still costs a release heading.
#
# Draft PRs are included and labelled REGISTERED. A draft is how a session says
# "I am working here" before it has anything to land, so it has to be visible
# even though it cannot be landed.
#
# Usage:  overlap.sh            report on every open PR
#         overlap.sh 42         report only on what blocks or is blocked by #42
#         overlap.sh 42 --ci-ahead
#                               machine mode for guard-ready.sh. Prints the
#                               number of every NON-DRAFT open PR that shares
#                               ground with #42, one per line. Exit 0 nothing
#                               ahead, 1 something ahead, 3 could not tell.
#
#         overlap.sh 42 --ci-ahead --except=90,91
#                               the same, never naming these. ready.sh passes
#                               the Dependabot pull requests the user put off
#                               with --skip-deps.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# Before anything else, and in THIS shell rather than in a subshell that cannot
# stop the script. See mc_require_config in lib/gh.sh.
mc_require_config

focus=""
ci_ahead=0
except=""
for arg in "$@"; do
	case "$arg" in
	--ci-ahead) ci_ahead=1 ;;
	--except=*)
		except="${arg#--except=}"
		case "$except" in
		'' | *[!0-9,]*) mc_die "--except takes pull request numbers joined by commas, not '$except'." ;;
		esac
		;;
	-*) mc_die "unknown option $arg" ;;
	*) focus="$arg" ;;
	esac
done

if [ "$ci_ahead" -eq 1 ] && [ -z "$focus" ]; then
	mc_die "--ci-ahead needs a pull request number."
fi
if [ -n "$except" ] && [ "$ci_ahead" -ne 1 ]; then
	mc_die "--except goes with --ci-ahead."
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
records="$work/records.tsv"

# MC_OVERLAP_INPUT feeds a pre-built record file straight to the analysis. The
# test script uses it to exercise every ordering rule without a network, and the
# fixture-gh path above it is tested separately.
if [ -n "${MC_OVERLAP_INPUT:-}" ]; then
	cp "$MC_OVERLAP_INPUT" "$records"
else
	: >"$records"

	# One line per PR, then one line per changed file. Both prefixed, so the
	# analysis reads a single stream.
	#
	# Each list is read into a variable BEFORE the loop, never as $(...) inside
	# the heredoc. A heredoc throws away the exit status of a substitution in
	# it, so a failed call read as an empty list. Human mode then printed "no
	# open pull requests", and a PR whose files could not be read overlapped
	# nothing, which in --ci-ahead mode let ready.sh go ahead. Exit 3 is "could
	# not tell" in both modes, and ready.sh already refuses on it.
	if ! open_prs=$(mc_open_prs); then
		echo "merge-coordinator: could not list the open pull requests; the API call failed. Nothing was checked." >&2
		exit 3
	fi
	numbers=""
	while IFS=$'\t' read -r number title draft head labels; do
		[ -z "$number" ] && continue
		printf 'PR\t%s\t%s\t%s\t%s\n' "$number" "$title" "$draft" "$labels" >>"$records"
		numbers="$numbers $number"
	done <<EOF
$open_prs
EOF

	if [ -z "$numbers" ]; then
		# In machine mode this is not "nothing ahead" — the focus pull request
		# is not open either, so the question was never answered. Say could not
		# tell and let the caller fail closed.
		# Not mc_die: that always exits 1, and 1 already means "something is
		# ahead". These have to stay tellable apart.
		if [ "$ci_ahead" -eq 1 ]; then
			echo "merge-coordinator: no open pull requests, so #$focus is not one of them." >&2
			exit 3
		fi
		echo "merge-coordinator: no open pull requests."
		exit 0
	fi

	for n in $numbers; do
		if ! pr_files=$(mc_pr_files "$n"); then
			echo "merge-coordinator: could not list the files of #$n, so what it shares with the others is unknown. Nothing was checked; run it again." >&2
			exit 3
		fi
		while IFS= read -r path; do
			[ -z "$path" ] && continue
			printf 'F\t%s\t%s\n' "$n" "$path" >>"$records"
		done <<EOF
$pr_files
EOF

		# Declared paths are written ALONGSIDE the real ones, never instead of
		# them. A pull request that declares a footprint keeps every finding its
		# actual files produce; the declaration only ever adds. Getting this
		# backwards would let a wrong prediction hide a real overlap, which is
		# worse than having no prediction at all.
		#
		# A body that cannot be read is reported by mc_pr_footprint and skipped
		# here. It must not stop the analysis: everything above this line is
		# still true, and an ordering answer is more useful than none.
		while IFS= read -r glob; do
			[ -z "$glob" ] && continue
			printf 'D\t%s\t%s\n' "$n" "$glob" >>"$records"
		done <<EOF
$(mc_pr_footprint "$n" || true)
EOF
	done

	# Ancestry is one API call per pair, so it is only asked about pairs that
	# already share a file. A pair with nothing in common is not going to be a
	# stacked branch.
	shas="$work/shas"
	: >"$shas"
	for n in $numbers; do
		printf '%s\t%s\n' "$n" "$(mc_pr_head_sha "$n")" >>"$shas"
	done
	repo=$(mc_repo)
	for a in $numbers; do
		for b in $numbers; do
			[ "$a" -ge "$b" ] && continue
			shared=$(awk -F'\t' -v a="$a" -v b="$b" '
				$1=="F" && $2==a { seen[$3]=1 }
				$1=="F" && $2==b && ($3 in seen) { print; exit }
			' "$records")
			[ -z "$shared" ] && continue
			sha_a=$(awk -F'\t' -v n="$a" '$1==n {print $2}' "$shas")
			sha_b=$(awk -F'\t' -v n="$b" '$1==n {print $2}' "$shas")
			status=$(mc_gh api "repos/$repo/compare/$sha_a...$sha_b" --jq '.status' 2>/dev/null || echo "")
			case "$status" in
			ahead) printf 'DEP\t%s\t%s\n' "$a" "$b" >>"$records" ;;  # b contains a
			behind) printf 'DEP\t%s\t%s\n' "$b" "$a" >>"$records" ;; # a contains b
			esac
		done
	done
fi

# The hotspot table travels with the records so the analysis needs no second
# config read.
mc_hotspots | sed 's/^/HOTSPOT\t/' >>"$records"

# The ordering advice used to be backbone-blind by construction: this
# script never read the setting, so it gave serialized-claim answers on a repo
# running a merge queue. That is how a pull request whose only overlap was one
# file got told it was fifth in a chain of seven.
backbone=$(mc_cfg_get backbone)

MC_FOCUS="$focus" MC_RECORDS="$records" MC_BACKBONE="$backbone" \
	MC_CI_AHEAD="$ci_ahead" MC_EXCEPT="$except" MC_BLOCKED_LABEL="$(mc_cfg_get labels.blocked)" \
	mc_py -c '
import os, sys
from collections import defaultdict

records = os.environ["MC_RECORDS"]
focus = os.environ.get("MC_FOCUS") or ""
backbone = os.environ.get("MC_BACKBONE") or ""

# On a merge queue, sharing a file is not a reason to wait. The queue builds the
# base plus everything ahead of a pull request and tests THAT, so two branches
# editing opposite ends of one file both get retested against the real result
# and neither has to go first. It is still worth SAYING they overlap — that is
# how a session knows where to look when one of them does conflict — so the
# finding is kept and only its consequence changes.
#
# What still forces an order on a queue:
#   HOTSPOT     a clean merge is the dangerous case, and a queue merges cleanly
#               and is exactly as wrong.
#   DEPENDENCY  one head already contains the other. Order is not a choice.
#   TRUNCATED   the file list hit the API ceiling, so "they do not overlap" was
#               never established. Unknown is not the same as safe.
queue = backbone == "github-merge-queue"

prs = {}            # number -> {title, draft, labels}
files = defaultdict(set)
declared = defaultdict(set)   # number -> the globs it says it will touch
deps = []           # (ancestor, descendant)
hotspots = []       # (pattern, rule, action, why)

with open(records, encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0]:
            continue
        kind = parts[0]
        if kind == "PR" and len(parts) >= 5:
            prs[parts[1]] = {"title": parts[2], "draft": parts[3] == "true", "labels": parts[4]}
        elif kind == "F" and len(parts) >= 3:
            files[parts[1]].add(parts[2])
        elif kind == "D" and len(parts) >= 3:
            declared[parts[1]].add(parts[2])
        elif kind == "DEP" and len(parts) >= 3:
            deps.append((parts[1], parts[2]))
        elif kind == "HOTSPOT" and len(parts) >= 5:
            hotspots.append(tuple(parts[1:5]))

if not prs:
    # Machine mode has to say "could not tell", never "nothing ahead".
    if os.environ.get("MC_CI_AHEAD") == "1":
        sys.stderr.write("merge-coordinator: no open pull requests.\n")
        sys.exit(3)
    print("merge-coordinator: no open pull requests.")
    sys.exit(0)

def fold(pattern):
    while "**" in pattern:
        pattern = pattern.replace("**", "*")
    return pattern

import fnmatch
def in_hotspot(path, pattern):
    # fnmatch, not pathlib globbing: * has to cross directory separators, the
    # same way the bash case statement in lib/gh.sh treats it.
    return fnmatch.fnmatchcase(path, fold(pattern))

def covers(glob, path):
    # Same folding as the hotspot table: "**" and "*" both cross directory
    # separators here, so a declaration reads the way whoever wrote it meant.
    return fnmatch.fnmatchcase(path, fold(glob))

def declared_notes(a, b):
    """Everything the declarations say about this pair, as finished lines.

    Called once per pair and reads both directions itself, so two pull requests
    claiming the same ground are reported once rather than once from each side.

    Nothing in here reads or alters the real-file findings. A declaration is a
    prediction: it may only ever ADD a warning, never remove one."""
    notes = []
    shared_seen = set()
    for owner, other in ((a, b), (b, a)):
        for glob in sorted(declared.get(owner, ())):
            # Against the real files of the other pull request first. This is the
            # case where one session has already written the code, and it is
            # the more certain of the two, so it is the one reported.
            hit = None
            for path in sorted(files.get(other, ())):
                if path == "MERGE-COORDINATOR-TRUNCATED":
                    continue
                if covers(glob, path):
                    hit = "#%s declared %s, which #%s already changes (%s)" % (
                        owner, glob, other, path)
                    break
            if hit is None:
                # Against the DECLARATION of the other pull request. This is the
                # case the whole layer exists for: two sessions that have
                # written no code yet, where every other rule has nothing to
                # read. Compared as text in both directions, which catches an
                # identical declaration and one nested inside a broader one.
                # It is not true glob intersection and does not pretend to be.
                for og in sorted(declared.get(other, ())):
                    if glob == og or covers(glob, og) or covers(og, glob):
                        key = tuple(sorted((glob, og)))
                        if key not in shared_seen:
                            shared_seen.add(key)
                            hit = "#%s and #%s both declared the same ground (%s / %s)" % (
                                a, b, key[0], key[1])
                        break
            if hit:
                notes.append(hit)
    return notes

# For each PR, which hotspots it sits in.
spot_of = {n: set() for n in prs}
for n in prs:
    for path in files.get(n, ()):
        if path == "MERGE-COORDINATOR-TRUNCATED":
            spot_of[n].update(h[0] for h in hotspots)
            continue
        for h in hotspots:
            if in_hotspot(path, h[0]):
                spot_of[n].add(h[0])

hotspot_by_path = {h[0]: h for h in hotspots}

numbers = sorted(prs, key=lambda n: int(n))

# A PR whose file list was truncated is treated as touching everything.
truncated = {n for n in numbers if "MERGE-COORDINATOR-TRUNCATED" in files.get(n, ())}

def edge(a, b):
    """(what forces an order, what is only worth knowing). Either may be None."""
    ordering = []
    notes = []
    shared = (files.get(a, set()) & files.get(b, set())) - {"MERGE-COORDINATOR-TRUNCATED"}
    if a in truncated or b in truncated:
        ordering.append("one of them changes more files than the API will list")
    if shared:
        shown = sorted(shared)[:3]
        more = "" if len(shared) <= 3 else " (+%d more)" % (len(shared) - 3)
        text = "both change " + ", ".join(shown) + more
        # The one line that moves. On a queue this is worth knowing and is not
        # worth waiting for; everywhere else it is the whole reason to wait.
        (notes if queue else ordering).append(text)
    common_spots = spot_of[a] & spot_of[b]
    for pattern in sorted(common_spots):
        rule = hotspot_by_path[pattern][1]
        ordering.append("both touch %s — hotspot, rule: %s" % (pattern, rule))
    return ("; ".join(ordering) or None, "; ".join(notes) or None)

# An "alone" hotspot entangles its PR with EVERY other PR, not just matching ones.
alone_prs = set()
for n in numbers:
    for pattern in spot_of[n]:
        if hotspot_by_path[pattern][1] == "alone":
            alone_prs.add(n)

edges = {}
overlaps = {}   # pairs that share a file but do not have to be ordered
for i, a in enumerate(numbers):
    for b in numbers[i + 1:]:
        why, note = edge(a, b)
        if note:
            overlaps[(a, b)] = note
        if why is None and (a in alone_prs or b in alone_prs):
            lone = a if a in alone_prs else b
            pattern = sorted(p for p in spot_of[lone]
                             if hotspot_by_path[p][1] == "alone")[0]
            why = "#%s changes %s and must land alone" % (lone, pattern)
        if why:
            edges[(a, b)] = why

# Declarations are computed here, AFTER the ordering edges and outside edge().
# Nothing below this line can put one into `edges`, so a prediction cannot make
# a chain even by accident: the union guard is structural rather than a rule
# somebody has to remember. Delete this separation and a wrong prediction could
# reorder real work.
declarations = {}
for i, a in enumerate(numbers):
    for b in numbers[i + 1:]:
        said = declared_notes(a, b)
        if said:
            declarations[(a, b)] = said

for anc, desc in deps:
    if anc in prs and desc in prs:
        prior = edges.get((min(anc, desc, key=int), max(anc, desc, key=int)))
        note = "#%s is built on top of #%s" % (desc, anc)
        key = (min(anc, desc, key=int), max(anc, desc, key=int))
        edges[key] = (prior + "; " + note) if prior else note

# Connected components: everything reachable through an edge has to serialize.
parent = {n: n for n in numbers}
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb:
        parent[rb] = ra
for (a, b) in edges:
    union(a, b)

groups = defaultdict(list)
for n in numbers:
    groups[find(n)].append(n)

def is_hotfix(n):
    labels = prs[n]["labels"].split(",")
    return "sev:critical" in labels or prs[n]["title"].lower().startswith(("hotfix", "revert"))

def is_ready(n):
    # Can this pull request land at all, right now?
    #
    # A draft runs no CI and GitHub will not merge it. A pull
    # request carrying the blocked label is waiting on something with no date
    # on it. Neither can go first, whatever else is true about them.
    #
    # The same rule already lived in the --ci-ahead branch below, where it was
    # written for a different question and applied to nobody else. Lifting it
    # here is the whole of the fix.
    if prs[n]["draft"]:
        return False
    blocked = os.environ.get("MC_BLOCKED_LABEL") or ""
    if blocked and blocked in prs[n]["labels"].split(","):
        return False
    return True

def blocks_count(n, group):
    return sum(1 for m in group if m != n and (min(n, m, key=int), max(n, m, key=int)) in edges)

def rank(group):
    # READINESS COMES FIRST, AHEAD OF EVERYTHING ELSE.
    #
    # This key used to start at is_hotfix, and blocks_count came next. That
    # ranks by ENTANGLEMENT: the pull request with the most ordering edges
    # sorts first. An alone hotspot creates an edge to every other open pull
    # request by construction, so a draft touching .github/workflows/** was
    # guaranteed first place while being unable to land at all.
    #
    # It happened. On 29 August 2026 a draft that had run zero CI was printed
    # as position 1 and two green pull requests waited behind it until a human
    # overrode the tool. Four days earlier the opposite: position 1 was ignored
    # and position 1 paid for it with two rebases. The output was identical in
    # both cases, so no reader could tell which one they were looking at.
    #
    # A pull request that cannot land cannot land first. That is not a
    # preference to weigh against the others - it is a fact about the world,
    # so it goes ahead of them rather than among them.
    return sorted(group, key=lambda n: (0 if is_ready(n) else 1,
                                        0 if is_hotfix(n) else 1,
                                        -blocks_count(n, group),
                                        int(n)))

def label(n):
    bits = []
    if prs[n]["draft"]:
        bits.append("REGISTERED (draft)")
    for name in prs[n]["labels"].split(","):
        if name.startswith("merge:"):
            bits.append(name)
    suffix = ("  [" + ", ".join(bits) + "]") if bits else ""
    title = prs[n]["title"]
    if len(title) > 68:
        title = title[:65] + "..."
    return "#%-5s %s%s" % (n, title, suffix)

independent = [g[0] for g in groups.values() if len(g) == 1]
chains = [rank(g) for g in groups.values() if len(g) > 1]
chains.sort(key=lambda g: (0 if is_hotfix(g[0]) else 1, -len(g), int(g[0])))

def overlaps_with(n):
    """Pairs involving n that share a file but do not force an order."""
    out = []
    for (a, b), note in overlaps.items():
        if n in (a, b):
            out.append((a, b, note))
    return sorted(out, key=lambda t: (int(t[0]), int(t[1])))

def declared_with(n):
    """Pairs involving n where a declaration says they are on the same ground."""
    out = []
    for (a, b), said in declarations.items():
        if n in (a, b):
            out.append((a, b, said))
    return sorted(out, key=lambda t: (int(t[0]), int(t[1])))

def print_declared(pairs, heading):
    if not pairs:
        return
    print()
    print(heading)
    for a, b, said in pairs:
        for line in said:
            print("  " + line)

# --ci-ahead: the machine question guard-ready.sh asks.
#
# NOT the same question as the report below, and the difference is the point.
# The report answers "must this wait to LAND", and on a queue a shared file is
# not a reason to wait, because the queue retests against the real result.
#
# This answers "will running CI now be WASTED", and there a shared file is
# exactly the reason. Two branches touching one file cannot both produce the
# tree they were tested on: whichever lands second has its merge group build
# something new, so its green has to be earned twice. That second run is the one
# case in fifteen that a CI cache keyed on the tree cannot avoid, and the
# cheapest way to avoid it is for the second branch to stay a draft until the
# first lands.
#
# So the set here is edges UNION overlaps: everything that shares ground, in
# whatever way. Declarations are deliberately left out. A declaration is a guess
# about files nobody has written yet, and it may never block anybody - the same
# separation the ordering code keeps a few lines above.
#
# Only NON-DRAFT pull requests count. A draft runs no CI, so it has
# spent nothing and invalidates nothing. Non-draft means the CI is already paid
# for, and the branch that already paid is the one that keeps its turn.
if os.environ.get("MC_CI_AHEAD") == "1":
    if focus not in prs:
        sys.stderr.write("merge-coordinator: #%s is not an open pull request.\n" % focus)
        sys.exit(3)
    except_set = set(n for n in (os.environ.get("MC_EXCEPT") or "").split(",") if n)
    ahead = set()
    for pair in list(edges) + list(overlaps):
        a, b = pair
        if focus == a:
            other = b
        elif focus == b:
            other = a
        else:
            continue
        # A pull request that cannot land cannot hold the line. Waiting behind a
        # draft, or behind one carrying the blocked label, is waiting for
        # something with no date on it, and the whole rule is "whoever lands
        # first keeps the CI they already paid for". Found live: a blocked pull
        # request would otherwise have held another one indefinitely.
        #
        # ONE rule, shared with rank() above. It used to live only here, which
        # is why the human-facing chain could put an unlandable pull request in
        # first place while this branch correctly ignored it.
        if not is_ready(other):
            continue
        # A Dependabot pull request the user put off with --skip-deps.
        if other in except_set:
            continue
        ahead.add(other)
    for n in sorted(ahead, key=int):
        print(n)
    sys.exit(1 if ahead else 0)

if focus:
    if focus not in prs:
        sys.exit("merge-coordinator: #%s is not an open pull request." % focus)
    mine = groups[find(focus)]
    if len(mine) == 1:
        also = overlaps_with(focus)
        if also:
            # "Nothing touches what it touches" would be a lie here, and the
            # session needs to know where to look if the queue does reject it.
            print("#%s may land now — nothing it shares a file with has to go first." % focus)
            print()
            print("It does share files, which is worth knowing and not worth waiting for:")
            for a, b, note in also:
                other = b if a == focus else a
                print("  #%s / #%s: %s" % (focus, other, note))
        else:
            print("#%s may land now — nothing else open touches what it touches." % focus)
        print_declared(declared_with(focus),
                       "Declared, not yet written — worth a word with whoever holds it:")
        sys.exit(0)
    order = rank(mine)
    position = order.index(focus)
    print("#%s is in a chain of %d." % (focus, len(mine)))
    print()
    for i, n in enumerate(order):
        mark = "->" if n == focus else "  "
        print(" %s %d. %s" % (mark, i + 1, label(n)))
    print()
    if position == 0:
        print("#%s is first: it may land now. Everything under it waits." % focus)
    else:
        ahead = order[:position]
        print("#%s waits on %s." % (focus, ", ".join("#" + a for a in ahead)))
    print()
    for i, n in enumerate(order):
        for m in order[i + 1:]:
            key = (min(n, m, key=int), max(n, m, key=int))
            if focus in key and key in edges:
                print("  #%s / #%s: %s" % (n, m, edges[key]))
    also = overlaps_with(focus)
    if also:
        print()
        print("Shares files with these too, which does not change the order:")
        for a, b, note in also:
            other = b if a == focus else a
            print("  #%s / #%s: %s" % (focus, other, note))
    print_declared(declared_with(focus),
                   "Declared, not yet written — worth a word with whoever holds it:")
    sys.exit(0)

print("merge-coordinator: %d open pull request(s).   (backbone: %s)"
      % (len(prs), backbone or "unset"))
print()
if independent:
    print("INDEPENDENT — any order, no waiting:")
    for n in sorted(independent, key=int):
        print("  " + label(n))
    print()
if chains:
    # SUGGESTED, NOT DECIDED, AND IT SAYS SO. land.sh enforces none of
    # this. The old caption read "one at a time, in this order", which sessions
    # took as their queue position - and following it was wrong once and
    # ignoring it was wrong once, four days apart, with the same words printed
    # both times. A reader has to be able to tell what this is before deciding
    # how much to trust it.
    print("CHAINS — these share ground, so landing them together costs extra CI.")
    print("Suggested order, by what can land now and what unblocks the most work.")
    print("Nothing enforces it: if you go out of order, say why.")
    for group in chains:
        print()
        for i, n in enumerate(group):
            # Marked on the line itself, not only in the caption. The 29 August
            # failure was a session reading position 1 and stopping there.
            mark = "" if is_ready(n) else "   <- cannot land yet, do not wait for it"
            print("  %d. %s%s" % (i + 1, label(n), mark))
        for i, n in enumerate(group):
            for m in group[i + 1:]:
                key = (min(n, m, key=int), max(n, m, key=int))
                if key in edges:
                    print("     #%s / #%s: %s" % (n, m, edges[key]))
    print()
if overlaps:
    # Reported, never ordered. A session reading this needs to know these pairs
    # exist — it is where a conflict would come from if one comes — without
    # reading it as a queue it has to join.
    print("SHARE FILES, NO WAITING — the queue tests each against the real result:")
    for (a, b), note in sorted(overlaps.items(), key=lambda kv: (int(kv[0][0]), int(kv[0][1]))):
        print("  #%s / #%s: %s" % (a, b, note))
    print()
if declarations:
    # A declaration is what somebody INTENDS to touch. It is the only signal
    # that exists before the code is written, and it is a guess, so it is
    # printed and never ordered. The answer to one of these is a conversation,
    # not a queue position.
    print("DECLARED — said in a pull request body, not written yet:")
    for (a, b), said in sorted(declarations.items(),
                               key=lambda kv: (int(kv[0][0]), int(kv[0][1]))):
        for line in said:
            print("  " + line)
    print()
print("Land with /merge-land <number>, which re-checks all of this before it acts.")
'
