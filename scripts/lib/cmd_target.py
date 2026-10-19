"""Which repository and pull request a Bash command's gh call acts on.

The merge and ready guards read the command Claude asked to run. Where that
command starts (the hook payload's cwd) is not always where it acts: a leading
`cd <dir> &&`, gh's -R, a pull request URL and GH_REPO all point it at another
repository, and a harness that resets the shell to the session folder after
every call makes those the normal way to work elsewhere.

This reads the command the way the shell would, quotes, `$( )` and heredocs
included, so a `-R` or `--draft` inside a quoted --body is text and not a flag.
It recognises a closed set of ways to point a gh call elsewhere:

  -R / --repo, value attached or not, as OWNER/NAME, github.com/OWNER/NAME or
    https://github.com/OWNER/NAME, before or after `pr` as gh allows
  a pull request URL as the argument
  GH_REPO=OWNER/NAME on the call itself, or through env
  the REST merge, PUT repos/OWNER/NAME/pulls/N/merge
  one leading `cd <literal path> &&`

The forms of retargeting it knows it does not read are "unknown", and the
guards refuse them with the override as the way through: another cd, pushd,
eval or source before the call; a variable; gh named after any other command's
name (sudo, xargs, timeout, ssh, echo); a call in a string, heredoc or pipe a
shell runs; a shell function; an alias naming gh; a merge through curl; two
guarded calls that disagree. Before this, every one of those came out as "it
acts where it starts", which is how the misses looked.

What it cannot see is the limit of reading a command line: a script file the
command runs, a gh alias (`gh alias set`), GraphQL mutations, and environment
the session set before the command. Those pass as the command reads.

A draft (`gh pr create --draft`) and a step back to draft (`gh pr ready
--undo`) are never guarded, in any form: they start no CI, wherever they act.

Usage: printf '%s\\0%s\\0%s' <cwd> <home> <command> | python cmd_target.py merge|ready
Prints key=value lines, every key every time. found=0: no guarded call.

The inputs come on stdin and not in the environment: Git Bash rewrites an
environment value that starts with / before Windows Python sees it, so
`/usr/bin/gh pr merge 7` arrived as a path into Git's install folder.
"""
import os
import re
import sys

GH = {"gh", "gh.exe"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Words that can stand in front of a command without changing where it runs.
# Any other word in front of a gh call (sudo, xargs, timeout, ssh, echo, a
# wrapper nobody listed) makes the call unknown: the guard cannot tell a
# command that runs gh somewhere else from one that prints its name.
TRANSPARENT = {"!", "{", "}", "do", "then", "else", "elif", "if", "while", "until",
               "time", "command", "builtin", "exec", "nohup"}
# Commands that run a string, or their input, as shell. Their quoted arguments,
# their heredocs and what is piped into them are read as commands.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "ssh", "su", "sudo", "doas",
          "pwsh", "powershell", "watch", "cmd", "cmd.exe"}
# Commands that run other commands in THIS shell, so a cd inside them moves
# what follows, and the guard cannot see inside a sourced file.
SAME_SHELL = {"eval", "source", "."}
# Commands that can merge over HTTP without gh.
HTTP_CLIENTS = {"curl", "wget", "http", "https", "xh"}
# Variables that point gh, or git under it, at another repository or host.
RETARGET_ENV = {"GH_REPO", "GH_HOST", "GIT_DIR", "GIT_WORK_TREE"}
VERBS = {"merge": {"merge"}, "ready": {"ready", "create", "new"}}
# Break glass, as an assignment word: before the call, or exported before it.
# The same text inside a --body or a commit message is text.
OVERRIDE = "MERGE_COORDINATOR_OVERRIDE=1"
# The flags of each call that take a value. A value is never a positional, so a
# --body or --title that reads like a number or a URL is not taken for the PR.
VALUE_FLAGS = {
    "merge": {"-b", "--body", "-F", "--body-file", "-t", "--subject",
              "--match-head-commit", "-A", "--author-email", "-R", "--repo"},
    "ready": {"-R", "--repo"},
    "create": {"-t", "--title", "-b", "--body", "-F", "--body-file", "-B", "--base",
               "-H", "--head", "-a", "--assignee", "-l", "--label", "-m",
               "--milestone", "-p", "--project", "-r", "--reviewer", "-T",
               "--template", "--recover", "-R", "--repo"},
    "api": {"-X", "--method", "-H", "--header", "-f", "--raw-field", "-F", "--field",
            "-q", "--jq", "-t", "--template", "--input", "--hostname", "-p",
            "--preview", "--cache"},
}
NAME = r"[A-Za-z0-9_.-]+"
PR_URL = re.compile(r"^https?://(?:www\.)?github\.com/(%s)/(%s)/pull/(\d+)(?:[/?#].*)?$" % (NAME, NAME), re.I)
REST_MERGE = re.compile(r"^repos/([^/?#]+)/([^/?#]+)/pulls/([^/?#]+)/merge/?(?:[?#].*)?$")
FORMS = ("It reads -R OWNER/NAME, a pull request URL, GH_REPO=OWNER/NAME on the call, "
         "a PUT to repos/OWNER/NAME/pulls/N/merge, and one leading `cd <path> &&`")


