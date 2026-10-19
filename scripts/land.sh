#!/usr/bin/env bash
# The landing sequence. Seven steps, idempotent, safe to re-run at any point.
#
#   0 deps        a waiting Dependabot pull request stops it; not for
#                 --post-merge, and --skip-deps passes it
#   1 preflight   open, not a draft, not blocked, approved (or break-glass)
#   2 claim       take the landing label, or name whoever holds it
#   3 freshness   refuse a stale head — or on a queue, a conflicting one
#   4 verify      read the named checks on THIS commit and believe nothing else
#   5 land        hand to the merge queue, or squash directly on the claim
#   6 release     drop the claim, then prove the release heading survived
#   7 notify      tell the pull requests this merge actually affected
#
# THREE STEPS ASK A DIFFERENT QUESTION DEPENDING ON `backbone`, and each one
# says so where it happens. The short version:
#
#   step 2  serialized-claim: one pull request lands at a time, repo-wide.
#           github-merge-queue: the claim is a lock on THIS pull request only,
#           so the queue can hold and batch several.
#   step 3  serialized-claim: refuse a head the base has moved past.
#           github-merge-queue: the queue owns freshness, so refuse a CONFLICT.
#   step 7  serialized-claim: every overlapping pull request went stale.
#           github-merge-queue: only a conflict or a hotspot is worth sending.
#
# Getting this wrong is not a small waste. On a queue the old step 3 makes every
# session rebase and re-run a full CI pass to satisfy a rule the queue already
# meets, and the old step 7 tells them to.
#
# IT DOES NO LOCAL GIT WORK. Several sessions share one checkout, so this script
# only ever talks to GitHub. When a branch has to be rebased it prints the
# commands and stops rather than running them somewhere it cannot see.
#
# THE CLAIM IS A LABEL, AND LABELS ARE NOT ATOMIC. Two sessions can add it in
# the same second. Step 2 therefore adds it and reads back the full holder list
# before trusting it. On serialized-claim the lowest PR number then wins and the
# loser gives the label back. That is a real resolution rather than a hope, but
# it is not a lock: a session that ignores this script and merges by hand
# defeats it, which is what the PreToolUse hook in hooks/ is for.
#
# Usage:
#   land.sh <number>                  run the sequence
#   land.sh <number> --dry-run        print every step, change nothing
#   land.sh <number> --admin          break glass: merge without the approval
#                                     the ruleset wants, but keep steps 3-7
#   land.sh <number> --update-branch  let GitHub bring a stale head up to date
#                                     (refused when a hotspot is involved, and
#                                     refused outright on a merge queue)
#   land.sh <number> --release-claim  drop the claim and do nothing else
#   land.sh <number> --post-merge     run only the release guard and the notify,
#                                     for a PR the merge queue already merged
#   land.sh <number> --skip-deps      the user said "later" to the Dependabot
#                                     pull requests waiting; land without them
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

# Before anything else, and in THIS shell rather than in a subshell that cannot
# stop the script. See mc_require_config in lib/gh.sh.
mc_require_config

pr="${1:-}"
[ -n "$pr" ] || mc_die "usage: land.sh <pr-number> [--dry-run] [--admin] [--update-branch] [--release-claim] [--post-merge] [--skip-deps]"
shift
case "$pr" in
'' | *[!0-9]*) mc_die "'$pr' is not a pull request number." ;;
esac

dry_run=0
admin=0
update_branch=0
release_only=0
post_merge=0
skip_deps=0
for arg in "$@"; do
	case "$arg" in
	--skip-deps) skip_deps=1 ;;
	--dry-run) dry_run=1 ;;
	--admin) admin=1 ;;
	--update-branch) update_branch=1 ;;
	--release-claim) release_only=1 ;;
	--post-merge) post_merge=1 ;;
	*) mc_die "unknown option: $arg" ;;
	esac
done

repo=$(mc_repo)
base=$(mc_cfg_get defaultBranch)
backbone=$(mc_cfg_get backbone)
landing_label=$(mc_cfg_get labels.landing)
blocked_label=$(mc_cfg_get labels.blocked)
rebase_label=$(mc_cfg_get labels.needsRebase)
require_approval=$(mc_cfg_get requireApproval)

# Every mutating call goes through here, so --dry-run is one decision rather
# than a flag threaded through twenty call sites.
mc_do() {
	if [ "$dry_run" -eq 1 ]; then
		echo "       would run: $*"
		return 0
	fi
	"$@"
}

