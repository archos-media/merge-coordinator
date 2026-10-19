#!/usr/bin/env bash
# SessionStart, and PostToolUse / EnterWorktree — is each vendored copy here
# (or, outside a repository, one folder below), and the installed plugin, the
# newest release?
#
# A copy taken by vendor.sh is pinned, which is the point, and pinned things
# fall behind without anyone noticing. This says so when a session starts in,
# or enters, a repository that carries a copy. It is silent when everything is
# current and when there is no copy. It is NOT silent when it could not check:
# "could not look" and "nothing to report" must never read the same.
#
# WHERE IT LOOKS. A session inside a repository: that repository, and nowhere
# else. A session in a folder that is NOT a repository: every repository ONE
# folder below it. Many projects keep their repositories side by side under one
# working folder, and a check that looked only at the session's own folder
# never told them a release was out. One level, not a walk: a walk would slow
# every session start and find copies nobody here works on.
#
# It never blocks anything and always exits 0. It asks each release source
# once, however many repositories pin a copy from it, and the sources share 18
# seconds: the hook has 25, and a hook that is killed says nothing, not even
# that it could not look.
#
# MC_VENDOR_REMOTE_TAGS, when set, is used instead of asking the remote. It
# exists for the tests.
set -u

payload="$(cat)"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"
# shellcheck source=lib/hook-repo.sh
. "$here/lib/hook-repo.sh"

