#!/usr/bin/env bash
# Tests lib/cmd_target.py — which repository and pull request a command's gh
# call acts on, read the way the shell reads it.
#
# The guards trust this reading to pick whose rules apply. A wrong slug or a
# missed `cd` lets a merge through unchecked, and nothing about an allowed
# command says it was misread. So most cases here pin a field exactly, and each
# form of retargeting the reader knows it does not read is pinned to
# status=unknown. The reader's limits (a script file it cannot open, a gh
# alias) are listed in lib/cmd_target.py.
set -euo pipefail

cd "$(dirname "$0")"
PARSER=./lib/cmd_target.py

pass=0
fail=0

for cand in python3 python py; do
	if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
		PY="$cand"
		break
	fi
done
[ -n "${PY:-}" ] || { echo "no python: could not run"; exit 1; }

# expect <mode> <command> <check>... — each check is key=value, which must be a
# whole output line, or key~text, which that key's value must contain.
expect() {
	local mode="$1" cmd="$2" out check key want line got bad=""
	shift 2
	out=$(printf '%s\0%s\0%s' "${EXPECT_CWD-/w}" /h "$cmd" | "$PY" "$PARSER" "$mode")
	for check in "$@"; do
		case "$check" in
		*~*)
			key="${check%%~*}" want="${check#*~}" got=""
			while IFS= read -r line; do
				case "$line" in "$key="*) got="${line#"$key="}" ;; esac
			done <<<"$out"
			case "$got" in *"$want"*) ;; *) bad="$bad [$check]" ;; esac
			;;
		*)
			got=0
			while IFS= read -r line; do
				[ "$line" = "$check" ] && got=1
			done <<<"$out"
			[ "$got" = 1 ] || bad="$bad [$check]"
			;;
		esac
	done
	if [ -z "$bad" ]; then
		echo "ok: $mode: $cmd"
		pass=$((pass + 1))
	else
		echo "FAIL: $mode: $cmd — wanted$bad"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=$((fail + 1))
	fi
}

# --------------------------------------------------------------------------
# Not a guarded call. found=0 lets the command through untouched.
# --------------------------------------------------------------------------
expect merge "ls -la" found=0
expect merge "git merge main" found=0
expect merge "gh pr view 7 --json title" found=0
expect merge "grep -rn 'merge queue' docs/" found=0
expect ready "gh pr merge 7" found=0
expect merge "gh pr ready 7" found=0
# Text that only mentions a merge: a quoted argument, a heredoc fed to a
# command that does not run it, a comment.
expect merge 'git commit -m "gh pr merge 5 -R a/b is refused"' found=0
expect merge $'git commit -F - <<\'EOF\'\ngh pr merge 5 -R a/b\nEOF' found=0
expect merge "git status # then gh pr merge 5" found=0
# Reading a pull request or its merge state through the API is not merging it.
expect merge "gh api repos/o/n/pulls/5/merge" found=0
expect merge "gh api repos/o/n/pulls/5" found=0
expect merge "gh api -X GET repos/o/n/pulls/5/merge" found=0
# Calls that change nothing CI cares about are never guarded, in any form: a
# draft, and going back to draft.
expect ready "gh pr create --draft --title t" found=0
expect ready "cd /a; gh pr create --draft" found=0
expect ready "timeout 60 gh pr create -d" found=0
expect ready 'cd "$WT" && gh pr ready 5 --undo' found=0

