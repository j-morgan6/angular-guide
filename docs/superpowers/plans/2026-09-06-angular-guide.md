# angular-guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that deterministically enforces modern Angular (v20+, signals-first, zoneless) through 32 version-aware hook rules, backed by 9 judgment-layer skills.

**Architecture:** Thin skill layer over a thick enforcement layer. Hook logic lives in four testable shell scripts wired through native plugin hooks (`hooks/hooks.json` + `${CLAUDE_PLUGIN_ROOT}`) — never inline bash in JSON. A `SessionStart` detector writes a workspace profile that every downstream rule consults, so v21 projects never receive v22 advice. Angular's own official skills and MCP server remain the reference layer and are not vendored.

**Tech Stack:** Bash (POSIX-ish, bash 3.2 compatible for macOS), Python 3 for JSON parsing only (stdlib, no dependencies), Markdown for skills and agents.

**Spec:** `docs/superpowers/specs/2026-09-06-angular-guide-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Angular floor: v20.** Do not add support for v19 or below.
- **No `jq` dependency.** JSON is parsed with `python3` (stdlib) or `grep`/`sed`.
- **No `install.sh`, no writes to `~/.claude/settings.json`.** Hooks are delivered natively via `hooks/hooks.json` using `${CLAUDE_PLUGIN_ROOT}`.
- **All hook feedback goes to stderr.** Stdout is reserved for structured JSON hook output. Exit 2 = finding; exit 0 = pass.
- **Fail open, always.** Any unexpected script condition (missing cache, unparseable JSON, unreadable file, absent `angular.json`) exits 0. A plugin defect must never wedge a session or block a legitimate write.
- **Never guess a version.** When `angular_major` is unknown, every version-gated rule is skipped, not assumed.
- **Do not vendor Angular's official skills.** Skills link outward to angular.dev and to `angular/angular` `skills/dev-skills/`; they never restate reference documentation.
- **Rule IDs are stable and permanent.** `BG001`–`BG006`, `NG001`–`NG018`, `NG101`–`NG106`. Every finding message begins with its ID. IDs are the contract between hook-lint.sh, the skills, the README, and the tests.
- **Finding message format:** `<emoji> <ID>: <what was found>` then a `   💡 Fix: <what to do instead>` line, then optionally `   See: <skill-name> skill`. Blocking findings use 🚫, advisory use ⚠️.
- **Bash 3.2 compatible.** macOS ships bash 3.2; no associative arrays, no `${var,,}`.
- Author metadata: `Joseph Morgan`, `https://github.com/j-morgan6`, MIT, repo `github.com/j-morgan6/angular-guide`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `.claude-plugin/plugin.json` | Plugin identity + version |
| `.claude-plugin/marketplace.json` | Self-hosted marketplace entry |
| `hooks/hooks.json` | Native hook wiring, `${CLAUDE_PLUGIN_ROOT}` paths only |
| `scripts/detect_project.sh` | SessionStart. Parses workspace → `.angular-guide-project.json` |
| `scripts/hook-lint.sh` | Write/Edit rules. `pre` = blocking NG001–NG018, `post` = advisory NG101–NG106 |
| `scripts/bash-guard.sh` | Bash PreToolUse. BG001–BG006 |
| `scripts/analyze_quality.sh` | Complexity analysis, called by `hook-lint.sh post` for NG106 |
| `scripts/subagent-rules.sh` | SubagentStart. Emits condensed rules to stdout |
| `skills/<name>/SKILL.md` | 9 judgment-layer skills |
| `agents/<name>.md` | 3 read-only review agents |
| `tests/run-tests.sh` | Whole suite: fixtures in, exit code + stderr substring asserted |
| `README.md`, `CLAUDE.md.template`, `CHANGELOG.md`, `VERSION`, `LICENSE` | Docs and metadata |

Scripts are split by hook event, because that is the boundary along which they change and along which they are invoked. `analyze_quality.sh` is separate from `hook-lint.sh` because it is the only component that parses structure rather than matching patterns, and it is the only one a user may want to run standalone.

---

### Task 1: Repo skeleton, manifests, and test harness

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `VERSION`
- Create: `LICENSE`
- Create: `tests/run-tests.sh`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: the test harness helpers every later task uses —
  `run <stdin-json> <cmd...>` sets `$OUT` `$ERR` `$CODE`;
  `expect <name> <exit> <err|out|none> <substring>`;
  `write_json <path> <content>`, `edit_json <path> <old> <new>`, `bash_json <command>`;
  counters `$PASS` `$FAIL`; `$TMPROOT` scratch dir.
  Constant `VERSION_STRING="1.0.0"` written identically to `VERSION`, `plugin.json`, `marketplace.json`.

- [ ] **Step 1: Write the failing test**

Create `tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Test suite for angular-guide.
# Run: bash tests/run-tests.sh
#
# Contract under test:
#   - All hook feedback goes to STDERR (Claude Code feeds stderr to the model
#     on exit 2; stdout is reserved for JSON hook output).
#   - Every script fails open: unexpected conditions exit 0, never non-zero.
#   - Version-gated rules are SKIPPED when the version is unknown, never guessed.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$ROOT/scripts/detect_project.sh"
HOOK_LINT="$ROOT/scripts/hook-lint.sh"
BASH_GUARD="$ROOT/scripts/bash-guard.sh"
SUBAGENT="$ROOT/scripts/subagent-rules.sh"

PASS=0
FAIL=0
# Initialized so a check() called before any run() (the manifest checks below
# are) cannot trip `set -u` and abort the suite on its first failure.
CODE=""
OUT=""
ERR=""
FAILED_NAMES=()

# run <stdin-json> <cmd...>  — captures OUT, ERR, CODE
run() {
  local stdin_data="$1"; shift
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  printf '%s' "$stdin_data" | "$@" >"$out_f" 2>"$err_f"
  CODE=$?
  OUT=$(cat "$out_f"); ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

check() { # <name> <condition-description> <pass:0/1>
  local name="$1" desc="$2" ok="$3"
  if [ "$ok" = "0" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name: $desc")
    echo "FAIL $name — $desc"
    echo "     exit=$CODE"
    echo "     stdout: $(printf '%s' "$OUT" | head -3)"
    echo "     stderr: $(printf '%s' "$ERR" | head -3)"
  fi
}

expect() { # <name> <expected-exit> <stream:err|out|none> <substring-or-empty>
  local name="$1" want_code="$2" stream="$3" substr="${4:-}"
  local ok=0
  [ "$CODE" = "$want_code" ] || ok=1
  case "$stream" in
    err)  printf '%s' "$ERR" | grep -qF "$substr" || ok=1 ;;
    out)  printf '%s' "$OUT" | grep -qF "$substr" || ok=1 ;;
    none) [ -z "$OUT$ERR" ] || ok=1 ;;
  esac
  check "$name" "want exit=$want_code ${stream}~'$substr'" "$ok"
}

# JSON helpers — build the tool-input payloads Claude Code sends to hooks
write_json() { # file_path content
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}
edit_json() { # file_path old new
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"
}
bash_json() { # command
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# ng_workspace <dir> <angular-version> [extra-devdeps-json]
# Creates a minimal Angular workspace for detection/gating fixtures.
ng_workspace() {
  local dir="$1" ver="$2" extra="${3:-}"
  mkdir -p "$dir"
  printf '{"version":1,"projects":{"app":{"projectType":"application","root":""}}}\n' > "$dir/angular.json"
  python3 -c '
import json,sys
dev = {"@angular/cli": "^"+sys.argv[2]}
if sys.argv[3]:
    dev.update(json.loads(sys.argv[3]))
json.dump({"name":"fixture","dependencies":{"@angular/core":"^"+sys.argv[2]},"devDependencies":dev},
          open(sys.argv[1]+"/package.json","w"))
' "$dir" "$ver" "$extra"
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

###############################################################################
echo "== manifests =="
###############################################################################

VERSION_FILE=$(cat "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')

M1_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || M1_OK=1
check M1-plugin-json-parses "plugin.json is valid JSON" "$M1_OK"

M2_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null || M2_OK=1
check M2-marketplace-json-parses "marketplace.json is valid JSON" "$M2_OK"

M3_OK=0
PJ_VER=$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/.claude-plugin/plugin.json"))["version"])' 2>/dev/null)
MP_VER=$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/.claude-plugin/marketplace.json"))["plugins"][0]["version"])' 2>/dev/null)
[ -n "$VERSION_FILE" ] && [ "$PJ_VER" = "$VERSION_FILE" ] && [ "$MP_VER" = "$VERSION_FILE" ] || M3_OK=1
check M3-versions-agree "VERSION == plugin.json == marketplace.json (got '$VERSION_FILE'/'$PJ_VER'/'$MP_VER')" "$M3_OK"

M4_OK=0
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["name"]=="angular-guide", d["name"]
assert d["license"]=="MIT"
assert "angular" in d["keywords"]
' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || M4_OK=1
check M4-plugin-identity "name=angular-guide, MIT, keywords include angular" "$M4_OK"

###############################################################################
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED_NAMES[@]}"; exit 1; }
exit 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: FAIL on M1–M4 — `.claude-plugin/plugin.json` does not exist yet, so the JSON parse and version comparisons fail.

- [ ] **Step 3: Write minimal implementation**

`VERSION`:
```
1.0.0
```

`.claude-plugin/plugin.json`:
```json
{
  "name": "angular-guide",
  "version": "1.0.0",
  "description": "Enforce modern Angular (v20+, signals-first, zoneless) with deterministic hooks. Complements Angular's official agent skills and MCP server.",
  "author": {
    "name": "Joseph Morgan",
    "url": "https://github.com/j-morgan6"
  },
  "homepage": "https://github.com/j-morgan6/angular-guide",
  "repository": "https://github.com/j-morgan6/angular-guide",
  "license": "MIT",
  "keywords": ["angular", "signals", "zoneless", "typescript", "best-practices"]
}
```

`.claude-plugin/marketplace.json`:
```json
{
  "name": "angular-guide",
  "owner": {
    "name": "Joseph Morgan",
    "url": "https://github.com/j-morgan6"
  },
  "plugins": [
    {
      "name": "angular-guide",
      "source": "./",
      "description": "Enforce modern Angular (v20+, signals-first, zoneless) with deterministic hooks. Complements Angular's official agent skills and MCP server.",
      "version": "1.0.0"
    }
  ]
}
```

`LICENSE`: standard MIT text, `Copyright (c) 2026 Joseph Morgan`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 4 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin VERSION LICENSE tests/run-tests.sh
git commit -m "feat: plugin manifests and test harness"
```

---

### Task 2: `detect_project.sh` — workspace profile

**Files:**
- Create: `scripts/detect_project.sh`
- Modify: `tests/run-tests.sh` (append the detection section before the Results block)

**Interfaces:**
- Consumes: `ng_workspace`, `run`, `check` from Task 1.
- Produces: `.angular-guide-project.json` at the workspace root. Every later script reads it. Exact key set:
  `plugin_version`, `detected_at`, `workspace_root`, `angular_version`, `angular_major`,
  `standalone_default`, `onpush_default`, `signal_forms_available`, `service_decorator_available`,
  `zoneless`, `test_runner`, `ssr`, `state_lib`, `package_manager`, `typescript_strict`, `projects`.
  `angular_major` is an integer or the string `"unknown"`. Booleans are JSON `true`/`false`.
  `test_runner` ∈ `vitest|karma|jest|none`. `state_lib` ∈ `ngrx-signals|ngrx|ngxs|akita|none`.
  `package_manager` ∈ `pnpm|yarn|npm|bun`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh`, immediately before the `echo "Results:"` block:

```bash
###############################################################################
echo
echo "== detect_project.sh =="
###############################################################################

# D1: v22 workspace — all v22 gates on
WORK="$TMPROOT/d1"; ng_workspace "$WORK" "22.0.1"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D1_OK=0
grep -q '"angular_major": 22' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"onpush_default": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"signal_forms_available": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"service_decorator_available": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
check D1-v22-gates "v22 workspace sets all v22 gates true" "$D1_OK"

