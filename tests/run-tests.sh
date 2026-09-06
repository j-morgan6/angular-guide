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
