#!/usr/bin/env bash
# Who claims which issue, across every open pull request.
#
# Three callers read this, and they must agree. The GitHub Action refuses a
# second claim. The EnterWorktree hook refuses it earlier, on this machine. And
# queue-state.sh shows it. They all run this one script, so the three answers
# cannot drift apart.
#
# The rule is in lib/claims.py. This script reads the open pull requests from
# GitHub in one paginated GraphQL call and gives them to it.
#
# Usage:
#   claims.sh               one line for each open PR: number, issue column, verdict
#   claims.sh --pr 42       the verdict for one PR
#   claims.sh --issue 12    the PRs that claim or mention one issue
#
# Exit status:
#   0  clear
#   1  a duplicate claim (--pr), or the issue is claimed (--issue)
#   2  a usage error
#   3  could not look. This is never the same answer as clear.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/gh.sh
. "$here/lib/gh.sh"

usage() {
	echo "merge-coordinator: $*" >&2
	echo "  usage: claims.sh [--pr <number> | --issue <number>]" >&2
	exit 2
}

mode="table"
arg=""
case "${1:-}" in
"") ;;
--pr | --issue)
	mode="${1#--}"
	arg="${2:-}"
	case "$arg" in
	"" | *[!0-9]*) usage "$1 needs a number." ;;
	esac
	;;
--help | -h)
	sed -n '2,22p' "${BASH_SOURCE[0]}"
	exit 0
	;;
*) usage "unknown option $1" ;;
esac

mc_require_config

repo=$(mc_repo)
owner="${repo%%/*}"
name="${repo#*/}"

# Only what the rule reads. closingIssuesReferences is GitHub's own record of
# the issues a pull request closes, so it needs no parsing of the body here.
query='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body isDraft headRefName updatedAt
        closingIssuesReferences(first: 25) { nodes { number } }
      }
    }
  }
}'

page=$(mktemp)
errors=$(mktemp)
trap 'rm -f "$page" "$errors"' EXIT

if ! mc_gh api graphql --paginate -f owner="$owner" -f name="$name" -f query="$query" \
	>"$page" 2>"$errors"; then
	echo "merge-coordinator: could not read the open pull requests, so no claim was checked." >&2
	sed 's/^/  /' "$errors" >&2
	exit 3
fi

set +e
mc_py "$here/lib/claims.py" "$mode" "$arg" <"$page"
rc=$?
set -e
exit "$rc"