class Word:
    def __init__(self):
        self.parts = []
        self.quoted = False   # some part of it was quoted
        self.dynamic = False  # it holds an expansion, so its value is not in the text
        self.splits = False   # an expansion outside quotes, which can become several words
        self.tilde = False    # it starts with an unquoted ~
        self.strings = []     # the contents of its quoted parts
        self.qstart = None    # where its first quoted part starts

    @property
    def value(self):
        return "".join(self.parts)

    def quote(self):
        """Mark that a quoted part starts here."""
        if self.qstart is None:
            self.qstart = len(self.value)
        self.quoted = True

    def is_assignment(self):
        """NAME=value, the name unquoted; the value may be quoted, as in X="a b"."""
        v = self.value
        return bool(ASSIGN.match(v)) and (self.qstart is None or v.index("=") < self.qstart)

    def tail(self, text):
        """A word made of the end of this one: the value attached to -Rvalue."""
        w = Word()
        w.parts = [text]
        w.quoted, w.dynamic, w.splits = self.quoted, self.dynamic, self.splits
        return w


class Heredoc:
    def __init__(self):
        self.body = ""
        self.subs = []


class Lexer:
    """Splits a command into words, separators, command substitutions and heredocs."""

    def __init__(self, s):
        self.s = s
        self.n = len(s)

    def brace_end(self, i):
        depth = 0
        while i < self.n:
            if self.s[i] == "{":
                depth += 1
            elif self.s[i] == "}":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        return self.n

    def scan_dq(self, i, w, items, closing):
        """The inside of double quotes, or of an unquoted heredoc body (closing None)."""
        s, n, lit = self.s, self.n, []
        while i < n:
            c = s[i]
            if closing and c == closing:
                i += 1
                break
            if c == "\\" and i + 1 < n:
                if s[i + 1] in '$`"\\\n':
                    if s[i + 1] != "\n":
                        lit.append(s[i + 1])
                    i += 2
                    continue
                lit.append(c)
                i += 1
                continue
            if c == "$" and s[i + 1:i + 2] == "(":
                w.dynamic = True
                lit.append("$(...)")
                sub, i = self.lex(i + 2, ")")
                items.append(("sub", sub))
                continue
            if c == "`":
                w.dynamic = True
                lit.append("`...`")
                sub, i = self.lex(i + 1, "`")
                items.append(("sub", sub))
                continue
            if c == "$" and s[i + 1:i + 2] == "{":
                w.dynamic = True
                j = self.brace_end(i + 1)
                lit.append(s[i:j])
                i = j
                continue
            if c == "$" and i + 1 < n and (s[i + 1].isalnum() or s[i + 1] in "_?#@*!$-"):
                w.dynamic = True
            lit.append(c)
            i += 1
        text = "".join(lit)
        w.parts.append(text)
        w.strings.append(text)
        return i

    def read_heredocs(self, i, pending):
        s, n = self.s, self.n
        for delim, strip, quoted, hd in pending:
            lines = []
            while i < n:
                j = s.find("\n", i)
                end = n if j < 0 else j
                line = s[i:end]
                i = n if j < 0 else j + 1
                if (line.lstrip("\t") if strip else line).rstrip("\r") == delim:
                    break
                lines.append(line)
            hd.body = "\n".join(lines)
            if not quoted:
                # An unquoted delimiter means the body expands: a $( ) in it runs.
                its = []
                Lexer(hd.body).scan_dq(0, Word(), its, None)
                hd.subs = [v for k, v in its if k == "sub"]
        del pending[:]
        return i

    def lex(self, i=0, stop=None):
        """Lex from i to the end, or to the `stop` that closes a $( ) or backtick."""
        s, n = self.s, self.n
        items, pending = [], []
        st = {"word": None, "expect": None, "strip": False}
        depth = 0

        def start():
            if st["word"] is None:
                st["word"] = Word()
            return st["word"]

        def flush():
            w, expect = st["word"], st["expect"]
            st["word"] = None
            if w is None:
                return
            st["expect"] = None
            if expect == "heredoc":
                hd = Heredoc()
                items.append(("heredoc", hd))
                pending.append((w.value, st["strip"], w.quoted, hd))
            elif expect == "herestring":
                hd = Heredoc()
                hd.body = w.value
                items.append(("heredoc", hd))
            elif expect != "redirect":
                items.append(("word", w))

        while i < n:
            c = s[i]
            if stop == "`" and c == "`":
                flush()
                return items, i + 1
            if c == "\\":
                if s[i + 1:i + 2] == "\n":
                    i += 2
                    continue
                w = start()
                w.quote()
                w.parts.append(s[i + 1:i + 2])
                i += 2
                continue
            if c == "'":
                w = start()
                j = s.find("'", i + 1)
                j = n if j < 0 else j
                w.quote()
                w.parts.append(s[i + 1:j])
                w.strings.append(s[i + 1:j])
                i = j + 1
                continue
            if c == '"':
                w = start()
                w.quote()
                i = self.scan_dq(i + 1, w, items, '"')
                continue
            if c == "$":
                nxt = s[i + 1:i + 2]
                w = start()
                if nxt == "'":
                    # $'...', ANSI-C quoting: \' inside it does not end it.
                    j = i + 2
                    while j < n and s[j] != "'":
                        j += 2 if s[j] == "\\" else 1
                    text = re.sub(r"\\(.)", r"\1", s[i + 2:min(j, n)])
                    w.quote()
                    w.parts.append(text)
                    w.strings.append(text)
                    i = j + 1
                    continue
                if nxt == '"':
                    i += 1  # $"..." is a double-quoted string
                    continue
                if nxt == "(":
                    w.dynamic = w.splits = True
                    w.parts.append("$(...)")
                    sub, i = self.lex(i + 2, ")")
                    items.append(("sub", sub))
                    continue
                if nxt == "{":
                    w.dynamic = w.splits = True
                    j = self.brace_end(i + 1)
                    w.parts.append(s[i:j])
                    i = j
                    continue
                if nxt and (nxt.isalnum() or nxt in "_?#@*!$-"):
                    w.dynamic = w.splits = True
                w.parts.append("$")
                i += 1
                continue
            if c == "`":
                w = start()
                w.dynamic = w.splits = True
                w.parts.append("`...`")
                sub, i = self.lex(i + 1, "`")
                items.append(("sub", sub))
                continue
            if c in " \t\r":
                flush()
                i += 1
                continue
            if c == "\n":
                flush()
                st["expect"] = None
                items.append(("sep", "\n"))
                i = self.read_heredocs(i + 1, pending)
                continue
            if c == "#" and st["word"] is None:
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c in "<>":
                w = st["word"]
                if w is not None and not w.quoted and not w.dynamic and w.value.isdigit():
                    st["word"] = None  # the fd of 2>&1, not an argument
                else:
                    flush()
                if s.startswith("<<<", i):
                    st["expect"] = "herestring"
                    i += 3
                    continue
                if s.startswith("<<", i):
                    i += 2
                    st["strip"] = s[i:i + 1] == "-"
                    if st["strip"]:
                        i += 1
                    st["expect"] = "heredoc"
                    continue
                if s[i + 1:i + 2] == "(":
                    sub, i = self.lex(i + 2, ")")
                    items.append(("sub", sub))
                    continue
                j = i + 1
                while j < n and s[j] in "<>&|":
                    j += 1
                if s[j - 1] == "&":
                    k = j
                    while k < n and (s[k].isdigit() or s[k] == "-"):
                        k += 1
                    if k > j:
                        i = k
                        continue
                st["expect"] = "redirect"
                i = j
                continue
            if c == "&" and s[i + 1:i + 2] == ">":
                flush()
                st["expect"] = "redirect"
                i += 3 if s[i + 2:i + 3] == ">" else 2
                continue
            if c in ";&|":
                flush()
                st["expect"] = None
                op = s[i:i + 2] if s[i:i + 2] in ("&&", "||", ";;", "|&") else c
                items.append(("sep", op))
                i += len(op)
                continue
            if c == "(":
                flush()
                depth += 1
                items.append(("sep", "("))
                i += 1
                continue
            if c == ")":
                flush()
                if depth == 0 and stop == ")":
                    return items, i + 1
                depth = max(0, depth - 1)
                items.append(("sep", ")"))
                i += 1
                continue
            w = start()
            if not w.parts and c == "~":
                w.tilde = True
            w.parts.append(c)
            i += 1
        flush()
        return items, i


