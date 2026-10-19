#!/usr/bin/env bash
# Tests that every config key a script requires is in config.example.json and
# in this repository's own config.
#
# What must be caught: a script that reads a key with mc_cfg_get or
# mc_cfg_list (both fail when the key is absent) while the example leaves it
# out. Someone who copies the example then gets a refusal or a "could not
# read" on the first run that reaches that line, and the suites never see it,
# because their fixtures write their own configs. ciWorkflow shipped that way.
#
# The optional readers (mc_cfg_get_opt, mc_cfg_list_opt) are left out: an
# absent key is an answer to them. Two keys have readers of their own in
# lib/gh.sh and are listed by hand below.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=lib/gh.sh
. "$HERE/lib/gh.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok: $1"; }
bad() {
	fail=$((fail + 1))
	echo "FAIL: $1"
	[ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/    /'
	return 0
}

# The literal keys passed to the required readers, one per line, quoted or
# not. A key built from a variable ("$key", "labels.$want") cannot be read
# this way; literal calls elsewhere cover the same keys.
keys=$(MC_ROOT="$ROOT" mc_py -c '
import glob, os, re
root = os.environ["MC_ROOT"]
found = set()
for path in glob.glob(os.path.join(root, "scripts", "*.sh")) + glob.glob(os.path.join(root, "scripts", "lib", "*.sh")):
    if os.path.basename(path).startswith("test-"):
        continue
    with open(path, encoding="utf-8") as fh:
        for m in re.finditer(r"\bmc_cfg_(?:get|list)\b[ \t]+[\"\x27]?([A-Za-z][A-Za-z0-9.]*[A-Za-z0-9])[\"\x27]?(?=[\s)]|$)", fh.read()):
            found.add(m.group(1))
print("\n".join(sorted(found)))
')
# Required by readers of their own: mc_require_config (repo) and mc_hotspots
# (hotspots), each of which refuses a config without it.
keys=$(printf '%s\nrepo\nhotspots\n' "$keys" | sort -u | grep .)
count=$(printf '%s\n' "$keys" | grep -c .)

# Fewer than this and the scan itself is broken: there are more than ten
# required keys today, so a short list means the pattern stopped matching.
if [ "$count" -ge 8 ]; then
	ok "the scan finds the required keys ($count)"
else
	bad "the scan finds the required keys" "found $count:
$keys"
fi

# check_config <file> — every key in $keys resolves in <file>.
check_config() {
	local file="$1" missing
	missing=$(MC_FILE="$file" MC_KEYS="$keys" mc_py -c '
import json, os, sys
try:
    with open(os.environ["MC_FILE"], encoding="utf-8") as fh:
        cfg = json.load(fh)
except Exception as exc:
    sys.exit("cannot read %s: %s" % (os.environ["MC_FILE"], exc))
for key in os.environ["MC_KEYS"].split():
    node = cfg
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            print(key)
            break
        node = node[part]
') || {
		bad "$file is readable" "$missing"
		return
	}
	if [ -z "$missing" ]; then
		ok "${file#"$ROOT"/} has every required key"
	else
		bad "${file#"$ROOT"/} has every required key" "missing: $(printf '%s' "$missing" | tr '\n' ' ')"
	fi
}

check_config "$ROOT/config.example.json"
check_config "$ROOT/.github/merge-coordinator.json"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
