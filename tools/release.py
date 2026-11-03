#!/usr/bin/env python3
"""release.py — set the plugin version everywhere it appears, in one step.

Writes VERSION, the `version` in .claude-plugin/plugin.json and
.claude-plugin/marketplace.json, and renames CHANGELOG.md's
`## Unreleased` heading to `## <version> — <date>`. Everything else reads
the version from VERSION at runtime.

Usage:
  python3 tools/release.py <X.Y.Z> [--date YYYY-MM-DD] [--root <dir>]

Refuses (exit 1, nothing written) on a malformed version or when the
CHANGELOG has no `## Unreleased` section.
"""

import datetime
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fail(msg):
    sys.stderr.write("release.py: %s\n" % msg)
    return 1


def set_json_version(text, version, count):
    # Edit the text rather than re-serialising, so formatting is preserved.
    new, n = re.subn(r'("version"\s*:\s*")[^"]*(")', r"\g<1>%s\g<2>" % version, text)
    if n != count:
        raise ValueError("expected %d version field(s), found %d" % (count, n))
    return new


def main(argv):
    if not argv or argv[0].startswith("-"):
        return fail("usage: release.py <X.Y.Z> [--date YYYY-MM-DD] [--root <dir>]")
    version = argv[0]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        return fail("version must look like 1.2.3, got %r" % version)
    root = argv[argv.index("--root") + 1] if "--root" in argv else REPO
    date = argv[argv.index("--date") + 1] if "--date" in argv else datetime.date.today().isoformat()

    paths = {
        "VERSION": os.path.join(root, "VERSION"),
        "plugin": os.path.join(root, ".claude-plugin", "plugin.json"),
        "marketplace": os.path.join(root, ".claude-plugin", "marketplace.json"),
        "changelog": os.path.join(root, "CHANGELOG.md"),
    }
    try:
        text = {k: open(p, encoding="utf-8").read() for k, p in paths.items()}
        out = {
            "VERSION": version + "\n",
            "plugin": set_json_version(text["plugin"], version, 1),
            "marketplace": set_json_version(text["marketplace"], version, 1),
        }
    except (OSError, ValueError) as e:
        return fail(str(e))
    if "\n## Unreleased\n" not in text["changelog"]:
        return fail("CHANGELOG.md has no '## Unreleased' section to release")
    out["changelog"] = text["changelog"].replace(
        "\n## Unreleased\n", "\n## %s — %s\n" % (version, date), 1)

    for key, content in out.items():
        with open(paths[key], "w", encoding="utf-8") as f:
            f.write(content)
    print("released %s (%s)" % (version, date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