def segments(items):
    """Split lexed items into simple commands, in the order they run."""
    segs, cur = [], {"words": [], "subs": [], "heredocs": [], "after": None}
    for kind, val in items:
        if kind == "sep":
            cur["end"] = val
            segs.append(cur)
            cur = {"words": [], "subs": [], "heredocs": [], "after": val}
        elif kind == "word":
            cur["words"].append(val)
        elif kind == "sub":
            cur["subs"].append(val)
        else:
            cur["heredocs"].append(val)
    cur["end"] = None
    segs.append(cur)
    return segs


def base(word):
    """The command a word names, path and quotes aside: "/usr/bin/gh" is gh."""
    return re.split(r"[\\/]", word.value)[-1].lower() if word is not None else ""


def parse_slug(v):
    scheme = re.match(r"^https?://", v, re.I)
    rest = (v[scheme.end():] if scheme else v).rstrip("/")
    if rest.lower().endswith(".git"):
        rest = rest[:-4]
    parts = rest.split("/")
    if len(parts) == 3:
        if parts[0].lower() not in ("github.com", "www.github.com"):
            return None
        parts = parts[1:]
    elif scheme or len(parts) != 2:
        return None
    if all(re.fullmatch(NAME, p) and p not in (".", "..") for p in parts):
        return "/".join(parts)
    return None


