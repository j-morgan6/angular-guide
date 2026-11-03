#!/usr/bin/env bash
# subagent-rules.sh — SubagentStart hook. Subagents inherit no skills, so the
# condensed blocking rule set is injected directly, rendered from rules.py.
#
# Claude Code only injects SubagentStart output that arrives as JSON
# (hookSpecificOutput.additionalContext); plain stdout goes to the debug log.
#
# Only runs inside an Angular workspace (a profile resolves from the
# payload's cwd), and includes only the rules whose gates the profile turns
# on and that are not disabled — the same filter lint.py applies. Always
# exits 0.

set -u

INPUT=$(cat)

python3 -I -B - "$INPUT" "$(dirname "$0")" <<'PY' 2>/dev/null
import json, os, sys

try:
    payload = json.loads(sys.argv[1])
    start = payload.get("cwd") or os.getcwd()
    sys.path.insert(0, sys.argv[2])
    import ag_profile, rules
    _, profile = ag_profile.ensure(start)
except Exception:
    sys.exit(0)
if not profile:
    sys.exit(0)

disabled = ag_profile.disabled_rules()
active = [r for r in rules.RULES if r["hook"] == "pre" and r["id"] not in disabled
          and rules.gate_open(r["gate"], profile)]

out = [
    "## angular-guide — Rules for Subagents",
    "",
    "You are working in an Angular %s workspace. These are enforced by hooks;"
    % profile.get("angular_version", "unknown"),
    "violating them blocks your write.",
]
for section in rules.SECTIONS:
    lines = ["- %s %s" % (r["id"], r["rule"]) for r in active if r["section"] == section]
    if lines:
        out += ["", "### " + section] + lines
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
