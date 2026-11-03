#!/usr/bin/env python3
"""lint.py — Write|Edit rules for angular-guide.

Usage (stdin: the Claude Code hook payload):
  lint.py pre       Blocking checks NG001-NG018. Each rule runs against the
                    content before the change (the file on disk, or nothing
                    for a new file) and after it (a Write's `content`, or the
                    on-disk file with an Edit's `old_string` replaced by
                    `new_string`). Only a rule that matches MORE times after
                    the change blocks, so an edit to a file that already
                    breaks a rule is not blocked for what was already there.
  lint.py post      Advisory checks NG101-NG106 against the file now on disk.
  lint.py quality <file>
                    NG106's structural analysis, printed one finding per line
                    (used by analyze_quality.sh).

Findings go to stdout and the process exits 2; hook-lint.sh forwards them to
stderr, which Claude Code shows to the model. Every unexpected condition
exits 0 with no output — a plugin defect must never block a write.
"""

import bisect
import hashlib
import json
import math
import os
import re
import sys
import time
from collections import Counter

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPTS)

import ag_profile  # noqa: E402
import rules  # noqa: E402


# ------------------------------------------------------------------ helpers

def scan_delimited(src, i, opener_len, end_marker, out):
    # Skip content starting right after the opener, looking for end_marker.
    # If found, blank the content between (newlines kept for line accounting)
    # and return the index just past it. If it is never found -- an
    # unterminated /* or <!-- -- only the rest of THIS line is treated as
    # commented: swallowing the rest of the file would silently disable every
    # rule, a much worse failure than the syntax error it reflects.
    n = len(src)
    j = i + opener_len
    close = src.find(end_marker, j)
    if close != -1:
        out.append("".join("\n" if ch == "\n" else " " for ch in src[i:close + len(end_marker)]))
        return close + len(end_marker)
    nl = src.find("\n", j)
    end = n if nl == -1 else nl
    out.append(" " * (end - i))
    return end


def strip_comments(src, is_html):
    """Blank //, /* */ and <!-- --> comments, preserving every offset."""
    out = []
    i, n = 0, len(src)
    in_str = None   # None, or the quote character we are inside
    # in_tag is only meaningful for HTML: true between a tag's "<" and ">".
    in_tag = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_str:
            # Angular inline templates live in backtick strings, so an HTML
            # comment inside one is blanked too.
            if in_str == "`" and src[i:i + 4] == "<!--":
                i = scan_delimited(src, i, 4, "-->", out)
                continue
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if src[i:i + 4] == "<!--":
            i = scan_delimited(src, i, 4, "-->", out)
            continue
        if is_html and c == "<" and (nxt.isalpha() or nxt in ("/", "!", "?")):
            # A bare "<" in text ("1 < 2") is a comparison, not a tag opener.
            in_tag = True
            out.append(c)
            i += 1
            continue
        if is_html and c == ">" and in_tag:
            in_tag = False
            out.append(c)
            i += 1
            continue
        if c in ("\"", "'", "`"):
            # In HTML a quote only delimits a string inside a tag (an
            # attribute value); an apostrophe in text ("Don't") is prose and
            # must not trap the scanner inside a runaway string.
            if c != "`" and is_html and not in_tag:
                out.append(c)
                i += 1
                continue
            in_str = c
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            j = i
            while j < n and src[j] != "\n":
                j += 1
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and nxt == "*":
            i = scan_delimited(src, i, 2, "*/", out)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def blank_strings(src):
    """Blank string-literal content (quotes kept), preserving every offset."""
    out = []
    i, n = 0, len(src)
    in_str = None
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if c == in_str:
                in_str = None
                out.append(c)
            else:
                out.append(c if c == "\n" else " ")
            i += 1
            continue
        if c in ("\"", "'", "`"):
            in_str = c
        out.append(c)
        i += 1
    return "".join(out)


def balanced_end(s, open_index):
    """Index just past the ")" matching the "(" at open_index."""
    depth, k, n = 0, open_index, len(s)
    while k < n:
        if s[k] == "(":
            depth += 1
        elif s[k] == ")":
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    return n


def top_level_args(s, open_index):
    """Argument count of the call whose "(" is at open_index."""
    depth, k, n = 0, open_index, len(s)
    commas, nonblank, quote = 0, False, None
    while k < n:
        c = s[k]
        if quote:
            if c == "\\":
                k += 1
            elif c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
            nonblank = True
        elif c in "([{":
            depth += 1
            if depth > 1:
                nonblank = True
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                break
        elif c == "," and depth == 1:
            commas += 1
        elif not c.isspace():
            nonblank = True
        k += 1
    return commas + 1 if nonblank else 0


