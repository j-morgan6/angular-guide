#!/usr/bin/env bash
# detect_project.sh — SessionStart hook for angular-guide.
# Detects the Angular workspace for this session (walking up, then a bounded
# search down for a monorepo), caches its profile in the plugin data dir, and
# prints a summary into the session context. See ag_profile.py.
#
# Fails open: no workspace, or anything unexpected, exits 0 silently.

python3 -I "$(dirname "$0")/ag_profile.py" session "$PWD" 2>/dev/null
exit 0
