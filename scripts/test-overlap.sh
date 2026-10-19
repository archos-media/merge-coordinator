#!/usr/bin/env bash
# Tests overlap.sh — the ordering analysis.
#
# MC_OVERLAP_INPUT feeds the gathered records straight in, so every rule runs
# with no network and no repository. The rules are the thing worth testing: the
# gathering above them is three API calls with obvious shapes, and the interesting
# failure is a chain that should have formed and did not.
#
# The case that matters most is 3. Two PRs that share NO file, both editing a
# migrations directory, must still serialize. A merge queue cannot see that pair
# — there is no conflict for it to find — and it is the class of failure that
# reverted a release heading in CHANGELOG.md.
set -euo pipefail

# contains <haystack> <needle> — substring test, done in the shell.
#
# NOT `printf '%s' "$h" | grep -qF -- "$n"`. These files set `pipefail`, and
# grep -q exits at its first match while printf is still writing; printf dies of
# SIGPIPE and 141 becomes the pipeline's status. In an `if !` assertion that
# turns a found string into a failed test, which is merely noisy — but in the
# "must NOT appear" helpers it turns a found string into a PASS, which is a test
# that cannot fail. Script output is small today. That is not a guarantee.
contains() {
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	return 1
}

cd "$(dirname "$0")"
SCRIPT=./overlap.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

cat >"$WORK/config.json" <<'JSON'
{
  "repo": "example/repo",
  "defaultBranch": "main",
  "requiredChecks": ["CI passed"],
  "backbone": "serialized-claim",
  "requireApproval": true,
  "labels": { "landing": "merge:landing", "blocked": "merge:blocked", "needsRebase": "merge:needs-rebase" },
  "releaseGuard": { "changelog": "CHANGELOG.md", "headingFormat": "## [{tag}]" },
  "hotspots": [
    { "path": "CHANGELOG.md", "rule": "serialize", "action": "rebase by hand", "why": "clean merges lose entries" },
    { "path": "*/migrations/**", "rule": "serialize", "action": "renumber", "why": "numbers are assigned at merge time" },
    { "path": ".github/workflows/**", "rule": "alone", "action": "land alone", "why": "changes what every run means" }
  ]
}
JSON

# records <<'EOF' ... EOF  — writes the input file for the next run.
records() { cat >"$WORK/records.tsv"; }

# run <name> <focus-or-empty> <expected-substring>...
run() {
	local name="$1" focus="$2"
	shift 2
	local out status want
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" $focus 2>&1)
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		echo "FAIL: $name — exited $status"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			echo "FAIL: $name — output did not contain: $want"
			printf '%s\n' "$out" | sed 's/^/    /'
			fail=$((fail + 1))
			return
		fi
	done
	echo "ok: $name"
	pass=$((pass + 1))
}