# D2: v21 workspace — onpush/signal-forms/@Service OFF, standalone ON
WORK="$TMPROOT/d2"; ng_workspace "$WORK" "21.2.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D2_OK=0
grep -q '"angular_major": 21' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"onpush_default": false' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"signal_forms_available": false' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D2_OK=1
check D2-v21-gates "v21 leaves v22-only gates false, standalone true" "$D2_OK"

# D3: v20 workspace
WORK="$TMPROOT/d3"; ng_workspace "$WORK" "20.0.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D3_OK=0
grep -q '"angular_major": 20' .angular-guide-project.json 2>/dev/null || D3_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D3_OK=1
check D3-v20-gates "v20 sets standalone_default true" "$D3_OK"

# D4: not an Angular workspace — exit 0, no cache, no output
WORK="$TMPROOT/d4"; mkdir -p "$WORK"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D4_OK=0
[ "$CODE" = "0" ] || D4_OK=1
[ ! -f .angular-guide-project.json ] || D4_OK=1
check D4-non-angular-inert "no angular.json → exit 0, no cache written" "$D4_OK"

# D5: zone.js present → zoneless false; absent → zoneless true
WORK="$TMPROOT/d5"; ng_workspace "$WORK" "22.0.0" '{"zone.js":"~0.15.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D5_OK=0
grep -q '"zoneless": false' .angular-guide-project.json 2>/dev/null || D5_OK=1
check D5-zonejs-present "zone.js dependency → zoneless false" "$D5_OK"

WORK="$TMPROOT/d5b"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D5B_OK=0
grep -q '"zoneless": true' .angular-guide-project.json 2>/dev/null || D5B_OK=1
check D5b-zonejs-absent "no zone.js → zoneless true" "$D5B_OK"

# D6: test runner detection
WORK="$TMPROOT/d6"; ng_workspace "$WORK" "22.0.0" '{"vitest":"^3.0.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D6_OK=0
grep -q '"test_runner": "vitest"' .angular-guide-project.json 2>/dev/null || D6_OK=1
check D6-vitest "vitest devDependency detected" "$D6_OK"

WORK="$TMPROOT/d6b"; ng_workspace "$WORK" "21.0.0" '{"karma":"~6.4.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D6B_OK=0
grep -q '"test_runner": "karma"' .angular-guide-project.json 2>/dev/null || D6B_OK=1
check D6b-karma "karma devDependency detected" "$D6B_OK"

# D7: unknown version → gates must be false, never guessed
WORK="$TMPROOT/d7"; mkdir -p "$WORK"; cd "$WORK" || exit 1
printf '{"version":1,"projects":{}}\n' > angular.json
printf '{"name":"x","dependencies":{}}\n' > package.json
run "" bash "$DETECT"
D7_OK=0
grep -q '"angular_major": "unknown"' .angular-guide-project.json 2>/dev/null || D7_OK=1
grep -q '"onpush_default": false' .angular-guide-project.json 2>/dev/null || D7_OK=1
grep -q '"standalone_default": false' .angular-guide-project.json 2>/dev/null || D7_OK=1
check D7-unknown-version "unknown version → every gate false, never guessed" "$D7_OK"

# D8: package manager from lockfile
WORK="$TMPROOT/d8"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
touch pnpm-lock.yaml
run "" bash "$DETECT"
D8_OK=0
grep -q '"package_manager": "pnpm"' .angular-guide-project.json 2>/dev/null || D8_OK=1
check D8-pnpm-lockfile "pnpm-lock.yaml → package_manager pnpm" "$D8_OK"

# D9: detection runs from a nested subdirectory and finds the workspace root
WORK="$TMPROOT/d9"; ng_workspace "$WORK" "22.0.0"
mkdir -p "$WORK/src/app/feature"; cd "$WORK/src/app/feature" || exit 1
run "" bash "$DETECT"
D9_OK=0
[ -f "$WORK/.angular-guide-project.json" ] || D9_OK=1
check D9-walks-up "runs from nested dir, writes cache at workspace root" "$D9_OK"

# D10: announces to stdout for session context
D10_OK=0
printf '%s' "$OUT" | grep -q "Angular" || D10_OK=1
check D10-announces "emits a summary on stdout" "$D10_OK"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: D1–D10 FAIL — `scripts/detect_project.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/detect_project.sh`:

```bash
#!/usr/bin/env bash
# detect_project.sh — SessionStart hook for angular-guide.
# Walks up for angular.json, parses the workspace, and writes
# .angular-guide-project.json at the workspace root. Every version-gated rule
# in hook-lint.sh reads that file.
#
# Fails open: no angular.json, or anything unexpected, exits 0 silently.
# Never guesses a version — unknown means every gate stays false.

set -u

PLUGIN_VERSION="1.0.0"

find_workspace_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/angular.json" ]; then echo "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ROOT=$(find_workspace_root 2>/dev/null) || exit 0
[ -f "$ROOT/package.json" ] || exit 0

CACHE="$ROOT/.angular-guide-project.json"

python3 - "$ROOT" "$CACHE" "$PLUGIN_VERSION" <<'PY' 2>/dev/null || exit 0
import json, os, re, sys, datetime

root, cache, plugin_version = sys.argv[1], sys.argv[2], sys.argv[3]

def load(p, default):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return default

pkg = load(os.path.join(root, "package.json"), {})
ng  = load(os.path.join(root, "angular.json"), {})

deps = {}
deps.update(pkg.get("dependencies") or {})
deps.update(pkg.get("devDependencies") or {})

def major_of(spec):
    m = re.search(r"(\d+)", str(spec or ""))
    return int(m.group(1)) if m else None

# Version: package.json range first, then the lockfile's resolved version.
version_spec = deps.get("@angular/core") or deps.get("@angular/cli") or ""
major = major_of(version_spec)
version = str(version_spec).lstrip("^~>=< ") or "unknown"

if major is None:
    for lf in ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock"):
        p = os.path.join(root, lf)
        if not os.path.exists(p):
            continue
        try:
            txt = open(p, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        m = re.search(r'@angular/core["\'@:\s/]+(\d+)\.\d+\.\d+', txt)
        if m:
            major = int(m.group(1))
            version = m.group(0).split("core")[-1].strip("\"'@:/ ")
            break

known = major is not None

def dep(*names):
    return any(n in deps for n in names)

# --- gates: false whenever the version is unknown, never guessed
standalone_default          = bool(known and major >= 20)
onpush_default              = bool(known and major >= 22)
signal_forms_available      = bool(known and major >= 22)
service_decorator_available = bool(known and major >= 22)

# --- zoneless: explicit provider wins, else absence of the zone.js dependency
zoneless = not dep("zone.js")
for dirpath, dirnames, filenames in os.walk(os.path.join(root, "src")):
    dirnames[:] = [d for d in dirnames if d != "node_modules"]
    for fn in filenames:
        if not fn.endswith(".ts"):
            continue
        try:
            if "provideZonelessChangeDetection" in open(
                os.path.join(dirpath, fn), encoding="utf-8", errors="ignore"
            ).read():
                zoneless = True
        except Exception:
            pass

test_runner = ("vitest" if dep("vitest")
               else "karma" if dep("karma")
               else "jest" if dep("jest", "jest-preset-angular")
               else "none")

state_lib = ("ngrx-signals" if dep("@ngrx/signals")
             else "ngrx" if dep("@ngrx/store")
             else "ngxs" if dep("@ngxs/store")
             else "akita" if dep("@datorama/akita")
             else "none")

package_manager = ("pnpm" if os.path.exists(os.path.join(root, "pnpm-lock.yaml"))
                   else "yarn" if os.path.exists(os.path.join(root, "yarn.lock"))
                   else "bun" if os.path.exists(os.path.join(root, "bun.lock"))
                   else "npm")

ssr = dep("@angular/ssr") or bool(
    re.search(r'"(ssr|server|prerender)"\s*:', json.dumps(ng))
)

tsconfig_strict = False
try:
    raw = open(os.path.join(root, "tsconfig.json"), encoding="utf-8").read()
    raw = re.sub(r"//.*", "", raw)
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    tsconfig_strict = bool((json.loads(raw).get("compilerOptions") or {}).get("strict"))
except Exception:
    pass

projects = sorted((ng.get("projects") or {}).keys())

profile = {
    "plugin_version": plugin_version,
    "detected_at": datetime.datetime.now(datetime.timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "workspace_root": root,
    "angular_version": version if known else "unknown",
    "angular_major": major if known else "unknown",
    "standalone_default": standalone_default,
    "onpush_default": onpush_default,
    "signal_forms_available": signal_forms_available,
    "service_decorator_available": service_decorator_available,
    "zoneless": zoneless,
    "test_runner": test_runner,
    "ssr": bool(ssr),
    "state_lib": state_lib,
    "package_manager": package_manager,
    "typescript_strict": tsconfig_strict,
    "projects": projects,
}

with open(cache, "w") as f:
    json.dump(profile, f, indent=2)
    f.write("\n")

flags = []
if zoneless: flags.append("zoneless")
if signal_forms_available: flags.append("signal-forms")
if ssr: flags.append("ssr")
print("📐 angular-guide — Angular %s%s" % (
    profile["angular_version"], (" (" + ", ".join(flags) + ")") if flags else ""))
print("   tests: %s · state: %s · pm: %s · strict: %s"
      % (test_runner, state_lib, package_manager, str(tsconfig_strict).lower()))
print("   profile: %s" % cache)
PY

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 16 passed, 0 failed` (4 manifest + 12 detection checks)

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/detect_project.sh
git add scripts/detect_project.sh tests/run-tests.sh
git commit -m "feat: version-aware workspace detection (detect_project.sh)"
```

---

### Task 3: `hook-lint.sh` skeleton — stdin parsing, effective content, gate loader

Builds the pipeline every NG rule plugs into, proved by one ungated rule (NG007). No other rules yet.

**Files:**
- Create: `scripts/hook-lint.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `.angular-guide-project.json` from Task 2; `write_json`/`edit_json`/`ng_workspace` from Task 1.
- Produces — the contract every later rule task uses:
  - `hook-lint.sh <pre|post>`, tool-input JSON on stdin.
  - Shell variables available inside every check function: `$FILE_PATH` (the target path), `$CONTENT_PATH` (a readable file holding the effective content), `$CODE_PATH` (same content with comments stripped), `$EXT` (lowercase extension).
  - `add "<message>"` — appends a finding.
  - `gate <key>` — returns 0 when `<key>` is `true` in the profile, 1 otherwise (including a missing profile). `<key>` is any boolean key from Task 2's schema.
  - `gate_eq <key> <value>` — returns 0 when the profile's `<key>` equals `<value>` (used for `test_runner`).
  - `is_spec` — returns 0 when the file is a `.spec.ts` / `.test.ts`.
  - Check functions are named `check_ng001` … `check_ng018`, `check_ng101` … `check_ng106`, take no arguments, and are registered in the driver at the bottom.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== hook-lint.sh pipeline =="
###############################################################################

WORK="$TMPROOT/hl"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
mkdir -p "$WORK/src/app"
bash "$DETECT" >/dev/null 2>&1

# H1: Write payload — violation in pending content is caught
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect H1-write-any 2 err "NG007"

# H2: clean content passes silently
run "$(write_json "$WORK/src/app/a.ts" 'const x: number = 1;')" bash "$HOOK_LINT" pre
expect H2-clean-passes 0 none ""

# H3: Edit — violation introduced ONLY by new_string is caught against on-disk context
cat > "$WORK/src/app/b.ts" <<'EOF'
export function f(input: string) {
  return input.trim();
}
EOF
run "$(edit_json "$WORK/src/app/b.ts" 'input: string' 'input: any')" bash "$HOOK_LINT" pre
expect H3-edit-introduces 2 err "NG007"

