#!/usr/bin/env bash
# analyze_quality.sh <file> — structural complexity analysis for NG106.
# Prints one finding per line to stdout. Always exits 0.
# Usable standalone: bash scripts/analyze_quality.sh src/app/foo.component.ts

set -u
FILE="${1:-}"
[ -n "$FILE" ] && [ -r "$FILE" ] || exit 0

python3 - "$FILE" <<'PY' 2>/dev/null
import re, sys, os

path = sys.argv[1]
try:
    src = open(path, encoding="utf-8", errors="ignore").read()
except Exception:
    sys.exit(0)

base = os.path.basename(path)
findings = []

code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
code = re.sub(r"(^|[^:])//[^\n]*", r"\1", code)

# component-ness is decided on the comment-stripped content, so a
# commented-out @Component decorator cannot trigger these findings.
is_component = ".component." in base or "@Component" in code

loc = len([l for l in code.splitlines() if l.strip()])

if is_component:
    if re.search(r"\bHttpClient\b", code):
        findings.append(
            "HTTP call inside a component. Move it into an injectable service and "
            "expose the result as a signal or httpResource; components should render, not fetch.")
    if loc > 200:
        findings.append(
            "Component is %d lines. Past ~200 a component is usually doing several jobs — "
            "split out presentational children or move logic into a service." % loc)
    inputs = len(re.findall(r"=\s*input(?:\.required)?\s*[<(]", code))
    if inputs > 8:
        findings.append(
            "Component declares %d inputs. Past ~8, pass one object input or split the "
            "component." % inputs)

for f in findings:
    print(f)
PY
exit 0