def chain_start(s, end):
    # Walk back from the `.subscribe` at `end` to the start of its call
    # chain. Bracket depth is tracked so an arrow function or block inside an
    # earlier operator (`map((x) => { ... })`) is stepped over; at depth 0 a
    # statement or arrow boundary ends the chain, and an unmatched opener
    # means we left an enclosing call's argument list (`take(obs$.subscribe())`),
    # whose operators do not apply here.
    depth = 0
    k = end - 1
    while k >= 0:
        c = s[k]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                return k + 1
            depth -= 1
        elif depth == 0 and (c in ";," or (c == ">" and k > 0 and s[k - 1] == "=")):
            return k + 1
        k -= 1
    return 0


def find_all(pattern, text, flags=0):
    return [m.start() for m in re.finditer(pattern, text, flags)]


# -------------------------------------------------------------------- rules

class Ctx:
    """One version of the file, as the rules see it."""

    def __init__(self, file_path, raw, profile):
        self.file_path = file_path
        self.ext = file_path.rsplit(".", 1)[-1].lower() if "." in file_path else ""
        self.raw = raw
        self.code = strip_comments(raw, self.ext == "html")
        self.profile = profile
        self.ts = self.ext == "ts"
        self.spec = bool(re.search(r"\.(spec|test)\.ts$", file_path))
        self.component = (file_path.endswith(".component.ts") or "@Component" in self.code)
        self.newlines = [i for i, ch in enumerate(raw) if ch == "\n"]
        self.parse_ignores()

    def line_of(self, offset):
        return bisect.bisect_left(self.newlines, offset) + 1

    def parse_ignores(self):
        # angular-guide-ignore-{next-line,line,file} <IDs> -- <reason>
        # Only honoured inside a real comment: comment stripping blanks
        # comments in place, so a directive whose span is still non-blank in
        # `code` sits in a string or in code, not a comment. A directive with
        # no reason is recorded but not applied.
        self.ignored_lines, self.ignored_file, self.unreasoned = {}, set(), []
        for m in re.finditer(r"angular-guide-ignore-(next-line|line|file)\b([^\n]*)", self.raw):
            if self.code[m.start():m.end()].strip():
                continue
            rest = re.sub(r"\s*(-->|\*/).*$", "", m.group(2))
            ids_part, _, reason = rest.partition("--")
            ids = {i.upper() for i in re.findall(r"\b(?:NG|BG)\d{3}\b", ids_part, re.I)}
            line = self.line_of(m.start())
            target = line + 1 if m.group(1) == "next-line" else line
            if not reason.strip():
                self.unreasoned += [(i, line) for i in sorted(ids)]
            elif m.group(1) == "file":
                self.ignored_file |= ids
            else:
                for i in ids:
                    self.ignored_lines.setdefault(i, set()).add(target)

    def unignored(self, rule_id, hits):
        if rule_id in self.ignored_file:
            return []
        lines = self.ignored_lines.get(rule_id, ())
        return [h for h in hits if self.line_of(h) not in lines]


PRE, POST = "pre", "post"
CHECKS = {}


def check(rule_id):
    """Register the matcher for a rule; its words and gate are in rules.py."""
    def register(fn):
        CHECKS[rule_id] = fn
        return fn
    return register


# ------------------------------------------------------------- pre: NG001-018

@check("NG001")
def check_ng001(c):
    if not c.ts:
        return []
    return find_all(r"standalone:\s*true", c.code)


@check("NG002")
def check_ng002(c):
    if not c.ts:
        return []
    return find_all(r"@NgModule", c.code)


@check("NG003")
def check_ng003(c):
    return find_all(r"\*ngIf|\*ngFor|\*ngSwitch|\[ngSwitch\]", c.code)