# H4: Edit that REMOVES the violation must not report it
cat > "$WORK/src/app/c.ts" <<'EOF'
export function g(input: any) {
  return input;
}
EOF
run "$(edit_json "$WORK/src/app/c.ts" 'input: any' 'input: unknown')" bash "$HOOK_LINT" pre
expect H4-edit-removes 0 none ""

# H5: non-Angular extension ignored
run "$(write_json "$WORK/notes.md" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect H5-ignores-md 0 none ""

# H6: malformed stdin fails open
run 'not json at all' bash "$HOOK_LINT" pre
expect H6-malformed-json 0 none ""

# H7: unknown mode fails open
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" bogus
expect H7-unknown-mode 0 none ""

# H8: missing file_path fails open
run '{"tool_name":"Write","tool_input":{}}' bash "$HOOK_LINT" pre
expect H8-no-filepath 0 none ""

# H9: findings go to stderr, never stdout
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
H9_OK=0
[ -z "$OUT" ] || H9_OK=1
check H9-stderr-only "findings on stderr, stdout empty" "$H9_OK"

# H10: comments are stripped before matching — no fire on prose
run "$(write_json "$WORK/src/app/d.ts" 'const company = "acme"; // takes any value')" bash "$HOOK_LINT" pre
expect H10-comment-stripped 0 none ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: H1–H10 FAIL — `scripts/hook-lint.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/hook-lint.sh`:

```bash
#!/usr/bin/env bash
# hook-lint.sh — Write|Edit hook checks for angular-guide.
# Called by the PreToolUse and PostToolUse hooks in hooks/hooks.json.
#
# Claude Code feeds a hook's STDERR to the model on exit code 2 (stdout is
# reserved for JSON hook output), so every finding here is written to stderr.
#
# Modes:
#   pre   Blocking checks (NG001-NG018) against the EFFECTIVE post-edit content:
#         for Write that is the pending `content`; for Edit it is the on-disk
#         file with `old_string` replaced by `new_string`, so an edit that
#         introduces a violation into existing context is caught too.
#         Exit 2 blocks the write and the model sees the findings.
#   post  Advisory checks (NG101-NG106) against the file now on disk. Exit 2
#         feeds the findings back to the model without undoing the write.
#
# Every unexpected condition exits 0. A plugin defect must never block a write.
#
# Usage: hook-lint.sh <pre|post>

set -u

MODE="${1:-}"
INPUT=$(cat)

case "$MODE" in pre|post) ;; *) exit 0 ;; esac

DATA=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, os, tempfile

mode = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
fp = ti.get("file_path", "") or ""
if not fp:
    sys.exit(0)

if mode == "post":
    print(fp); print(fp); sys.exit(0)

if ti.get("content") is not None:
    content = ti["content"]
else:
    base = ""
    try:
        with open(fp, encoding="utf-8", errors="ignore") as f:
            base = f.read()
    except Exception:
        pass
    old = ti.get("old_string") or ""
    new = ti.get("new_string") or ""
    if old and old in base:
        content = base.replace(old, new) if ti.get("replace_all") else base.replace(old, new, 1)
    elif new:
        content = base + "\n" + new
    else:
        content = base

fd, tp = tempfile.mkstemp(prefix="angular-guide-hook-")
with os.fdopen(fd, "w") as f:
    f.write(content)
print(fp); print(tp)
' "$MODE" 2>/dev/null)

FILE_PATH=$(printf '%s\n' "$DATA" | sed -n '1p')
CONTENT_PATH=$(printf '%s\n' "$DATA" | sed -n '2p')

CODE_PATH=""
cleanup() {
  [ -n "${CODE_PATH:-}" ] && rm -f "$CODE_PATH"
  if [ "$MODE" = "pre" ] && [ -n "${CONTENT_PATH:-}" ] && [ "$CONTENT_PATH" != "$FILE_PATH" ]; then
    rm -f "$CONTENT_PATH"
  fi
  return 0
}
trap cleanup EXIT

[ -n "$FILE_PATH" ] && [ -r "$CONTENT_PATH" ] || exit 0

EXT=$(printf '%s' "${FILE_PATH##*.}" | tr '[:upper:]' '[:lower:]')
case "$EXT" in ts|html) ;; *) exit 0 ;; esac

# ------------------------------------------------------------------ profile
# Walk up from the edited file (NOT $PWD — the hook's cwd may differ from the
# workspace root) to find the profile written by detect_project.sh.
find_profile() {
  local dir
  dir="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd)" || dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.angular-guide-project.json" ]; then
      echo "$dir/.angular-guide-project.json"; return 0
    fi
    dir="$(dirname "$dir")"
  done
  [ -f "$PWD/.angular-guide-project.json" ] && echo "$PWD/.angular-guide-project.json"
  return 0
}
PROFILE=$(find_profile 2>/dev/null || true)

# gate <boolean-key> — true only when the profile explicitly says true.
# A missing profile or unknown version means the rule is SKIPPED, never guessed.
gate() {
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 1
  grep -q "\"$1\"[[:space:]]*:[[:space:]]*true" "$PROFILE" 2>/dev/null
}

# gate_eq <string-key> <value>
gate_eq() {
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 1
  grep -q "\"$1\"[[:space:]]*:[[:space:]]*\"$2\"" "$PROFILE" 2>/dev/null
}

is_spec() { printf '%s' "$FILE_PATH" | grep -qE '\.spec\.ts$|\.test\.ts$'; }

FINDINGS=()
add() { FINDINGS+=("$1"); }

# Content with // and /* */ comments stripped, so rules never fire on prose.
CODE_PATH=$(mktemp -t angular-guide-code) || CODE_PATH="$CONTENT_PATH"
python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
src = re.sub(r"(^|[^:])//[^\n]*", r"\1", src)
open(sys.argv[2], "w").write(src)
' "$CONTENT_PATH" "$CODE_PATH" 2>/dev/null || cp "$CONTENT_PATH" "$CODE_PATH" 2>/dev/null

# ------------------------------------------------------------- pre: NG001-018

check_ng007() {
  if grep -qE '(:[[:space:]]*any\b|\bas[[:space:]]+any\b|<any>)' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG007: `any` type detected.
   💡 Fix: Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide.
   See: angular-essentials skill'
  fi
}

# -------------------------------------------------------------------- driver

if [ "$MODE" = "pre" ]; then
  check_ng007
else
  :
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  for f in "${FINDINGS[@]}"; do
    printf '%s\n\n' "$f" >&2
  done
  exit 2
fi
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 26 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/hook-lint.sh
git add scripts/hook-lint.sh tests/run-tests.sh
git commit -m "feat: hook-lint pipeline with effective-content reconstruction and version gates"
```

---

### Task 4: `bash-guard.sh` — BG001–BG006

**Files:**
- Create: `scripts/bash-guard.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `bash_json` from Task 1; the profile's `package_manager` key from Task 2.
- Produces: `bash-guard.sh` reading tool-input JSON on stdin, no arguments. Exit 2 blocks.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block. Note `PUSH="git push"` — the literal command strings are assembled from variables so that a force-push guard installed in the *developer's own* environment does not match this test file's contents while it is being written.

```bash
###############################################################################
echo
echo "== bash-guard.sh =="
###############################################################################

WORK="$TMPROOT/bg"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
touch pnpm-lock.yaml
bash "$DETECT" >/dev/null 2>&1

PUSH="git push"; FORCE="--force"; SHORTF="-f"

run "$(bash_json "$PUSH $FORCE origin main")" bash "$BASH_GUARD"
expect B1-force-push-main 2 err "BG001"

run "$(bash_json "$PUSH $SHORTF origin master")" bash "$BASH_GUARD"
expect B2-force-push-master 2 err "BG001"

run "$(bash_json "$PUSH ${FORCE}-with-lease origin feature/x")" bash "$BASH_GUARD"
expect B3-force-with-lease-ok 0 none ""

run "$(bash_json "$PUSH origin main")" bash "$BASH_GUARD"
expect B4-normal-push-ok 0 none ""

run "$(bash_json 'ng build --prod')" bash "$BASH_GUARD"
expect B5-ng-build-prod 2 err "BG002"

run "$(bash_json 'ng build')" bash "$BASH_GUARD"
expect B6-ng-build-ok 0 none ""

run "$(bash_json 'npm install')" bash "$BASH_GUARD"
expect B7-pm-mismatch 2 err "BG003"

run "$(bash_json 'pnpm install')" bash "$BASH_GUARD"
expect B8-pm-match-ok 0 none ""

run "$(bash_json 'ng test')" bash "$BASH_GUARD"
expect B9-ng-test-watch 2 err "BG004"

run "$(bash_json 'ng test --watch=false')" bash "$BASH_GUARD"
expect B10-ng-test-nowatch-ok 0 none ""

run "$(bash_json 'rm -rf node_modules pnpm-lock.yaml')" bash "$BASH_GUARD"
expect B11-nuke-lockfile 2 err "BG005"

run "$(bash_json 'rm -rf node_modules')" bash "$BASH_GUARD"
expect B12-rm-nodemodules-ok 0 none ""

run "$(bash_json 'ng update @angular/core --force')" bash "$BASH_GUARD"
expect B13-ng-update-force 2 err "BG006"

run 'not json' bash "$BASH_GUARD"
expect B14-malformed-fails-open 0 none ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: B1–B14 FAIL — `scripts/bash-guard.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/bash-guard.sh`:

```bash
#!/usr/bin/env bash
# bash-guard.sh — Bash PreToolUse hook for angular-guide (BG001-BG006).
# Findings go to stderr; exit 2 blocks the command. Fails open on any error.

set -u

INPUT=$(cat)

CMD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
print((d.get("tool_input", {}) or {}).get("command", "") or "")
' 2>/dev/null)

[ -n "${CMD:-}" ] || exit 0

find_profile() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.angular-guide-project.json" ]; then
      echo "$dir/.angular-guide-project.json"; return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 0
}
PROFILE=$(find_profile 2>/dev/null || true)

profile_str() { # <key> — echoes the string value, empty if unavailable
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$PROFILE" 2>/dev/null \
    | sed -E 's/.*"([^"]*)"$/\1/' | head -1
}

FINDINGS=()
add() { FINDINGS+=("$1"); }

# BG001 — force push to the default branch
if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push' \
   && printf '%s' "$CMD" | grep -qE '(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))' \
   && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(main|master)([[:space:]]|$)'; then
  add '🚫 BG001: Force push to the default branch rewrites shared history.
   💡 Fix: Use --force-with-lease, and push to a feature branch instead.'
fi

# BG002 — ng build --prod (flag removed in Angular 12)
if printf '%s' "$CMD" | grep -qE 'ng[[:space:]]+build' \
   && printf '%s' "$CMD" | grep -qE -- '--prod([[:space:]]|$)'; then
  add '🚫 BG002: `ng build --prod` — the flag was removed in Angular 12.
   💡 Fix: Run `ng build`. Production is the default configuration.'
fi

# BG003 — package manager mismatching the lockfile
PM=$(profile_str package_manager)
if [ -n "$PM" ]; then
  for other in npm pnpm yarn bun; do
    [ "$other" = "$PM" ] && continue
    if printf '%s' "$CMD" | grep -qE "(^|[[:space:]&|;])$other[[:space:]]+(install|i|add|ci)([[:space:]]|$)"; then
      add "🚫 BG003: \`$other\` invoked but this workspace uses \`$PM\` (per its lockfile).
   💡 Fix: Use \`$PM\` — mixing package managers produces a second lockfile and divergent dependency trees."
      break
    fi
  done
fi

# BG004 — ng test without --watch=false hangs an agent session
if printf '%s' "$CMD" | grep -qE '(^|[[:space:]&|;])ng[[:space:]]+test([[:space:]]|$)' \
   && ! printf '%s' "$CMD" | grep -qE -- '--watch[= ]false|--no-watch|--run|--ci'; then
  add '🚫 BG004: `ng test` runs in watch mode by default and will hang this session.
   💡 Fix: Run `ng test --watch=false` (Karma) or `ng test --run` (Vitest).'
fi

# BG005 — deleting node_modules together with the lockfile
if printf '%s' "$CMD" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*r' \
   && printf '%s' "$CMD" | grep -qE '(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lock)'; then
  add '🚫 BG005: Deleting the lockfile discards every pinned transitive version.
   💡 Fix: Delete node_modules alone and reinstall. Only remove the lockfile when deliberately re-resolving the whole dependency tree.'
fi

# BG006 — ng update --force skips the checks that make updating safe
if printf '%s' "$CMD" | grep -qE 'ng[[:space:]]+update' \
   && printf '%s' "$CMD" | grep -qE -- '--force([[:space:]]|$)'; then
  add '🚫 BG006: `ng update --force` bypasses peer-dependency and migration checks.
   💡 Fix: Resolve the reported incompatibilities, or update one package at a time. Run `ng update` without --force first to see what it objects to.'
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  for f in "${FINDINGS[@]}"; do
    printf '%s\n\n' "$f" >&2
  done
  exit 2
fi
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 40 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/bash-guard.sh
git add scripts/bash-guard.sh tests/run-tests.sh
git commit -m "feat: bash-guard BG001-BG006"
```