step() {
	echo
	echo "-- $*"
}

claim_held=0
drop_claim() {
	[ "$claim_held" -eq 1 ] || return 0
	claim_held=0
	mc_do mc_gh pr edit "$pr" --repo "$repo" --remove-label "$landing_label" >/dev/null 2>&1 || true
	echo "       claim released."
}

# Any refusal after the claim is taken gives the claim back. Holding it after a
# failure would block every other session on a PR that is not going anywhere.
on_exit() {
	local code=$?
	if [ "$code" -ne 0 ]; then
		drop_claim
	fi
	exit "$code"
}
trap on_exit EXIT

if [ "$release_only" -eq 1 ]; then
	claim_held=1
	drop_claim
	exit 0
fi

echo "merge-coordinator: landing #$pr into $base of $repo"
[ "$dry_run" -eq 1 ] && echo "                   DRY RUN — nothing will be changed."

# A Dependabot pull request waiting stops a landing before step 1, and --admin
# does not step over it: the question is the user's, land the bump first or
# later. Not for --post-merge, which lands nothing; not for a Dependabot
# pull request, which is the answer to the question. mc_deps_gate in lib/gh.sh.
if [ "$post_merge" -eq 0 ]; then
	mc_deps_gate "$pr" "$skip_deps" "$dry_run" || exit 1
fi

# Fire CI for a commit that reached the default branch outside the merge queue.
#
# NEVER on the queue path. The queue already tested that exact tree, and firing
# here would add back the duplicate run that dropping CI on push removed.
#
# Non-blocking by design. The merge has already happened by the time this runs,
# so a failure here must report and carry on; aborting would leave the claim
# held and steps 6 and 7 unrun over a workflow dispatch.
fire_out_of_queue_ci() {
	local wf list rc=0

	# Read into a variable and TEST THE EXIT CODE. Putting the substitution
	# straight into a heredoc would swallow it: an unreadable config would
	# produce no lines, which reads exactly like "the key is absent, the feature
	# is off". Absent is fine. Could-not-look is not, and must say so.
	list=$(mc_cfg_list_opt outOfQueueCi) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "       WARNING: could not read outOfQueueCi from the config, so no run"
		echo "                was fired. This merge may be on $base untested."
		return 0
	fi
	if [ -z "$list" ]; then
		echo "       outOfQueueCi is not set, so no run was fired."
		return 0
	fi

	while IFS= read -r wf; do
		[ -n "$wf" ] || continue
		if mc_do mc_gh workflow run "$wf" --ref "$base"; then
			echo "       fired $wf on $base."
		else
			echo "       WARNING: could not fire $wf on $base. This merge is on"
			echo "                $base untested. Run it by hand:"
			echo "                  gh workflow run $wf --ref $base"
		fi
	done <<-EOF
	$list
	EOF
}


# --------------------------------------------------------------------------
# 1. Preflight
# --------------------------------------------------------------------------
step "1/7 preflight"

pr_json=$(mc_gh api "repos/$repo/pulls/$pr")
# Booleans come back as "true"/"false", the way the JSON spells them, so a bash
# comparison reads the same as the API response a human would look at.
pr_field() { printf '%s' "$pr_json" | MC_KEY="$1" mc_py -c '
import json, os, sys
node = json.load(sys.stdin)
for part in os.environ["MC_KEY"].split("."):
    node = node.get(part) if isinstance(node, dict) else None
    if node is None:
        break
if isinstance(node, bool):
    node = "true" if node else "false"
sys.stdout.write("" if node is None else str(node))
'; }

pr_state=$(pr_field state)
pr_draft=$(pr_field draft)
pr_merged=$(pr_field merged)
pr_title=$(pr_field title)
head_ref=$(pr_field head.ref)
head_sha=$(pr_field head.sha)

if [ "$post_merge" -eq 1 ]; then
	# Insist on merged, not merely closed. A pull request that was closed
	# unmerged has produced nothing, so there is no release heading to check and
	# nobody it could have invalidated — and running the notify for it would tell
	# other sessions to rebase onto a merge that never happened.
	[ "$pr_merged" = "true" ] || mc_die "#$pr is $pr_state and not merged, so there is nothing for
  --post-merge to check. That flag is for a pull request the merge queue has
  already merged."
else
	[ "$pr_state" = "open" ] || mc_die "#$pr is $pr_state, not open.
  If the merge queue already merged it, re-run with --post-merge to get the
  release guard and the notify, which are the steps the hand-off leaves behind."
	[ "$pr_draft" = "true" ] && mc_die "#$pr is a draft. A draft registers a footprint; it does not land."
fi

labels=$(mc_gh api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")')
dup_label=$(mc_dup_label)
case ",$labels," in
*",$blocked_label,"*) mc_die "#$pr carries $blocked_label. Someone stopped this on purpose; find out why before removing it." ;;
*",$dup_label,"*) mc_die "#$pr carries $dup_label: another open pull request already claims its issue.
  Read the issue claim comment on #$pr. The check removes the label when the claim is resolved." ;;