@check("NG004")
def check_ng004(c):
    if not c.ts:
        return []
    # Parameter properties are ordinary TypeScript in a plain value class
    # (`constructor(private amount: number)` on Money); they are only DI in a
    # class Angular manages, so an Angular class decorator must be present.
    if not re.search(r"@(Component|Directive|Injectable|Service|Pipe|NgModule)\b", c.code):
        return []
    # Known limitation: a default value with its own parens before the
    # injected param (`constructor(fn = () => 1, private http: HttpClient)`)
    # closes `[^)]*` early and is missed. A missed detection is recoverable
    # in review; a blocked correct write is not.
    return find_all(r"constructor\s*\([^)]*\b(private|public|protected|readonly)\s+"
                    r"[A-Za-z_$][A-Za-z0-9_$]*\s*:", c.code)


@check("NG005")
def check_ng005(c):
    if not c.ts:
        return []
    return find_all(r"@Input\s*\(|@Output\s*\(", c.code)


@check("NG006")
def check_ng006(c):
    if not c.ts:
        return []
    return find_all(r"changeDetection:\s*ChangeDetectionStrategy\.OnPush", c.code)


@check("NG007")
def check_ng007(c):
    if not c.ts:
        return []
    # `any` the TYPE, not the word inside a string literal.
    return find_all(r":\s*any\b|\bas\s+any\b|<any>", blank_strings(c.code))


@check("NG008")
def check_ng008(c):
    return find_all(r"\[ngClass\]|\[ngStyle\]|\sngClass=|\sngStyle=", c.code)


@check("NG009")
def check_ng009(c):
    if not c.ts:
        return []
    return find_all(r"@HostBinding|@HostListener", c.code)


@check("NG010")
def check_ng010(c):
    if not c.ts or c.spec:
        return []
    safe = ("takeUntilDestroyed", "takeUntil(", "take(", "first(", "firstValueFrom", "lastValueFrom")
    hits = []
    for m in re.finditer(r"\.subscribe\s*\(", c.code):
        chain = c.code[chain_start(c.code, m.start()):m.start()]
        if not any(s in chain for s in safe):
            hits.append(m.start())
    return hits


@check("NG011")
def check_ng011(c):
    if not c.ts:
        return []
    return find_all(r"\.mutate\s*\(", c.code)


@check("NG012")
def check_ng012(c):
    if not c.ts:
        return []
    src, hits = c.code, set()
    for m in re.finditer(r"\beffect\s*\(", src):
        start = m.end() - 1
        body = src[start:balanced_end(src, start)]
        # Writes lexically inside untracked(...) are excluded.
        untracked = [(u.start(), balanced_end(body, u.end() - 1))
                     for u in re.finditer(r"\buntracked\s*\(", body)]
        for sm in re.finditer(r"\.(set|update)\s*\(", body):
            if any(a <= sm.start() < b for a, b in untracked):
                continue
            # WritableSignal.set()/.update() take exactly one argument; a
            # two-argument .set() is a Map, HttpParams, URLSearchParams, ...
            if top_level_args(body, sm.end() - 1) >= 2:
                continue
            hits.add(start + sm.start())
    return sorted(hits)


@check("NG013")
def check_ng013(c):
    # The clause is extracted by balanced parens, not `[^)]*`: `@for (x of
    # xs(); track x.id)` calls a signal, and the first `)` closes `xs()`.
    hits = []
    for m in re.finditer(r"@for\s*\(", c.code):
        start = m.end() - 1
        if "track" not in c.code[start + 1:balanced_end(c.code, start) - 1]:
            hits.append(m.start())
    return hits


@check("NG014")
def check_ng014(c):
    return find_all(r"\[innerHTML\]|\[outerHTML\]", c.code)


@check("NG015")
def check_ng015(c):
    if not c.ts:
        return []
    return find_all(r"bypassSecurityTrust", c.code)


STRONG_SECRET_WORDS = {"password", "passwd", "pwd", "secret", "credential", "credentials"}
WEAK_SECRET_WORDS = {"key", "apikey", "token"}
SECRET_PREFIXES = ("sk_live_", "sk_test_", "rk_live_", "rk_test_", "sk-", "ghp_", "gho_",
                   "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-",
                   "xoxs-", "AKIA", "ASIA", "-----BEGIN")
PUBLIC_PREFIXES = ("AIza", "pk_live_", "pk_test_")


def looks_issued(v):
    if v.startswith(PUBLIC_PREFIXES):
        return False
    if v.startswith(SECRET_PREFIXES):
        return True
    if len(v) < 20 or " " in v or not re.search(r"\d", v) or not re.search(r"[A-Za-z]", v):
        return False
    entropy = -sum(k / len(v) * math.log2(k / len(v)) for k in Counter(v).values())
    return entropy >= 4.2