---

### Task 5: Hook wiring and subagent rule injection

**Files:**
- Create: `hooks/hooks.json`
- Create: `scripts/subagent-rules.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: all four scripts from Tasks 2–4.
- Produces: `hooks/hooks.json` — five hook entries (`SessionStart`, `PreToolUse:Bash`, `PreToolUse:Write|Edit`, `PostToolUse:Write|Edit`, `SubagentStart`). `scripts/subagent-rules.sh` emits the condensed rule set on stdout and always exits 0.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== hooks.json wiring =="
###############################################################################

W1_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/hooks/hooks.json" 2>/dev/null || W1_OK=1
check W1-hooks-json-parses "hooks.json is valid JSON" "$W1_OK"

W2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || W2_OK=1
import json, os, re, sys
root = sys.argv[1]
d = json.load(open(os.path.join(root, "hooks", "hooks.json")))["hooks"]
for ev in ("SessionStart", "PreToolUse", "PostToolUse", "SubagentStart"):
    assert ev in d, "missing event: " + ev
cmds = [h["command"] for groups in d.values() for g in groups for h in g["hooks"]]
assert len(cmds) == 5, "expected 5 hook commands, got %d" % len(cmds)
for c in cmds:
    assert "${CLAUDE_PLUGIN_ROOT}" in c, "hook not using CLAUDE_PLUGIN_ROOT: " + c
    for script in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)", c):
        p = os.path.join(root, script)
        assert os.path.exists(p), "referenced script missing: " + script
        assert os.access(p, os.X_OK), "referenced script not executable: " + script
matchers = sorted(g.get("matcher", "") for g in d["PreToolUse"])
assert matchers == ["Bash", "Write|Edit"], matchers
PY
check W2-hooks-wiring "5 commands, CLAUDE_PLUGIN_ROOT paths, scripts exist and are executable" "$W2_OK"

W3_OK=0
run "" bash "$SUBAGENT"
[ "$CODE" = "0" ] || W3_OK=1
printf '%s' "$OUT" | grep -q "NG001" || W3_OK=1
printf '%s' "$OUT" | grep -qF "inject()" || W3_OK=1
check W3-subagent-rules "subagent-rules emits rules on stdout, exit 0" "$W3_OK"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: W1–W3 FAIL — `hooks/hooks.json` and `scripts/subagent-rules.sh` do not exist.

- [ ] **Step 3: Write minimal implementation**

Create `hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/detect_project.sh\" 2>/dev/null; exit 0",
            "description": "Detect Angular workspace (version, zoneless, test runner, state lib) and cache the profile that gates every rule"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/bash-guard.sh\"",
            "description": "BG001-BG006: force-push, removed ng flags, package-manager mismatch, hanging test runs, lockfile deletion"
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook-lint.sh\" pre",
            "description": "NG001-NG018: blocking checks against the effective post-edit content (legacy Angular, reactivity misuse, security)"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook-lint.sh\" post",
            "description": "NG101-NG106: advisory checks — eager routes, legacy forms and DI idioms, image optimization, complexity"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/subagent-rules.sh\"",
            "description": "Inject the condensed Angular rule set into every subagent, which inherits no skills"
          }
        ]
      }
    ]
  }
}
```

Create `scripts/subagent-rules.sh`:

```bash
#!/usr/bin/env bash
# subagent-rules.sh — SubagentStart hook. Subagents inherit no skills, so the
# condensed rule set is injected directly. Mirrors skills/angular-essentials.
# Always exits 0; stdout becomes subagent context.

set -u
cat <<'RULES'
## angular-guide — Rules for Subagents

You are working in a modern Angular workspace (v20+). These are enforced by
hooks; violating them blocks your write.

### Components and templates
- NG001 Never write `standalone: true` — standalone is the default since v20.
- NG002 Never create an `@NgModule`. Use standalone components.
- NG003 Use `@if` / `@for` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch`.
- NG005 Use the `input()` / `output()` / `model()` functions, never the `@Input()` / `@Output()` decorators.
- NG006 Never set `changeDetection: ChangeDetectionStrategy.OnPush` — it is the default in v22.
- NG008 Use `[class.x]` and `[style.x]` bindings, never `ngClass` / `ngStyle`.
- NG009 Use the `host` object in the decorator, never `@HostBinding` / `@HostListener`.
- NG013 Every `@for` needs a `track` expression.

### Dependency injection and services
- NG004 Use `inject()`, never constructor-parameter injection.

### Reactivity
- NG011 Signals have no `mutate()`. Use `set()` or `update()`.
- NG012 Never write a signal from inside `effect()`. Derived state is `computed()`;
  state derived from multiple reactive sources is `linkedSignal()`.
- NG010 Never call `.subscribe()` without `takeUntilDestroyed()`. Prefer the
  `async` pipe, `toSignal()`, or `httpResource()`.

### TypeScript
- NG007 Never use `any`. Use `unknown` and narrow it.

### Security
- NG014 Never bind `[innerHTML]`.
- NG015 Never call `bypassSecurityTrust*`.
- NG016 Never put secrets in `environment*.ts`.

Keep components presentational: HTTP calls, state orchestration, and validation
belong in services, not components.
RULES
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 43 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/subagent-rules.sh
git add hooks/hooks.json scripts/subagent-rules.sh tests/run-tests.sh
git commit -m "feat: native hook wiring and subagent rule injection"
```

---

### Task 6: NG001–NG009 — legacy-Angular blocking rules

**Files:**
- Modify: `scripts/hook-lint.sh` (add nine check functions, register in the `pre` driver)
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `add`, `gate`, `is_spec`, `$CODE_PATH`, `$EXT` from Task 3.
- Produces: `gate_v20` and `gate_v22` helpers (defined here, used by Tasks 7 and 8);
  check functions `check_ng001` … `check_ng009`; `$COLLAPSED` — a single-line copy of
  the code used by the multi-line rules (NG004), created once and reused.

**Version-gate mapping.** The profile has no raw threshold key, so the derived gates
stand in for them: `standalone_default` is true exactly when major ≥ 20, and
`onpush_default` exactly when major ≥ 22. `gate_v20`/`gate_v22` name that mapping so
no later rule has to remember it.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== NG001-NG009 (legacy Angular) =="
###############################################################################

V22="$TMPROOT/ng22"; ng_workspace "$V22" "22.0.0"; mkdir -p "$V22/src/app"
cd "$V22" || exit 1; bash "$DETECT" >/dev/null 2>&1

V21="$TMPROOT/ng21"; ng_workspace "$V21" "21.0.0"; mkdir -p "$V21/src/app"
cd "$V21" || exit 1; bash "$DETECT" >/dev/null 2>&1

UNK="$TMPROOT/ngunk"; mkdir -p "$UNK/src/app"
printf '{"version":1,"projects":{}}\n' > "$UNK/angular.json"
printf '{"name":"x","dependencies":{}}\n' > "$UNK/package.json"
cd "$UNK" || exit 1; bash "$DETECT" >/dev/null 2>&1

cd "$V22" || exit 1

# NG001 standalone: true
run "$(write_json "$V22/src/app/a.ts" '@Component({ selector: "app-a", standalone: true, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-fires 2 err "NG001"

run "$(write_json "$V22/src/app/a.ts" '@Component({ selector: "app-a", template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-silent 0 none ""

# NG002 @NgModule
run "$(write_json "$V22/src/app/m.ts" '@NgModule({ declarations: [] })
export class M {}')" bash "$HOOK_LINT" pre
expect N002-fires 2 err "NG002"

# NG003 structural directives — template file and inline template
run "$(write_json "$V22/src/app/a.html" '<div *ngIf="ready">hi</div>')" bash "$HOOK_LINT" pre
expect N003-html-ngif 2 err "NG003"

run "$(write_json "$V22/src/app/a.html" '<li *ngFor="let x of xs">{{x}}</li>')" bash "$HOOK_LINT" pre
expect N003-html-ngfor 2 err "NG003"

run "$(write_json "$V22/src/app/a.ts" '@Component({ template: `<div *ngIf="ready"></div>` })
export class A {}')" bash "$HOOK_LINT" pre
expect N003-inline-template 2 err "NG003"

run "$(write_json "$V22/src/app/a.html" '@if (ready) { <div>hi</div> }')" bash "$HOOK_LINT" pre
expect N003-silent 0 none ""

# NG004 constructor-parameter DI, including the multi-line form
run "$(write_json "$V22/src/app/s.ts" 'export class S {
  constructor(
    private http: HttpClient,
    private router: Router,
  ) {}
}')" bash "$HOOK_LINT" pre
expect N004-multiline 2 err "NG004"

run "$(write_json "$V22/src/app/s.ts" 'export class S {
  private http = inject(HttpClient);
}')" bash "$HOOK_LINT" pre
expect N004-silent 0 none ""

# A plain constructor with no access modifier is not injection
run "$(write_json "$V22/src/app/p.ts" 'export class P {
  constructor(name: string) { this.name = name; }
}')" bash "$HOOK_LINT" pre
expect N004-plain-ctor-ok 0 none ""

# NG005 decorators
run "$(write_json "$V22/src/app/a.ts" 'export class A { @Input() name!: string; }')" bash "$HOOK_LINT" pre
expect N005-input 2 err "NG005"

run "$(write_json "$V22/src/app/a.ts" 'export class A { @Output() saved = new EventEmitter(); }')" bash "$HOOK_LINT" pre
expect N005-output 2 err "NG005"

run "$(write_json "$V22/src/app/a.ts" 'export class A { readonly name = input.required<string>(); }')" bash "$HOOK_LINT" pre
expect N005-silent 0 none ""

# NG006 explicit OnPush — v22 only
run "$(write_json "$V22/src/app/a.ts" '@Component({ changeDetection: ChangeDetectionStrategy.OnPush, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N006-fires-on-v22 2 err "NG006"

cd "$V21" || exit 1
run "$(write_json "$V21/src/app/a.ts" '@Component({ changeDetection: ChangeDetectionStrategy.OnPush, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N006-silent-on-v21 0 none ""

# Gate discipline: unknown version silences every gated rule
cd "$UNK" || exit 1
run "$(write_json "$UNK/src/app/a.ts" '@Component({ standalone: true, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-silent-unknown-version 0 none ""

cd "$V22" || exit 1

# NG008 ngClass / ngStyle
run "$(write_json "$V22/src/app/a.html" '<div [ngClass]="{ active: on }"></div>')" bash "$HOOK_LINT" pre
expect N008-ngclass 2 err "NG008"

run "$(write_json "$V22/src/app/a.html" '<div [class.active]="on"></div>')" bash "$HOOK_LINT" pre
expect N008-silent 0 none ""

# NG009 host decorators
run "$(write_json "$V22/src/app/a.ts" 'export class A { @HostListener("click") onClick() {} }')" bash "$HOOK_LINT" pre
expect N009-hostlistener 2 err "NG009"