# --------------------------------------------------------------------------
# Where it acts: the forms the guard reads.
# --------------------------------------------------------------------------
expect merge "gh pr merge 7 --squash" found=1 status=ok slug= pr=7 cd=
expect merge "gh pr merge -R o/n 7" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 --repo o/n" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 --repo=o/n" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 -Ro/n" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 -R github.com/o/n" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 -R https://github.com/o/n.git" status=ok slug=o/n pr=7
expect merge "gh pr merge 7 -R https://GitHub.com/o/n/" status=ok slug=o/n pr=7
expect merge "gh pr merge 15 -R other/app2" status=ok slug=other/app2 pr=15
expect merge "gh pr -R o/n merge 7" status=ok slug=o/n pr=7
expect merge "gh pr merge https://github.com/o/n/pull/7" status=ok slug=o/n pr=7
expect merge "gh pr merge https://github.com/o/n/pull/7/files" status=ok slug=o/n pr=7
expect merge "gh pr merge https://github.com/o/n/pull/7 -R O/N" status=ok slug=o/n pr=7
expect merge "GH_REPO=o/n gh pr merge 7" status=ok slug=o/n pr=7
expect merge "env GH_REPO=o/n gh pr merge 7" status=ok slug=o/n pr=7
expect merge "GH_REPO=o/n gh pr merge 7 -R x/y" status=ok slug=x/y
expect merge "/usr/bin/gh pr merge 7 -R o/n" status=ok slug=o/n pr=7
expect merge "'C:\\Program Files\\GitHub CLI\\gh.exe' pr merge 7" found=1 status=ok pr=7
expect merge '"gh" pr "merge" 7' found=1 status=ok pr=7
expect merge "gh pr merge '#7'" status=ok pr=7
expect merge "gh pr merge my-branch" status=ok pr= prsel=my-branch
# The last -R is the one gh uses.
expect merge "gh pr merge 7 -R a/b -R c/d" status=ok slug=c/d
# A -R, or a number, that sits inside a value is part of that value.
expect merge 'gh pr merge 7 --body "see -R x/y"' status=ok slug= pr=7
expect merge "gh pr merge --subject 12 7" status=ok pr=7
expect merge "gh pr merge 7 # -R a/b" found=1 status=ok slug= pr=7
expect merge "gh pr merge -b 12 7" status=ok pr=7
# A quoted value in an assignment before the call is still an assignment.
expect merge 'GH_REPO="o/n" gh pr merge 7' found=1 status=ok slug=o/n pr=7
expect merge "FOO='a b' gh pr merge 7" found=1 status=ok pr=7
expect merge 'env GH_REPO="o/n" gh pr merge 7' found=1 status=ok slug=o/n
# Words that run what follows them, in the current shell.
expect merge "time gh pr merge 7 -R o/n" found=1 status=ok slug=o/n pr=7
expect merge "command gh pr merge 7" found=1 status=ok pr=7
expect merge "if gh pr merge 7; then echo y; fi" found=1 status=ok pr=7
expect merge "! gh pr merge 7" found=1 status=ok pr=7
# A -R or a read on another command in the line is not the merge's.
expect merge "gh pr view -R a/b 3 && gh pr merge 7" status=ok slug= pr=7
expect merge "grep -R a/b . && gh pr merge 7" status=ok slug= pr=7
expect merge "gh api repos/x/y/pulls/3 --jq .title && gh pr merge 7" status=ok slug= pr=7
# Redirections are not arguments.
expect merge "gh pr merge 7 2>&1" status=ok pr=7
expect merge "gh pr merge 2>/dev/null 7" status=ok pr=7
expect merge "gh pr merge 7 &>/dev/null" status=ok pr=7
# A command substitution runs.
expect merge 'out=$(gh pr merge 7 -R o/n)' found=1 status=ok slug=o/n
expect merge 'echo "$(gh pr merge 7 -R o/n)"' found=1 status=ok slug=o/n
expect merge 'x=`gh pr merge 7 -R o/n`' found=1 status=ok slug=o/n
expect merge $'cat <<EOF\n$(gh pr merge 7 -R o/n)\nEOF' found=1 status=ok slug=o/n
# A cd inside a substitution moves only the substitution.
expect merge 'gh pr merge 7 --body "$(cd sub && git log -1)"' found=1 status=ok cd= pr=7
# The REST merge.
expect merge "gh api --method PUT repos/o/n/pulls/7/merge" status=ok slug=o/n pr=7
expect merge "gh api -XPUT /repos/o/n/pulls/7/merge -f merge_method=squash" status=ok slug=o/n pr=7
expect merge "gh api -X put https://api.github.com/repos/o/n/pulls/7/merge" status=ok slug=o/n pr=7
expect merge "gh api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'" status=ok slug= pr=7
expect merge "GH_REPO=o/n gh api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'" status=ok slug=o/n pr=7
expect merge "gh api -X PUT 'repos/o/n/pulls/7/merge?x=1'" found=1 status=ok slug=o/n pr=7
expect merge 'gh api -H "Accept: application/vnd.github+json" -X PUT repos/o/n/pulls/7/merge' found=1 status=ok slug=o/n pr=7
# One leading cd.
expect merge "cd /a/x && gh pr merge 7" status=ok cd=/a/x
expect merge 'cd "/a/b c" && gh pr merge 7' status=ok "cd=/a/b c"
expect merge "cd '/q' && gh pr merge 7" status=ok cd=/q
expect merge "cd sub && gh pr merge 7" status=ok cd=/w/sub
expect merge "cd ~/r && gh pr merge 7" status=ok cd=/h/r
expect merge "cd D:/r && gh pr merge 7" status=ok cd=D:/r
expect merge "cd /a/x && gh pr merge 7 -R o/n" status=ok cd=/a/x slug=o/n
# A cd after the call does not move it.
expect merge "gh pr merge 7 && cd /a" found=1 status=ok cd= pr=7
# Two calls that agree are one target.
expect merge "gh pr merge 7 -R o/n || gh pr merge 7 --repo o/n" status=ok slug=o/n pr=7

