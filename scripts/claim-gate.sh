#!/usr/bin/env bash
# The issue claim gate. .github/workflows/issue-claim.yml and
# issue-claim-others.yml run it; the plugin ships starting copies of both as
# issue-claim.example.yml and issue-claim-others.example.yml.
#
# WHY IT IS ON GITHUB. Most of this plugin's safety net binds only Claude
# sessions: the guard hooks and the skill. An agent from another
# vendor meets only what GitHub enforces. So the rule "one open pull request
# claims an issue" lives in a check that every pull request runs, drafts
# included.
#
# WHAT IT DOES. It asks claims.sh for the verdict on one pull request.
#   - Clear: it removes the duplicate-claim label if it is there, marks its old
#     comment resolved, and passes.
#   - Duplicate: it adds the label, writes one comment that names the holder and
#     the ways forward, and fails. It edits that comment on the next run. It does
#     not add a new comment on every push.
#   - Could not look: it fails, and says to re-run. It never passes a claim it
#     did not check.
#
# THE OTHER PULL REQUESTS. A check runs for the pull request whose event fired,
# and one pull request's event can change another's verdict: an older one
# that claims an issue later, or a holder that is reopened, makes a newer one a
# duplicate while its check stays green. So:
#   --reconcile   re-runs the check on every open pull request whose label
#                 disagrees with its verdict: a duplicate with no label, or a
#                 label on one that is now clear. Only those, so a re-run that
#                 finds nothing to change re-runs nothing, and runs cannot set
#                 each other off for ever.
#   --after-close the same, plus every pull request that carries the label:
#                 when the holder leaves, a refused one goes green, and one
#                 still refused names its new holder.
# A check that has not finished may already have read the claims as they were,
# so it is waited for (all waits share MC_RERUN_WAIT seconds, default 150),
# then re-run, unless a newer check or a new head commit has replaced it. A
# re-run that fails says so on the pull request it was for, not only in a red
# run on the one that fired, and the gate's next verdict on it replaces that
# note. These run from a second workflow on pull_request_target
# (issue-claim-others.example.yml), and re-running a check re-runs the claim
# workflow alone, so a re-run never sets off another.
#
# Usage:
#   claim-gate.sh <number>                      check one pull request
#   claim-gate.sh --reconcile [--except <N>]    re-run the checks that disagree
#   claim-gate.sh --after-close                 the same, and every labelled one
#   claim-gate.sh ... --dry-run                 print the writes instead
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

mc_require_config

MARK="<!-- merge-coordinator:issue-claim -->"

pr=""
mode="one"
except=""
dry_run=0
while [ $# -gt 0 ]; do
	case "$1" in
	--after-close) mode="after-close" ;;
	--reconcile) mode="reconcile" ;;
	--except)
		case "${2:-}" in
		"" | *[!0-9]*) mc_die "--except needs a pull request number." ;;
		esac
		except="$2"
		shift
		;;
	--dry-run) dry_run=1 ;;
	-*) mc_die "unknown option $1" ;;
	*)
		case "$1" in
		*[!0-9]*) mc_die "not a pull request number: $1" ;;
		esac
		pr="$1"
		;;
	esac
	shift
done

mc_do() {
	if [ "$dry_run" -eq 1 ]; then
		echo "would run: $*"
		return 0
	fi
	"$@"
}

repo=$(mc_repo)
label=$(mc_dup_label)
workflow="${MC_CLAIM_WORKFLOW:-issue-claim.yml}"
tab=$(printf '\t')

# find_comment <pr> — the id of the gate's comment on <pr>, or nothing.
find_comment() {
	mc_gh api --paginate "repos/$repo/issues/$1/comments" \
		--jq ".[] | select(.body | startswith(\"$MARK\")) | .id" | sed -n '1p'
}

# write_comment <pr> <comment id or ""> <body> — edit the gate's comment if it
# has one, else add it.
write_comment() {
	if [ -n "$2" ]; then
		mc_do mc_gh api -X PATCH "repos/$repo/issues/comments/$2" -f body="$3" --silent ||
			mc_warn "could not edit comment $2 on #$1."
	else
		mc_do mc_gh api "repos/$repo/issues/$1/comments" -f body="$3" --silent ||
			mc_warn "could not comment on #$1."
	fi
}