@check("NG016")
def check_ng016(c):
    if not c.ts or not re.search(r"/environments?/|environment(\.[a-z]+)*\.ts$", c.file_path):
        return []
    # The key's last word says what kind of value to expect (`dbPassword`,
    # `storageKey`; not `passwordPolicy`); the value decides. A password/
    # secret/credential key flags any non-empty literal; a key/token key only
    # a value that looks issued. URLs, lines that read process.env /
    # import.meta.env, and keys public by design (AIza..., pk_...) pass.
    pattern = re.compile(r'["\']?([A-Za-z_$][\w$-]*)["\']?\s*:\s*(["\'])([^"\']*)\2')
    url = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*://")
    hits, offset = [], 0
    for line in c.code.split("\n"):
        if "process.env" not in line and "import.meta.env" not in line:
            for m in pattern.finditer(line):
                words = re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", m.group(1))
                word, value = (words[-1].lower() if words else ""), m.group(3)
                if not value or url.match(value):
                    continue
                if word in STRONG_SECRET_WORDS or (word in WEAK_SECRET_WORDS and looks_issued(value)):
                    hits.append(offset + m.start())
        offset += len(line) + 1
    return hits


@check("NG017")
def check_ng017(c):
    return find_all(r"(import|require).*['\"]zone\.js", c.code)


@check("NG018")
def check_ng018(c):
    if not c.ts:
        return []
    return find_all(r"\bjasmine\s*\.", c.code)


# ------------------------------------------------------------ post: NG101-106

@check("NG101")
def check_ng101(c):
    if not c.ts or not re.search(r"routes?\.ts$|\.routes\.ts$|routing", c.file_path):
        return []
    return find_all(r"\bcomponent:\s*[A-Z]", c.code)


@check("NG102")
def check_ng102(c):
    if not c.ts or c.spec:
        return []
    return find_all(r"\bFormBuilder\b|\bnew\s+FormGroup\b|\bfb\.group\(", c.code)


@check("NG103")
def check_ng103(c):
    if not c.ts:
        return []
    return find_all(r"@Injectable\(\s*\{[^}]*providedIn:\s*['\"]root['\"]", c.code)


@check("NG104")
def check_ng104(c):
    # [^>]* spans the newlines Prettier puts inside a long <img> tag but can
    # never cross a `>` into a neighbouring tag. Inline data: URIs are
    # skipped — NgOptimizedImage does not support them.
    return find_all(r"<img[^>]*\ssrc=[\"'](?![Dd][Aa][Tt][Aa]:)", c.code)


@check("NG105")
def check_ng105(c):
    if not c.ts or c.spec or not c.component:
        return []
    # No preceding `.`: `this.document.body` is the injected DOCUMENT token.
    return [m.start(1) for m in re.finditer(r"(?:^|[^.$\w])((?:document|window)\.[a-zA-Z])",
                                            c.code, re.M)]


def quality_findings(src, basename):
    code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    code = re.sub(r"(^|[^:])//[^\n]*", r"\1", code)
    if ".component." not in basename and "@Component" not in code:
        return []
    findings = []
    if re.search(r"\bHttpClient\b", code):
        findings.append(
            "HTTP call inside a component. Move it into an injectable service and "
            "expose the result as a signal or httpResource; components should render, not fetch.")
    loc = len([l for l in code.splitlines() if l.strip()])
    if loc > 200:
        findings.append(
            "Component is %d lines. Past ~200 a component is usually doing several jobs — "
            "split out presentational children or move logic into a service." % loc)
    inputs = len(re.findall(r"=\s*input(?:\.required)?\s*[<(]", code))
    if inputs > 8:
        findings.append(
            "Component declares %d inputs. Past ~8, pass one object input or split the "
            "component." % inputs)
    return findings


@check("NG106")
def check_ng106(c):
    if not c.ts or c.spec or not c.component:
        return []
    return [0] if quality_findings(c.raw, os.path.basename(c.file_path)) else []


# ------------------------------------------------------------------- driver

def message_for(r, c):
    extra = None
    if r["id"] == "NG106":
        extra = quality_findings(c.raw, os.path.basename(c.file_path))
    return rules.message(r, extra=extra)


def run_rule(rule_id, fn, c):
    try:
        return c.unignored(rule_id, fn(c))
    except Exception:
        return []


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return None