# --------------------------------------------------------------------------
# Forms the guard does not read: unknown, never "acts where it starts".
# --------------------------------------------------------------------------
expect merge "cd /a; gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge $'cd /a\ngh pr merge 7' status=unknown "why~cd, pushd, popd"
expect merge "(cd /a && gh pr merge 7)" status=unknown "why~cd, pushd, popd"
expect merge "pushd /a && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge "git fetch && cd /a && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge "cd /a && cd /b && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge 'cd "$X" && gh pr merge 7' status=unknown "why~variable"
expect merge 'gh pr merge 7 -R "$R"' status=unknown "why~repository is a variable"
expect merge 'gh pr merge "$PR"' status=unknown "why~pull request is a variable"
expect merge 'gh pr merge $ARGS' status=unknown "why~unquoted"
expect merge 'gh pr merge 7 --body $(cat notes)' status=unknown "why~unquoted"
expect merge "export GH_REPO=o/n && gh pr merge 7" status=unknown "why~GH_REPO is set"
expect merge "GH_REPO=o/n; gh pr merge 7" status=unknown "why~GH_REPO is set"
expect merge "GH_HOST=x gh pr merge 7" status=unknown "why~GH_HOST"
expect merge "GIT_DIR=/a/.git gh pr merge 7" status=unknown "why~GIT_DIR"
expect merge "sudo gh pr merge 7" status=unknown "why~through sudo"
expect merge "echo 7 | xargs gh pr merge" status=unknown "why~through xargs"
expect merge "env -i gh pr merge 7" status=unknown "why~through env"
expect merge 'bash -c "gh pr merge 7"' status=unknown "why~string"
expect merge "ssh box 'cd /a && gh pr merge 7'" status=unknown
expect merge $'bash <<\'EOF\'\ngh pr merge 7\nEOF' status=unknown "why~string"
expect merge "gh pr merge 7 -R gitlab.com/o/n" status=unknown "why~not a repository"
expect merge "gh pr merge 7 -R o" status=unknown "why~not a repository"
expect merge "gh pr merge 7 -R" status=unknown "why~no value"
expect merge "gh pr merge https://gitlab.com/o/n/pull/7" status=unknown "why~not a pull request URL"
expect merge "gh pr merge https://github.com/a/b/pull/7 -R c/d" status=unknown "why~different"
expect merge "gh pr merge 7 && gh pr merge 8" status=unknown "why~two guarded calls"
expect merge "gh pr merge 7 -R a/b && gh pr merge 7 -R c/d" status=unknown "why~two guarded calls"
expect merge "gh pr --foo merge 7" status=unknown "why~before the verb"
expect merge 'gh api -X "$M" repos/o/n/pulls/7/merge' status=unknown "why~method"
expect merge 'gh api -X PUT "$URL"' status=unknown "why~API path"
expect merge "gh api --hostname ghe.example.com -X PUT repos/o/n/pulls/7/merge" status=unknown "why~another GitHub host"
expect merge "cd -P /a && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge 'x=$(cd /a && true); gh pr merge 7' found=1 status=ok cd=
expect merge 'x=$(cd /a && gh pr merge 7)' status=unknown "why~cd, pushd, popd"
expect merge "cd ~bob/r && gh pr merge 7" status=unknown "why~home"
EXPECT_CWD= expect merge "cd sub && gh pr merge 7" status=unknown "why~relative"
expect merge "source env.sh && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge ". ./env.sh && gh pr merge 7" status=unknown "why~cd, pushd, popd"
expect merge 'eval "cd /a" && gh pr merge 7' status=unknown "why~cd, pushd, popd"
expect merge $'f() { gh pr merge 7; }\ncd /a && f' status=unknown "why~function"
expect merge 'function f { gh pr merge 7; }; cd /a && f' status=unknown "why~function"
# The body on lines of its own: the call is a plain segment, and only the
# keyword says it runs later, somewhere else.
expect merge $'function f {\n  gh pr merge 7\n}\ncd /a && f' status=unknown "why~function"
expect merge "alias g=gh; g pr merge 7" status=unknown "why~alias"
expect merge "GIT_WORK_TREE=/a gh pr merge 7" status=unknown "why~GIT_WORK_TREE"
expect merge "GH_HOST=x gh api -X PUT repos/o/n/pulls/7/merge" status=unknown "why~GH_HOST"
expect merge 'gh api -X PUT repos/o/n/pulls/7/merge $EXTRA' status=unknown "why~unquoted"
expect merge 'gh pr $verb 7' status=unknown "why~variable"
expect merge '"$GH" pr merge 7' status=unknown "why~variable"
expect merge "gh pr merge 7 -R https://o/n" status=unknown "why~not a repository"
expect merge "gh pr merge 7 -R ../n" status=unknown "why~not a repository"
# gh after another command's name: a runner the guard does not know, or text.
# It cannot tell which, so it refuses.
for runner in timeout nice ionice stdbuf watch parallel doas winpty flock "time -p" "command -p" "exec -a x" "ssh box" "find . -exec" echo; do
	expect merge "$runner gh pr merge 7" status=unknown "why~through"