esac

review=$(mc_gh api "repos/$repo/pulls/$pr/reviews" --jq '[.[] | select(.state == "APPROVED")] | length')
echo "       #$pr  $pr_title"
echo "       head $head_sha on $head_ref, $review approval(s)"

if [ "$require_approval" = "true" ] && [ "$post_merge" -eq 0 ]; then
	if [ "$review" -lt 1 ]; then
		if [ "$admin" -eq 1 ]; then
			echo "       NO APPROVAL, and --admin was passed."
			echo "       This is the break-glass path. It still runs steps 3-7, so the"
			echo "       freshness, verify and notify work below all happen — only the"
			echo "       review requirement is being stepped over, and it is being"
			echo "       stepped over on purpose and in writing."
		else
			mc_die "#$pr has no approving review, and the ruleset requires one.
  Either get the approval, or re-run with --admin to break glass on that one
  requirement while keeping every other step of this sequence."
		fi
	fi
fi

# Steps 2 to 5 are the landing itself. --post-merge skips them: the pull
# request is already merged, and what is left is the release guard and the
# notify — the step that tells the other sessions they went stale, which is
# the reason this tool exists. On the queue backbone step 5 hands off and
# returns, so without this those two steps had no way of ever running.
if [ "$post_merge" -eq 0 ]; then
	# --------------------------------------------------------------------------
	# 2. Claim
	# --------------------------------------------------------------------------
	step "2/7 claim"

	# WHAT THE CLAIM IS FOR ALSO DEPENDS ON THE BACKBONE.
	#
	# On serialized-claim it is the serialization: one pull request lands at a
	# time, repository-wide, because nothing else orders them.
	#
	# On a merge queue the queue does that, and does it on better information —
	# it holds one to five entries and tests them as a batch. A global claim
	# hands it one entry at a time and switches that off. Measured the day this
	# was written: fifteen merges produced fifteen single-entry merge groups,
	# none overlapping, against a ruleset that allows batches of five.
	#
	# So under a queue the claim narrows to what is still worth having — a lock
	# on THIS pull request, which stops two sessions landing the same one twice.
	# Another pull request holding it is information, not a refusal.
	holders=$(mc_claim_holders "$landing_label" || true)
	# `sed -n '1p'` and not `head -1`, here and everywhere below. head stops reading
	# as soon as it has its lines, which closes the pipe under whatever is still
	# writing; that writer dies of SIGPIPE and pipefail makes it the pipeline's
	# status. sed -n reads to the end, so there is nothing to signal. This one is
	# small enough today that it would never have shown, and so was the release
	# guard's, until the changelog grew past the pipe buffer.
	other=$(printf '%s\n' "$holders" | grep -v "^$pr\$" | grep -v '^$' | sed -n '1p' || true)
	if [ -n "$other" ]; then
		if [ "$backbone" = "github-merge-queue" ]; then
			echo "       #$other is landing too. That is fine on a queue — it holds both and"
			echo "       tests them together. Carrying on."
		else
			mc_die "#$other already holds $landing_label. Wait for it, or ask that session to
	  run: land.sh $other --release-claim"
		fi
	fi

	case ",$labels," in
	*",$landing_label,"*)
		echo "       #$pr already holds $landing_label — resuming."
		claim_held=1
		;;
	*)
		mc_do mc_gh pr edit "$pr" --repo "$repo" --add-label "$landing_label" >/dev/null
		claim_held=1
		if [ "$dry_run" -eq 1 ]; then
			echo "       would take the claim."
		else
			echo "       claim taken."
		fi
		;;
	esac

	# Read it back. Adding a label is not atomic, so two sessions can both believe
	# they took it. Lowest number wins; the other gives it back here.
	#
	# READ YOUR OWN WRITE FIRST. A label listing that does not yet contain the label
	# we just added is stale, and a stale listing here reads exactly like "nobody
	# else is claiming" — the one conclusion this step must never reach by accident.
	# So the loop waits for our own number to appear before the list is used for
	# anything, and refuses if it never does.
	#
	# ON A QUEUE, READ THE PULL REQUEST'S OWN LABELS. The label listing
	# lags the write by several seconds, so nearly every land printed "claim not
	# visible yet" and re-read. On a queue the listing has no other use here: the
	# tie-break below runs only on serialized-claim. The pull request's own label
	# list sees the write at once. serialized-claim still reads the listing,
	# because its tie-break needs every holder.
	if [ "$dry_run" -eq 0 ]; then
		# Overridable so the test suite does not spend twelve seconds asleep proving
		# the refusal. Nothing else sets these.
		claim_retries="${MC_CLAIM_RETRIES:-6}"
		claim_sleep="${MC_CLAIM_SLEEP:-2}"
		attempt=0
		holders=""
		while :; do
			if [ "$backbone" = "github-merge-queue" ]; then
				own=$(mc_gh api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")' 2>/dev/null || true)
				case ",$own," in
				*",$landing_label,"*) break ;;
				esac
			else
				holders=$(mc_claim_holders "$landing_label" || true)
				case " $(printf '%s' "$holders" | tr '\n' ' ') " in
				*" $pr "*) break ;;
				esac
			fi
			attempt=$((attempt + 1))
			if [ "$attempt" -ge "$claim_retries" ]; then
				mc_die "took $landing_label on #$pr, but reading the labels back never showed it.
	  Refusing to go on. A listing that cannot see our own claim cannot be trusted
	  to see anyone else's either, and this step would then wave through exactly the
	  simultaneous claim it exists to catch."
			fi
			echo "       claim not visible yet; re-reading (attempt $attempt)."
			[ "$claim_sleep" = "0" ] || sleep "$claim_sleep"
		done

		# The tie-break belongs to the global claim, so it goes with it. On a
		# queue two sessions holding the label at once is the intended state,
		# and the loop above already proved the only thing still worth proving:
		# that our own label stuck.
		if [ "$backbone" != "github-merge-queue" ]; then
			winner=$(printf '%s\n' "$holders" | grep -v '^$' | sort -n | sed -n '1p' || true)
			if [ -n "$winner" ] && [ "$winner" != "$pr" ]; then
				mc_die "#$winner took $landing_label at the same moment and wins the tie
	  (lowest number). Giving the claim back; re-run when #$winner has landed."
			fi
		fi
	fi

	# --------------------------------------------------------------------------
	# 3. Freshness, or on a queue, conflicts
	# --------------------------------------------------------------------------
	# WHAT THIS STEP IS FOR DEPENDS ON THE BACKBONE, and getting that wrong is
	# expensive.
	#
	# On serialized-claim there is nothing between a green run and the merge, so
	# a head the base has moved past is refused: its green result was produced
	# against a tree that no longer exists.
	#
	# On a merge queue that reasoning is already handled, and better. The queue
	# builds the base plus everything ahead of this pull request and tests THAT
	# before merging, so "behind by N" stops being a fact about correctness. It
	# is only a fact about the branch. Refusing on it makes every session rebase
	# and re-run a full CI pass to satisfy a rule the queue has already met —
	# measured at two rebases and about sixteen wasted CI minutes on a single
	# pull request the day this was written.
	#
	# What the queue genuinely cannot do is merge a pull request git refuses to
	# merge. So the refusal becomes CONFLICTING.
	if [ "$backbone" = "github-merge-queue" ]; then
		step "3/7 conflicts"
	else
		step "3/7 freshness"
	fi

	behind=$(mc_behind_by "$head_sha")
	echo "       $base is $behind commit(s) ahead of this head."

	# Which hotspots this PR sits in. Printed on both backbones and whatever the
	# freshness answer: a hotspot is about a merge that is CLEAN and wrong, so
	# "nothing conflicts" is exactly when it needs saying.
	spots=""
	spot_lines=$(mc_hotspots)
	files=$(mc_pr_files "$pr")
	while IFS=$'\t' read -r pattern rule action why; do
		[ -z "$pattern" ] && continue
		while IFS= read -r path; do
			[ -z "$path" ] && continue
			if mc_hotspot_match "$pattern" "$path"; then
				spots="$spots$pattern"$'\n'
				echo "       HOTSPOT $pattern ($rule): $action"
				echo "               $why"
				break
			fi
		done <<EOF