# --------------------------------------------------------------------------
# The other pull requests: re-run the check where it is out of date.
# --------------------------------------------------------------------------
if [ "$mode" != "one" ]; then
	[ -z "$pr" ] || mc_die "--$mode takes no pull request number (use --except)."
	rc=0
	labelled=$(mc_gh pr list --repo "$repo" --state open --label "$label" --limit 1000 \
		--json number --jq '.[].number') || {
		echo "merge-coordinator: could not list the pull requests that carry $label." >&2
		echo "  Nothing was re-run. Re-run this job, or re-run their checks by hand." >&2
		exit 1
	}
	if table=$(bash "$here/claims.sh"); then
		dups=$(printf '%s\n' "$table" | awk -F'\t' '$3 == "duplicate" { print $1 }')
	else
		echo "merge-coordinator: could not read the claims, so a pull request that has just become a duplicate was not looked for." >&2
		[ "$mode" = "after-close" ] || exit 1
		echo "  Re-running the labelled ones only. Re-run this job to look again." >&2
		dups=""
		rc=1
	fi
	if [ "$mode" = "after-close" ]; then
		numbers=$(printf '%s\n%s\n' "$labelled" "$dups" | sed '/^$/d' | sort -nu)
		why="a pull request closed"
	else
		# One list or the other, not both: the label and the verdict disagree.
		numbers=$(printf '%s\n%s\n' "$labelled" "$dups" | sed '/^$/d' | sort -n | uniq -u)
		why="another pull request changed its claim"
	fi
	[ -z "$except" ] || numbers=$(printf '%s\n' "$numbers" | sed "/^$except\$/d")
	if [ -z "$numbers" ]; then
		echo "merge-coordinator: every open pull request's label matches its claim. Nothing to re-run."
		exit "$rc"
	fi

	# not_rechecked <pr> <reason> — fail, and say so on that pull request.
	not_rechecked() {
		mc_warn "$2"
		rc=1
		local id
		id=$(find_comment "$1") || id=""
		write_comment "$1" "$id" "$MARK
**Issue claim: not re-checked.** The claims changed ($why), and the \`issue claim\` check on this pull request could not be re-run: $2 Its result, and the \`$label\` label, may be out of date. Push a commit or edit the body to run it again (once any merge conflict is resolved: GitHub runs no pull_request check while there is one)."
	}

	# head_of <pr> — commit<TAB>branch<TAB>owner/repository of <pr>'s head.
	head_of() {
		mc_gh pr view "$1" --repo "$repo" --json headRefOid,headRefName,headRepository,headRepositoryOwner \
			--jq '"\(.headRefOid)\t\(.headRefName)\t\(.headRepositoryOwner.login // "")/\(.headRepository.name // "")"'
	}
	# latest_run <commit> <branch> <owner/repository> — "id status" of the
	# newest $workflow run for that head, or nothing. By commit, branch AND
	# repository: two forks' branches both called main share a name, and two
	# pull requests from one branch share a commit.
	latest_run() {
		local rows
		rows=$(mc_claim_runs "$1" "$workflow") || return 1
		printf '%s\n' "$rows" | MC_B="$2" MC_R="$3" awk -F'\t' '
			$3 == ENVIRON["MC_B"] && tolower($4) == tolower(ENVIRON["MC_R"]) { last = $1 " " $2 }
			END { if (last != "") print last }'
	}

	# One deadline for every wait in this job, well inside its timeout-minutes:
	# a job killed mid-loop would leave the rest neither re-run nor noted.
	poll=${MC_RERUN_POLL:-5}
	case "$poll" in "" | *[!0-9]* | 0) poll=1 ;; esac
	deadline=$((SECONDS + ${MC_RERUN_WAIT:-150}))

	for n in $numbers; do
		head=$(head_of "$n") || {
			not_rechecked "$n" "could not read the head commit of #$n."
			continue
		}
		sha=${head%%"$tab"*}
		rest=${head#*"$tab"}
		hbranch=${rest%%"$tab"*}
		hrepo=${rest#*"$tab"}
		latest=$(latest_run "$sha" "$hbranch" "$hrepo") || {
			not_rechecked "$n" "could not list the $workflow runs for #$n."
			continue
		}
		if [ -z "$latest" ]; then
			not_rechecked "$n" "#$n has no $workflow run on its head commit to re-run."
			continue
		fi
		run=${latest%% *}
		state=${latest#* }
		if [ "$state" != "completed" ]; then
			echo "merge-coordinator: the issue claim check on #$n (run $run) has not finished; it may have read the claims before they changed. Waiting for it, then re-running it."
			newer=""
			while [ "$state" != "completed" ] && [ "$SECONDS" -lt "$deadline" ]; do
				sleep "$poll"
				now=$(latest_run "$sha" "$hbranch" "$hrepo") || now=""
				[ -n "$now" ] || now="$run ?"
				if [ "${now%% *}" != "$run" ]; then
					newer=${now%% *}
					break
				fi
				state=${now#* }
			done
			# A run that started after this one read the claims as they are now.
			if [ -n "$newer" ]; then
				echo "merge-coordinator: a newer issue claim check on #$n (run $newer) started after the claims changed; leaving it to run."
				continue
			fi
			if [ "$state" != "completed" ]; then
				not_rechecked "$n" "run $run for #$n had not finished by this job's deadline (status: $state), so it could not be re-run."
				continue
			fi
			# A push while waiting made a new head with its own new check; the
			# run waited on was cancelled by it, and re-running that one would
			# cancel the new check in turn. A head that cannot be read is not
			# re-run blind for the same reason.
			now_head=$(head_of "$n") || {
				not_rechecked "$n" "could not read the head commit of #$n after waiting, so run $run was not re-run (it might cancel a newer check)."
				continue
			}
			now_sha=${now_head%%"$tab"*}
			if [ "$now_sha" != "$sha" ]; then
				new_run=$(latest_run "$now_sha" "$hbranch" "$hrepo") || new_run=""
				if [ -n "$new_run" ]; then
					echo "merge-coordinator: #$n has a new head commit since, with its own check (run ${new_run%% *}); it reads the claims as they are now."
				else
					not_rechecked "$n" "#$n has a new head commit since, and no $workflow run on it (GitHub runs none while a pull request has a merge conflict)."
				fi
				continue
			fi
		fi
		echo "merge-coordinator: re-running the issue claim check on #$n (run $run)."
		mc_do mc_gh run rerun "$run" --repo "$repo" && continue
		# Two runs of this can re-run the same check at once, and the second
		# is refused because the first already started it. That is not a
		# failure: the check is running again.
		now=$(mc_gh run view "$run" --repo "$repo" --json status --jq '.status') || now=""
		if [ -n "$now" ] && [ "$now" != "completed" ]; then
			echo "merge-coordinator: run $run for #$n was re-run by something else; it is running."
			continue
		fi
		not_rechecked "$n" "the re-run of run $run for #$n failed."
	done
	exit "$rc"
fi

[ -n "$pr" ] || mc_die "give a pull request number, --reconcile or --after-close."

# --------------------------------------------------------------------------
# One pull request
# --------------------------------------------------------------------------
set +e
verdict=$(bash "$here/claims.sh" --pr "$pr" 2>&1)
status=$?
set -e
printf '%s\n' "$verdict"

# The label and the comment are the message. The exit status is the gate. A
# failure to write the message is reported, and it never changes the verdict.
labels=$(mc_gh api "repos/$repo/issues/$pr/labels" --jq '[.[].name] | join(",")') || {
	mc_warn "could not read the labels of #$pr."
	labels="?"
}
has_label=0
case ",$labels," in
*",$label,"*) has_label=1 ;;
esac

comment=$(find_comment "$pr") || {
	mc_warn "could not read the comments of #$pr."
	comment=""
}

case "$status" in
0)
	if [ "$has_label" -eq 1 ]; then
		mc_do mc_gh pr edit "$pr" --repo "$repo" --remove-label "$label" ||
			mc_warn "could not remove $label from #$pr."
	fi
	if [ -n "$comment" ]; then
		write_comment "$pr" "$comment" "$MARK
**Issue claim: resolved.** $verdict"
	fi
	exit 0
	;;
1)
	# The label may not exist yet on a repository that has not synced
	# labels.json. Creating it with --force is safe to repeat.
	mc_do mc_gh label create "$label" --repo "$repo" --color b60205 \
		--description "Another open pull request already claims this issue" --force ||
		mc_warn "could not create the label $label."
	if [ "$has_label" -eq 0 ]; then
		mc_do mc_gh pr edit "$pr" --repo "$repo" --add-label "$label" ||
			mc_warn "could not add $label to #$pr."
	fi
	write_comment "$pr" "$comment" "$MARK
**Issue claim refused.** The \`issue claim\` check fails until this is resolved. It runs again when the body is edited or a commit is pushed (while there is no merge conflict: GitHub runs no pull_request check during one), when another pull request's claim changes and clears this one, and when any other pull request closes.

\`\`\`
$verdict
\`\`\`"
	exit 1
	;;
*)
	echo >&2
	echo "merge-coordinator: could not check the issue claim of #$pr, so this check fails." >&2
	echo "  Could not look is not the same answer as clear. Re-run this check." >&2
	exit 1
	;;
esac
