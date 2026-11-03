#!/usr/bin/env python3
"""gen_docs.py — render the rule tables and lists from scripts/rules.py.

Rewrites the blocks between `<!-- generated:NAME -->` and
`<!-- /generated:NAME -->` in README.md and CLAUDE.md.template.

Usage:
  python3 tools/gen_docs.py            regenerate in place
  python3 tools/gen_docs.py --check    exit 1 if any block is stale
  ... --root <dir>                     operate on <dir> instead of the repo
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

import rules  # noqa: E402


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def table(hook, with_gate):
    head = "| ID | Catches | Fix |" + (" Gate |" if with_gate else "")
    sep = "|---|---|---|" + ("---|" if with_gate else "")
    rows = []
    for r in rules.RULES:
        if r["hook"] != hook:
            continue
        row = "| %s | %s | %s |" % (r["id"], cell(r["catches"]), cell(r["fix"]))
        if with_gate:
            row += " %s |" % rules.gate_label(r["gate"])
        rows.append(row)
    return "\n".join([head, sep] + rows)


def rule_list():
    def item(r):
        # The template targets v20+ workspaces, so only narrower gates are named.
        gate = "" if r["gate"] in (None, "v20") else ", %s only" % rules.gate_label(r["gate"])
        return "- %s (%s%s)" % (r["rule"], r["id"], gate)

    out = []
    for section in rules.SECTIONS:
        items = [item(r) for r in rules.RULES if r["hook"] == "pre" and r["section"] == section]
        if items:
            out += ["## " + section, ""] + items + [""]
    out += ["## Advisory (flagged after the write, not blocked)", ""]
    out += [item(r) for r in rules.RULES if r["hook"] == "post"]
    return "\n".join(out)


BLOCKS = {
    "README.md": {
        "rules-bash": lambda: table("bash", with_gate=False),
        "rules-pre": lambda: table("pre", with_gate=True),
        "rules-post": lambda: table("post", with_gate=True),
    },
    "CLAUDE.md.template": {
        "rules-list": rule_list,
    },
}


def render(text, name, body):
    pattern = re.compile(r"(<!-- generated:%s -->\n).*?(\n<!-- /generated:%s -->)"
                         % (re.escape(name), re.escape(name)), re.S)
    if not pattern.search(text):
        raise SystemExit("missing <!-- generated:%s --> block" % name)
    return pattern.sub(lambda m: m.group(1) + body + m.group(2), text)


def main(argv):
    check = "--check" in argv
    root = argv[argv.index("--root") + 1] if "--root" in argv else REPO
    stale = []
    for filename, blocks in BLOCKS.items():
        path = os.path.join(root, filename)
        with open(path, encoding="utf-8") as f:
            old = f.read()
        new = old
        for name, build in blocks.items():
            new = render(new, name, build())
        if new != old:
            stale.append(filename)
            if not check:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(new)
    if check and stale:
        print("stale generated docs: %s — run python3 tools/gen_docs.py" % ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