$files
EOF
	done <<EOF
$spot_lines
EOF

	if [ "$backbone" = "github-merge-queue" ]; then
		# Refused rather than ignored. --update-branch exists to fix staleness,
		# the queue already fixes staleness, and running it anyway would merge
		# the base into the branch and re-run a full CI pass to reach the state
		# the queue produces for free.
		if [ "$update_branch" -eq 1 ]; then
			mc_die "refusing --update-branch on a merge queue. The queue tests this pull
	  request against $base plus everything ahead of it, so bringing the branch up to
	  date buys nothing and costs a full CI run. Drop the flag. If the pull request
	  CONFLICTS, this step says so below and a rebase is the fix."
		fi

		conflict=$(mc_mergeable_settled "$pr")
		case "$conflict" in
		CLEAN)
			echo "       no conflict with $base; the queue tests the merged tree."
			;;
		CONFLICTING)
			mc_die "#$pr conflicts with $base. The queue cannot merge this — it tests the
	  tree the merge would produce, and git will not produce one. In your own worktree:

	    git fetch origin
	    git rebase origin/$base
	    git push --force-with-lease

	  then re-run this script."
			;;
		*)
			# Fails closed. GitHub computes this lazily and answers null until a
			# background merge attempt finishes, so an unsettled read means the
			# question was never answered — not that the answer was yes.
			mc_die "could not find out whether #$pr conflicts with $base: GitHub still
	  reports mergeable as null after several tries. Nothing was checked, so nothing
	  is known either way. Look at the pull request, or run this again in a minute."
			;;
		esac
	elif [ "$behind" != "0" ]; then
		if [ -n "$spots" ] && [ "$update_branch" -eq 1 ]; then
			mc_die "refusing --update-branch: this PR touches a hotspot above, and the
	  update-branch API resolves the file by merging. A clean merge is the dangerous
	  case here. Rebase it by hand instead."
		fi

		if [ "$update_branch" -eq 1 ]; then
			mc_do mc_gh api --method PUT "repos/$repo/pulls/$pr/update-branch" >/dev/null
			mc_die "asked GitHub to bring the branch up to date. Checks now re-run on the
	  new head; re-run this script when they are green. (Not an error — just not
	  finished.)"
		fi

		mc_die "this head was tested against an older $base, so its green result says
	  nothing about the tree it would produce. In your own worktree:

	    git fetch origin
	    git rebase origin/$base
	    git push --force-with-lease

	  then re-run this script. If the PR touches no hotspot above, --update-branch
	  will have GitHub do it for you."
	fi

	# --------------------------------------------------------------------------
	# 4. Verify
	# --------------------------------------------------------------------------
	# On serialized-claim this is the guarantee: nothing re-tests after it, so
	# these conclusions are the last word before the merge.
	#
	# On a merge queue it is a filter, and it is worth keeping as one. The queue
	# re-tests everything it merges and drops what fails, so a red pull request
	# cannot land either way — but it can waste a queue slot and a full CI pass
	# getting there. Reading the head first is cheaper than finding out.
	step "4/7 verify"
	echo "       reading required checks on $head_sha:"

	if ! mc_require_checks "$head_sha"; then
		mc_die "not landing. A check that is missing, running, cancelled or failed is
	  not a pass. Note that a run cancelled by a later push reports success to
	  'gh run watch --exit-status' — that is why this reads conclusions directly."
	fi

	# --------------------------------------------------------------------------
	# 5. Land
	# --------------------------------------------------------------------------
	step "5/7 land"

	merged_files=$(mc_pr_files "$pr")

	merge_args="--squash --repo $repo"
	if [ "$backbone" = "github-merge-queue" ]; then
		echo "       handing to the merge queue (--auto); the queue does the speculative test."
		# shellcheck disable=SC2086 # deliberate word splitting of the flag list
		mc_do mc_gh pr merge "$pr" $merge_args --auto
		echo
		echo "       #$pr is queued. The queue tests it against the exact tree it will"
		echo "       produce and drops it if that fails. Steps 6 and 7 cannot run until"
		echo "       it lands, so once it has, run:"
		echo
		echo "         land.sh $pr --post-merge"
		echo
		echo "       Watch it with: gh pr view $pr"
		drop_claim
		exit 0
	fi

	echo "       no merge queue on this repository: steps 3 and 4 above are the guarantee."
	if [ "$admin" -eq 1 ]; then
		# shellcheck disable=SC2086
		mc_do mc_gh pr merge "$pr" $merge_args --delete-branch --admin
	else
		# shellcheck disable=SC2086
		mc_do mc_gh pr merge "$pr" $merge_args --delete-branch
	fi
	echo "       merged."

	# This merge did not go through a queue, so no merge group tested the tree
	# it just produced. On a repository that also stopped running CI on a push
	# to the default branch, nothing tests it at all unless something asks.
	# outOfQueueCi names the workflows to fire; leave it out of the config and
	# this does nothing, which keeps the plugin portable to a repository that
	# still runs CI on push.
	fire_out_of_queue_ci