fields=$(printf '%s' "$payload" | mc_py -c 'import json, sys
try:
    p = json.load(sys.stdin)
    sys.stdout.write("%s\t%s" % (p.get("cwd") or "", p.get("hook_event_name") or "SessionStart"))
except Exception:
    pass' 2>/dev/null) || exit 0
tab=$(printf '\t')
nl='
'
cwd=${fields%%"$tab"*}
event=${fields#*"$tab"}
[ -n "$event" ] || event=SessionStart

say() {
	printf '%s' "$1" | MC_EVENT="$event" mc_py -c 'import json, os, sys
m = sys.stdin.read()
print(json.dumps({"systemMessage": m,
                  "hookSpecificOutput": {"hookEventName": os.environ["MC_EVENT"],
                                         "additionalContext": m}}))' 2>/dev/null
	exit 0
}

nested=0
if top=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null); then
	candidates=$top
else
	# Only "not a repository" means look below. Any other failure (no git, a
	# folder git refuses as unsafe, one that is gone) is could not look.
	# LC_ALL=C: a translated git words "not a git repository" its own way.
	why=$(LC_ALL=C LANGUAGE= git -C "${cwd:-.}" rev-parse --show-toplevel 2>&1 >/dev/null)
	case "$why" in
	*"not a git repository"*) ;;
	*) say "merge-coordinator: could not tell whether ${cwd:-.} is a repository (${why:-git failed}), so no vendored copy was checked." ;;
	esac
	nested=1
	# Spelled D:/... on Windows, so the paths in the message are ones every
	# shell there accepts. Git Bash globs a Windows-spelled folder either way.
	base=$(cygpath -m "${cwd:-.}" 2>/dev/null || printf '%s' "${cwd:-.}")
	candidates=""
	for d in "$base"/*/; do
		d=${d%/}
		[ -e "$d/.git" ] && candidates="$candidates$d$nl"
	done
fi

msgs=""
add() { msgs="${msgs:+$msgs$nl}$1"; }

# One row per copy: repository, source, pinned tag, path of the copy.
rows=""
while IFS= read -r repo; do
	[ -n "$repo" ] || continue
	stamp="$repo/.github/merge-coordinator.vendor"
	[ -f "$stamp" ] || continue
	info=$(MC_STAMP="$stamp" mc_py -c 'import json, os, sys
try:
    s = json.load(open(os.environ["MC_STAMP"], encoding="utf-8"))
    row = [s["source"], s["tag"], s["path"]]
    # An empty field would shift the ones after it when the shell splits the
    # row on tabs, and the message would name the wrong thing.
    if all(isinstance(f, str) and f and "\t" not in f for f in row):
        sys.stdout.write("\t".join(row))
except Exception:
    pass' 2>/dev/null)
	if [ -z "$info" ]; then
		add "merge-coordinator: could not read $stamp, so whether the vendored copy is current is unknown."
		continue
	fi
	rows="$rows$repo$tab$info$nl"
done <<EOF
$candidates
EOF

# The newest vN.N.N tag, compared as numbers: v0.10.0 is newer than v0.9.0.
newest_of() {
	printf '%s\n' "$1" | mc_py -c 'import re, sys
best = None
for line in sys.stdin:
    m = re.search(r"refs/tags/(v(\d+)\.(\d+)\.(\d+))\s*$", line.strip())
    if m:
        key = tuple(int(x) for x in m.group(2, 3, 4))
        if best is None or key > best[0]:
            best = (key, m.group(1))
sys.stdout.write(best[1] if best else "")' 2>/dev/null
}

# Each distinct source, asked once: "source<TAB>newest", newest empty when the
# source could not be read or lists no release.
answers=""
reference=""
sources=$(printf '%s' "$rows" | cut -f2 | sort -u)
# 18 of the hook's 25 seconds in all (MC_VENDOR_BUDGET), shared: the rest is
# for python and git starting. Each source gets an even share, at least 3
# seconds and never more than is left; a source left with no time is named as
# not asked, not skipped in silence. Where neither timeout nor gtimeout exists
# (stock macOS) git runs with no deadline, and only the hook's own timeout
# bounds it.
budget=${MC_VENDOR_BUDGET:-18}
case "$budget" in "" | *[!0-9]*) budget=18 ;; esac
count=$(printf '%s\n' "$sources" | sed '/^$/d' | wc -l | tr -d ' ')
share=15
[ "$count" -le 1 ] || share=$((budget / count))
[ "$share" -ge 3 ] || share=3
[ "$share" -le "$budget" ] || share=$budget
budget_end=$((SECONDS + budget))
while IFS= read -r source; do
	[ -n "$source" ] || continue
	left=$((budget_end - SECONDS))
	per=$share
	[ "$per" -le "$left" ] || per=$left
	if [ -n "${MC_VENDOR_REMOTE_TAGS+x}" ]; then
		tags=$MC_VENDOR_REMOTE_TAGS
		rc=0
	elif [ "$per" -lt 1 ]; then
		tags=""
		rc=124
	else
		tags=$(mc_timed "$per" git ls-remote --tags --refs "$source" 2>/dev/null)
		rc=$?
	fi
	if [ "$per" -lt 1 ] && [ -z "${MC_VENDOR_REMOTE_TAGS+x}" ]; then
		newest="~"
	elif [ "$rc" -ne 0 ] || [ -z "$tags" ]; then
		newest=""
	else
		newest=$(newest_of "$tags")
		[ -n "$newest" ] || newest="-"
	fi
	# The installed plugin is compared with the first source that answered.
	[ -n "$reference" ] || case "$newest" in v*) reference=$newest ;; esac
	answers="$answers$source$tab$newest$nl"
done <<EOF
$sources
EOF

while IFS="$tab" read -r repo source pinned vpath; do
	[ -n "$repo" ] || continue
	# ENVIRON, not -v: awk reads backslash escapes in a -v value.
	newest=$(printf '%s' "$answers" | MC_SOURCE="$source" awk -F'\t' '$1 == ENVIRON["MC_SOURCE"] { print $2; exit }')
	where=$vpath
	refresh="bash $here/vendor.sh"
	if [ "$nested" -eq 1 ]; then
		where="${repo##*/}/$vpath"
		refresh="cd \"$repo\" && bash $here/vendor.sh"
	fi
	case "$newest" in
	"") add "merge-coordinator: could not read the releases at $source, so whether the vendored copy in $where ($pinned) is current is unknown." ;;
	"~") add "merge-coordinator: $source was not asked, because the $budget seconds this check has for releases were used up by the sources before it, so whether the vendored copy in $where ($pinned) is current is unknown." ;;
	-) add "merge-coordinator: $source lists no vN.N.N release tags, so whether the vendored copy in $where ($pinned) is current is unknown." ;;
	"$pinned") ;;
	*) add "merge-coordinator: the vendored copy in $where is $pinned; the newest release is $newest. Refresh it on a branch: $refresh $newest" ;;
	esac
done <<EOF
$rows
EOF

if [ -n "$reference" ]; then
	installed=$(mc_py -c 'import json, sys
try:
    sys.stdout.write("v" + json.load(open(sys.argv[1], encoding="utf-8"))["version"])
except Exception:
    pass' "$here/../.claude-plugin/plugin.json" 2>/dev/null)
	if [ -n "$installed" ] && [ "$installed" != "$reference" ]; then
		add "merge-coordinator: the installed plugin is $installed; the newest release is $reference. Update it: claude plugin update merge-coordinator@merge-coordinator"
	fi
fi

[ -z "$msgs" ] || say "$msgs"
exit 0