done
expect merge 'eval "gh pr merge 7"' status=unknown "why~string"
expect merge "eval gh pr merge 7" status=unknown
expect merge 'cmd //c "gh pr merge 7"' status=unknown "why~string"
expect merge 'sh -c "gh pr merge 7"' status=unknown "why~string"
expect merge 'zsh -c "gh pr merge 7"' status=unknown "why~string"
expect merge 'pwsh -c "gh pr merge 7"' status=unknown "why~string"
expect merge 'echo "gh pr merge 7 -R a/b" | bash' status=unknown "why~string"
expect merge $'cat <<\'EOF\' | sh\ngh pr merge 7\nEOF' status=unknown "why~string"
expect merge "curl -X PUT -H 'Authorization: token t' https://api.github.com/repos/o/n/pulls/7/merge" status=unknown "why~curl"
# Every unknown says what the guard does read, the REST form included.
expect merge "sudo gh pr merge 7" "why~It reads -R OWNER/NAME" "why~pulls/N/merge"

# --------------------------------------------------------------------------
# Readiness.
# --------------------------------------------------------------------------
expect ready "gh pr ready 5" found=1 status=ok kind=ready pr=5 undo=0
expect ready "gh pr ready" status=ok kind=ready pr= prsel=
expect ready "gh pr ready 5 --undo" found=0
expect ready "gh pr ready 5 --undo=false" found=1 status=ok kind=ready undo=0 pr=5
expect ready "gh pr ready -R o/n 5" status=ok slug=o/n pr=5
expect ready "gh pr ready https://github.com/o/n/pull/5" status=ok slug=o/n pr=5
expect ready "gh pr ready my-branch" found=1 status=ok pr= prsel=my-branch
expect ready 'X="1" gh pr ready 5' found=1 status=ok pr=5
expect ready "gh pr create --title x --body y" found=1 status=ok kind=create draft=0
expect ready "gh pr create --draft --title x" found=0
expect ready "gh pr create --title x -d" found=0
expect ready "gh pr create -dt x" found=0
expect ready "gh pr create --title x --draft=false" found=1 status=ok kind=create draft=0
expect ready "gh pr create -R o/n --draft" found=0
expect ready 'FOO="x" gh pr create --title t' found=1 status=ok kind=create draft=0
# --draft inside the body is text.
expect ready 'gh pr create --title x --body "open it with --draft"' found=1 status=ok kind=create draft=0
expect ready "gh pr create --title --draft" found=1 status=ok kind=create draft=0
# The body Claude writes: a heredoc in a command substitution in double quotes,
# holding a quote, an unmatched parenthesis, a -R and a --draft, with the real
# --draft after it (a draft: not guarded), and the same without it.
expect ready $'gh pr create --title "t" --body "$(cat <<\'EOF\'\nWhat (1) does: see "-R a/b" and 2) --draft\nEOF\n)" --draft' found=0
expect ready $'gh pr create --title "t" --body "$(cat <<\'EOF\'\nWhat (1) does: see "-R a/b" and 2) --draft\nEOF\n)"' found=1 status=ok kind=create draft=0 slug=
expect ready "echo the branch is ready to land" found=0
# gh pr new is gh pr create.
expect ready "gh pr new --title t --body b" found=1 status=ok kind=create draft=0
expect ready "gh pr new --draft --title t" found=0
# pflag's booleans: 0, f and false are false; anything else it does not read.
expect ready "gh pr create --draft=0 --title t" found=1 status=ok kind=create draft=0
expect ready "gh pr create --draft=f --title t" found=1 status=ok kind=create draft=0
expect ready "gh pr create -d=false --title t" found=1 status=ok kind=create draft=0
expect ready "gh pr create --draft=1 --title t" found=0
expect ready "gh pr create --draft=maybe --title t" found=1 status=unknown "why~not a value"
expect ready "gh pr ready 7 --undo=0" found=1 status=ok kind=ready undo=0 pr=7