else
	# Steps 6 and 7 both read this: the guard needs nothing from it, but the
	# notify decides who to tell from the merged file list, and an unset one
	# under `set -u` would abort after the guard and tell nobody.
	merged_files=$(mc_pr_files "$pr")
	echo "       already merged — steps 2 to 5 skipped."
fi


# --------------------------------------------------------------------------
# 6. Release the claim, then prove the release heading survived
# --------------------------------------------------------------------------
step "6/7 release"
drop_claim

changelog=$(mc_cfg_get releaseGuard.changelog)
if [ -z "$changelog" ]; then
	echo "       release guard is switched off in the config."
else
	tag=$(mc_gh api "repos/$repo/tags?per_page=1" --jq '.[0].name' || true)
	if [ -z "$tag" ]; then
		echo "       no tags yet; nothing for the release guard to check."
	else
		fmt=$(mc_cfg_get releaseGuard.headingFormat)
		heading=${fmt//\{tag\}/$tag}
		# Normalise CRLF before looking. A file stored with Windows line endings
		# reads as changed on every line otherwise, and the heading match fails
		# for a reason that has nothing to do with the merge.
		# Asked for raw, NOT the default JSON with a base64 .content. The contents
		# API silently stops embedding content above 1 MiB: it answers 200 with
		# "encoding": "none" and an empty "content", and only download_url is any
		# use. The CHANGELOG.md of the repository this was built for crossed that
		# line on 25 August 2026
		# at 1,049,858 bytes, and the guard then read an empty body and announced
		# that a release heading had been reverted when nothing had. Raw has no
		# such ceiling and needs no decode step.
		body=$(mc_gh api "repos/$repo/contents/$changelog?ref=$base" \
			-H "Accept: application/vnd.github.raw" | tr -d '\r')

		# "I could not read it" and "the heading is gone" are different answers
		# and must not print the same alarm. Every changelog this guard is
		# pointed at has content, so an empty body means the read failed. Say
		# that, rather than blaming the merge for it.
		if [ -z "$body" ]; then
			echo
			echo "  !! could not read $changelog on $base — the response was empty."
			echo "     This is NOT the reverted-heading alarm. Nothing was checked, so nothing is"
			echo "     known about the release heading either way. Read the file"
			echo "     yourself before landing anything else."
			exit 1
		fi
		# Matched in the shell, NOT through `printf | grep -qF`.
		#
		# grep -q stops at the first match and closes the pipe. printf is still
		# writing, so it dies of SIGPIPE (141), and `set -o pipefail` at the top
		# of this file promotes that to the status of the whole pipeline. The
		# heading is found and the guard reports it missing.
		#
		# It only happens once the text is larger than the pipe buffer, so every
		# fixture in test-land.sh (about 30 bytes each) passes while a 1 MB
		# CHANGELOG.md failed every single time. The guard raised the
		# reverted-heading alarm after a merge that had reverted nothing, and
		# exited before step 7 — so nothing was ever told it had gone stale.
		#
		# A quoted expansion inside a case pattern is a literal, so the brackets
		# in "## [v1.2.3]" are not glob characters here.
		case "$body" in
		*"$heading"*)
			echo "       release guard ok — $base still has '$heading'."
			;;
		*)
			echo
			echo "  !! $changelog on $base NO LONGER CONTAINS '$heading'."
			echo "     This merge reverted a release heading. It is the failure this guard exists for:"
			echo "     both sides inserted under the same heading, git resolved it"
			echo "     cleanly, and the older side won. The tag is fine; the file is not."
			echo "     Restore the heading on $base in a follow-up PR before anything"
			echo "     else lands."
			exit 1
			;;
		esac
	fi
