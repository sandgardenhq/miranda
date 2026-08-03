#!/usr/bin/env bash
# Cursor stop/sessionStart/sessionEnd hook entrypoint. Cursor's hook payloads
# carry no token usage or cost data (verified against cursor.com/docs/hooks),
# so this calls the collector's "hook-cursor" subcommand — a deliberate no-op
# until the Team/Enterprise Admin API adapter exists (see
# packages/collector/src/hooks.ts, runHookCursor). Never fails the hook: a
# missing node or an unstaged stub just means nothing runs, same as Claude
# Code's hooks.json guard.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB="$DIR/../collector/stub.mjs"
command -v node >/dev/null 2>&1 && [ -f "$STUB" ] && exec node "$STUB" hook-cursor
exit 0
