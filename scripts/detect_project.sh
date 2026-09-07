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

def version_from_package_lock(txt):
    # npm lockfiles are JSON; parse structurally first, regex only as a fallback
    # for a malformed/unusual file (fail open — never raise).
    try:
        data = json.loads(txt)
    except Exception:
        data = None
    if isinstance(data, dict):
        pkgs = data.get("packages")
        if isinstance(pkgs, dict):
            entry = pkgs.get("node_modules/@angular/core")
            if isinstance(entry, dict) and entry.get("version"):
                return str(entry["version"])
        deps = data.get("dependencies")
        if isinstance(deps, dict):
            entry = deps.get("@angular/core")
            if isinstance(entry, dict) and entry.get("version"):
                return str(entry["version"])
    m = re.search(r'"@angular/core"\s*:\s*\{[^}]*?"version"\s*:\s*"(\d+\.\d+\.\d+)"', txt, re.S)
    return m.group(1) if m else None

def version_from_yarn_lock(txt):
    # classic yarn.lock: '"@angular/core@^22.0.0":\n  version "22.0.1"'
    # yarn berry:        '"@angular/core@npm:^22.0.0":\n  version: 22.0.1'
    m = re.search(
        r'@angular/core@[^\n]*\n(?:[^\n]*\n){0,6}?\s*version:?\s*"?(\d+\.\d+\.\d+)"?',
        txt,
    )
    return m.group(1) if m else None

def version_from_inline_lock(txt):
    # pnpm-lock.yaml / bun.lock embed the resolved version inline, e.g.
    # "'@angular/core@22.0.1':" or "\"@angular/core@22.0.1\"".
    m = re.search(r'@angular/core["\'@:\s/]+(\d+\.\d+\.\d+)', txt)
    return m.group(1) if m else None

if major is None:
    lockfile_parsers = (
        ("package-lock.json", version_from_package_lock),
        ("pnpm-lock.yaml", version_from_inline_lock),
        ("yarn.lock", version_from_yarn_lock),
        ("bun.lock", version_from_inline_lock),
    )
    for lf, parser in lockfile_parsers:
        p = os.path.join(root, lf)
        if not os.path.exists(p):
            continue
        try:
            txt = open(p, encoding="utf-8", errors="ignore").read()
            resolved = parser(txt)
        except Exception:
            resolved = None
        if resolved:
            major = int(re.match(r"(\d+)", resolved).group(1))
            version = resolved
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
_found_provider = False
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
                _found_provider = True
                break
        except Exception:
            pass
    if _found_provider:
        break

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
