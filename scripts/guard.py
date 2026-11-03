#!/usr/bin/env python3
"""guard.py — Bash rules for angular-guide (BG001-BG006).

Usage (stdin: the Claude Code hook payload): guard.py

Only runs inside an Angular workspace (a profile resolves from the
payload's cwd). The command line is parsed into simple commands with shlex
— separators split commands, quoted text stays one argument, wrappers
(sudo, env, npx, pnpm exec, ...) are peeled, `bash -c "..."` is parsed
recursively — and each rule inspects real argv lists. So text that merely
mentions a command (an echo, a commit message) never matches, and a flag
belonging to one command is never credited to another.

Findings go to stdout and the process exits 2; bash-guard.sh forwards them
to stderr. Every unexpected condition exits 0 with no output.
"""

import json
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ag_profile  # noqa: E402
import rules  # noqa: E402

SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
WRAPPERS = {"sudo", "time", "command", "nohup", "exec", "nice", "env", "builtin"}
SHELLS = {"bash", "sh", "zsh"}
LOCKFILES = {"package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"}
MANAGERS = ("npm", "pnpm", "yarn", "bun")


def simple_commands(text, depth=0):
    """Yield argv lists for each simple command in a shell command line."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    argv, skip_next = [], False
    for tok in list(lex) + [";"]:
        if skip_next:
            skip_next = False
            continue
        if tok in SEPARATORS:
            if argv:
                yield from expand(argv, depth)
            argv = []
        elif tok and set(tok) <= set("<>&"):
            skip_next = True  # a redirection and its target
        else:
            argv.append(tok)


def expand(argv, depth):
    argv = strip_wrappers(argv)
    if not argv:
        return
    if argv[0] in SHELLS and "-c" in argv and depth < 3:
        i = argv.index("-c")
        if i + 1 < len(argv):
            yield from simple_commands(argv[i + 1], depth + 1)
        return
    yield argv


def strip_wrappers(argv):
    i = 0
    while i < len(argv):
        a = argv[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            i += 1
        elif a in WRAPPERS:
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                i += 1
        else:
            break
    return argv[i:]


def as_ng(argv):
    """argv for the Angular CLI however it is launched, else None."""
    if argv[0] == "ng":
        return argv
    if argv[0] in ("npx", "bunx") and len(argv) > 1 and argv[1] in ("ng", "@angular/cli"):
        return ["ng"] + argv[2:]
    if argv[0] in ("pnpm", "yarn") and len(argv) > 1:
        rest = argv[2:] if argv[1] in ("exec", "dlx") else argv[1:]
        if rest and rest[0] in ("ng", "@angular/cli"):
            return ["ng"] + rest[1:]
    if argv[0] == "npm" and len(argv) > 2 and argv[1] in ("exec", "x"):
        rest = [a for a in argv[2:] if a != "--"]
        if rest and rest[0] in ("ng", "@angular/cli"):
            return ["ng"] + rest[1:]
    return None


def watch_disabled(args):
    for i, a in enumerate(args):
        if a in ("--no-watch", "--run", "--ci") or a.startswith(("--run=", "--ci=")):
            return True
        if a == "--watch=false" or (a == "--watch" and i + 1 < len(args) and args[i + 1] == "false"):
            return True
    return False


def current_branch(git_dir):
    try:
        out = subprocess.run(["git", "-C", git_dir, "symbolic-ref", "--short", "-q", "HEAD"],
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip()
    except Exception:
        return ""


class Guard:
    def __init__(self, cwd, profile):
        self.cwd = cwd
        self.profile = profile
        self.disabled = ag_profile.disabled_rules()
        self.findings = []

    def add(self, rule_id, **fmt):
        if rule_id in self.disabled:
            return
        r = rules.BY_ID[rule_id]
        text = rules.message(r, title=r["title"].format(**fmt) if fmt else None)
        if text not in self.findings:
            self.findings.append(text)

    def check(self, argv):
        if argv[0] == "git":
            self.check_git_push(argv)
        ng = as_ng(argv)
        if ng:
            self.check_ng(ng)
        self.check_pm_test(argv)
        self.check_pm_mismatch(argv)
        self.check_rm(argv)

    def check_git_push(self, argv):
        # BG001 — force push to the default branch
        git_dir, i = self.cwd, 1
        while i < len(argv) and argv[i].startswith("-"):
            if argv[i] in ("-C", "-c") and i + 1 < len(argv):
                if argv[i] == "-C":
                    git_dir = os.path.join(self.cwd, argv[i + 1])
                i += 2
            else:
                i += 1
        if i >= len(argv) or argv[i] != "push":
            return
        force, positional = False, []
        rest = argv[i + 1:]
        k = 0
        while k < len(rest):
            a = rest[k]
            if a in ("--force", "-f") or re.match(r"^-[A-Za-z]*f[A-Za-z]*$", a):
                force = True
            elif a in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
                k += 1
            elif not a.startswith("-"):
                positional.append(a)
            k += 1
        refspecs = positional[1:]
        targets = []
        for r in refspecs:
            forced = force or r.startswith("+")
            r = r.lstrip("+")
            dst = r.split(":", 1)[1] if ":" in r else r
            if dst == "HEAD":
                dst = current_branch(git_dir)
            if dst.startswith("refs/heads/"):
                dst = dst[len("refs/heads/"):]
            if forced:
                targets.append(dst)
        if not refspecs and force:
            targets.append(current_branch(git_dir))
        if any(t in ("main", "master") for t in targets):
            self.add("BG001")

    def check_ng(self, ng):
        sub, args = (ng[1] if len(ng) > 1 else ""), ng[2:]
        # BG002 — ng build --prod (flag removed in Angular 12)
        if sub == "build" and any(a == "--prod" or a.startswith("--prod=") for a in args):
            self.add("BG002")
        # BG004 — ng test without --watch=false hangs an agent session
        if sub in ("test", "t") and not watch_disabled(args):
            self.add("BG004")
        # BG006 — ng update --force skips the checks that make updating safe
        if sub == "update" and "--force" in args:
            self.add("BG006")

    def test_script(self):
        try:
            with open(os.path.join(self.profile["workspace_root"], "package.json")) as f:
                return (json.load(f).get("scripts") or {}).get("test") or ""
        except Exception:
            return ""

    def check_pm_test(self, argv):
        # BG004 — `npm test` / `pnpm test` / `yarn test` whose script runs `ng test`
        if argv[0] not in MANAGERS or len(argv) < 2:
            return
        if argv[1] in ("test", "t") and argv[0] != "bun":
            extra = argv[2:]
        elif argv[1] == "run" and len(argv) > 2 and argv[2] == "test":
            extra = argv[3:]
        else:
            return
        script = self.test_script()
        ng = next((as_ng(c) for c in simple_commands(script) if as_ng(c)), None)
        if not ng or ng[1:2] not in (["test"], ["t"]) or watch_disabled(ng):
            return
        passthrough = extra[extra.index("--") + 1:] if "--" in extra else \
            ([] if argv[0] == "npm" else extra)
        if not watch_disabled(passthrough):
            self.add("BG004")

    def check_pm_mismatch(self, argv):
        # BG003 — package manager mismatching the lockfile
        pm = self.profile.get("package_manager") or ""
        if (pm and argv[0] in MANAGERS and argv[0] != pm and len(argv) > 1
                and argv[1] in ("install", "i", "add", "ci")):
            self.add("BG003", used=argv[0], pm=pm)

    def check_rm(self, argv):
        # BG005 — deleting the lockfile
        if argv[0] == "rm" and any(os.path.basename(a) in LOCKFILES for a in argv[1:]):
            self.add("BG005")


def main():
    try:
        payload = json.loads(sys.stdin.read())
        cmd = (payload.get("tool_input") or {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
        _, profile = ag_profile.ensure(cwd)
        if not cmd or not profile:
            return 0
        guard = Guard(cwd, profile)
        for argv in simple_commands(cmd):
            guard.check(argv)
    except Exception:
        return 0
    if guard.findings:
        sys.stdout.write("\n\n".join(guard.findings))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