fi

# --------------------------------------------------------------------------
# 7. Notify everyone this merge just invalidated
# --------------------------------------------------------------------------
step "7/7 notify"

spot_lines=$(mc_hotspots)
notified=0
# Overlapping pull requests that were deliberately NOT written to. Counted so
# the run says what it chose not to do — a silent skip and a missing check read
# the same in a log, and only one of them is correct.
quiet=0

# A file list the API truncated is the one case where reading no overlap proves
# nothing. Treat it the way overlap.sh does — as touching everything — so a huge
# merge tells every open PR rather than silently telling none of them.
mine_truncated=0
# `case`, not `printf | grep -qFx`. This file sets `pipefail`, and a merged file
# list runs to 3000 paths — well past the pipe buffer. grep -q exits at its
# match, printf dies of SIGPIPE, pipefail makes 141 the pipeline's status, and
# the test reads FALSE. The sentinel would be found and reported absent, so the
# huge merge that most needs to tell everybody would tell nobody.
#
# It happens to be safe today only because mc_pr_files appends the sentinel LAST,
# so grep reads the whole list before matching. That is another function's
# implementation detail, not a property of this line.
case "$merged_files" in
*MERGE-COORDINATOR-TRUNCATED*)
	mine_truncated=1
	echo "       #$pr changes more files than the API will list, so every open PR is"
	echo "       being told rather than only the ones a short list happened to name."
	;;