# --------------------------------------------------------------------------
# Flags before the subcommand: gh reads them there too.
# --------------------------------------------------------------------------
expect merge "gh -R o/r pr merge 7" found=1 status=ok slug=o/r pr=7
expect merge "gh --repo=o/r pr merge 7" found=1 status=ok slug=o/r pr=7
expect merge "gh -X PUT api repos/o/r/pulls/7/merge" found=1 status=ok slug=o/r pr=7
expect merge "gh api -X=PUT repos/o/r/pulls/7/merge" found=1 status=ok slug=o/r pr=7
expect merge "gh --foo pr merge 7" found=1 status=unknown "why~before the verb"
expect ready "gh -R o/r pr ready 7" found=1 status=ok slug=o/r pr=7

# --------------------------------------------------------------------------
# $'...' and $"..." strings.
# --------------------------------------------------------------------------
expect merge "echo \$'it\\'s'; gh pr merge 7" found=1 status=ok pr=7
expect merge "\$'gh' pr merge 7" found=1 status=ok pr=7
expect merge '$"gh" pr merge 7' found=1 status=ok pr=7

# --------------------------------------------------------------------------
# Break glass is an assignment word, not text.
# --------------------------------------------------------------------------
expect ready 'MERGE_COORDINATOR_OVERRIDE=1 gh pr ready 5' status=ok pr=5 override=1
expect merge "MERGE_COORDINATOR_OVERRIDE=1 gh pr merge 7" override=1
expect merge "export MERGE_COORDINATOR_OVERRIDE=1; gh pr merge 7" override=1
expect merge 'gh pr merge 7 --body "MERGE_COORDINATOR_OVERRIDE=1"' found=1 override=0
expect merge "gh pr merge 7 --squash" override=0

echo
echo "test-cmd-target: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