# run_absent <name> <focus-or-empty> <substring-that-must-not-appear>
run_absent() {
	local name="$1" focus="$2" unwanted="$3" out
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" $focus 2>&1)
	set -e
	if contains "$out" "$unwanted"; then
		echo "FAIL: $name — output contained what it must not: $unwanted"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

tab=$'\t'

# --------------------------------------------------------------------------
# 1. A shared file makes a chain, and the report names the file.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Change the auth handler${tab}false${tab}
PR${tab}11${tab}Also change the auth handler${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "a shared file serializes two PRs" "" "CHAINS" "both change auth/handler.go" "1. #10" "2. #11"

# --------------------------------------------------------------------------
# 2. Disjoint file sets land in any order. This is the case a strict FIFO queue
#    gets wrong by serialising work that never needed it.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Touch auth${tab}false${tab}
PR${tab}11${tab}Touch the web app${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}web/app/page.tsx
EOF
run "disjoint PRs are independent" "" "INDEPENDENT" "#10" "#11"
run_absent "disjoint PRs form no chain" "" "CHAINS"

# --------------------------------------------------------------------------
# 3. THE ONE THAT MATTERS. No shared file at all, but both sit in the same
#    hotspot. git would merge these without a word, and the second migration
#    number would collide the moment it landed.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Add an auth migration${tab}false${tab}
PR${tab}11${tab}Add a content migration${tab}false${tab}
F${tab}10${tab}auth/migrations/000041_x.up.sql
F${tab}11${tab}content/migrations/000112_y.up.sql
EOF
run "same hotspot with no shared file still serializes" "" \
	"CHAINS" "both touch */migrations/** — hotspot, rule: serialize"

# --------------------------------------------------------------------------
# 4. A 'serialize' hotspot must NOT drag in a PR that is nowhere near it.
#    Over-serialising is the failure mode that gets a tool switched off.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Add an auth migration${tab}false${tab}
PR${tab}11${tab}Add a content migration${tab}false${tab}
PR${tab}12${tab}Edit a doc${tab}false${tab}
F${tab}10${tab}auth/migrations/000041_x.up.sql
F${tab}11${tab}content/migrations/000112_y.up.sql
F${tab}12${tab}docs/README.md
EOF
run "a serialize hotspot leaves unrelated PRs alone" "" "INDEPENDENT" "#12"

# --------------------------------------------------------------------------
# 5. 'alone' is different: it entangles with everything open, including PRs
#    that share no file and no hotspot.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Edit CI${tab}false${tab}
PR${tab}11${tab}Edit a doc${tab}false${tab}
F${tab}10${tab}.github/workflows/ci.yml
F${tab}11${tab}docs/README.md
EOF
run "an alone hotspot entangles everything" "" \
	"CHAINS" "must land alone"
run_absent "an alone hotspot leaves nothing independent" "" "INDEPENDENT"

# --------------------------------------------------------------------------
# 6. A stacked branch has to follow the branch it is stacked on, and the report
#    has to say which way round.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Base work${tab}false${tab}
PR${tab}11${tab}Built on the base${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
DEP${tab}10${tab}11
EOF
run "a dependency is reported by direction" "" "#11 is built on top of #10"

# --------------------------------------------------------------------------
# 7. A hotfix goes first even though it is the newer PR.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Ordinary work${tab}false${tab}size:S
PR${tab}11${tab}Fix the outage${tab}false${tab}sev:critical
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "a hotfix is ranked first in its chain" "" "1. #11" "2. #10"

# --------------------------------------------------------------------------
# 8. A draft is shown, and shown as a registration rather than as a candidate.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Working here${tab}true${tab}
F${tab}10${tab}auth/handler.go
EOF
run "a draft appears as a registration" "" "REGISTERED (draft)"

# --------------------------------------------------------------------------
# 9. Focus mode answers the only question a session actually has: may I land?
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}First${tab}false${tab}
PR${tab}11${tab}Second${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "focus mode names what a PR waits on" "11" "#11 waits on #10"
run "focus mode clears the first in the chain" "10" "#10 is first"

records <<EOF
PR${tab}10${tab}Alone in the world${tab}false${tab}
F${tab}10${tab}auth/handler.go
EOF
run "focus mode clears an unentangled PR" "10" "#10 may land now"

# --------------------------------------------------------------------------
# 10. A file list the API truncated must make the PR entangle with everything.
#     A short list that looks complete is the failure this plugin exists for.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Enormous${tab}false${tab}
PR${tab}11${tab}Unrelated${tab}false${tab}
F${tab}10${tab}MERGE-COORDINATOR-TRUNCATED
F${tab}11${tab}docs/README.md
EOF
run "a truncated file list is treated as touching everything" "" \
	"CHAINS" "more files than the API will list"

# --------------------------------------------------------------------------
# 11. Ranking inside a chain puts whatever unblocks the most work first.
#     #12 touches both other PRs; the other two touch only it.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}One${tab}false${tab}
PR${tab}11${tab}Two${tab}false${tab}
PR${tab}12${tab}Blocks both${tab}false${tab}
F${tab}10${tab}a.go
F${tab}11${tab}b.go
F${tab}12${tab}a.go
F${tab}12${tab}b.go
EOF
run "the PR blocking the most work is ranked first" "" "1. #12"

# --------------------------------------------------------------------------
# 12. The bash and python hotspot matchers have to agree, or land.sh and
#     overlap.sh will disagree about the same pull request.
# --------------------------------------------------------------------------
. ./lib/gh.sh
match_case() {
	local pattern="$1" path="$2" want="$3" got=no
	if mc_hotspot_match "$pattern" "$path"; then got=yes; fi
	local py_got
	py_got=$(MC_P="$pattern" MC_F="$path" mc_py -c '
import fnmatch, os
p = os.environ["MC_P"]
while "**" in p:
    p = p.replace("**", "*")
print("yes" if fnmatch.fnmatchcase(os.environ["MC_F"], p) else "no")
')
	if [ "$got" != "$want" ] || [ "$py_got" != "$want" ]; then
		echo "FAIL: matcher $pattern vs $path — bash=$got python=$py_got, wanted $want"
		fail=$((fail + 1))
		return
	fi
	echo "ok: matcher $pattern vs $path = $want"
	pass=$((pass + 1))
}

match_case 'vendor/**' 'vendor/github.com/x/y.go' yes
match_case 'vendor/**' 'auth/vendor.go' no
match_case '*/migrations/**' 'auth/migrations/000041_x.up.sql' yes
match_case '*/migrations/**' 'migrations/000041_x.up.sql' no
match_case 'CHANGELOG.md' 'CHANGELOG.md' yes
match_case 'CHANGELOG.md' 'docs/CHANGELOG.md' no
match_case '.github/workflows/**' '.github/workflows/ci.yml' yes
match_case '.github/workflows/**' '.github/labels.json' no

# --------------------------------------------------------------------------
# THE MERGE-QUEUE BACKBONE.
#
# Everything above runs against serialized-claim, and it stays that way: the
# plugin is portable, so the old backbone has to keep working. These cases are
# the SAME inputs read under `github-merge-queue`, which is the only honest way
# to test a branch — a rule that behaves identically under both is a rule that
# is not reading the setting.
# --------------------------------------------------------------------------
sed 's/"serialized-claim"/"github-merge-queue"/' "$WORK/config.json" >"$WORK/config-queue.json"
grep -q 'github-merge-queue' "$WORK/config-queue.json" ||
	{ echo "FAIL: the queue fixture was not written"; exit 1; }

runq() {
	local name="$1" focus="$2"
	shift 2
	local out status want
	set +e
	out=$(MC_CONFIG="$WORK/config-queue.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" $focus 2>&1)
	status=$?
	set -e
	if [ "$status" -ne 0 ]; then
		echo "FAIL: $name — exited $status"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			echo "FAIL: $name — output did not contain: $want"
			printf '%s\n' "$out" | sed 's/^/    /'
			fail=$((fail + 1))
			return
		fi
	done
	echo "ok: $name"
	pass=$((pass + 1))
}

runq_absent() {
	local name="$1" focus="$2" unwanted="$3" out
	set +e
	out=$(MC_CONFIG="$WORK/config-queue.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" $focus 2>&1)
	set -e
	if contains "$out" "$unwanted"; then
		echo "FAIL: $name — output contained what it must not: $unwanted"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# Q1. The headline change. The same two PRs that chain above must NOT chain
#     here — and must still be told they share the file.
records <<EOF
PR${tab}10${tab}Change the auth handler${tab}false${tab}
PR${tab}11${tab}Also change the auth handler${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "same input still chains on serialized-claim" "" "CHAINS"
runq_absent "a shared file does not chain on a queue" "" "CHAINS"
runq "a shared file is still reported on a queue" "" \
	"SHARE FILES, NO WAITING" "both change auth/handler.go"
runq "the report names the backbone it reasoned against" "" "backbone: github-merge-queue"

# Q2. A hotspot with NO file in common still chains. This is the case the queue
#     genuinely cannot see, so the queue must not be an excuse to drop it.
records <<EOF
PR${tab}20${tab}Add a migration${tab}false${tab}
PR${tab}21${tab}Add another migration${tab}false${tab}
F${tab}20${tab}auth/migrations/000041_a.up.sql
F${tab}21${tab}auth/migrations/000042_b.up.sql
EOF
runq "a hotspot still chains on a queue" "" "CHAINS" "hotspot, rule: serialize"

# Q3. And the alone rule survives, for the same reason.
records <<EOF
PR${tab}30${tab}Edit the workflow${tab}false${tab}
PR${tab}31${tab}Unrelated${tab}false${tab}
F${tab}30${tab}.github/workflows/ci.yml
F${tab}31${tab}web/app/page.tsx
EOF
runq "an alone hotspot still chains on a queue" "" "CHAINS" "must land alone"

# Q4. A dependency chains on a queue. Order is not a preference here — one head
#     already contains the other.
records <<EOF
PR${tab}40${tab}Base${tab}false${tab}
PR${tab}41${tab}Stacked on top${tab}false${tab}
F${tab}40${tab}auth/handler.go
F${tab}41${tab}auth/handler.go
DEP${tab}40${tab}41
EOF
runq "a dependency still chains on a queue" "" "CHAINS" "built on top of"

# Q5. A truncated file list must keep forcing an order. "We could not read the
#     overlap" is not "there is no overlap", on any backbone.
records <<EOF
PR${tab}50${tab}Enormous${tab}false${tab}
PR${tab}51${tab}Small${tab}false${tab}
F${tab}50${tab}MERGE-COORDINATOR-TRUNCATED
F${tab}51${tab}web/app/page.tsx
EOF
runq "a truncated list still chains on a queue" "" "CHAINS" "more files than the API will list"

# Q6. Focus mode has its own wording for "clear, but you should know". A PR that
#     shares a file with one other and nothing else must read as landable AND
#     still name the file.
records <<EOF
PR${tab}60${tab}One${tab}false${tab}
PR${tab}61${tab}Two${tab}false${tab}
F${tab}60${tab}auth/handler.go
F${tab}61${tab}auth/handler.go
EOF
runq "focus mode clears a shared-file PR on a queue" "60" \
	"may land now" "It does share files" "#60 / #61"
runq_absent "focus mode does not claim nothing touches it" "60" \
	"nothing else open touches what it touches"

# --------------------------------------------------------------------------
# 7. DECLARED PATHS — the Register layer.
#
#    Every rule above reads a pull request's CHANGED FILES, so a session that
#    has not written the code yet is invisible to all of them. These cases are
#    about the signal that exists before the code does, and about the two ways
#    it must never behave: it must not order anything, and it must not take
#    anything away.
# --------------------------------------------------------------------------

# run_once <name> <focus-or-empty> <substring> — present, and present ONCE.
#
# A symmetric finding is easy to report from both sides. `contains` cannot tell
# one from two, so an assertion built on it passes either way. grep -c reads its
# whole input and never exits early, so it is safe under pipefail here.
run_once() {
	local name="$1" focus="$2" want="$3" out n
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" $focus 2>&1)
	set -e
	n=$(printf '%s\n' "$out" | grep -c -- "$want" || true)
	if [ "$n" != "1" ]; then
		echo "FAIL: $name — expected exactly one line matching '$want', found $n"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# 7a. Two registrations, no code written on either. This is the failure of
#     25 August in miniature: neither pull request has a single file, so rules
#     1 to 3 have nothing at all to read, and without this the answer is that
#     the two are unrelated.
records <<EOF
PR${tab}70${tab}Register: feed ranking${tab}true${tab}
PR${tab}71${tab}Register: feed ranking, other session${tab}true${tab}
D${tab}70${tab}go/feed/**
D${tab}71${tab}go/feed/**
EOF
run "two declarations of the same ground are reported" "" \
	"DECLARED" "both declared the same ground" "go/feed/**"
run_once "the same ground is reported once, not once per side" "" "both declared the same ground"
run_absent "a declaration does not make a chain" "" "CHAINS"
run "focus mode names a declaration on an otherwise clear PR" "70" \
	"may land now" "Declared, not yet written"

# 7b. One session has written the code and the other has only said it will.
#     The certain half of the pair is the one named.
records <<EOF
PR${tab}72${tab}Register: the feed${tab}true${tab}
PR${tab}73${tab}Rewrite the ranker${tab}false${tab}
D${tab}72${tab}go/feed/**
F${tab}73${tab}go/feed/rank.go
EOF
run "a declaration covering another PR's real file is reported" "" \
	"DECLARED" "#72 declared go/feed/**, which #73 already changes (go/feed/rank.go)"
run_absent "a declaration against real files still does not chain" "" "CHAINS"

# 7c. THE UNION GUARD, and the reason this section exists.
#
#     Declared paths are added to what is known. They never stand in for it. A
#     pull request that declares web/** while actually changing auth/handler.go
#     must still chain with the other pull request changing auth/handler.go —
#     a prediction that removed a real finding would be worse than no
#     prediction at all. Delete the separation and this is the case that goes
#     quiet.
records <<EOF
PR${tab}74${tab}One${tab}false${tab}
PR${tab}75${tab}Two${tab}false${tab}
F${tab}74${tab}auth/handler.go
F${tab}75${tab}auth/handler.go
D${tab}74${tab}web/**
EOF
run "declaring paths does not remove what the real files already prove" "" \
	"CHAINS" "both change auth/handler.go"

# 7d. A declaration is matched against real paths, and the truncation sentinel
#     is not one. A pull request over the API ceiling is already treated as
#     touching everything by rule 1; saying so a second time in the words of a
#     file nobody wrote would be a confusing way to repeat it.
records <<EOF
PR${tab}76${tab}Register${tab}true${tab}
PR${tab}77${tab}Enormous${tab}false${tab}
D${tab}76${tab}*
F${tab}77${tab}MERGE-COORDINATOR-TRUNCATED
EOF
run_absent "a declaration is not matched against the truncation sentinel" "" \
	"declared *, which #77 already changes (MERGE-COORDINATOR-TRUNCATED)"

# 7e. The backbone does not change any of this. A declaration is advisory on a
#     queue and advisory without one, because a queue cannot test a tree nobody
#     has written either.
records <<EOF
PR${tab}78${tab}Register: one${tab}true${tab}
PR${tab}79${tab}Register: two${tab}true${tab}
D${tab}78${tab}go/feed/**
D${tab}79${tab}go/feed/rank.go
EOF
runq "a declaration is reported the same way on a queue" "" \
	"DECLARED" "both declared the same ground"
runq_absent "a declaration does not chain on a queue either" "" "CHAINS"

# 7f. A broader declaration covering a narrower one is the same ground. Two
#     sessions rarely write the same glob; one writes the directory and the
#     other writes the file in it.
records <<EOF
PR${tab}80${tab}Register: all of feed${tab}true${tab}
PR${tab}81${tab}Register: one ranker${tab}true${tab}
D${tab}80${tab}go/feed/**
D${tab}81${tab}go/feed/rank.go
EOF
run "a broad declaration covers a narrow one" "" \
	"both declared the same ground (go/feed/** / go/feed/rank.go)"

# 7g. Declaring nothing is the normal case and must stay silent. Most pull
#     requests will never carry a block.
records <<EOF
PR${tab}82${tab}One${tab}false${tab}
PR${tab}83${tab}Two${tab}false${tab}
F${tab}82${tab}auth/handler.go
F${tab}83${tab}web/app.tsx
EOF
run_absent "no declarations means no declared section" "" "DECLARED"

# --------------------------------------------------------------------------
# --ci-ahead: the machine mode guard-ready.sh reads.
#
# The contract it has to keep is an exit code, not prose, so these assert on the
# code first and the numbers second. Everything runs against the QUEUE config,
# because that is the live backbone and because it is the config where a shared
# file stops being an ordering edge — the case this mode exists to still catch.
# --------------------------------------------------------------------------

# ahead <name> <focus> <expected-exit> <expected numbers, space separated> [extra arg]
ahead() {
	local name="$1" focus="$2" want_status="$3" want_list="$4" extra="${5:-}"
	local out status got
	set +e
	out=$(MC_CONFIG="$WORK/config-queue.json" MC_OVERLAP_INPUT="$WORK/records.tsv" \
		bash "$SCRIPT" "$focus" --ci-ahead ${extra:+"$extra"} 2>/dev/null)
	status=$?
	set -e
	got=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//')
	if [ "$status" -ne "$want_status" ]; then
		echo "FAIL: $name — wanted exit $want_status, got $status (output: '$got')"
		fail=$((fail + 1))
		return
	fi
	if [ "$got" != "$want_list" ]; then
		echo "FAIL: $name — wanted '$want_list', got '$got'"
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# A shared file is NOT an ordering edge on a queue. It is still wasted CI, so
# this mode must report it where the report above deliberately does not.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}
PR${tab}91${tab}Second${tab}true${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
EOF
ahead "a non-draft sharing a file is ahead" 91 1 "90"
runq "and the report still says no waiting" 91 "may land now"

# The draft is the one with nothing spent, so it is never what anybody waits on.
records <<EOF
PR${tab}90${tab}First${tab}true${tab}
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
EOF
ahead "a DRAFT sharing a file is not ahead" 91 0 ""

records <<EOF
PR${tab}90${tab}First${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}web/app.tsx
EOF
ahead "an unrelated non-draft is not ahead" 91 0 ""

# A hotspot pair shares no file at all. It is an ordering edge, so it has to be
# in the union too — this is what proves the mode reads edges and not only the
# textual overlaps.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}content/migrations/0100_a.sql
F${tab}91${tab}content/migrations/0101_b.sql
EOF
ahead "a hotspot with no shared file is ahead" 91 1 "90"

# --except: the Dependabot pull requests the user put off with ready.sh
# --skip-deps. Without it the overlap check refuses next, naming the same one,
# and "later" turns back into --force.
records <<EOF
PR${tab}90${tab}Bump x${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
PR${tab}92${tab}Third${tab}false${tab}
F${tab}90${tab}go/go.mod
F${tab}91${tab}go/go.mod
F${tab}92${tab}go/go.mod
EOF
ahead "--except leaves out the pull requests it names" 91 1 "92" "--except=90"
ahead "--except with all of them leaves nothing ahead" 91 0 "" "--except=90,92"
set +e
out=$(MC_CONFIG="$WORK/config-queue.json" MC_OVERLAP_INPUT="$WORK/records.tsv" bash "$SCRIPT" 91 --ci-ahead "--except=90;rm" 2>&1)
status=$?
set -e
if [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && contains "$out" "joined by commas"; then
	echo "ok: --except takes numbers only"; pass=$((pass + 1))
else
	echo "FAIL: --except takes numbers only (status $status: $out)"; fail=$((fail + 1))
fi

# A declaration is a guess about unwritten files. It may report, never block.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
D${tab}91${tab}auth/**
EOF
ahead "a declaration alone does not put anybody ahead" 91 0 ""

records <<EOF
PR${tab}90${tab}First${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
PR${tab}92${tab}Third${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
F${tab}92${tab}auth/handler.go
EOF
ahead "every non-draft sharer is listed, in number order" 92 1 "90 91"

# A pull request that cannot land cannot hold the line. Found live: a blocked
# pull request would otherwise have held another for as long as the block lasted.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}merge:blocked
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
EOF
ahead "a BLOCKED non-draft does not hold the line" 91 0 ""

# But a label that merely looks similar must not be read as the blocked one.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}merge:landing
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
EOF
ahead "another merge: label is not a block" 91 1 "90"

# Blocked excuses only the blocked one. Everybody else still holds their turn.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}merge:blocked
PR${tab}92${tab}Third${tab}false${tab}
PR${tab}91${tab}Second${tab}false${tab}
F${tab}90${tab}auth/handler.go
F${tab}91${tab}auth/handler.go
F${tab}92${tab}auth/handler.go
EOF
ahead "one blocked does not excuse the rest" 91 1 "92"

# Could not tell, which the hook has to treat as a refusal and not as a pass.
records <<EOF
PR${tab}90${tab}First${tab}false${tab}
F${tab}90${tab}auth/handler.go
EOF
ahead "a focus that is not open is could-not-tell, not clear" 91 3 ""

# --------------------------------------------------------------------------
# READINESS RANKS FIRST.
#
# The 29 August 2026 incident, rebuilt exactly. #10 is a DRAFT touching
# .github/workflows/**, which is an alone hotspot and therefore has an edge to
# every other open pull request. Under the old key that entanglement put it in
# first place, and a session owning a green pull request read that as its queue
# position and stopped. The draft had run zero CI and could not be admitted to
# the queue by anything.
#
# blocks_count still ranks #10 above the others. Readiness has to beat it.
# --------------------------------------------------------------------------
records <<EOF
PR${tab}10${tab}Not started yet${tab}true${tab}
PR${tab}11${tab}Green and ready${tab}false${tab}
PR${tab}12${tab}Also ready${tab}false${tab}
F${tab}10${tab}.github/workflows/ci.yml
F${tab}11${tab}auth/handler.go
F${tab}12${tab}web/src/page.tsx
EOF
run "a draft does not take first place in a chain" "" "1. #11"
records <<EOF
PR${tab}10${tab}Not started yet${tab}true${tab}
PR${tab}11${tab}Green and ready${tab}false${tab}
PR${tab}12${tab}Also ready${tab}false${tab}
F${tab}10${tab}.github/workflows/ci.yml
F${tab}11${tab}auth/handler.go
F${tab}12${tab}web/src/page.tsx
EOF
run "an unlandable pull request is marked on its own line" "" "cannot land yet, do not wait for it"

# A hotfix is the strongest preference in the old key. It still must not send an
# unlandable pull request to the front: a draft hotfix cannot land either.
records <<EOF
PR${tab}10${tab}Fix the outage${tab}true${tab}sev:critical
PR${tab}11${tab}Ordinary work${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "readiness beats hotfix" "" "1. #11" "2. #10"

# The blocked label, the other half of is_ready, through the human-facing path
# rather than through --ci-ahead.
records <<EOF
PR${tab}10${tab}Waiting on something${tab}false${tab}merge:blocked
PR${tab}11${tab}Ready${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "a blocked pull request does not hold first place" "" "1. #11" "2. #10"

# The caption. Both incidents turned on a reader taking an advisory list as a
# ruling, so the words that invited that must be gone, and the words that say
# what it really is must be present.
records <<EOF
PR${tab}10${tab}First${tab}false${tab}
PR${tab}11${tab}Second${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run_absent "the chain no longer reads as a ruling" "" "one at a time, in this order"
records <<EOF
PR${tab}10${tab}First${tab}false${tab}
PR${tab}11${tab}Second${tab}false${tab}
F${tab}10${tab}auth/handler.go
F${tab}11${tab}auth/handler.go
EOF
run "the chain says nothing enforces it" "" "Nothing enforces it"

# ---------------------------------------------------------------------------
# The gathering half, through the routed fake gh.
#
# Every case above feeds records in directly. None of them reaches the three
# API calls that build those records, and two of those calls sat inside a
# heredoc that threw away their exit status. A failed PR listing printed "no
# open pull requests". A failed file listing made that PR overlap nothing, so
# --ci-ahead said "nothing ahead" and ready.sh went ahead. [BUG 3 shape]
# ---------------------------------------------------------------------------
FIX="$WORK/fix"
reset_gather() {
	rm -rf "$FIX"
	mkdir -p "$FIX"
	: >"$FIX/calls.log"
	printf '10\tFirst\tfalse\tone\t\n11\tSecond\tfalse\ttwo\t\n' >"$FIX/openprs.txt"
	printf 'auth/handler.go\n' >"$FIX/files.txt"
	printf 'sha10\n' >"$FIX/sha10.txt"
	printf 'sha11\n' >"$FIX/sha11.txt"
	cat >"$FIX/routes" <<ROUTES
api --paginate repos/example/repo/pulls?state=open*	openprs.txt
api --paginate repos/example/repo/pulls/10/files*	files.txt
api --paginate repos/example/repo/pulls/11/files*	files.txt
api repos/example/repo/pulls/10 --jq .head.sha*	sha10.txt
api repos/example/repo/pulls/11 --jq .head.sha*	sha11.txt
api repos/example/repo/pulls/10 --jq .body*	EMPTY
api repos/example/repo/pulls/11 --jq .body*	EMPTY
api repos/example/repo/compare/*	EMPTY
ROUTES
}

# route <glob> <response> — put a route ahead of the defaults.
route() {
	printf '%s\t%s\n' "$1" "$2" | cat - "$FIX/routes" >"$FIX/routes.new"
	mv "$FIX/routes.new" "$FIX/routes"
}

# gather <name> <expected-status> <args> <expected-substring>...
gather() {
	local name="$1" want_status="$2" args="$3" out status want
	shift 3
	set +e
	out=$(MC_CONFIG="$WORK/config.json" MC_GH=./lib/fixture-gh.sh MC_FIXTURES="$FIX" bash "$SCRIPT" $args 2>&1)
	status=$?
	set -e
	if [ "$status" -ne "$want_status" ]; then
		echo "FAIL: $name — exited $status, wanted $want_status"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		if ! contains "$out" "$want"; then
			echo "FAIL: $name — output did not contain: $want"
			printf '%s\n' "$out" | sed 's/^/    /'
			fail=$((fail + 1))
			return
		fi
	done
	if contains "$out" "no open pull requests"; then
		echo "FAIL: $name — it said there were no open pull requests"
		fail=$((fail + 1))
		return
	fi
	echo "ok: $name"
	pass=$((pass + 1))
}

# The control. Without it, a route missing from the defaults would make every
# case below "fail" for the wrong reason and still pass.
reset_gather
gather "the gathered records find the shared file" 0 "" "#10" "#11"
reset_gather
gather "and --ci-ahead names the pull request ahead" 1 "11 --ci-ahead" "10"

reset_gather
route "api --paginate repos/example/repo/pulls?state=open*" FAIL
gather "a failed pull request listing is 'could not tell', not 'none open'" 3 "" \
	"could not list the open pull requests"
reset_gather
route "api --paginate repos/example/repo/pulls?state=open*" FAIL
gather "and --ci-ahead says the same" 3 "11 --ci-ahead" "could not list the open pull requests"

reset_gather
route "api --paginate repos/example/repo/pulls/10/files*" FAIL
gather "a failed file listing does not read as no overlap" 3 "11 --ci-ahead" \
	"could not list the files of #10"
reset_gather
route "api --paginate repos/example/repo/pulls/10/files*" FAIL
gather "and human mode stops rather than advise on half the picture" 3 "" \
	"could not list the files of #10"

echo
echo "test-overlap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