esac

while IFS=$'\t' read -r number title draft head labels; do
	[ -z "$number" ] && continue
	[ "$number" = "$pr" ] && continue

	their_files=$(mc_pr_files "$number" || true)
	theirs_truncated=0
	# Same reasoning as the sentinel test above: `case`, never a piped grep -q.
	case "$their_files" in
	*MERGE-COORDINATOR-TRUNCATED*) theirs_truncated=1 ;;
	esac
	# No need to filter the sentinel out of this: it can only appear when one of
	# the two checks above already fired, and that branch wins.
	shared=$(printf '%s\n' "$their_files" | grep -Fx -f <(printf '%s\n' "$merged_files") || true)

	reason=""
	# Which of the two things went wrong, because on a queue they get different
	# answers. "textual" means these two touch the same paths, so git may or may
	# not be able to merge the second one now. "hotspot" means they touch no
	# common path but both sit in a place where a CLEAN merge is the hazard.
	kind=""
	if [ "$mine_truncated" -eq 1 ] || [ "$theirs_truncated" -eq 1 ]; then
		reason="one of these changes more files than the API will list, so whether they overlap cannot be read"
		kind="textual"
	elif [ -n "$shared" ]; then
		# Two PRs can share thousands of paths, which puts this list well past
		# the pipe buffer — and this runs after the merge, so an abort here
		# would land the PR and then tell nobody.
		first=$(printf '%s\n' "$shared" | sed -n '1,3p' | tr '\n' ' ')
		reason="both change: $first"
		kind="textual"
	else
		while IFS=$'\t' read -r pattern rule action why; do
			[ -z "$pattern" ] && continue
			mine=""
			theirs=""
			while IFS= read -r path; do
				[ -n "$path" ] && mc_hotspot_match "$pattern" "$path" && mine=1 && break
			done <<EOF
$merged_files
EOF
			while IFS= read -r path; do
				[ -n "$path" ] && mc_hotspot_match "$pattern" "$path" && theirs=1 && break
			done <<EOF
$their_files
EOF
			if [ -n "$mine" ] && [ -n "$theirs" ]; then
				reason="both touch $pattern — $action"
				kind="hotspot"
				break
			fi
		done <<EOF
$spot_lines
EOF
	fi

	[ -z "$reason" ] && continue

	# ------------------------------------------------------------------
	# What to say about it, which the backbone decides.
	# ------------------------------------------------------------------
	# On serialized-claim, overlapping at all is enough: nothing re-tests
	# between the green run and the merge, so the other branch's result really
	# is worthless now and the whole set gets told.
	#
	# On a queue that sentence is FALSE, and sending it anyway is expensive.
	# The queue rebuilds and retests whatever it merges, so a green run that
	# predates this merge costs the other session nothing. One pull request
	# collected six of these comments in a single day and needed none of them.
	# What is still worth sending is the part a queue cannot fix by itself: a pull request
	# that now CONFLICTS, and a hotspot where a clean merge is the hazard.
	if [ "$backbone" = "github-merge-queue" ]; then
		if [ "$kind" = "hotspot" ]; then
			# Nothing is broken yet, so no rebase label. The hotspot's own
			# action is the message.
			echo "       #$number — hotspot: $reason"
			mc_do mc_gh pr comment "$number" --repo "$repo" --body "#$pr landed on \`$base\`. Nothing here conflicts, and the merge queue will retest this pull request against the current \`$base\` when it lands — so there is nothing to redo.