def read_flags(words, value_flags):
    """gh's own reading of its arguments: (positionals, [(flag, value Word or None)])."""
    pos, flags, i, only_pos = [], [], 0, False
    while i < len(words):
        w = words[i]
        v = w.value
        if only_pos or w.dynamic or not v.startswith("-") or v == "-":
            pos.append(w)
            i += 1
            continue
        if v == "--":
            only_pos = True
            i += 1
            continue
        if v.startswith("--"):
            name, eq, val = v.partition("=")
            if eq:
                flags.append((name, w.tail(val)))
            elif name in value_flags:
                flags.append((name, words[i + 1] if i + 1 < len(words) else None))
                i += 1
            else:
                flags.append((name, None))
            i += 1
            continue
        if len(v) > 2 and v[2] == "=":
            flags.append((v[:2], w.tail(v[3:])))  # -X=PUT, -d=false
            i += 1
            continue
        # -abc is a cluster of short flags; the first that takes a value takes
        # the rest of the word, or the next word.
        for k in range(1, len(v)):
            name = "-" + v[k]
            if name in value_flags:
                if k + 1 < len(v):
                    flags.append((name, w.tail(v[k + 1:])))
                else:
                    flags.append((name, words[i + 1] if i + 1 < len(words) else None))
                    i += 1
                break
            flags.append((name, None))
        i += 1
    return pos, flags


def flag_true(val):
    """pflag's reading of a boolean flag, bare or =1/t/true/0/f/false; None when neither."""
    if val is None:
        return True
    if val.dynamic:
        return None
    v = val.value.lower()
    if v in ("1", "t", "true"):
        return True
    if v in ("0", "f", "false"):
        return False
    return None


def env_slug(assigns, call):
    slug = ""
    for w in assigns:
        name, _, val = w.value.partition("=")
        if name == "GH_REPO":
            if w.dynamic:
                call["why"] = call["why"] or "GH_REPO is a variable"
                continue
            slug = parse_slug(val) or ""
            if not slug:
                call["why"] = call["why"] or "GH_REPO=%s is not a repository the guard reads" % val
        elif name in RETARGET_ENV:
            call["why"] = call["why"] or "%s is set on the call" % name
    return slug


