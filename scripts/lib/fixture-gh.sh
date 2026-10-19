#!/usr/bin/env bash
# A stand-in for `gh`, used by the test scripts through MC_GH.
#
# It routes on the whole argument line. MC_FIXTURES points at a directory holding
# a `routes` file of `glob<TAB>response` lines; the first glob that matches the
# arguments decides the answer. A response of FAIL exits non-zero, which is how a
# test makes an API call fail on purpose.
#
# AN UNROUTED CALL IS AN ERROR, not an empty answer. If a script starts making a
# request the test never declared, the test has to fail rather than quietly
# receive nothing — an empty response is exactly what several of these scripts
# are written to distrust, and a fixture that handed one out would make them look
# correct for the wrong reason.
#
# WHAT IT DOES NOT DO: it does not implement `--jq`. The response files hold the
# text a real gh would print AFTER applying the filter in the calling script. So
# these tests prove the logic around each call, and do not prove the jq filter
# inside it. Changing a filter needs a real call to check it; that is what the
# verification section of the plan of record is for.
#
# Every call is appended to MC_FIXTURES/calls.log so a test can assert that a
# mutating call was or was not made.
set -u

dir="${MC_FIXTURES:?fixture-gh.sh needs MC_FIXTURES}"
printf '%s\n' "$*" >>"$dir/calls.log"

[ -f "$dir/routes" ] || {
	echo "fixture-gh: no routes file in $dir" >&2
	exit 1
}

line=0
while IFS=$'\t' read -r pattern response; do
	line=$((line + 1))
	[ -z "$pattern" ] && continue
	case "$pattern" in \#*) continue ;; esac
	# shellcheck disable=SC2254 # the pattern is a glob on purpose
	case "$*" in
	$pattern)
		# SEQ:a,b,c answers a on the first call, b on the second and so on,
		# sticking on the last one. That is how a test exercises a script that
		# reads the same endpoint twice and expects the world to have changed
		# in between — the claim read-back is the case that needs it.
		case "$response" in
		SEQ:*)
			counter="$dir/.seq.$line"
			n=0
			[ -f "$counter" ] && n=$(cat "$counter")
			printf '%s' "$((n + 1))" >"$counter"
			choices=$(printf '%s' "${response#SEQ:}" | tr ',' '\n')
			response=$(printf '%s\n' "$choices" | sed -n "$((n + 1))p")
			[ -z "$response" ] && response=$(printf '%s\n' "$choices" | tail -1)
			;;
		esac
		if [ "$response" = "FAIL" ]; then
			echo "fixture-gh: routed failure for: $*" >&2
			exit 1
		fi
		if [ "$response" = "EMPTY" ]; then
			exit 0
		fi
		cat "$dir/$response"
		exit 0
		;;
	esac
done <"$dir/routes"

echo "fixture-gh: no route for: $*" >&2
exit 1