This is a heads-up about one path where a *clean* merge is the dangerous case: $reason

No label and no action needed unless that reads wrong to you. Posted by the merge coordinator." >/dev/null
			notified=$((notified + 1))
			continue
		fi

		# Textual overlap. Whether it matters is a question with an answer, so
		# ask it instead of assuming. Only reachable when the two share a path,
		# which is the only way this merge could have broken that one.
		conflict=$(mc_mergeable_settled "$number" 3)
		case "$conflict" in
		CLEAN)
			echo "       #$number — overlaps, still merges cleanly. Saying nothing."
			quiet=$((quiet + 1))
			continue
			;;
		CONFLICTING)
			echo "       #$number — CONFLICTS now: $reason"
			mc_do mc_gh pr edit "$number" --repo "$repo" --add-label "$rebase_label" >/dev/null 2>&1 || true
			mc_do mc_gh pr comment "$number" --repo "$repo" --body "#$pr landed on \`$base\` and this pull request now **conflicts** with it. The merge queue cannot merge a conflict — it tests the tree the merge would produce, and git will not produce one.

Why this one: $reason

    git fetch origin
    git rebase origin/$base
    git push --force-with-lease

Labelled \`$rebase_label\` by the merge coordinator." >/dev/null
			notified=$((notified + 1))
			continue
			;;
		*)
			# Not labelled. "I could not tell" is not "you must rebase", and
			# guessing the second is how a queue-era coordinator goes back to
			# generating busywork.
			echo "       #$number — overlaps; GitHub has not said whether it conflicts."
			mc_do mc_gh pr comment "$number" --repo "$repo" --body "#$pr landed on \`$base\`, and it touches paths this pull request also touches: $reason

GitHub had not finished computing whether this now conflicts when the coordinator looked, so this is a heads-up rather than a verdict — check the pull request itself. No label set.

Posted by the merge coordinator." >/dev/null
			notified=$((notified + 1))
			continue
			;;
		esac
	fi

	echo "       #$number — $reason"
	mc_do mc_gh pr edit "$number" --repo "$repo" --add-label "$rebase_label" >/dev/null 2>&1 || true
	mc_do mc_gh pr comment "$number" --repo "$repo" --body "#$pr landed on \`$base\`. This PR's last green result was produced against a \`$base\` that no longer exists, so it no longer says anything about the tree this would produce.

Why this one: $reason

    git fetch origin
    git rebase origin/$base
    git push --force-with-lease

Then re-run the checks. Labelled \`$rebase_label\` by the merge coordinator." >/dev/null
	notified=$((notified + 1))
done <<EOF
$(mc_open_prs)
EOF

if [ "$notified" -eq 0 ]; then
	echo "       nothing else open needed telling about this merge."
else
	echo "       told $notified pull request(s)."
fi
if [ "$quiet" -gt 0 ]; then
	echo "       $quiet more overlap and still merge cleanly; the queue retests them, so they were left alone."
fi

echo
echo "merge-coordinator: #$pr landed."

# --------------------------------------------------------------------------
# What it cost.
# --------------------------------------------------------------------------
# Reported here because this is where a land already stops to read something.
# A CI cache keyed on the tree (see queue-cost.sh) spent three days answering
# every merge group with a
# reason that was fiction, and the only place that showed was a job log nobody
# opens after a green merge. A land that pays twice now says so on the spot.
#
# ONLY ON --post-merge, and never fatal. On the queue path the merge group has
# not run yet when land.sh hands over, so there is nothing to read; and a
# report that can end a landing in an error is a report that gets deleted
# rather than fixed.
if [ "$post_merge" -eq 1 ]; then
	echo
	bash "$here/queue-cost.sh" "$pr" || echo "merge-coordinator: could not work out what #$pr cost. The land itself is unaffected."
fi