run "$(write_json "$V22/src/app/a.ts" '@Component({ host: { "(click)": "onClick()" }, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N009-silent 0 none ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: every N0* check FAILs — the check functions do not exist, so nothing exits 2.

- [ ] **Step 3: Write minimal implementation**

In `scripts/hook-lint.sh`, immediately after the `add()` definition, add the version-gate
helpers and the collapsed-code copy:

```bash
# Version thresholds expressed through the profile's derived gates:
#   standalone_default is true exactly when major >= 20
#   onpush_default     is true exactly when major >= 22
gate_v20() { gate standalone_default; }
gate_v22() { gate onpush_default; }

# Single-line copy of the code, for rules that must match across newlines.
COLLAPSED=$(tr '\n' ' ' < "$CODE_PATH" 2>/dev/null)
```

Then replace the `# pre: NG001-018` section's contents with the following, keeping
`check_ng007` where it is:

```bash
check_ng001() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE 'standalone:[[:space:]]*true' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG001: `standalone: true` in a decorator.
   💡 Fix: Delete the property. Standalone is the default since Angular v20 — writing it is redundant and signals a pre-v20 mental model.
   See: angular-essentials skill'
  fi
}

check_ng002() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -q '@NgModule' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG002: `@NgModule` declaration.
   💡 Fix: Use standalone components. Put shared providers in `providers` at bootstrap or on a route, and import components directly via the `imports` array.
   See: angular-essentials skill'
  fi
}

check_ng003() {
  gate_v20 || return 0
  if grep -qE '\*ngIf|\*ngFor|\*ngSwitch|\[ngSwitch\]' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG003: Legacy structural directive (`*ngIf` / `*ngFor` / `*ngSwitch`).
   💡 Fix: Use native control flow — `@if (cond) { }`, `@for (x of xs; track x.id) { }`, `@switch (v) { @case (a) { } }`. It needs no imports, is faster, and is the only supported form going forward.
   See: angular-essentials skill'
  fi
}

check_ng004() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if printf '%s' "$COLLAPSED" \
     | grep -qE 'constructor[[:space:]]*\([^)]*\b(private|public|protected|readonly)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*:'; then
    add '🚫 NG004: Constructor-parameter dependency injection.
   💡 Fix: Use the `inject()` function at field level:
     private readonly http = inject(HttpClient);
   It gives better type inference, works in field initializers and functional guards/interceptors, and avoids inheritance boilerplate.
   See: angular-essentials skill'
  fi
}

check_ng005() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '@Input[[:space:]]*\(|@Output[[:space:]]*\(' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG005: `@Input()` / `@Output()` decorator.
   💡 Fix: Use the signal-based functions:
     readonly name = input.required<string>();
     readonly saved = output<Item>();
     readonly value = model<string>("");
   Signal inputs are readable in computed() without a lifecycle hook.
   See: angular-essentials skill'
  fi
}

check_ng006() {
  gate_v22 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE 'changeDetection:[[:space:]]*ChangeDetectionStrategy\.OnPush' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG006: Explicit `changeDetection: ChangeDetectionStrategy.OnPush`.
   💡 Fix: Delete the property and its import. OnPush is the default strategy in Angular v22 — setting it explicitly is now noise.
   See: performance-and-zoneless skill'
  fi
}

check_ng008() {
  if grep -qE '\[ngClass\]|\[ngStyle\]|[[:space:]]ngClass=|[[:space:]]ngStyle=' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG008: `ngClass` / `ngStyle`.
   💡 Fix: Use native bindings — `[class.active]="isActive()"`, `[style.width.px]="w()"`, or `[class]="classRecord()"`. They need no import and avoid an extra directive instance per element.
   See: angular-essentials skill'
  fi
}

check_ng009() {
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '@HostBinding|@HostListener' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG009: `@HostBinding` / `@HostListener` decorator.
   💡 Fix: Use the `host` object in the decorator metadata:
     @Component({ host: { "[class.active]": "isActive()", "(click)": "onClick($event)" } })
   It keeps host behaviour in one place and is statically analysable.
   See: angular-essentials skill'
  fi
}
```

Update the `pre` branch of the driver:

```bash
if [ "$MODE" = "pre" ]; then
  check_ng001
  check_ng002
  check_ng003
  check_ng004
  check_ng005
  check_ng006
  check_ng007
  check_ng008
  check_ng009
else
  :
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 63 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/hook-lint.sh tests/run-tests.sh
git commit -m "feat: NG001-NG009 legacy-Angular blocking rules"
```

---

### Task 7: NG010–NG018 — reactivity, security, and workspace-gated rules

**Files:**
- Modify: `scripts/hook-lint.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `add`, `gate`, `gate_eq`, `gate_v20`, `is_spec`, `$CODE_PATH`, `$COLLAPSED`, `$EXT`.
- Produces: `check_ng010` … `check_ng018`, registered in the `pre` driver after `check_ng009`.

NG010 and NG012 need statement-level analysis rather than file-level matching, so both
shell out to a short Python pass. File-level matching would flag a component that
correctly uses `takeUntilDestroyed` on one subscription and not another, and would miss
an `effect()` that writes a signal in a file that also legitimately calls `.set()`
elsewhere.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== NG010-NG018 (reactivity, security, workspace-gated) =="
###############################################################################

cd "$V22" || exit 1

# NG010 subscribe without teardown
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  ngOnInit() { this.svc.items$.subscribe((v) => this.items.set(v)); }
}')" bash "$HOOK_LINT" pre
expect N010-bare-subscribe 2 err "NG010"

run "$(write_json "$V22/src/app/a.ts" 'export class A {
  ngOnInit() { this.svc.items$.pipe(takeUntilDestroyed(this.ref)).subscribe((v) => this.items.set(v)); }
}')" bash "$HOOK_LINT" pre
expect N010-with-teardown-ok 0 none ""

# A file with one guarded and one bare subscription must still be caught
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  a() { this.x$.pipe(takeUntilDestroyed()).subscribe(f); }
  b() { this.y$.subscribe(g); }
}')" bash "$HOOK_LINT" pre
expect N010-mixed-caught 2 err "NG010"

# Spec files are exempt — test subscriptions are scoped to the test
run "$(write_json "$V22/src/app/a.spec.ts" 'it("works", () => { obs$.subscribe(done); });')" bash "$HOOK_LINT" pre
expect N010-spec-exempt 0 none ""

# NG011 signal.mutate()
run "$(write_json "$V22/src/app/a.ts" 'this.items.mutate((v) => v.push(x));')" bash "$HOOK_LINT" pre
expect N011-mutate 2 err "NG011"

# NG012 effect() writing a signal
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.total.set(this.a() + this.b()); });')" bash "$HOOK_LINT" pre
expect N012-effect-writes 2 err "NG012"

run "$(write_json "$V22/src/app/a.ts" 'readonly total = computed(() => this.a() + this.b());
effect(() => { console.log(this.total()); });')" bash "$HOOK_LINT" pre
expect N012-effect-readonly-ok 0 none ""

# A .set() outside any effect is fine
run "$(write_json "$V22/src/app/a.ts" 'onClick() { this.count.set(1); }')" bash "$HOOK_LINT" pre
expect N012-set-outside-effect-ok 0 none ""

# NG013 @for without track
run "$(write_json "$V22/src/app/a.html" '@for (item of items(); let i = $index) { <li>{{item}}</li> }')" bash "$HOOK_LINT" pre
expect N013-no-track 2 err "NG013"

run "$(write_json "$V22/src/app/a.html" '@for (item of items(); track item.id) { <li>{{item}}</li> }')" bash "$HOOK_LINT" pre
expect N013-track-ok 0 none ""

# NG014 innerHTML
run "$(write_json "$V22/src/app/a.html" '<div [innerHTML]="body"></div>')" bash "$HOOK_LINT" pre
expect N014-innerhtml 2 err "NG014"

# NG015 bypassSecurityTrust
run "$(write_json "$V22/src/app/a.ts" 'const u = this.san.bypassSecurityTrustHtml(raw);')" bash "$HOOK_LINT" pre
expect N015-bypass 2 err "NG015"

# NG016 secrets in environment files
run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiKey: "sk_live_abc123def456" };')" bash "$HOOK_LINT" pre
expect N016-secret 2 err "NG016"

run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiKey: "" };')" bash "$HOOK_LINT" pre
expect N016-empty-ok 0 none ""

run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiUrl: "https://api.example.com" };')" bash "$HOOK_LINT" pre
expect N016-nonsecret-ok 0 none ""

# NG017 zone.js in a zoneless workspace
run "$(write_json "$V22/src/app/a.ts" 'import "zone.js";')" bash "$HOOK_LINT" pre
expect N017-zonejs-zoneless 2 err "NG017"

# ...and silent in a workspace that still depends on zone.js
ZONED="$TMPROOT/zoned"; ng_workspace "$ZONED" "22.0.0" '{"zone.js":"~0.15.0"}'
mkdir -p "$ZONED/src/app"; cd "$ZONED" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$ZONED/src/app/a.ts" 'import "zone.js";')" bash "$HOOK_LINT" pre
expect N017-silent-when-zoned 0 none ""

# NG018 Jasmine APIs in a Vitest workspace
VIT="$TMPROOT/vit"; ng_workspace "$VIT" "22.0.0" '{"vitest":"^3.0.0"}'
mkdir -p "$VIT/src/app"; cd "$VIT" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$VIT/src/app/a.spec.ts" 'const spy = jasmine.createSpy("x");')" bash "$HOOK_LINT" pre
expect N018-jasmine-in-vitest 2 err "NG018"

run "$(write_json "$VIT/src/app/a.spec.ts" 'const spy = vi.fn();')" bash "$HOOK_LINT" pre
expect N018-vi-ok 0 none ""

# ...and silent in a Karma workspace
KAR="$TMPROOT/kar"; ng_workspace "$KAR" "21.0.0" '{"karma":"~6.4.0"}'
mkdir -p "$KAR/src/app"; cd "$KAR" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$KAR/src/app/a.spec.ts" 'const spy = jasmine.createSpy("x");')" bash "$HOOK_LINT" pre
expect N018-silent-on-karma 0 none ""

cd "$V22" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: every N01[0-8] check FAILs.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/hook-lint.sh` after `check_ng009`:

```bash
check_ng010() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null || return 0
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
# For each .subscribe( call, inspect the chain back to the start of its
# statement. A chain carrying takeUntilDestroyed (or an explicit take/first
# completion operator) is considered self-terminating.
SAFE = ("takeUntilDestroyed", "takeUntil(", "take(", "first(", "firstValueFrom", "lastValueFrom")
for m in re.finditer(r"\.subscribe\s*\(", src):
    start = max(src.rfind(";", 0, m.start()), src.rfind("{", 0, m.start()),
                src.rfind("}", 0, m.start()), src.rfind("=>", 0, m.start()))
    chain = src[start + 1:m.start()]
    if not any(s in chain for s in SAFE):
        sys.exit(1)
sys.exit(0)
PY
  if [ $? -eq 1 ]; then
    add '🚫 NG010: `.subscribe()` with no teardown in its chain.
   💡 Fix: Prefer not subscribing at all — use the `async` pipe, `toSignal(obs$)`, or `httpResource()`. When you must subscribe, add teardown:
     obs$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(...)
   Manual subscriptions without teardown are the most common memory leak in Angular apps.
   See: rxjs-interop skill'
  fi
}

check_ng011() {
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '\.mutate[[:space:]]*\(' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG011: `.mutate()` on a signal — the API was removed.
   💡 Fix: Use `set()` with a new value, or `update()` with a pure transform:
     this.items.update((xs) => [...xs, item]);
   Signals compare by reference, so in-place mutation would not notify readers.
   See: signals-essentials skill'
  fi
}

check_ng012() {
  [ "$EXT" = "ts" ] || return 0
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null || return 0
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r"\beffect\s*\(", src):
    i = m.end() - 1
    depth, j, n = 0, i, len(src)
    while j < n:
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = src[i:j]
    if re.search(r"\.(set|update)\s*\(", body):
        sys.exit(1)
sys.exit(0)
PY
  if [ $? -eq 1 ]; then
    add '🚫 NG012: `effect()` writes a signal.
   💡 Fix: Effects are for side effects that leave the reactive graph — logging, third-party DOM, analytics. Derived state belongs in `computed()`; writable state derived from other signals belongs in `linkedSignal()`. Writing signals inside an effect creates feedback loops and re-entrant change detection.
   See: signals-essentials skill'
  fi
}

check_ng013() {
  gate_v20 || return 0
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null || return 0
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r"@for\s*\(([^)]*)\)", src):
    if "track" not in m.group(1):
        sys.exit(1)
sys.exit(0)
PY
  if [ $? -eq 1 ]; then
    add '🚫 NG013: `@for` without a `track` expression.
   💡 Fix: Add a stable identity — `@for (item of items(); track item.id) { }`. `track` is mandatory; without it Angular cannot reuse DOM nodes and rebuilds the whole list on every change.
   See: performance-and-zoneless skill'
  fi
}

check_ng014() {
  if grep -qE '\[innerHTML\]|\[outerHTML\]' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG014: `[innerHTML]` binding.
   💡 Fix: Render text with interpolation, or compose real components. If you must render untrusted markup, sanitize it server-side and render through a vetted component — Angular sanitizes `[innerHTML]` but the pattern still invites XSS as soon as someone reaches for bypassSecurityTrust.
   See: angular-essentials skill'
  fi
}

check_ng015() {
  [ "$EXT" = "ts" ] || return 0
  if grep -q 'bypassSecurityTrust' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG015: `bypassSecurityTrust*` call.
   💡 Fix: This disables Angular XSS protection for that value. Sanitize upstream and render normally. If a genuine trusted-value case exists, it belongs in one reviewed, narrowly-scoped helper — never inline in a component.
   See: angular-essentials skill'
  fi
}

check_ng016() {
  [ "$EXT" = "ts" ] || return 0
  printf '%s' "$FILE_PATH" | grep -qE '/environments?/|environment(\.[a-z]+)*\.ts$' || return 0
  if grep -qiE '(key|secret|token|password|credential)[A-Za-z]*[[:space:]]*:[[:space:]]*["'"'"'][^"'"'"']+["'"'"']' "$CODE_PATH" 2>/dev/null \
     && ! grep -qE 'process\.env|import\.meta\.env' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG016: Secret-shaped value in an environment file.
   💡 Fix: `environment.ts` is compiled into the browser bundle — anything in it is public. Move the secret behind your backend and have the client call your API. Build-time injection does not help; the value still ships.
   See: angular-essentials skill'
  fi
}

check_ng017() {
  gate zoneless || return 0
  if grep -qE "(import|require).*['\"]zone\.js" "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG017: `zone.js` import in a zoneless workspace.
   💡 Fix: Remove the import. This app runs with `provideZonelessChangeDetection()`; loading zone.js re-introduces monkey-patching of every async API and negates the benefit.
   See: performance-and-zoneless skill'
  fi
}

check_ng018() {
  gate_eq test_runner vitest || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '\bjasmine\.|\bjasmine\b[[:space:]]*\.' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG018: Jasmine API in a Vitest workspace.
   💡 Fix: Use the Vitest equivalents — `vi.fn()` for `jasmine.createSpy()`, `vi.spyOn()` for `spyOn()`, `expect.objectContaining()` for `jasmine.objectContaining()`. TestBed itself is unchanged.
   See: testing-essentials skill'
  fi
}
```

Extend the `pre` driver with `check_ng010` through `check_ng018`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 83 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/hook-lint.sh tests/run-tests.sh
git commit -m "feat: NG010-NG018 reactivity, security, and workspace-gated rules"
```

---

### Task 8: NG101–NG106 advisory rules and `analyze_quality.sh`

**Files:**
- Create: `scripts/analyze_quality.sh`
- Modify: `scripts/hook-lint.sh` (add six check functions, populate the `post` driver)
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `add`, `gate`, `gate_v22`, `is_spec`, `$CODE_PATH`, `$FILE_PATH`, `$EXT`.
- Produces: `check_ng101` … `check_ng106`, registered in the `post` driver.
  `analyze_quality.sh <file>` prints one finding per line to stdout and exits 0 always;
  it is a standalone tool a user can run directly, which is why it lives outside `hook-lint.sh`.

Advisory rules run in `post` mode: they surface on stderr with exit 2, which feeds the model
without undoing the write. They are advisory precisely because each has a legitimate
counter-example — an eagerly-loaded route can be correct for a shell route, and `FormBuilder`
is correct when extending an existing Reactive Forms screen.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== NG101-NG106 (advisory, post mode) =="
###############################################################################

cd "$V22" || exit 1
mkdir -p "$V22/src/app"

post_file() { # <path> <content> — write to disk, then lint in post mode
  printf '%s' "$2" > "$1"
  run "$(write_json "$1" "$2")" bash "$HOOK_LINT" post
}

# NG101 eager feature route
post_file "$V22/src/app/app.routes.ts" 'export const routes: Routes = [
  { path: "admin", component: AdminPageComponent },
];'
expect N101-eager-route 2 err "NG101"

post_file "$V22/src/app/app.routes.ts" 'export const routes: Routes = [
  { path: "admin", loadComponent: () => import("./admin/admin-page").then((m) => m.AdminPage) },
];'
expect N101-lazy-ok 0 none ""

# NG102 FormBuilder where Signal Forms are available
post_file "$V22/src/app/f.ts" 'export class F { form = this.fb.group({ name: [""] }); }'
expect N102-formbuilder 2 err "NG102"

# ...silent on v21, where Signal Forms are not stable
cd "$V21" || exit 1; mkdir -p "$V21/src/app"
post_file "$V21/src/app/f.ts" 'export class F { form = this.fb.group({ name: [""] }); }'
expect N102-silent-on-v21 0 none ""
cd "$V22" || exit 1

# NG103 providedIn root where @Service exists
post_file "$V22/src/app/s.ts" '@Injectable({ providedIn: "root" })
export class S {}'
expect N103-providedin 2 err "NG103"

# NG104 static img without ngSrc
post_file "$V22/src/app/a.html" '<img src="/assets/hero.png" alt="Hero">'
expect N104-plain-img 2 err "NG104"

post_file "$V22/src/app/a.html" '<img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">'
expect N104-ngsrc-ok 0 none ""

# A data-bound src is not a static image
post_file "$V22/src/app/a.html" '<img [src]="avatarUrl()" alt="Avatar">'
expect N104-bound-src-ok 0 none ""

# NG105 direct DOM access in a component
post_file "$V22/src/app/a.component.ts" 'export class A { init() { document.getElementById("x"); } }'
expect N105-document-access 2 err "NG105"

# NG106 HTTP call inside a component
post_file "$V22/src/app/b.component.ts" 'export class B {
  private http = inject(HttpClient);
  load() { return this.http.get("/api/items"); }
}'
expect N106-http-in-component 2 err "NG106"

# A service making HTTP calls is correct
post_file "$V22/src/app/b.service.ts" 'export class BService {
  private http = inject(HttpClient);
  load() { return this.http.get("/api/items"); }
}'
expect N106-http-in-service-ok 0 none ""

# analyze_quality.sh runs standalone and always exits 0
QA="$ROOT/scripts/analyze_quality.sh"
run "" bash "$QA" "$V22/src/app/b.component.ts"
Q1_OK=0; [ "$CODE" = "0" ] || Q1_OK=1
check Q1-analyze-exit0 "analyze_quality.sh exits 0" "$Q1_OK"

run "" bash "$QA" /nonexistent/path.ts
Q2_OK=0; [ "$CODE" = "0" ] || Q2_OK=1
check Q2-analyze-missing-file "analyze_quality.sh fails open on a missing file" "$Q2_OK"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: every N10* and Q* check FAILs.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/analyze_quality.sh`:

```bash
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
is_component = ".component." in base or "@Component" in src
findings = []

code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
code = re.sub(r"(^|[^:])//[^\n]*", r"\1", code)
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
```

Add to `scripts/hook-lint.sh` after `check_ng018`:

```bash
check_ng101() {
  [ "$EXT" = "ts" ] || return 0
  printf '%s' "$FILE_PATH" | grep -qE 'routes?\.ts$|\.routes\.ts$|routing' || return 0
  if grep -qE '\bcomponent:[[:space:]]*[A-Z]' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG101: Route declared with an eager `component:` reference.
   💡 Fix: Lazy-load it so the feature leaves the initial bundle:
     { path: "admin", loadComponent: () => import("./admin/admin-page").then((m) => m.AdminPage) }
   Eager routes are defensible for a small shell route — for a feature screen they are almost always a mistake.
   See: performance-and-zoneless skill'
  fi
}

check_ng102() {
  gate signal_forms_available || return 0
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  if grep -qE '\bFormBuilder\b|\bnew[[:space:]]+FormGroup\b|\bfb\.group\(' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG102: Reactive Forms in a workspace where Signal Forms are stable.
   💡 Fix: Prefer Signal Forms for new forms on v22+ — form state is signals, so it composes with computed() and needs no valueChanges subscription. Staying on Reactive Forms is correct when extending an existing Reactive Forms screen; starting a new one there is not.
   See: angular-essentials skill'
  fi
}

check_ng103() {
  gate service_decorator_available || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE "@Injectable\([[:space:]]*\{[^}]*providedIn:[[:space:]]*['\"]root['\"]" "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG103: `@Injectable({ providedIn: "root" })`.
   💡 Fix: On v22+ use the `@Service` decorator — it is the same root-provided singleton with less ceremony:
     @Service()
     export class ItemStore {}
   See: state-management skill'
  fi
}

check_ng104() {
  if grep -qE '<img[^>]+[[:space:]]src=["'"'"']' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG104: Static `<img src>` without NgOptimizedImage.
   💡 Fix: Import NgOptimizedImage and use `ngSrc` with explicit width/height (or `fill`):
     <img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">
   It adds lazy loading, srcset generation, and priority hints, and it prevents layout shift.
   See: performance-and-zoneless skill'
  fi
}

check_ng105() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  printf '%s' "$FILE_PATH" | grep -qE '\.component\.ts$|\.ts$' || return 0
  grep -qE '@Component|\.component\.ts$' "$CODE_PATH" 2>/dev/null \
    || printf '%s' "$FILE_PATH" | grep -qE '\.component\.ts$' || return 0
  if grep -qE '\b(document|window)\.[a-zA-Z]' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG105: Direct `document` / `window` access in a component.
   💡 Fix: Use `viewChild()` signal queries for element access, `afterRenderEffect()` for DOM work that must run post-render, and inject `DOCUMENT` rather than reaching for the global. Direct globals break SSR, where neither exists.
   See: component-architecture skill'
  fi
}

check_ng106() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  local out
  out=$(bash "$(dirname "$0")/analyze_quality.sh" "$CONTENT_PATH" 2>/dev/null)
  # analyze_quality.sh inspects content; component-ness is decided by the real
  # filename, so re-check it here rather than trusting the temp file's name.
  printf '%s' "$FILE_PATH" | grep -qE '\.component\.ts$' || \
    grep -q '@Component' "$CODE_PATH" 2>/dev/null || return 0
  if [ -n "$out" ]; then
    add "⚠️  NG106: Component complexity.
   $out
   See: component-architecture skill"
  fi
}
```

`check_ng106` passes `$CONTENT_PATH` rather than `$CODE_PATH` because
`analyze_quality.sh` strips comments itself and must stay usable standalone on a real file.

Fill in the `post` branch of the driver:

```bash
else
  check_ng101
  check_ng102
  check_ng103
  check_ng104
  check_ng105
  check_ng106
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 96 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/analyze_quality.sh
git add scripts/analyze_quality.sh scripts/hook-lint.sh tests/run-tests.sh
git commit -m "feat: NG101-NG106 advisory rules and standalone quality analyzer"
```

---

### Task 9: `angular-essentials` skill and the rule-drift test