def parse_gh(args, mode, assigns):
    """The guarded call these gh arguments make, or None when they make none."""
    if not args:
        return None
    call = {"kind": "", "slug": "", "pr": "", "prsel": "", "draft": "0", "undo": "0", "why": None}

    def bad(why):
        call["why"] = call["why"] or why

    # Flags may stand before the subcommand (`gh -R o/n pr merge 7`, `gh -X PUT
    # api ...`). Move them after it, where the rest of this reads them.
    lead = []
    while args and args[0].value.startswith("-") and not args[0].dynamic:
        v = args[0].value
        lead.append(args[0])
        args = args[1:]
        if (v in ("-R", "--repo") or v in VALUE_FLAGS["api"]) and args:
            lead.append(args[0])
            args = args[1:]
    if not args:
        return None
    if lead:
        args = [args[0]] + lead + args[1:]

    if args[0].dynamic or len(args) > 1 and args[0].value == "pr" and args[1].dynamic:
        call["kind"] = "merge" if mode == "merge" else "ready"
        bad("the gh subcommand is a variable")
        return call

    if args[0].value == "api":
        if mode != "merge":
            return None
        pos, flags = read_flags(args[1:], VALUE_FLAGS["api"])
        method = None
        for name, val in flags:
            if name in ("-X", "--method"):
                method = val
            if name == "--hostname" and (val is None or val.value.lower() != "github.com"):
                bad("the call names another GitHub host")
        if not pos:
            return None
        endpoint = pos[0]
        path = re.sub(r"^https?://api\.github\.com/", "", endpoint.value, flags=re.I).lstrip("/")
        m = REST_MERGE.match(path)
        verb = None if method is None else ("?" if method.dynamic else method.value.upper())
        if endpoint.dynamic:
            if verb in ("PUT", "?"):
                call["kind"] = "merge"
                bad("the API path is a variable")
                return call
            return None
        if not m:
            return None
        if verb is None or verb not in ("PUT", "?"):
            return None  # not a PUT, so not a merge
        call["kind"] = "merge"
        if verb == "?":
            bad("the HTTP method is a variable")
        owner, name, number = m.groups()
        if (owner, name) == ("{owner}", "{repo}"):
            call["slug"] = env_slug(assigns, call)
        elif re.fullmatch(NAME, owner) and re.fullmatch(NAME, name):
            call["slug"] = "%s/%s" % (owner, name)
            env_slug(assigns, call)
        else:
            bad("the API path does not name a repository the guard reads")
        if re.fullmatch(r"\d+", number):
            call["pr"] = number
        for w in args[1:]:
            if w.splits:
                bad("an unquoted variable or substitution could add arguments the guard cannot see")
        return call

    if args[0].value != "pr":
        return None
    rest, j, pre = args[1:], 0, []
    # -R may stand between `pr` and the verb.
    while j < len(rest) and rest[j].value.startswith("-") and not rest[j].dynamic:
        v = rest[j].value
        if v in ("-R", "--repo"):
            pre.append((v, rest[j + 1] if j + 1 < len(rest) else None))
            j += 2
        elif v.startswith("--repo="):
            pre.append(("--repo", rest[j].tail(v[7:])))
            j += 1
        elif v.startswith("-R"):
            pre.append(("-R", rest[j].tail(v[2:])))
            j += 1
        else:
            pre.append(("?", rest[j]))
            j += 1
    if j >= len(rest) or rest[j].value not in VERBS[mode]:
        return None
    kind = "create" if rest[j].value == "new" else rest[j].value  # gh pr new is create
    call["kind"] = kind
    pos, flags = read_flags(rest[j + 1:], VALUE_FLAGS[kind])
    flags = pre + flags
    for w in rest:
        if w.splits:
            bad("an unquoted variable or substitution could add arguments the guard cannot see")

    flag_slug = ""
    for name, val in flags:
        if name == "?":
            bad("%s stands before the verb" % val.value)
        elif name in ("-R", "--repo"):
            if val is None:
                bad("-R has no value")
            elif val.dynamic:
                bad("the repository is a variable")
            else:
                flag_slug = parse_slug(val.value) or ""
                if not flag_slug:
                    bad("-R %s is not a repository the guard reads" % val.value)
        elif kind == "create" and name in ("-d", "--draft"):
            t = flag_true(val)
            call["draft"] = "1" if t else "0"
            if t is None:
                bad("%s=%s is not a value the guard reads" % (name, val.value))
        elif kind == "ready" and name == "--undo":
            t = flag_true(val)
            call["undo"] = "1" if t else "0"
            if t is None:
                bad("--undo=%s is not a value the guard reads" % val.value)

    url_slug = ""
    if kind in ("merge", "ready") and pos:
        p = pos[0]
        if p.dynamic:
            bad("the pull request is a variable, and a pull request URL names its own repository")
        elif re.fullmatch(r"#?\d+", p.value):
            call["pr"] = p.value.lstrip("#")
        elif "://" in p.value:
            m = PR_URL.match(p.value)
            if m:
                url_slug = "%s/%s" % (m.group(1), m.group(2))
                call["pr"] = m.group(3)
            else:
                bad("%s is not a pull request URL the guard reads" % p.value)
        else:
            call["prsel"] = p.value
    from_env = env_slug(assigns, call)
    if url_slug and flag_slug and url_slug.lower() != flag_slug.lower():
        bad("the pull request URL and -R name different repositories")
    call["slug"] = url_slug or flag_slug or from_env
    return call


