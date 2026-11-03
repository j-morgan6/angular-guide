#!/usr/bin/env python3
"""ag_profile.py — the cached Angular workspace profile every rule is gated on.

Profiles live in the plugin's data directory (CLAUDE_PLUGIN_DATA, falling
back to $XDG_CACHE_HOME/angular-guide), keyed by workspace root, so nothing
is ever written into the user's repository. Any hook can resolve a profile
from a starting directory: a missing profile is detected on first use, and
one older than package.json, angular.json, a lockfile or tsconfig.json is
re-detected, so an `ng update` mid-session takes effect immediately.

Never guesses a version — unknown means every version gate stays false.
Fails open: any error resolves to "no profile" and the rules stay off.

Usage:
  ag_profile.py path <root>       print where <root>'s profile is cached
  ag_profile.py resolve <start>   print the profile path for <start>, detecting
                                  or refreshing it first; nothing if <start> is
                                  not inside an Angular workspace
  ag_profile.py session <start>   SessionStart: also search downward for a
                                  monorepo's workspace, always re-detect, and
                                  print a summary
"""

import datetime
import hashlib
import json
import os
import re
import sys

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Files whose change can change the profile.
INPUTS = ("package.json", "angular.json", "tsconfig.json", "package-lock.json",
          "pnpm-lock.yaml", "yarn.lock", "bun.lock")


def disabled_rules():
    """Rule IDs turned off by the user or the project.

    CLAUDE_PLUGIN_OPTION_DISABLED_RULES carries the plugin's `disabled_rules`
    userConfig option (per user); ANGULAR_GUIDE_DISABLED_RULES can be set in
    a project's committed .claude/settings.json `env` (per team). Either is
    a comma- or space-separated list of IDs, case-insensitive.
    """
    raw = " ".join(os.environ.get(k, "") for k in
                   ("CLAUDE_PLUGIN_OPTION_DISABLED_RULES", "ANGULAR_GUIDE_DISABLED_RULES"))
    return {r.upper() for r in re.findall(r"\b(?:ng|bg)\d{3}\b", raw, re.I)}


def data_dir():
    d = os.environ.get("CLAUDE_PLUGIN_DATA")
    if d:
        return d
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(cache, "angular-guide")


def plugin_version():
    try:
        with open(os.path.join(PLUGIN_ROOT, "VERSION")) as f:
            return f.read().strip() or "unknown"
    except Exception:
        return "unknown"


def profile_path(root):
    key = hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:16]
    return os.path.join(data_dir(), "profiles", key + ".json")


def index_path():
    return os.path.join(data_dir(), "roots.json")


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


# ------------------------------------------------------------- root lookup

def ancestors(start):
    d = os.path.realpath(start)
    while True:
        yield d
        parent = os.path.dirname(d)
        if parent == d:
            return
        d = parent


def find_root_up(start):
    for d in ancestors(start):
        if os.path.isfile(os.path.join(d, "angular.json")):
            return d if os.path.isfile(os.path.join(d, "package.json")) else None
    return None


def find_root_down(start, max_depth=6, max_matches=200):
    # A monorepo session started at the repo root has no angular.json above
    # it. Bounded in depth and match count so it stays fast; node_modules and
    # .git are pruned since an angular.json under either is never a real
    # workspace root. Several matches at the shallowest depth is genuinely
    # ambiguous — return nothing rather than guess.
    start = os.path.realpath(start)
    base = start.count(os.sep)
    found = []
    for dirpath, dirnames, filenames in os.walk(start):
        depth = dirpath.count(os.sep) - base
        dirnames[:] = [] if depth >= max_depth - 1 else \
            [d for d in dirnames if d not in ("node_modules", ".git")]
        if "angular.json" in filenames:
            found.append(dirpath)
            if len(found) > max_matches:
                return None
    if not found:
        return None
    shallowest = min(p.count(os.sep) for p in found)
    top = [p for p in found if p.count(os.sep) == shallowest]
    if len(top) != 1 or not os.path.isfile(os.path.join(top[0], "package.json")):
        return None
    return top[0]


def lookup_index(start):
    # Directories where a session found a workspace by searching downward.
    idx = load_json(index_path(), {})
    for d in ancestors(start):
        root = idx.get(d)
        if root and os.path.isfile(os.path.join(root, "angular.json")):
            return root
    return None


def record_index(start, root):
    idx = load_json(index_path(), {})
    idx[os.path.realpath(start)] = root
    write_json_atomic(index_path(), idx)


def resolve_root(start, search_down=False):
    root = find_root_up(start) or lookup_index(start)
    if root is None and search_down:
        root = find_root_down(start)
        if root:
            record_index(start, root)
    return root


