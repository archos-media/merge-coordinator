"""Issue claims across the open pull requests.

claims.sh runs this. Standard input is the output of one paginated GraphQL
read of the open pull requests. gh writes one JSON document per page, one after
another, so the input is read as a stream of documents.

A pull request CLAIMS an issue in one of two ways:

  - an `issue: N` line inside its footprint block, which register.sh writes;
  - GitHub lists N in its closingIssuesReferences ("Closes #N" in the body, or
    a link made in the Development sidebar).

Any agent writes the second one without knowing this tool exists. That is why it
counts.

A MENTION is not a claim. A title such as "Plan the sections move (#101)" names
an issue. Plan pull requests and phase pull requests do that all the time. In
the 958 pull requests of the repository this was built for, before it was
built, 73 pairs were open at the same time
and named the same issue that way. Almost all were planned work. A mention is
reported, and it never refuses anything.

A claim can say it is planned work beside another pull request:

  issue: 44 part-of #50

A claim with part-of is never refused. Of the claims without it, the oldest
pull request (the lowest number) holds the issue. Each other one is a
DUPLICATE. overlap.sh uses the same oldest-first order.

Modes:
  table        one line for each open PR: number<TAB>issue column<TAB>verdict
  pr <N>       the verdict for PR N. Exit 0 clear, 1 duplicate, 3 unknown.
  issue <N>    the PRs that claim or mention issue N. Exit 1 when one claims it.

Exit 3 always means "could not look". It is never the same answer as "clear".
"""
import io
import json
import re
import sys

OPEN = "<!-- merge-coordinator:footprint"
CLOSE = "-->"
ISSUE_LINE = re.compile(r"^issue:\s*#?(\d+)(?:\s+part-of\s+#?(\d+))?(?:\s|$)", re.IGNORECASE)
MENTION = re.compile(r"#(\d+)\b")

CLEAR, DUPLICATE, UNKNOWN = 0, 1, 3


def fail(message):
    sys.stderr.write("merge-coordinator: %s\n" % message)
    sys.exit(UNKNOWN)


def documents(text):
    """Every JSON document in the text, in order."""
    decoder = json.JSONDecoder()
    docs, i, n = [], 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return docs
        doc, i = decoder.raw_decode(text, i)
        docs.append(doc)


def load(text):
    docs = documents(text)
    if not docs:
        raise ValueError("the read of open pull requests returned nothing")
    prs = []
    for doc in docs:
        if doc.get("errors"):
            raise ValueError("GitHub returned errors: %s" % json.dumps(doc["errors"]))
        prs.extend(doc["data"]["repository"]["pullRequests"]["nodes"])
    return prs


def declared(body):
    """The issue lines in the footprint block, as {issue: part_of or None}."""
    body = body or ""
    start = body.find(OPEN)
    if start < 0:
        return {}
    end = body.find(CLOSE, start + len(OPEN))
    if end < 0:
        # overlap.sh reports a block with no end. Here it only means that no
        # claim was declared. A closing reference still counts.
        return {}
    found = {}
    for line in body[start + len(OPEN):end].splitlines():
        match = ISSUE_LINE.match(line.strip())
        if match:
            found[int(match.group(1))] = int(match.group(2)) if match.group(2) else None
    return found


def analyse(prs):
    numbers = set(p["number"] for p in prs)
    info = {}
    for p in prs:
        claims = declared(p.get("body"))
        refs = (p.get("closingIssuesReferences") or {}).get("nodes") or []
        for node in refs:
            # setdefault: a part-of on the declared line applies to the same
            # issue when the body also closes it.
            claims.setdefault(int(node["number"]), None)
        mentions = []
        for raw in MENTION.findall(p.get("title") or ""):
            n = int(raw)
            if n not in numbers and n not in claims and n not in mentions:
                mentions.append(n)
        info[p["number"]] = {"pr": p, "claims": claims, "mentions": mentions, "dups": []}

    claimants = {}
    for number, item in info.items():
        for issue, part_of in item["claims"].items():
            claimants.setdefault(issue, []).append((number, part_of))

    for issue, rows in claimants.items():
        primaries = sorted(number for number, part_of in rows if part_of is None)
        for number in primaries[1:]:
            info[number]["dups"].append((issue, primaries[0]))
    return info, claimants


def issue_column(item):
    if item["dups"]:
        return "DUP #%d" % item["dups"][0][0]
    if item["claims"]:
        issues = sorted(item["claims"])
        extra = "+%d" % (len(issues) - 1) if len(issues) > 1 else ""
        return "#%d%s" % (issues[0], extra)
    if item["mentions"]:
        return "~%d" % item["mentions"][0]
    return "-"


def describe(pr):
    state = "draft" if pr.get("isDraft") else "ready"
    return "#%d (%s, branch %s, updated %s)" % (
        pr["number"], state, pr.get("headRefName") or "?", pr.get("updatedAt") or "?")


def main():
    if len(sys.argv) < 2:
        fail("claims.py needs a mode: table, pr <N> or issue <N>")
    mode = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else ""

    stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")
    try:
        prs = load(stdin.read())
    except (ValueError, KeyError, TypeError) as exc:
        fail("could not read the open pull requests: %s" % exc)
    info, claimants = analyse(prs)

    if mode == "table":
        for number in sorted(info):
            item = info[number]
            verdict = "duplicate" if item["dups"] else "clear"
            print("%d\t%s\t%s" % (number, issue_column(item), verdict))
        return CLEAR

    if not arg.isdigit():
        fail("mode %s needs a number, not %r" % (mode, arg))
    n = int(arg)

    if mode == "pr":
        item = info.get(n)
        if item is None:
            fail("#%d is not among the open pull requests, so its claim was not checked" % n)
        if not item["dups"]:
            if item["claims"]:
                print("#%d claims %s, and no other open pull request claims the same issue." % (
                    n, ", ".join("#%d" % i for i in sorted(item["claims"]))))
            else:
                print("#%d claims no issue." % n)
            return CLEAR
        for issue, holder in item["dups"]:
            print("#%d claims issue #%d, and %s already claims it." % (
                n, issue, describe(info[holder]["pr"])))
        print("")
        print("Read %s before you do more work here. Then do one of these:" % (
            ", ".join("#%d" % h for _, h in item["dups"])))
        print("  - If this is planned work beside it, declare that in the footprint block:")
        for issue, holder in item["dups"]:
            print("      issue: %d part-of #%d" % (issue, holder))
        print("    or run: register.sh --issue %d --part-of %d" % item["dups"][0])
        print("  - If its session is dead, take the work over and close one of the two.")
        print("  - If this pull request does not do that issue, remove the claim.")
        return DUPLICATE

    if mode == "issue":
        # Every field has a value ("-" when there is none). A shell reads these
        # lines with IFS set to a tab, and bash joins two tabs into one. An empty
        # field would move every later field one place left.
        def row(kind, number, part_of):
            pr = info[number]["pr"]
            return "%s\t%d\t%s\t%s\t%s\t%s" % (
                kind, number, pr.get("headRefName") or "-",
                "draft" if pr.get("isDraft") else "ready",
                pr.get("updatedAt") or "-", "part-of #%d" % part_of if part_of else "-")
        rows = sorted(claimants.get(n, []))
        for number, part_of in rows:
            print(row("claim", number, part_of))
        for number in sorted(info):
            if n in info[number]["mentions"]:
                print(row("mention", number, None))
        return DUPLICATE if rows else CLEAR

    fail("unknown mode %r" % mode)


if __name__ == "__main__":
    sys.exit(main())