def contents(mode, tool_input, file_path):
    """(before, after) for pre mode; (None, on-disk) for post mode."""
    on_disk = read(file_path)
    if mode == "post":
        return None, on_disk
    before = on_disk or ""
    if tool_input.get("content") is not None:
        return before, tool_input["content"]
    old = tool_input.get("old_string") or ""
    new = tool_input.get("new_string") or ""
    if old and old in before:
        count = -1 if tool_input.get("replace_all") else 1
        return before, before.replace(old, new, count)
    if new:
        # old_string not on disk (Claude Code validates it first, so this is
        # defensive): lint new_string appended rather than drop it.
        return before, before + "\n" + new
    return before, before


def lint(mode, payload):
    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path") or ""
    if not file_path or any(ch in file_path for ch in "\n\r\x00"):
        return []
    if file_path.rsplit(".", 1)[-1].lower() not in ("ts", "html"):
        return []
    _, profile = ag_profile.ensure(os.path.dirname(os.path.abspath(file_path)))
    if not profile:
        return []
    before, after = contents(mode, tool_input, file_path)
    if after is None:
        return []
    after_ctx = Ctx(file_path, after, profile)
    before_ctx = Ctx(file_path, before, profile) if before else None
    disabled = ag_profile.disabled_rules()
    reported = Reported(payload.get("session_id"), file_path) if mode == POST else None

    findings = []
    for r in rules.RULES:
        rule_id = r["id"]
        if r["hook"] != mode or rule_id in disabled or not rules.gate_open(r["gate"], profile):
            continue
        fn = CHECKS[rule_id]
        hits = run_rule(rule_id, fn, after_ctx)
        if reported:
            had = reported.swap(rule_id, len(hits))
        else:
            had = len(run_rule(rule_id, fn, before_ctx)) if hits and before_ctx else 0
        if len(hits) <= had:
            continue
        text = message_for(r, after_ctx)
        if had and reported:
            text += ("\n   ℹ️  %d of these were already reported for this file this session; "
                     "this change adds %d." % (had, len(hits) - had))
        elif had:
            text += ("\n   ℹ️  This file already had %d of these; this change adds %d. "
                     "Only the new ones block." % (had, len(hits) - had))
        for ignored_id, line in after_ctx.unreasoned:
            if ignored_id == rule_id:
                text += ("\n   ℹ️  The angular-guide-ignore comment for %s on line %d has no "
                         "`-- reason`, so it was not applied." % (rule_id, line))
        findings.append(text)
    if reported:
        reported.save()
    return findings


class Reported:
    """Advisory match counts already reported, per file, in this session.

    Post-write rules see only the file as written, so without this every
    edit to a file re-reports the same advisories. A rule is reported again
    only when its count for the file rises above what this session last saw
    (a fix followed by a re-add counts). No session_id means no memory.
    """

    KEEP_DAYS = 7

    def __init__(self, session_id, file_path):
        self.path, self.state = None, {}
        self.file = os.path.realpath(file_path)
        if not session_id:
            return
        folder = os.path.join(ag_profile.data_dir(), "advisories")
        key = hashlib.sha256(str(session_id).encode("utf-8")).hexdigest()[:16]
        self.path = os.path.join(folder, key + ".json")
        self.state = ag_profile.load_json(self.path, {})
        self.prune(folder)

    def __bool__(self):
        return self.path is not None

    def swap(self, rule_id, count):
        """Record the new count; return the previous one."""
        counts = self.state.setdefault(self.file, {})
        previous = counts.get(rule_id, 0)
        counts[rule_id] = count
        return previous

    def save(self):
        try:
            ag_profile.write_json_atomic(self.path, self.state)
        except Exception:
            pass

    def prune(self, folder):
        cutoff = time.time() - self.KEEP_DAYS * 86400
        try:
            for name in os.listdir(folder):
                p = os.path.join(folder, name)
                if os.path.getmtime(p) < cutoff:
                    os.remove(p)
        except Exception:
            pass


def main(argv):
    if len(argv) == 3 and argv[1] == "quality":
        src = read(argv[2])
        if src is not None:
            for f in quality_findings(src, os.path.basename(argv[2])):
                print(f)
        return 0
    if len(argv) != 2 or argv[1] not in (PRE, POST):
        return 0
    try:
        payload = json.loads(sys.stdin.read())
        findings = lint(argv[1], payload)
    except Exception:
        return 0
    if findings:
        sys.stdout.write("\n\n".join(findings))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
