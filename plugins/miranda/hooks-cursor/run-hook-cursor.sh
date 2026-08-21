#!/usr/bin/env bash
# Cursor stop/sessionStart/sessionEnd hook entrypoint. Cursor's hook payloads
# carry no token usage or cost data (verified against cursor.com/docs/hooks),
# so this calls the collector's "hook-cursor" subcommand — a deliberate no-op
# until the Team/Enterprise Admin API adapter exists (see
# packages/collector/src/hooks.ts, runHookCursor). The collector is fronted by
# a POSIX-sh download stub (#761), so no JS runtime is required here. Never
# fails the hook: an unstaged stub just means nothing runs, same as Claude
# Code's hooks.json guard.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB="$DIR/../collector/stub.sh"
[ -f "$STUB" ] && exec sh "$STUB" hook-cursor
exit 0