def harmless(call):
    """A draft, or a step back to draft: nothing CI cares about, wherever it acts."""
    return ((call["kind"] == "create" and call["draft"] == "1")
            or (call["kind"] == "ready" and call["undo"] == "1"))


def analyse(items, mode, ctx, events, top, scope):
    """Append, in the order they run, the events that decide the target.

    `scope` names the shell an event happens in: () for the command's own, a
    longer tuple for a $( ) or a string another shell runs. A cd moves only the
    calls in its own scope or inside it.
    """
    subs = [0]

    def child():
        subs[0] += 1
        return scope + (subs[0],)

    # name ( ) { ... }: a function's body runs wherever and whenever it is called.
    for a, b, c in zip(items, items[1:], items[2:]):
        if a[0] == "word" and b == ("sep", "(") and c == ("sep", ")"):
            events.append(("func", scope))
    first, prev = True, None
    for seg in segments(items):
        for sub in seg["subs"]:
            analyse(sub, mode, "sub", events, False, child())
        for hd in seg["heredocs"]:
            for sub in hd.subs:
                analyse(sub, mode, "sub", events, False, child())
        words = seg["words"]
        if not words:
            prev = seg
            continue
        is_first, first = first, False
        k, assigns = 0, []
        while k < len(words):
            w = words[k]
            if w.is_assignment():
                assigns.append(w)
                if w.value == OVERRIDE:
                    events.append(("override", scope))
            elif w.quoted or w.value not in TRANSPARENT and w.value != "env":
                break
            elif w.value == "env" and k + 1 < len(words) and words[k + 1].value.startswith("-"):
                break  # env -i, env -u: read below as gh run through env
            k += 1
        head = words[k] if k < len(words) else None
        name = base(head)
        if head is None or name in ("export", "declare", "typeset", "readonly", "local"):
            for w in words[k + 1:] if head is not None else []:
                if w.value == OVERRIDE:
                    events.append(("override", scope))
            for w in assigns + (words[k + 1:] if head is not None else []):
                if w.value.partition("=")[0] in RETARGET_ENV:
                    events.append(("env", scope, w.value.partition("=")[0]))
            prev = seg
            continue
        if name in ("cd", "pushd", "popd"):
            leading = (name == "cd" and top and is_first and seg["after"] in (None, "\n")
                       and k == 0 and len(words) == 2 and seg["end"] == "&&")
            events.append(("cd", scope, words[k + 1] if leading else None))
            prev = seg
            continue
        if name in SAME_SHELL:
            events.append(("cd", scope, None))
        if name == "function":
            events.append(("func", scope))
        if name == "alias" and any("gh" in w.value for w in words[k + 1:]):
            events.append(("unknown", scope, "an alias names gh, and the guard does not follow aliases"))
        if name in GH:
            call = parse_gh(words[k + 1:], mode, assigns)
            if call is not None and not harmless(call):
                events.append(("call", scope, call, ctx))
            prev = seg
            continue
        if head.dynamic and k + 1 < len(words) and words[k + 1].value in ("pr", "api"):
            call = parse_gh(words[k + 1:], mode, [])
            if call is not None and not harmless(call):
                events.append(("unknown", scope, "the command name is a variable"))
        # gh named after another command's name: something that runs it, or text.
        for j in range(k + 1, len(words)):
            if base(words[j]) in GH:
                call = parse_gh(words[j + 1:], mode, [])
                if call is not None and not harmless(call):
                    through = " ".join(w.value for w in words[:j])[:60]
                    events.append(("unknown", scope, "gh is run through %s, which the guard does not follow" % through))
                    break
        if mode == "merge" and name in HTTP_CLIENTS and any(re.search(r"/pulls/[^/\s]+/merge", w.value) for w in words):
            events.append(("unknown", scope, "the merge goes through %s, which the guard does not read" % name))
        if name in SHELLS:
            inner = scope if name in SAME_SHELL else child()
            texts = [t for w in words[k + 1:] for t in w.strings]
            texts += [hd.body for hd in seg["heredocs"]]
            # what is piped in: `echo "..." | bash`, `cat <<EOF | sh`
            if prev is not None and seg["after"] in ("|", "|&"):
                texts += [t for w in prev["words"] for t in w.strings]
                texts += [hd.body for hd in prev["heredocs"]]
            for t in texts:
                analyse(Lexer(t).lex()[0], mode, "string", events, False, inner)
        prev = seg