The spine skill, plus the test that keeps the three copies of the rule set — `hook-lint.sh`,
`subagent-rules.sh`, and the skills — from diverging. Written together because the drift
test is what makes the skill trustworthy.

**Files:**
- Create: `skills/angular-essentials/SKILL.md`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: rule IDs defined in `scripts/hook-lint.sh`.
- Produces: the skill-file conventions every later skill follows —
  frontmatter keys `name`, `description`, `file_patterns`, `auto_suggest`;
  an `## RULES — Follow these with no exceptions` section as the first heading after the title;
  every rule ID mentioned in a skill must exist in `hook-lint.sh`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== skills =="
###############################################################################

S1_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S1_OK=1
import os, re, sys, glob
root = sys.argv[1]
skills = sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md")))
assert skills, "no skills found"
for p in skills:
    txt = open(p, encoding="utf-8").read()
    assert txt.startswith("---\n"), p + ": missing frontmatter"
    fm = txt.split("---", 2)[1]
    for key in ("name:", "description:", "file_patterns:", "auto_suggest:"):
        assert key in fm, "%s: frontmatter missing %s" % (p, key)
    name = re.search(r"^name:\s*(\S+)", fm, re.M).group(1)
    assert name == os.path.basename(os.path.dirname(p)), \
        "%s: frontmatter name %r != directory name" % (p, name)
    assert "RULES — Follow these with no exceptions" in txt, p + ": missing RULES section"
PY
check S1-skill-shape "every SKILL.md has valid frontmatter and a RULES section" "$S1_OK"

S2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S2_OK=1
import os, re, sys, glob
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
defined = set(re.findall(r"check_(ng\d{3})\s*\(\)", lint))
defined = {d.upper() for d in defined}
guard = open(os.path.join(root, "scripts", "bash-guard.sh"), encoding="utf-8").read()
defined |= set(re.findall(r"\b(BG\d{3})\b", guard))
referenced = set()
for p in glob.glob(os.path.join(root, "skills", "*", "SKILL.md")):
    referenced |= set(re.findall(r"\b((?:NG|BG)\d{3})\b", open(p, encoding="utf-8").read()))
sub = open(os.path.join(root, "scripts", "subagent-rules.sh"), encoding="utf-8").read()
referenced |= set(re.findall(r"\b((?:NG|BG)\d{3})\b", sub))
orphans = sorted(referenced - defined)
assert not orphans, "rule IDs referenced but not implemented: " + ", ".join(orphans)
PY
check S2-no-orphan-rule-ids "every rule ID cited in a skill or subagent-rules exists in a script" "$S2_OK"

S3_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S3_OK=1
import os, re, sys
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
pre = {d.upper() for d in re.findall(r"check_(ng0\d{2})\s*\(\)", lint)}
sub = open(os.path.join(root, "scripts", "subagent-rules.sh"), encoding="utf-8").read()
cited = set(re.findall(r"\b(NG0\d{2})\b", sub))
missing = sorted(pre - cited)
assert not missing, "blocking rules absent from the subagent rule set: " + ", ".join(missing)
PY
check S3-subagent-covers-blocking "every blocking NG0xx rule appears in subagent-rules.sh" "$S3_OK"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: S1 FAILs — `skills/` is empty, so the assertion `assert skills` trips.
(S2 and S3 may already pass; S1 is the gate.)

- [ ] **Step 3: Write minimal implementation**

Create `skills/angular-essentials/SKILL.md` with exactly this frontmatter:

```markdown
---
name: angular-essentials
description: MANDATORY for ALL Angular code changes. Invoke before writing any .ts or .html file in an Angular workspace.
file_patterns:
  - "**/*.ts"
  - "**/*.html"
auto_suggest: true
---
```

Body requirements — the numbered RULES list must be exactly these ten, in this order,
because `subagent-rules.sh` mirrors them and test S3 enforces the correspondence:

```markdown
# Angular Essentials

## RULES — Follow these with no exceptions

1. **Never write `standalone: true`** — standalone is the default since v20 (NG001)
2. **Never create an `@NgModule`** — use standalone components and route-level providers (NG002)
3. **Use native control flow** `@if` / `@for` / `@switch`, never `*ngIf` / `*ngFor` / `*ngSwitch` (NG003)
4. **Use `inject()`**, never constructor-parameter injection (NG004)
5. **Use `input()` / `output()` / `model()`**, never `@Input()` / `@Output()` decorators (NG005)
6. **Never set `changeDetection: OnPush`** — it is the default in v22 (NG006)
7. **Never use `any`** — use `unknown` and narrow it (NG007)
8. **Use `[class.x]` / `[style.x]` bindings**, never `ngClass` / `ngStyle` (NG008)
9. **Use the `host` object**, never `@HostBinding` / `@HostListener` (NG009)
10. **Never bind `[innerHTML]` and never call `bypassSecurityTrust*`** (NG014, NG015)
```

Then one `##` section per rule, each containing a **Bad:** and a **Good:** fenced
`typescript` or `html` block drawn from the fix text already written into the
corresponding check function in `hook-lint.sh` — the hook message and the skill section
must teach the same fix.

Close with a `## Reference` section stating that Angular's own agent skill
(`angular/angular` → `skills/dev-skills/angular-developer/`), its MCP server
(`npx @angular/cli mcp`), and `angular.dev/llms.txt` are the authority for API detail,
and that this skill covers only the enforced rules. Do not restate reference documentation.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-tests.sh`
Expected: `Results: 99 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add skills/angular-essentials tests/run-tests.sh
git commit -m "feat: angular-essentials skill and rule-drift tests"
```

---

### Task 10: Reactivity and architecture skills

**Files:**
- Create: `skills/signals-essentials/SKILL.md`
- Create: `skills/rxjs-interop/SKILL.md`
- Create: `skills/component-architecture/SKILL.md`
- Create: `skills/state-management/SKILL.md`

**Interfaces:**
- Consumes: the skill-file conventions and drift tests from Task 9.
- Produces: four skills. No new test code — tests S1–S3 already cover every file added to `skills/`.

- [ ] **Step 1: Run the existing tests to confirm the baseline is green**

Run: `bash tests/run-tests.sh`
Expected: `Results: 99 passed, 0 failed`

- [ ] **Step 2: Write `skills/signals-essentials/SKILL.md`**

Frontmatter:

```markdown
---
name: signals-essentials
description: MANDATORY for ALL signal and reactivity work. Invoke before writing signal, computed, linkedSignal, effect, or resource.
file_patterns:
  - "**/*.ts"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Derived state is `computed()`** — never an `effect()` that writes a signal (NG012)
2. **State derived from other signals but independently writable is `linkedSignal()`**
3. **`effect()` is only for leaving the reactive graph** — logging, third-party DOM, analytics
4. **Never call `.mutate()`** — signals compare by reference; use `set()` or `update()` (NG011)
5. **`update()` takes a pure transform** — return a new value, never mutate the argument
6. **Read signals in templates by calling them** — `count()`, not `count`
7. **Use `untracked()`** when reading a signal inside a reactive context without depending on it
8. **Async state is `resource()` / `rxResource()` / `httpResource()`**, not an effect plus a signal
```

The skill's centrepiece is a decision table, since choosing the wrong primitive is the
single most common AI failure mode in modern Angular:

| Need | Primitive |
|---|---|
| Independent writable state | `signal()` |
| Value derived purely from other signals | `computed()` |
| Derived, but locally overridable and reset when its source changes | `linkedSignal()` |
| Async data keyed on other signals | `resource()` / `httpResource()` |
| A side effect outside the reactive graph | `effect()` |

Include a worked **Bad/Good** pair for the dominant mistake — an `effect()` that recomputes
a total into a signal, rewritten as a `computed()` — and explain *why*: the effect version
runs after change detection, produces one extra frame of stale UI, and can re-enter.

- [ ] **Step 3: Write `skills/rxjs-interop/SKILL.md`**

Frontmatter:

```markdown
---
name: rxjs-interop
description: MANDATORY for ALL RxJS work in an Angular workspace. Invoke before writing subscribe, toSignal, toObservable, or any Observable pipeline.
file_patterns:
  - "**/*.ts"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Prefer not subscribing** — use the `async` pipe, `toSignal()`, or `httpResource()`
2. **Every manual `.subscribe()` needs teardown** — `takeUntilDestroyed()` (NG010)
3. **`toSignal()` at the boundary** — convert to signals as early as possible
4. **`toObservable()` only when a real RxJS operator is needed** — debounce, retry, concurrency
5. **Never nest subscribes** — use `switchMap` / `concatMap` / `mergeMap`
6. **`switchMap` for cancel-previous** (typeahead), **`concatMap` for ordered**, **`mergeMap` for parallel**
7. **Never `subscribe()` inside a `computed()` or `effect()`**
```

Include a "when RxJS is still the right tool" section — event streams with time semantics
(debounce, throttle, retry with backoff, race), and coordination across multiple async
sources. This matters because the reflex to convert everything to signals produces worse
code for genuinely stream-shaped problems.

- [ ] **Step 4: Write `skills/component-architecture/SKILL.md`**

Frontmatter:

```markdown
---
name: component-architecture
description: MANDATORY for ALL component design decisions. Invoke before creating a component or adding logic to an existing one.
file_patterns:
  - "**/*.component.ts"
  - "**/*.html"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Components render; services decide** — no HTTP calls in a component (NG106)
2. **No direct `document` / `window`** — use `viewChild()`, `afterRenderEffect()`, inject `DOCUMENT` (NG105)
3. **Presentational components take inputs and emit outputs** — they inject nothing but presentation helpers
4. **One container per screen** — it orchestrates; its children render
5. **Past ~200 lines or ~8 inputs, split the component** (NG106)
6. **Validation and transformation belong in the service or a pure function**, never inline in a template
7. **Prefer a directive over a component** when adding behaviour to an existing element
8. **Templates hold no logic** — extract to a `computed()` or a method
```

Include a Bad/Good pair showing a component that injects `HttpClient`, holds loading and
error flags, and transforms the response inline — rewritten as a service exposing an
`httpResource()` with the component reading `.value()`, `.isLoading()`, and `.error()`.
This is the documented top production anti-pattern; it deserves the fullest treatment.

- [ ] **Step 5: Write `skills/state-management/SKILL.md`**

Frontmatter:

```markdown
---
name: state-management
description: MANDATORY before introducing shared state or a state library. Invoke before adding a store, a state service, or NgRx.
file_patterns:
  - "**/*.store.ts"
  - "**/*.service.ts"
  - "**/*.ts"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Start with a `signal()` in the component** — most state never needs to leave it
2. **Escalate to a root-provided service with signals** only when two components need the same state
3. **Escalate to a SignalStore** only when you need entities, effects, and devtools together
4. **Never reach for NgRx by default** — it is the answer to a problem most apps do not have
5. **Expose state as readonly** — `readonly items = this._items.asReadonly()`
6. **Mutations go through named methods**, never by writing the signal from outside
7. **On v22+, use `@Service`** rather than `@Injectable({ providedIn: "root" })` (NG103)
8. **Derived state is `computed()` in the store**, never recomputed in each consumer
```

The centrepiece is the escalation ladder with an explicit "you have gone far enough"
marker at each rung, and the cost of each rung stated plainly. Angular ships no guidance
here at all, which is exactly why models default to whatever their training data
over-represents.

- [ ] **Step 6: Run tests**

Run: `bash tests/run-tests.sh`
Expected: `Results: 99 passed, 0 failed` — S1 now validates five skills, S2 confirms
every cited rule ID exists.

- [ ] **Step 7: Commit**

```bash
git add skills/signals-essentials skills/rxjs-interop skills/component-architecture skills/state-management
git commit -m "feat: reactivity and architecture skills"
```

---

### Task 11: Data, testing, performance, and structure skills

**Files:**
- Create: `skills/data-loading/SKILL.md`
- Create: `skills/testing-essentials/SKILL.md`
- Create: `skills/performance-and-zoneless/SKILL.md`
- Create: `skills/project-structure/SKILL.md`

**Interfaces:**
- Consumes: skill conventions from Task 9.
- Produces: the final four skills, bringing the total to nine.

- [ ] **Step 1: Write `skills/data-loading/SKILL.md`**

Frontmatter:

```markdown
---
name: data-loading
description: MANDATORY for ALL HTTP and async data work. Invoke before writing HttpClient calls, interceptors, resource, or httpResource.
file_patterns:
  - "**/*.service.ts"
  - "**/*.ts"
