#!/usr/bin/env bash
# subagent-rules.sh — SubagentStart hook. Subagents inherit no skills, so the
# condensed rule set is injected directly. Mirrors skills/angular-essentials.
#
# Claude Code only injects SubagentStart output that arrives as JSON
# (hookSpecificOutput.additionalContext); plain stdout goes to the debug log.
#
# Only runs inside an Angular workspace (a cached profile exists up the tree
# from the payload's cwd), and includes only the rules whose gates the
# profile turns on — the same gates hook-lint.sh applies. Always exits 0.

set -u

INPUT=$(cat)

python3 - "$INPUT" <<'PY' 2>/dev/null
import json, os, sys

try:
    payload = json.loads(sys.argv[1])
    start = payload.get("cwd") or os.getcwd()
except Exception:
    sys.exit(0)

def find_profile(d):
    d = os.path.abspath(d)
    while True:
        p = os.path.join(d, ".angular-guide-project.json")
        if os.path.isfile(p):
            return p
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent

try:
    path = find_profile(start)
    if not path:
        sys.exit(0)
    profile = json.load(open(path))
except Exception:
    sys.exit(0)

v20 = profile.get("standalone_default") is True
v22 = profile.get("onpush_default") is True
zoneless = profile.get("zoneless") is True
vitest = profile.get("test_runner") == "vitest"
version = profile.get("angular_version", "unknown")

# (include?, line) per section, in display order. Gates match hook-lint.sh.
sections = [
    ("Components and templates", [
        (v20, "- NG001 Never write `standalone: true` — standalone is the default since v20."),
        (v20, "- NG002 Never create an `@NgModule`. Use standalone components."),
        (v20, "- NG003 Use `@if` / `@for` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch`."),
        (v20, "- NG005 Use the `input()` / `output()` / `model()` functions, never the `@Input()` / `@Output()` decorators."),
        (v22, "- NG006 Never set `changeDetection: ChangeDetectionStrategy.OnPush` — it is the default in v22."),
        (True, "- NG008 Use `[class.x]` and `[style.x]` bindings, never `ngClass` / `ngStyle`."),
        (True, "- NG009 Use the `host` object in the decorator, never `@HostBinding` / `@HostListener`."),
        (v20, "- NG013 Every `@for` needs a `track` expression."),
    ]),
    ("Dependency injection and services", [
        (v20, "- NG004 Use `inject()`, never constructor-parameter injection."),
    ]),
    ("Reactivity", [
        (True, "- NG011 Signals have no `mutate()`. Use `set()` or `update()`."),
        (True, "- NG012 Never write a signal from inside `effect()`. Derived state is `computed()`;\n"
               "  writable state derived from other signals is `linkedSignal()`."),
        (True, "- NG010 Never call `.subscribe()` without teardown (`takeUntilDestroyed()`). Prefer the\n"
               "  `async` pipe, `toSignal()`, or `httpResource()`; for a one-shot HTTP command,\n"
               "  `await firstValueFrom(...)`."),
    ]),
    ("TypeScript", [
        (True, "- NG007 Never use `any`. Use `unknown` and narrow it."),
    ]),
    ("Security", [
        (True, "- NG014 Never bind `[innerHTML]`."),
        (True, "- NG015 Never call `bypassSecurityTrust*`."),
        (True, "- NG016 Never put secrets in `environment*.ts`."),
    ]),
    ("Workspace-specific", [
        (zoneless, "- NG017 Never import `zone.js` — this workspace is zoneless, and zone.js\n"
                   "  re-introduces the monkey-patching that zoneless exists to remove."),
        (vitest, "- NG018 Never use Jasmine APIs — this workspace runs Vitest. Use `vi.fn()` /\n"
                 "  `vi.spyOn()`; TestBed itself is unchanged."),
    ]),
]

out = [
    "## angular-guide — Rules for Subagents",
    "",
    "You are working in an Angular %s workspace. These are enforced by hooks;" % version,
    "violating them blocks your write.",
]
for title, rules in sections:
    lines = [line for include, line in rules if include]
    if lines:
        out += ["", "### " + title] + lines
out += [
    "",
    "Keep components presentational: HTTP calls, state orchestration, and validation",
    "belong in services, not components.",
]

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": "\n".join(out),
}}))
PY
exit 0