def resolve(word, cwd, home):
    """The folder a leading cd goes to, or (None, why) when it cannot be told."""
    p = word.value
    if word.tilde:
        if p != "~" and not p.startswith("~/"):
            return None, "the cd goes to another user's home folder"
        p = (home or os.path.expanduser("~")).rstrip("/\\") + p[1:]
    if p.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", p):
        return p, None
    if not cwd:
        return None, "the cd is relative and the hook was not told where the command starts"
    return cwd.rstrip("/\\") + "/" + p, None


def within(inner, outer):
    return inner[:len(outer)] == outer


def decide(cmd, mode, cwd, home):
    out = {"found": "0", "status": "ok", "why": "", "kind": "", "slug": "", "pr": "",
           "prsel": "", "draft": "0", "undo": "0", "cd": "", "override": "0"}
    events = []
    analyse(Lexer(cmd).lex()[0], mode, "top", events, True, ())
    # Break glass holds whatever else the command says, so it is read first.
    if any(e[0] == "override" for e in events):
        out["override"] = "1"
    calls = [i for i, e in enumerate(events) if e[0] == "call"]
    unknowns = [e for e in events if e[0] == "unknown"]
    if not calls and not unknowns:
        return out
    out["found"] = "1"

    def unknown(why):
        out["status"] = "unknown"
        out["why"] = why
        return out

    if any(e[0] == "func" for e in events):
        return unknown("the command defines a shell function, and the guard does not follow where it is called")
    if unknowns:
        return unknown(unknowns[0][2])
    for i in calls:
        _, _, c, ctx = events[i]
        if ctx == "string":
            return unknown("the call sits in a string that another command runs as shell")
        if c["why"]:
            return unknown(c["why"])
    for idx, e in enumerate(events[:calls[-1]]):
        if e[0] not in ("env", "cd"):
            continue
        # Only what happens in a call's own shell, or one around it, moves it.
        if not any(i > idx and within(events[i][1], e[1]) for i in calls):
            continue
        if e[0] == "env":
            return unknown("%s is set for the commands after it" % e[2])
        w = e[2]
        if w is None:
            return unknown("a cd, pushd, popd, eval or source the guard does not follow comes before the call")
        if w.dynamic:
            return unknown("the cd goes to a variable")
        out["cd"], why = resolve(w, cwd, home)
        if why:
            return unknown(why)
    keys = set()
    for i in calls:
        c = events[i][2]
        keys.add((c["kind"], c["slug"].lower(), c["pr"], c["prsel"], c["draft"], c["undo"]))
    if len(keys) > 1:
        return unknown("the command makes two guarded calls that do not name the same pull request")
    c = events[calls[0]][2]
    for key in ("kind", "slug", "pr", "prsel", "draft", "undo"):
        out[key] = c[key]
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in VERBS:
        sys.exit("usage: cmd_target.py merge|ready")
    parts = sys.stdin.buffer.read().decode("utf-8", "replace").split("\0", 2)
    if len(parts) != 3:
        sys.exit("cmd_target.py: stdin is <cwd> NUL <home> NUL <command>")
    cwd, home, cmd = parts
    out = decide(cmd, mode, cwd, home)
    if out["status"] == "unknown":
        out["why"] = "%s. %s" % (out["why"], FORMS)
    text = "".join("%s=%s\n" % (k, str(v).replace("\n", " ")) for k, v in out.items())
    sys.stdout.buffer.write(text.encode("utf-8"))


if __name__ == "__main__":
    main()