auto_suggest: true
---
```

RULES list:

```markdown
1. **`httpResource()` for reads keyed on signals** — it tracks, cancels, and exposes loading and error state
2. **`HttpClient` directly only for commands** — POST/PUT/DELETE, or one-shot calls
3. **Never fetch in a component** (NG106)
4. **Independent requests run in parallel** — never `await` them in sequence
5. **Interceptors are functions**, registered via `withInterceptors([...])`
6. **Handle errors at the boundary** — an interceptor for cross-cutting concerns, `.error()` for per-view state
7. **Never subscribe to an HTTP call without teardown** (NG010)
8. **`resource()` for non-HTTP async**, `rxResource()` when the source is an Observable
```

Include a decision table for `httpResource` / `resource` / `rxResource` / `HttpClient`, and
a Bad/Good pair on the request-waterfall anti-pattern: three sequential `await`s rewritten
to run concurrently. Note that `resource`, `rxResource`, and `httpResource` are stable as
of v22 and that the earlier subscription leak in `rxResource` was fixed there.

- [ ] **Step 2: Write `skills/testing-essentials/SKILL.md`**

Frontmatter:

```markdown
---
name: testing-essentials
description: MANDATORY for ALL Angular test files. Invoke before writing any .spec.ts file.
file_patterns:
  - "**/*.spec.ts"
  - "**/*.test.ts"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Vitest is the runner on v21+** — `vi.fn()`, `vi.spyOn()`, never Jasmine APIs (NG018)
2. **TestBed is unchanged** — the runner swapped; the Angular testing API did not
3. **Test behaviour through the template**, not method calls on the instance
4. **Use component harnesses** for anything with a public interaction surface
5. **`RouterTestingHarness` for navigation**, never a hand-rolled router mock
6. **Never test framework behaviour** — that inputs bind or outputs emit is Angular's test, not yours
7. **`provideHttpClientTesting()` for HTTP** — assert on the request, not on a stubbed service
8. **Run non-interactively** — `ng test --run` / `--watch=false` (BG004)
```

Include the Jasmine→Vitest migration table (`jasmine.createSpy`→`vi.fn`,
`spyOn`→`vi.spyOn`, `jasmine.objectContaining`→`expect.objectContaining`), because a model
carrying pre-v21 habits will otherwise write Karma-era tests into a Vitest workspace.

- [ ] **Step 3: Write `skills/performance-and-zoneless/SKILL.md`**

Frontmatter:

```markdown
---
name: performance-and-zoneless
description: MANDATORY for zoneless, change detection, and bundle work. Invoke before touching change detection, defer blocks, route loading, or images.
file_patterns:
  - "**/*.ts"
  - "**/*.html"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Never set `OnPush` explicitly on v22+** — it is the default (NG006)
2. **Never import `zone.js` in a zoneless workspace** (NG017)
3. **In zoneless apps, state changes must go through signals** — a plain field mutation will not schedule a render
4. **Lazy-load every feature route** (NG101)
5. **`@defer` for below-the-fold and heavy components**, with a `@placeholder`
6. **Every `@for` needs `track`** (NG013)
7. **`NgOptimizedImage` for every static image** (NG104)
8. **Measure before optimizing** — `ng build --stats-json`, then the bundle analyzer
```

Include a section on the zoneless failure mode specifically: code that worked under
zone.js because *any* async callback triggered change detection, and silently stops
updating once zone.js is removed. This is the migration bug that costs the most time.

- [ ] **Step 4: Write `skills/project-structure/SKILL.md`**

Frontmatter:

```markdown
---
name: project-structure
description: MANDATORY for file naming and project layout. Invoke before creating files or directories in an Angular workspace.
file_patterns:
  - "**/*.ts"
  - "**/angular.json"
auto_suggest: true
---
```

RULES list:

```markdown
1. **Hyphenate filenames** — `user-profile.ts` for `UserProfile`
2. **Name by intent, not role** — v20+ style drops the `.component` / `.service` suffix requirement
3. **Organize by feature, never by type** — no top-level `components/` or `services/` directories
4. **One concept per file**
5. **Component files share a base name** — `.ts`, `.html`, `.css` together in one directory
6. **`src/` holds all UI code**, bootstrap in `src/main.ts`
7. **`protected` for template-only members**, `readonly` for Angular-initialized ones
8. **Name handlers for the action, not the event** — `saveUser()`, not `handleClick()`
```

Note that this skill follows Angular's official style guide and link to
`angular.dev/style-guide` plus `naming-conventions.md` in Angular's own agent skill rather
than restating them.

- [ ] **Step 5: Run tests**

Run: `bash tests/run-tests.sh`
Expected: `Results: 99 passed, 0 failed` — S1 now validates all nine skills.

- [ ] **Step 6: Commit**

```bash
git add skills/data-loading skills/testing-essentials skills/performance-and-zoneless skills/project-structure
git commit -m "feat: data, testing, performance, and structure skills"
```

---

### Task 12: Agents, documentation, and release

**Files:**
- Create: `agents/angular-architecture-review.md`
- Create: `agents/signals-review.md`
- Create: `agents/angular-project-structure.md`
- Create: `README.md`
- Create: `CLAUDE.md.template`
- Create: `CHANGELOG.md`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: every rule ID and skill name from Tasks 2–11.
- Produces: the shipped plugin. The README's rule tables become the documented contract,
  and test R2 keeps them synchronized with the scripts.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-tests.sh` before the Results block:

```bash
###############################################################################
echo
echo "== docs and agents =="
###############################################################################

R1_OK=0
for f in README.md CLAUDE.md.template CHANGELOG.md; do
  [ -s "$ROOT/$f" ] || R1_OK=1
done
check R1-docs-exist "README, CLAUDE.md.template, CHANGELOG are present and non-empty" "$R1_OK"

R2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || R2_OK=1
import os, re, sys
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
guard = open(os.path.join(root, "scripts", "bash-guard.sh"), encoding="utf-8").read()
implemented = {d.upper() for d in re.findall(r"check_(ng\d{3})\s*\(\)", lint)}
implemented |= set(re.findall(r"\b(BG\d{3})\b", guard))
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
documented = set(re.findall(r"\b((?:NG|BG)\d{3})\b", readme))
missing = sorted(implemented - documented)
assert not missing, "rules implemented but undocumented in README: " + ", ".join(missing)
PY
check R2-readme-documents-every-rule "every implemented rule ID appears in the README" "$R2_OK"

R3_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || R3_OK=1
import os, re, sys, glob
root = sys.argv[1]
agents = sorted(glob.glob(os.path.join(root, "agents", "*.md")))
assert len(agents) == 3, "expected 3 agents, got %d" % len(agents)
for p in agents:
    txt = open(p, encoding="utf-8").read()
    assert txt.startswith("---\n"), p + ": missing frontmatter"
    fm = txt.split("---", 2)[1]
    for key in ("name:", "description:", "tools:"):
        assert key in fm, "%s: frontmatter missing %s" % (p, key)
    assert "Write" not in fm.split("tools:")[1].split("\n")[0], \
        p + ": review agents must be read-only"
PY
check R3-agents-readonly "3 agents, valid frontmatter, no write tools" "$R3_OK"

R4_OK=0
grep -q '.angular-guide-project.json' "$ROOT/CLAUDE.md.template" 2>/dev/null || R4_OK=1
check R4-template-gitignore "CLAUDE.md.template tells users to gitignore the profile cache" "$R4_OK"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-tests.sh`
Expected: R1–R4 FAIL — none of the documentation or agent files exist.

- [ ] **Step 3: Write the three agents**

Each is read-only. `agents/angular-architecture-review.md`:

```markdown
---
name: angular-architecture-review
description: Read-only auditor for Angular component and service boundaries. Dispatch after implementing a feature to catch logic that has accumulated in the wrong layer.
tools: Read, Grep, Glob
---
```

Body: a checklist covering HTTP calls in components, components over ~200 lines or ~8
inputs, presentational components that inject services, validation logic inline in
templates, direct `document`/`window` access, and state duplicated across components
instead of shared through a service. For each finding it reports file, line, and the
`component-architecture` rule it violates. It reports; it never edits.

`agents/signals-review.md`:

```markdown
---
name: signals-review
description: Read-only reviewer for Angular signal usage. Dispatch after writing signal, computed, linkedSignal, or effect code.
tools: Read, Grep, Glob
---
```

Body: a checklist covering effects that write signals, `computed()` that should be
`linkedSignal()`, `linkedSignal()` that should be `computed()`, signals read without
calling them, missing `untracked()` where a read should not create a dependency, and
async state hand-rolled from an effect plus a signal instead of a `resource()`.

`agents/angular-project-structure.md`:

```markdown
---
name: angular-project-structure
description: Read-only auditor for Angular project layout and naming against the official style guide.
tools: Read, Grep, Glob
---
```

Body: a checklist covering hyphenated filenames, feature-based directories rather than
type-based, one concept per file, co-located component files, `src/main.ts` bootstrap, and
`protected`/`readonly` member modifiers.

- [ ] **Step 4: Write the documentation**

`README.md` must contain, in order:

1. **What this is** — one paragraph, and an explicit statement that it *complements*
   Angular's official agent skills and CLI MCP server rather than replacing them. Link to
   `angular/angular` `skills/dev-skills/`, `npx @angular/cli mcp`, and `angular.dev/llms.txt`.
2. **Why it exists** — Angular's skills are advisory and load only when the model elects to;
   these hooks fire on every Write, Edit, and Bash, including inside subagents, which
   inherit no skills.
3. **Requirements** — Angular v20+, bash, python3. No `jq`.
4. **Installation** — `/plugin marketplace add j-morgan6/angular-guide`, then install
   through the plugin manager. State plainly that there is no install script and that
   nothing is written to `~/.claude/settings.json`.
5. **The 9 skills** — a table of name, when it triggers, what it covers.
6. **The 32 rules** — three tables (BG001–BG006, NG001–NG018, NG101–NG106), each row giving
   the ID, what it catches, the fix, and the version gate. Test R2 fails the build if any
   implemented rule is missing here.
7. **Version awareness** — the `.angular-guide-project.json` schema and the rule that an
   unknown version skips gated rules rather than guessing.
8. **Running the tests** — `bash tests/run-tests.sh`.
9. **Tuning** — how to disable a rule by editing `hooks/hooks.json`, and a note that
   NG010 is the likeliest false-positive source given long-lived root-service subscriptions.

`CLAUDE.md.template` — project-level rules for a consuming Angular repo: the condensed
rule list, a pointer to the skills, and an explicit instruction to add
`.angular-guide-project.json` to `.gitignore` (it is a machine-local cache and must not be
committed).

`CHANGELOG.md` — a `## 1.0.0` entry dated 2026-09-06 listing the nine skills, thirty-two
rules, three agents, and the version-aware detection.

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run-tests.sh`
Expected: `Results: 103 passed, 0 failed`

- [ ] **Step 6: Verify the plugin loads end-to-end**

Run:
```bash
python3 -c "import json; json.load(open('.claude-plugin/plugin.json')); json.load(open('hooks/hooks.json')); print('manifests OK')"
ls -l scripts/*.sh | awk '{print $1, $NF}'
```
Expected: `manifests OK`, and every script shows an executable bit (`-rwxr-xr-x`).

- [ ] **Step 7: Commit**

```bash
git add agents README.md CLAUDE.md.template CHANGELOG.md tests/run-tests.sh
git commit -m "feat: review agents, documentation, and 1.0.0 release notes"
```
