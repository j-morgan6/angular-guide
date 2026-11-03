#!/usr/bin/env bash
# bash-guard.sh — Bash PreToolUse hook for angular-guide (BG001-BG006).
# Findings go to stderr; exit 2 blocks the command. Fails open on any error.
#
# Only runs inside an Angular workspace (a profile resolves from the
# payload's cwd). The command line is parsed into simple commands with shlex
# — separators split commands, quoted text stays one argument, wrappers
# (sudo, env, npx, pnpm exec, ...) are peeled, `bash -c "..."` is parsed
# recursively — and each rule inspects real argv lists. So text that merely
# mentions a command (an echo, a commit message) never matches, and a flag
# belonging to one command is never credited to another.

set -u

INPUT=$(cat)

# Findings come back on stdout (Python's stderr is discarded so a crash stays
# silent) and are forwarded to stderr, where Claude Code shows them on exit 2.
FINDINGS=$(python3 -I -B - "$INPUT" "$(dirname "$0")" <<'PY' 2>/dev/null
import json, os, re, shlex, subprocess, sys

try:
    payload = json.loads(sys.argv[1])
    cmd = (payload.get("tool_input") or {}).get("command") or ""
    cwd = payload.get("cwd") or os.getcwd()
    sys.path.insert(0, sys.argv[2])
    import ag_profile
    _, profile = ag_profile.ensure(cwd)
except Exception:
    sys.exit(0)
if not cmd or not profile:
    sys.exit(0)

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
        elif set(tok) <= set("<>&") and tok:
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


findings = []
def add(msg):
    if msg not in findings:
        findings.append(msg)


def check_git_push(argv):
    # BG001 — force push to the default branch
    git_dir, i = cwd, 1
    while i < len(argv) and argv[i].startswith("-"):
        if argv[i] in ("-C", "-c") and i + 1 < len(argv):
            if argv[i] == "-C":
                git_dir = os.path.join(cwd, argv[i + 1])
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
        if a in ("--force", "-f"):
            force = True
        elif re.match(r"^-[A-Za-z]*f[A-Za-z]*$", a):
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
        add("🚫 BG001: Force push to the default branch rewrites shared history.\n"
            "   💡 Fix: Use --force-with-lease, and push to a feature branch instead.")


def check_ng(ng):
    sub, args = (ng[1] if len(ng) > 1 else ""), ng[2:]
    # BG002 — ng build --prod (flag removed in Angular 12)
    if sub == "build" and any(a == "--prod" or a.startswith("--prod=") for a in args):
        add("🚫 BG002: `ng build --prod` — the flag was removed in Angular 12.\n"
            "   💡 Fix: Run `ng build`. Production is the default configuration.")
    # BG004 — ng test without --watch=false hangs an agent session
    if sub in ("test", "t") and not watch_disabled(args):
        add("🚫 BG004: `ng test` runs in watch mode by default and will hang this session.\n"
            "   💡 Fix: Run `ng test --watch=false` (Karma) or `ng test --run` (Vitest).")
    # BG006 — ng update --force skips the checks that make updating safe
    if sub == "update" and "--force" in args:
        add("🚫 BG006: `ng update --force` bypasses peer-dependency and migration checks.\n"
            "   💡 Fix: Resolve the reported incompatibilities, or update one package at a time. "
            "Run `ng update` without --force first to see what it objects to.")


def test_script():
    try:
        pkg = json.load(open(os.path.join(profile["workspace_root"], "package.json")))
        return (pkg.get("scripts") or {}).get("test") or ""
    except Exception:
        return ""


def check_pm_test(argv):
    # BG004 — `npm test` / `pnpm test` / `yarn test` whose script runs `ng test`
    if argv[0] not in MANAGERS or len(argv) < 2:
        return
    if argv[1] in ("test", "t") and argv[0] != "bun":
        extra = argv[2:]
    elif argv[1] == "run" and len(argv) > 2 and argv[2] == "test":
        extra = argv[3:]
    else:
        return
    script = test_script()
    ng = next((c for c in simple_commands(script) if as_ng(c)), None)
    if not ng or as_ng(ng)[1:2] not in (["test"], ["t"]) or watch_disabled(ng):
        return
    passthrough = extra[extra.index("--") + 1:] if "--" in extra else \
        ([] if argv[0] == "npm" else extra)
    if not watch_disabled(passthrough):
        add("🚫 BG004: `%s` runs `%s` in watch mode and will hang this session.\n"
            "   💡 Fix: Pass the flag through: `%s test -- --watch=false` (Karma) or "
            "`%s test -- --run` (Vitest)." % (" ".join(argv[:3] if argv[1] == "run" else argv[:2]),
                                            script, argv[0], argv[0]))


def check_pm_mismatch(argv):
    # BG003 — package manager mismatching the lockfile
    pm = profile.get("package_manager") or ""
    if (pm and argv[0] in MANAGERS and argv[0] != pm and len(argv) > 1
            and argv[1] in ("install", "i", "add", "ci")):
        add("🚫 BG003: `%s` invoked but this workspace uses `%s` (per its lockfile).\n"
            "   💡 Fix: Use `%s` — mixing package managers produces a second lockfile and "
            "divergent dependency trees." % (argv[0], pm, pm))


def check_rm(argv):
    # BG005 — deleting the lockfile
    if argv[0] == "rm" and any(os.path.basename(a) in LOCKFILES for a in argv[1:]):
        add("🚫 BG005: Deleting the lockfile discards every pinned transitive version.\n"
            "   💡 Fix: Delete node_modules alone and reinstall. Only remove the lockfile "
            "when deliberately re-resolving the whole dependency tree.")


try:
    for argv in simple_commands(cmd):
        if argv[0] == "git":
            check_git_push(argv)
        ng = as_ng(argv)
        if ng:
            check_ng(ng)
        check_pm_test(argv)
        check_pm_mismatch(argv)
        check_rm(argv)
except Exception:
    sys.exit(0)

if findings:
    sys.stdout.write("\n\n".join(findings))
    sys.exit(2)
PY
)
if [ $? -eq 2 ] && [ -n "$FINDINGS" ]; then
  printf '%s\n\n' "$FINDINGS" >&2
  exit 2
fi
exit 0