# --------------------------------------------------------------- detection

def major_of(spec):
    m = re.search(r"(\d+)", str(spec or ""))
    return int(m.group(1)) if m else None


def version_from_package_lock(txt):
    # npm lockfiles are JSON; parse structurally first, regex only as a
    # fallback for a malformed/unusual file.
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


def detect(root):
    pkg = load_json(os.path.join(root, "package.json"), {})
    ng = load_json(os.path.join(root, "angular.json"), {})

    deps = {}
    deps.update(pkg.get("dependencies") or {})
    deps.update(pkg.get("devDependencies") or {})

    # Version: package.json range first, then the lockfile's resolved version.
    version_spec = deps.get("@angular/core") or deps.get("@angular/cli") or ""
    major = major_of(version_spec)
    version = str(version_spec).lstrip("^~>=< ") or "unknown"

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
                resolved = parser(open(p, encoding="utf-8", errors="ignore").read())
            except Exception:
                resolved = None
            if resolved:
                major = int(re.match(r"(\d+)", resolved).group(1))
                version = resolved
                break

    known = major is not None

    def dep(*names):
        return any(n in deps for n in names)

    # zoneless: explicit provider wins, else absence of the zone.js dependency
    zoneless = not dep("zone.js")
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, "src")):
        dirnames[:] = [d for d in dirnames if d != "node_modules"]
        if any(fn.endswith(".ts") and "provideZonelessChangeDetection" in
               open(os.path.join(dirpath, fn), encoding="utf-8", errors="ignore").read()
               for fn in filenames):
            zoneless = True
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

    ssr = dep("@angular/ssr") or bool(re.search(r'"(ssr|server|prerender)"\s*:', json.dumps(ng)))

    tsconfig_strict = False
    try:
        raw = open(os.path.join(root, "tsconfig.json"), encoding="utf-8").read()
        raw = re.sub(r"//.*", "", raw)
        raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
        raw = re.sub(r",(\s*[}\]])", r"\1", raw)
        tsconfig_strict = bool((json.loads(raw).get("compilerOptions") or {}).get("strict"))
    except Exception:
        pass

    return {
        "plugin_version": plugin_version(),
        "detected_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "workspace_root": root,
        "angular_version": version if known else "unknown",
        "angular_major": major if known else "unknown",
        # gates: false whenever the version is unknown, never guessed
        "standalone_default": bool(known and major >= 20),
        "onpush_default": bool(known and major >= 22),
        "signal_forms_available": bool(known and major >= 22),
        "service_decorator_available": bool(known and major >= 22),
        "zoneless": zoneless,
        "test_runner": test_runner,
        "ssr": bool(ssr),
        "state_lib": state_lib,
        "package_manager": package_manager,
        "typescript_strict": tsconfig_strict,
        "projects": sorted((ng.get("projects") or {}).keys()),
    }


def is_fresh(root, path):
    try:
        stamp = os.path.getmtime(path)
    except OSError:
        return False
    for name in INPUTS:
        p = os.path.join(root, name)
        if os.path.exists(p) and os.path.getmtime(p) > stamp:
            return False
    return load_json(path, {}).get("plugin_version") == plugin_version()


def ensure(start, search_down=False, force=False):
    """Return (profile_path, profile) for <start>, or (None, None)."""
    root = resolve_root(start, search_down)
    if root is None:
        return None, None
    path = profile_path(root)
    if force or not is_fresh(root, path):
        write_json_atomic(path, detect(root))
    return path, load_json(path, None)


def summary(path, profile):
    flags = [f for f, on in (("zoneless", profile["zoneless"]),
                             ("signal-forms", profile["signal_forms_available"]),
                             ("ssr", profile["ssr"])) if on]
    return "\n".join([
        "📐 angular-guide — Angular %s%s" % (
            profile["angular_version"], (" (" + ", ".join(flags) + ")") if flags else ""),
        "   tests: %s · state: %s · pm: %s · strict: %s" % (
            profile["test_runner"], profile["state_lib"], profile["package_manager"],
            str(profile["typescript_strict"]).lower()),
        "   profile: %s" % path,
    ])


def main(argv):
    if len(argv) != 3:
        return
    cmd, arg = argv[1], argv[2]
    if cmd == "path":
        print(profile_path(arg))
    elif cmd == "resolve":
        path, profile = ensure(arg)
        if profile:
            print(path)
    elif cmd == "session":
        path, profile = ensure(arg, search_down=True, force=True)
        if profile:
            print(summary(path, profile))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception:
        pass
    sys.exit(0)
